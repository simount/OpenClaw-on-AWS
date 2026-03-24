#!/bin/bash
# NemoClaw + LiteLLM setup script for OpenClaw on AWS
# Called from UserData when EnableSandbox=true
# Arguments: $1=AWS_REGION $2=OpenClawModel $3=GATEWAY_TOKEN
set -uo pipefail
export HOME="${HOME:-/root}"
AWS_REGION="${1:?Region required}"
MODEL="${2:?Model required}"
GATEWAY_TOKEN="${3:?Token required}"

# ── Step 1: Install and start LiteLLM proxy ──────────────────────────
echo "[4.5/9] Installing LiteLLM proxy..."
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
# LiteLLM listens on 0.0.0.0 so sandbox can reach it via host.openshell.internal
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
echo "Waiting for LiteLLM..."
for i in $(seq 1 30); do
  curl -s http://127.0.0.1:4000/health 2>/dev/null | grep -q "healthy" && echo "LiteLLM healthy" && break
  sleep 2
done

# ── Step 2: Write OpenClaw config BEFORE NemoClaw install ─────────────
# nemoclaw onboard copies $HOME/.openclaw/openclaw.json into the sandbox.
echo "[5/9] Pre-staging OpenClaw config..."
mkdir -p /root/.openclaw
python3 -c "
import json
t='$GATEWAY_TOKEN'
cfg={
  'gateway':{
    'mode':'local',
    'port':18789,
    'bind':'loopback',
    'controlUi':{
      'enabled':True,
      'allowInsecureAuth':True,
      'allowedOrigins':['http://localhost:18789','http://127.0.0.1:18789']
    },
    'auth':{'mode':'token','token':t}
  }
}
json.dump(cfg,open('/root/.openclaw/openclaw.json','w'),indent=2)
"

# ── Step 3: Install NemoClaw (--non-interactive runs onboard automatically) ──
# Note: NIM API key is not provided, so onboard stops at [4/7] "Configuring inference".
# This is expected — we configure inference ourselves via openshell provider/inference.
echo "[6/9] Installing NemoClaw (includes onboard)..."
curl -fsSL https://www.nvidia.com/nemoclaw.sh -o /tmp/nc.sh
bash /tmp/nc.sh --non-interactive || bash /tmp/nc.sh --non-interactive
rm -f /tmp/nc.sh

# Add NVM node to PATH (NemoClaw installer installs its own node via nvm)
NVM_NODE=$(find /root/.nvm/versions/node -name node -type f 2>/dev/null | head -1)
if [ -n "$NVM_NODE" ]; then
  export PATH="$(dirname "$NVM_NODE"):$PATH"
fi
export PATH="/root/.local/bin:$PATH"

# Wait for sandbox to be ready (nemoclaw onboard creates it)
echo "Waiting for sandbox to be ready..."
for i in $(seq 1 30); do
  SANDBOX_NAME=$(openshell sandbox list 2>/dev/null | awk 'NR==2{print $1}')
  if [ -n "$SANDBOX_NAME" ]; then
    echo "Sandbox ready: $SANDBOX_NAME"
    break
  fi
  sleep 5
done
[ -z "$SANDBOX_NAME" ] && SANDBOX_NAME="my-assistant"

# ── Step 4: Configure inference to use LiteLLM via OpenShell ──────────
# The sandbox reaches LiteLLM on the host via host.openshell.internal.
echo "[7/9] Configuring LiteLLM inference provider..."
openshell provider create \
  --name litellm-bedrock \
  --type openai \
  --credential OPENAI_API_KEY=sk-dummy \
  --config OPENAI_BASE_URL=http://host.openshell.internal:4000/v1 \
  2>&1 || echo "Provider create failed (may already exist)"

openshell inference set \
  --provider litellm-bedrock \
  --model "$MODEL" \
  --no-verify \
  2>&1 || echo "Inference route set failed"

# ── Step 5: Set up persistent port forward ────────────────────────────
echo "[7.5/9] Setting up port forwarding..."

cat > /usr/local/bin/openshell-forward-wrapper.sh << 'FWDEOF'
#!/bin/bash
export HOME=/root
export PATH="/root/.local/bin:$PATH"
SANDBOX="$1"
# Start the forward (spawns an SSH tunnel child process)
/usr/local/bin/openshell forward start 18789 "$SANDBOX" &
FWD_PID=$!
# Wait for the port to be ready
for i in $(seq 1 30); do
  if ss -tlnp | grep -q :18789; then break; fi
  sleep 1
done
# Keep alive: monitor port, exit if tunnel dies
while ss -tlnp | grep -q :18789; do
  sleep 10
done
FWDEOF
chmod +x /usr/local/bin/openshell-forward-wrapper.sh

cat > /etc/systemd/system/openshell-forward.service << EOF
[Unit]
Description=OpenShell Port Forward 18789
After=network.target docker.service
StartLimitIntervalSec=60
StartLimitBurst=10
[Service]
Type=simple
Environment=HOME=/root
Environment=PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/openshell-forward-wrapper.sh $SANDBOX_NAME
Restart=always
RestartSec=5
KillMode=process
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable openshell-forward && systemctl start openshell-forward

echo "NemoClaw + LiteLLM setup complete"
