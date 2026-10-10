#!/bin/sh
set -eu

PUBLIC_PORT="${PORT:-10000}"
export N8N_PORT="${N8N_PORT:-5678}"
export N8N_LISTEN_ADDRESS="${N8N_LISTEN_ADDRESS:-127.0.0.1}"
export N8N_PROTOCOL="http"

mkdir -p /root/.n8n /tmp/eg365-output

echo "EG365_BOOT: starting_public_renderer"
exec_renderer() {
  /opt/venv/bin/uvicorn app:app --app-dir /opt/renderer --host 0.0.0.0 --port "$PUBLIC_PORT"
}
/opt/venv/bin/uvicorn app:app --app-dir /opt/renderer --host 0.0.0.0 --port "$PUBLIC_PORT" >/tmp/renderer.log 2>&1 &
RPID=$!

cleanup() {
  kill "$RPID" 2>/dev/null || true
  [ -n "${NPID:-}" ] && kill "$NPID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

i=0
until curl -fsS "http://127.0.0.1:$PUBLIC_PORT/health" >/dev/null 2>&1; do
  i=$((i+1))
  if [ "$i" -gt 40 ]; then
    echo "EG365_BOOT_ERROR: renderer_failed"
    cat /tmp/renderer.log || true
    exit 1
  fi
  sleep 1
done
echo "EG365_BOOT: renderer_ready"

# Restore encrypted SQLite state when a previous cloud backup exists.
if [ -n "${STATE_BACKUP_URL:-}" ] && [ -n "${STATE_BACKUP_KEY:-}" ]; then
  echo "EG365_BOOT: checking_state_backup"
  if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "$STATE_BACKUP_URL" -o /tmp/eg365-state.fernet; then
    if /opt/venv/bin/python - <<'PY'
from pathlib import Path
import os
from cryptography.fernet import Fernet
src=Path('/tmp/eg365-state.fernet')
dst=Path('/root/.n8n/database.sqlite')
key=os.environ['STATE_BACKUP_KEY'].encode()
raw=Fernet(key).decrypt(src.read_bytes())
dst.write_bytes(raw)
print('EG365_BOOT: state_restore_ok bytes='+str(len(raw)))
PY
    then
      :
    else
      echo "EG365_BOOT_ERROR: state_restore_failed"
      exit 1
    fi
  else
    echo "EG365_BOOT: no_previous_state"
  fi
fi

# Inject runtime secrets only inside the ephemeral container.
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
    if val and val != 'PENDING':
        s=s.replace(ph,val)
    elif activate:
        missing.append(k)
if missing:
    raise SystemExit('Missing required env for activation: '+','.join(missing))
p.write_text(s,encoding='utf-8')
PY

echo "EG365_BOOT: importing_workflow"
if ! timeout 120 n8n import:workflow --input=/opt/workflow/EG365_CLOUD_RENDER_V128.json; then
  echo "EG365_BOOT_ERROR: workflow_import_failed_or_timed_out"
  exit 1
fi
echo "EG365_BOOT: workflow_import_ok"

if [ "${CLOUD_ACTIVATE:-false}" = "true" ]; then
  echo "EG365_BOOT: activating_workflow"
  if ! n8n update:workflow --id=EG365CLOUDRENDERV128 --active=true; then
    echo "EG365_BOOT_ERROR: activation_failed"
    exit 1
  fi
else
  echo "EG365_BOOT: keeping_workflow_inactive"
  n8n update:workflow --id=EG365CLOUDRENDERV128 --active=false >/dev/null 2>&1 || true
fi

echo "EG365_BOOT: starting_n8n_internal"
n8n start >/tmp/n8n.log 2>&1 &
NPID=$!

i=0
until curl -fsS "http://127.0.0.1:$N8N_PORT/healthz" >/dev/null 2>&1; do
  i=$((i+1))
  if ! kill -0 "$NPID" 2>/dev/null; then
    echo "EG365_BOOT_ERROR: n8n_exited"
    cat /tmp/n8n.log || true
    exit 1
  fi
  if [ "$i" -gt 120 ]; then
    echo "EG365_BOOT_ERROR: n8n_health_timeout"
    cat /tmp/n8n.log || true
    exit 1
  fi
  sleep 1
done
echo "EG365_BOOT: n8n_ready"
echo "EG365_BOOT: cloud_ready"

wait "$NPID"
