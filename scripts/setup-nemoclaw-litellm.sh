#!/bin/bash
# NemoClaw + LiteLLM setup script for OpenClaw on AWS
# Called from UserData when EnableSandbox=true
# Arguments: $1=AWS_REGION $2=OpenClawModel $3=GATEWAY_TOKEN
set -e
export HOME="${HOME:-/root}"
AWS_REGION="${1:?Region required}"
MODEL="${2:?Model required}"
GATEWAY_TOKEN="${3:?Token required}"

echo "[4.5/9] Installing LiteLLM proxy..."
apt-get install -y python3-pip python3-venv
python3 -m venv /opt/litellm
/opt/litellm/bin/pip install 'litellm[proxy]'
mkdir -p /etc/litellm
python3 -c "
import yaml
models=[('global.amazon.nova-2-lite-v1:0','amazon.nova-lite-v1:0'),('global.anthropic.claude-sonnet-4-5-20250929-v1:0','anthropic.claude-sonnet-4-5-20250929-v1:0'),('us.amazon.nova-pro-v1:0','amazon.nova-pro-v1:0'),('global.anthropic.claude-opus-4-6-v1','anthropic.claude-opus-4-6-v1'),('global.anthropic.claude-opus-4-5-20251101-v1:0','anthropic.claude-opus-4-5-20251101-v1:0'),('global.anthropic.claude-haiku-4-5-20251001-v1:0','anthropic.claude-haiku-4-5-20251001-v1:0'),('global.anthropic.claude-sonnet-4-20250514-v1:0','anthropic.claude-sonnet-4-20250514-v1:0'),('us.deepseek.r1-v1:0','deepseek.r1-v1:0'),('us.meta.llama3-3-70b-instruct-v1:0','meta.llama3-3-70b-instruct-v1:0'),('moonshotai.kimi-k2.5','moonshotai.kimi-k2.5')]
r='$AWS_REGION'
cfg={'model_list':[{'model_name':n,'litellm_params':{'model':'bedrock/'+m,'aws_region_name':r}} for n,m in models],'general_settings':{'master_key':None}}
yaml.dump(cfg,open('/etc/litellm/config.yaml','w'),default_flow_style=False)
"
printf '[Unit]\nDescription=LiteLLM Proxy\nAfter=network.target\n[Service]\nType=simple\nUser=ubuntu\nExecStart=/opt/litellm/bin/litellm --config /etc/litellm/config.yaml --host 127.0.0.1 --port 4000\nRestart=always\nRestartSec=5\nEnvironment=AWS_DEFAULT_REGION=%s\nEnvironment=AWS_REGION=%s\n[Install]\nWantedBy=multi-user.target\n' "$AWS_REGION" "$AWS_REGION" > /etc/systemd/system/litellm.service
systemctl daemon-reload && systemctl enable litellm && systemctl start litellm
echo "Waiting for LiteLLM..."
for i in $(seq 1 30); do
  curl -s http://127.0.0.1:4000/health 2>/dev/null | grep -q "healthy" && echo "LiteLLM healthy" && break
  sleep 2
done

echo "[5.5/9] Installing NemoClaw (OpenShell)..."
curl -fsSL https://www.nvidia.com/nemoclaw.sh -o /tmp/nc.sh
bash /tmp/nc.sh --non-interactive || bash /tmp/nc.sh --non-interactive
rm -f /tmp/nc.sh
openshell sandbox create --from openclaw --name openclaw-sandbox || true
mkdir -p /etc/nemoclaw/policies
python3 -c "
import yaml
p={'version':1,'filesystem_policy':{'include_workdir':True,'read_only':['/usr','/lib','/proc','/etc'],'read_write':['/home/ubuntu/.openclaw','/tmp']},'landlock':{'compatibility':'best_effort'},'process':{'run_as_user':'ubuntu','run_as_group':'ubuntu'},'network_policies':{'litellm_proxy':{'name':'litellm-bedrock-proxy','endpoints':[{'host':'127.0.0.1','port':4000,'enforcement':'enforce','access':'full'}]}}}
yaml.dump(p,open('/etc/nemoclaw/policies/strict-bedrock.yaml','w'),default_flow_style=False)
"
openshell policy set openclaw-sandbox --policy /etc/nemoclaw/policies/strict-bedrock.yaml || true

echo "[8/9] Configuring OpenClaw for NemoClaw..."
sudo -u ubuntu mkdir -p /home/ubuntu/.openclaw
python3 -c "
import json,os
t='$GATEWAY_TOKEN'
r='$AWS_REGION'
m='$MODEL'
gw={'mode':'local','port':18789,'bind':'loopback','controlUi':{'enabled':True,'allowInsecureAuth':True},'auth':{'mode':'token','token':t}}
mi={'id':m,'name':'Bedrock Model','input':['text','image'],'contextWindow':200000,'maxTokens':8192}
prov={'litellm':{'baseUrl':'http://127.0.0.1:4000','api':'openai','auth':'none','models':[mi]}}
prim='litellm/'+m
cfg={'gateway':gw,'models':{'providers':prov},'agents':{'defaults':{'model':{'primary':prim}}}}
json.dump(cfg,open('/home/ubuntu/.openclaw/openclaw.json','w'),indent=2)
"
chown ubuntu:ubuntu /home/ubuntu/.openclaw/openclaw.json

echo "Starting OpenClaw in NemoClaw sandbox..."
openshell sandbox upload openclaw-sandbox /home/ubuntu/.openclaw /home/ubuntu/.openclaw || true
printf '[Unit]\nDescription=OpenClaw in NemoClaw Sandbox\nAfter=litellm.service docker.service\nRequires=litellm.service docker.service\n[Service]\nType=simple\nUser=root\nExecStartPre=/usr/local/bin/openshell policy set openclaw-sandbox --policy /etc/nemoclaw/policies/strict-bedrock.yaml\nExecStart=/usr/local/bin/openshell sandbox connect openclaw-sandbox --exec "OPENAI_API_BASE=http://127.0.0.1:4000 OPENAI_API_KEY=dummy-key-for-litellm openclaw gateway"\nExecStartPost=/usr/local/bin/openshell forward start 18789 openclaw-sandbox -d\nExecStop=/usr/local/bin/openshell forward stop 18789 openclaw-sandbox\nRestart=always\nRestartSec=5\nEnvironment=HOME=/home/ubuntu\nEnvironment=AWS_REGION=%s\nEnvironment=AWS_DEFAULT_REGION=%s\n[Install]\nWantedBy=multi-user.target\n' "$AWS_REGION" "$AWS_REGION" > /etc/systemd/system/openclaw-nemoclaw.service
systemctl daemon-reload && systemctl enable openclaw-nemoclaw && systemctl start openclaw-nemoclaw
echo "NemoClaw + LiteLLM setup complete"
