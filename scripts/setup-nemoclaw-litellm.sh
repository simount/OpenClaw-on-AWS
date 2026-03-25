#!/bin/bash
# NemoClaw + LiteLLM setup script for OpenClaw on AWS
# Called from UserData when EnableSandbox=true
# Arguments: $1=AWS_REGION $2=OpenClawModel $3=GATEWAY_TOKEN
#
# Architecture:
#   Browser → SSM port forward → host:18789 (SSH LocalForward)
#     → sandbox:18789 (OpenClaw Gateway)
#     → https://inference.local (OpenShell managed inference proxy)
#     → host.openshell.internal:4000 (LiteLLM)
#     → Amazon Bedrock
set -uo pipefail
export HOME="${HOME:-/root}"
export PATH="/root/.local/bin:$PATH"

AWS_REGION="${1:?Region required}"
MODEL="${2:?Model required}"
GATEWAY_TOKEN="${3:?Token required}"

SANDBOX_NAME="openclaw"

# ── Helper functions ──────────────────────────────────────────────────
wait_for() {
  local desc="$1" cmd="$2" max="${3:-30}" interval="${4:-2}"
  echo "  Waiting for $desc..."
  for i in $(seq 1 "$max"); do
    if eval "$cmd" >/dev/null 2>&1; then
      echo "  $desc ready (${i}/${max})"
      return 0
    fi
    sleep "$interval"
  done
  echo "  WARNING: $desc not ready after $((max * interval))s"
  return 1
}

ssh_sandbox() {
  sudo -u ubuntu ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 openshell-${SANDBOX_NAME} "$@"
}

# ── Step 1: Set inotify limits (required for k3s inside Docker) ───────
echo "[1/10] Setting inotify limits for OpenShell k3s..."
sysctl -w fs.inotify.max_user_instances=512
sysctl -w fs.inotify.max_user_watches=524288
cat > /etc/sysctl.d/99-openshell.conf << 'EOF'
fs.inotify.max_user_instances=512
fs.inotify.max_user_watches=524288
EOF

# ── Step 2: Install and start LiteLLM proxy ───────────────────────────
echo "[2/10] Installing LiteLLM proxy..."
apt-get install -y python3-pip python3-venv python3-yaml
python3 -m venv /opt/litellm
/opt/litellm/bin/pip install 'litellm[proxy]'
mkdir -p /etc/litellm

python3 -c "
import yaml
models=[
  ('global.amazon.nova-2-lite-v1:0','amazon.nova-lite-v1:0'),
  ('global.anthropic.claude-sonnet-4-5-20250929-v1:0','anthropic.claude-sonnet-4-5-20250929-v1:0'),
  ('us.amazon.nova-pro-v1:0','amazon.nova-pro-v1:0'),
  ('global.anthropic.claude-opus-4-6-v1','anthropic.claude-opus-4-6-v1'),
  ('global.anthropic.claude-opus-4-5-20251101-v1:0','anthropic.claude-opus-4-5-20251101-v1:0'),
  ('global.anthropic.claude-haiku-4-5-20251001-v1:0','anthropic.claude-haiku-4-5-20251001-v1:0'),
  ('global.anthropic.claude-sonnet-4-20250514-v1:0','anthropic.claude-sonnet-4-20250514-v1:0'),
  ('us.deepseek.r1-v1:0','deepseek.r1-v1:0'),
  ('us.meta.llama3-3-70b-instruct-v1:0','meta.llama3-3-70b-instruct-v1:0'),
  ('moonshotai.kimi-k2.5','moonshotai.kimi-k2.5')
]
r='$AWS_REGION'
cfg={
  'model_list':[{'model_name':n,'litellm_params':{'model':'bedrock/'+m,'aws_region_name':r}} for n,m in models],
  'general_settings':{'master_key':None}
}
yaml.dump(cfg,open('/etc/litellm/config.yaml','w'),default_flow_style=False)
"

cat > /etc/systemd/system/litellm.service << EOF
[Unit]
Description=LiteLLM Proxy
After=network.target
[Service]
Type=simple
User=ubuntu
ExecStart=/opt/litellm/bin/litellm --config /etc/litellm/config.yaml --host 0.0.0.0 --port 4000
Restart=always
RestartSec=5
Environment=AWS_DEFAULT_REGION=$AWS_REGION
Environment=AWS_REGION=$AWS_REGION
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable litellm && systemctl start litellm

wait_for "LiteLLM health" "curl -sf http://127.0.0.1:4000/health" 30 2

# ── Step 3: Install OpenShell CLI via NemoClaw installer ──────────────
echo "[3/10] Installing OpenShell CLI..."
export NVIDIA_API_KEY=dummy-sk
curl -fsSL https://www.nvidia.com/nemoclaw.sh -o /tmp/nc.sh
bash /tmp/nc.sh --non-interactive || echo "NemoClaw install completed (warnings expected without real NVIDIA_API_KEY)"
rm -f /tmp/nc.sh

# Ensure openshell is in PATH
if ! command -v openshell &>/dev/null; then
  for p in /usr/local/bin/openshell /root/.local/bin/openshell; do
    [ -x "$p" ] && export PATH="$(dirname "$p"):$PATH" && break
  done
fi
echo "openshell version: $(openshell --version 2>&1 || echo 'not found')"

# ── Step 4: Start OpenShell gateway ───────────────────────────────────
echo "[4/10] Starting OpenShell gateway..."
# Destroy any leftover gateway from NemoClaw installer
openshell gateway destroy --name nemoclaw 2>/dev/null || true
docker rm -f openshell-cluster-nemoclaw 2>/dev/null || true
sleep 3

openshell gateway start --name nemoclaw --plaintext --port 18789
openshell gateway select nemoclaw
wait_for "gateway container healthy" \
  "docker inspect openshell-cluster-nemoclaw --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy" 60 3

# ── Step 5: Fix host.openshell.internal IP ────────────────────────────
echo "[5/10] Fixing host.openshell.internal IP mapping..."
# The k3s cluster container is on its own Docker network (e.g. 172.18.0.0/16).
# OpenShell defaults host.openshell.internal to 172.17.0.1 (docker0), which is
# unreachable from inside the cluster. We need to point it to the actual gateway IP.
GATEWAY_IP=$(docker inspect openshell-cluster-nemoclaw \
  --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')
echo "  Docker network gateway IP: $GATEWAY_IP"

# Fix /etc/hosts inside the k3s cluster container
docker exec openshell-cluster-nemoclaw sh -c \
  "echo $GATEWAY_IP host.openshell.internal host.docker.internal >> /etc/hosts"

# Verify LiteLLM is reachable from inside the cluster
wait_for "LiteLLM from cluster" \
  "docker exec openshell-cluster-nemoclaw wget -q -O/dev/null --timeout=5 http://host.openshell.internal:4000/health" 10 3

# ── Step 6: Create provider and set inference route ───────────────────
echo "[6/10] Configuring inference provider..."
openshell provider create \
  --name litellm-bedrock \
  --type openai \
  --credential "OPENAI_API_KEY=sk-litellm" \
  --config "OPENAI_BASE_URL=http://host.openshell.internal:4000/v1"

openshell inference set \
  --provider litellm-bedrock \
  --model "$MODEL"

echo "  Inference route: inference.local -> litellm-bedrock -> $MODEL"

# ── Step 7: Write sandbox policy ──────────────────────────────────────
echo "[7/10] Creating sandbox policy..."
cat > /tmp/sandbox-policy.yaml << 'POLICYEOF'
version: 1
network_policies:
  outbound:
    name: litellm-access
    endpoints:
      - host: host.openshell.internal
        port: 4000
      - host: host.docker.internal
        port: 4000
      - host: "*.githubusercontent.com"
        port: 443
      - host: github.com
        port: 443
POLICYEOF

# ── Step 8: Create sandbox ────────────────────────────────────────────
echo "[8/10] Creating sandbox..."
openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
openshell sandbox create \
  --name "$SANDBOX_NAME" \
  --from openclaw \
  --provider litellm-bedrock \
  --policy /tmp/sandbox-policy.yaml \
  --no-tty

wait_for "sandbox ready" \
  "openshell sandbox list 2>/dev/null | grep -q '$SANDBOX_NAME.*Ready'" 60 3

# Patch Sandbox CRD hostAliases to use correct gateway IP, then recreate pod
echo "  Patching sandbox hostAliases to $GATEWAY_IP..."
docker exec openshell-cluster-nemoclaw kubectl patch sandbox "$SANDBOX_NAME" -n openshell \
  --type=merge \
  -p "{\"spec\":{\"podTemplate\":{\"spec\":{\"hostAliases\":[{\"ip\":\"$GATEWAY_IP\",\"hostnames\":[\"host.docker.internal\",\"host.openshell.internal\"]}]}}}}"

docker exec openshell-cluster-nemoclaw kubectl delete pod "$SANDBOX_NAME" -n openshell
wait_for "sandbox pod running" \
  "docker exec openshell-cluster-nemoclaw kubectl get pod $SANDBOX_NAME -n openshell -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running" 60 3

# Setup SSH config for sandbox access
sudo -u ubuntu bash -c "
  mkdir -p ~/.ssh
  openshell sandbox ssh-config $SANDBOX_NAME > ~/.ssh/openshell-sandbox.conf 2>/dev/null
  grep -q 'Include.*openshell-sandbox' ~/.ssh/config 2>/dev/null || \
    echo 'Include ~/.ssh/openshell-sandbox.conf' >> ~/.ssh/config
"

# ── Step 9: Configure OpenClaw inside sandbox ─────────────────────────
echo "[9/10] Configuring OpenClaw inside sandbox..."

# Create required directories inside sandbox (must be done from inside, not via overlayfs)
ssh_sandbox "chmod 777 /sandbox/.openclaw"
ssh_sandbox "mkdir -p /sandbox/.openclaw/identity /sandbox/.openclaw/canvas /sandbox/.openclaw/cron"

# Generate OpenClaw config JSON
# Key: baseUrl uses https://inference.local/v1 (OpenShell managed inference proxy)
python3 -c "
import json
t='$GATEWAY_TOKEN'
m='$MODEL'
cfg={
  'gateway':{
    'mode':'local',
    'port':18789,
    'bind':'lan',
    'controlUi':{
      'enabled':True,
      'allowInsecureAuth':True,
      'dangerouslyAllowHostHeaderOriginFallback':True
    },
    'auth':{'mode':'token','token':t}
  },
  'models':{
    'providers':{
      'nvidia':{
        'baseUrl':'https://inference.local/v1',
        'api':'openai-completions',
        'auth':'api-key',
        'apiKey':'sk-1234',
        'models':[{
          'id':m,
          'name':'Bedrock Model via LiteLLM',
          'input':['text','image'],
          'contextWindow':300000,
          'maxTokens':5120
        }]
      }
    }
  },
  'agents':{'defaults':{'model':{'primary':'nvidia/'+m}}}
}
json.dump(cfg,open('/tmp/openclaw.json','w'),indent=2)
"

# Deliver config to sandbox via SSH (not overlayfs — avoids stale file handle issues)
cat /tmp/openclaw.json | sudo -u ubuntu ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  openshell-${SANDBOX_NAME} "tee /sandbox/.openclaw/openclaw.json > /dev/null"

# Verify config
ssh_sandbox "openclaw config validate" || echo "Config validation failed (non-fatal)"

# Write and deliver start script
cat > /tmp/start-gw.sh << 'GWEOF'
#!/bin/sh
export HOME=/sandbox
export NVIDIA_API_KEY=sk-1234
export ANTHROPIC_API_KEY=sk-1234
export NODE_TLS_REJECT_UNAUTHORIZED=0
cd /sandbox
nohup openclaw gateway >/tmp/openclaw-gw.log 2>&1 &
echo $!
GWEOF

cat /tmp/start-gw.sh | sudo -u ubuntu ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  openshell-${SANDBOX_NAME} "tee /sandbox/start-gw.sh > /dev/null && chmod +x /sandbox/start-gw.sh"

# Start OpenClaw gateway inside sandbox
ssh_sandbox "sh /sandbox/start-gw.sh"
sleep 5
ssh_sandbox "ss -tlnp | grep 18789" && echo "  OpenClaw gateway running on sandbox:18789" || echo "  WARNING: Gateway not listening yet"

# ── Step 10: SSH LocalForward + systemd service ───────────────────────
echo "[10/10] Setting up SSH port forward (host:18789 -> sandbox:18789)..."

# Create systemd service for persistent SSH LocalForward
cat > /etc/systemd/system/openshell-forward.service << EOF
[Unit]
Description=SSH LocalForward to OpenClaw sandbox (host:18789 -> sandbox:18789)
After=network.target docker.service
StartLimitIntervalSec=0
[Service]
Type=simple
User=ubuntu
ExecStart=/usr/bin/ssh -N -L 0.0.0.0:18789:127.0.0.1:18789 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes openshell-${SANDBOX_NAME}
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openshell-forward
systemctl start openshell-forward

wait_for "SSH port forward on 18789" "ss -tlnp | grep -q ':18789'" 15 2

# ── Store gateway token in SSM Parameter Store ────────────────────────
aws ssm put-parameter \
  --name "/openclaw/gateway-token" \
  --value "$GATEWAY_TOKEN" \
  --type SecureString \
  --overwrite \
  --region "$AWS_REGION" 2>/dev/null || echo "SSM parameter store failed (non-fatal)"

# ── Done ──────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " NemoClaw + LiteLLM setup complete"
echo "============================================"
echo "  Sandbox:    $SANDBOX_NAME (OpenClaw $(ssh_sandbox 'openclaw --version 2>&1' | grep -oP '[\d.]+' | head -1))"
echo "  Model:      $MODEL"
echo "  Inference:  https://inference.local -> LiteLLM:4000 -> Bedrock"
echo "  Dashboard:  http://localhost:18789/#token=$GATEWAY_TOKEN"
echo "  Access:     aws ssm start-session --target INSTANCE_ID \\"
echo "                --document-name AWS-StartPortForwardingSession \\"
echo "                --parameters '{\"portNumber\":[\"18789\"],\"localPortNumber\":[\"18789\"]}'"
echo ""
