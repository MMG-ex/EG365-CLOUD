#!/bin/sh
set -eu

PORT="${PORT:-10000}"
export N8N_PORT="$PORT"
export N8N_LISTEN_ADDRESS="0.0.0.0"

mkdir -p /home/node/.n8n /tmp/eg365-output

python3 - <<'PY'
from pathlib import Path
import os
p=Path('/opt/workflow/EG365_CLOUD_RENDER_V128.json')
s=p.read_text(encoding='utf-8')
keys=[
'OPENAI_API_KEY','TELEGRAM_BOT_TOKEN','TELEGRAM_CHAT_ID','TELEGRAM_PUBLIC_URL',
'INSTAGRAM_USER_ID','INSTAGRAM_ACCESS_TOKEN','THREADS_ACCESS_TOKEN',
'FACEBOOK_PAGE_ID','FACEBOOK_PAGE_ACCESS_TOKEN'
]
activate=os.environ.get('CLOUD_ACTIVATE','false').lower()=='true'
missing=[]
for k in keys:
    ph='__'+k+'__'
    val=os.environ.get(k,'')
    if val:
        s=s.replace(ph,val)
    elif activate:
        missing.append(k)
if missing:
    raise SystemExit('Missing required env for activation: '+','.join(missing))
p.write_text(s,encoding='utf-8')
PY

/opt/venv/bin/uvicorn app:app --app-dir /opt/renderer --host 127.0.0.1 --port 8787 >/tmp/renderer.log 2>&1 &
RPID=$!

cleanup() { kill "$RPID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

i=0
until curl -fsS http://127.0.0.1:8787/health >/dev/null 2>&1; do
  i=$((i+1))
  if [ "$i" -gt 40 ]; then
    echo "Renderer failed to become ready"
    cat /tmp/renderer.log || true
    exit 1
  fi
  sleep 1
done

echo "EG365_BOOT: renderer_ready"
echo "EG365_BOOT: importing_workflow"
if ! timeout 120 n8n import:workflow --input=/opt/workflow/EG365_CLOUD_RENDER_V128.json; then
  echo "EG365_BOOT_ERROR: workflow_import_failed_or_timed_out"
  exit 1
fi
echo "EG365_BOOT: workflow_import_ok"

if [ "${CLOUD_ACTIVATE:-false}" = "true" ]; then
  n8n update:workflow --id=EG365CLOUDRENDERV128 --active=true >/tmp/n8n-activate.log 2>&1 || {
    cat /tmp/n8n-activate.log
    exit 1
  }
else
  n8n update:workflow --id=EG365CLOUDRENDERV128 --active=false >/tmp/n8n-inactivate.log 2>&1 || true
fi

echo "EG365_BOOT: starting_n8n"
exec n8n start
