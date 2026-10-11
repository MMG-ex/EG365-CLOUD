#!/bin/sh
set -eu

PUBLIC_PORT="${PORT:-10000}"
export N8N_PORT="${N8N_PORT:-5678}"
export N8N_LISTEN_ADDRESS="${N8N_LISTEN_ADDRESS:-127.0.0.1}"
export N8N_PROTOCOL="http"

mkdir -p /root/.n8n /tmp/eg365-output

RPID=""
NPID=""
MPID=""
KPID=""

cleanup() {
  [ -n "${RPID:-}" ] && kill "$RPID" 2>/dev/null || true
  [ -n "${NPID:-}" ] && kill "$NPID" 2>/dev/null || true
  [ -n "${MPID:-}" ] && kill "$MPID" 2>/dev/null || true
  [ -n "${KPID:-}" ] && kill "$KPID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

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
stored={}
db_path=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
try:
    import sqlite3
    if os.path.exists(db_path):
        con=sqlite3.connect(db_path,timeout=20)
        try:
            con.execute("CREATE TABLE IF NOT EXISTS eg365_secrets (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
            stored=dict(con.execute("SELECT k,v FROM eg365_secrets").fetchall())
        finally:
            con.close()
except Exception as e:
    print('EG365_BOOT: secret_store_read_warning='+str(e))
missing=[]
for k in keys:
    ph='__'+k+'__'
    val=os.environ.get(k,'')
    if not val or val == 'PENDING':
        val=stored.get(k,'')
    if val:
        s=s.replace(ph,val)
    elif activate:
        missing.append(k)
if missing:
    raise SystemExit('Missing required secrets for activation: '+','.join(missing))
p.write_text(s,encoding='utf-8')
PY

WF_SHA="$(sha256sum /opt/workflow/EG365_CLOUD_RENDER_V128.json | awk '{print $1}')"
export WF_SHA
NEED_IMPORT="$(/opt/venv/bin/python - <<'PY'
import os,sqlite3
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
sha=os.environ.get('WF_SHA','')
need='1'
if os.path.exists(db):
    con=sqlite3.connect(db,timeout=20)
    try:
        con.execute("CREATE TABLE IF NOT EXISTS eg365_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
        row=con.execute("SELECT v FROM eg365_meta WHERE k='workflow_sha'").fetchone()
        wf=con.execute("SELECT id FROM workflow_entity WHERE id='EG365CLOUDRENDERV128'").fetchone()
        if row and row[0]==sha and wf:
            need='0'
    except Exception:
        need='1'
    finally:
        con.close()
print(need)
PY
)"
export WF_SHA
if [ "$NEED_IMPORT" = "1" ]; then
  echo "EG365_BOOT: importing_workflow"
  if ! timeout 150 n8n import:workflow --input=/opt/workflow/EG365_CLOUD_RENDER_V128.json >/tmp/n8n-import.log 2>&1; then
    echo "EG365_BOOT_ERROR: workflow_import_failed_or_timed_out"
    tail -80 /tmp/n8n-import.log | sed -E 's/(token|api[_ -]?key|authorization)[^ ]*/[REDACTED]/Ig' || true
    exit 1
  fi
  /opt/venv/bin/python - <<'PY'
import os,sqlite3
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
sha=os.environ.get('WF_SHA','')
con=sqlite3.connect(db,timeout=20)
try:
    con.execute("CREATE TABLE IF NOT EXISTS eg365_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
    con.execute("INSERT INTO eg365_meta(k,v) VALUES('workflow_sha',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(sha,))
    con.commit()
finally:
    con.close()
PY
  echo "EG365_BOOT: workflow_import_ok"
else
  echo "EG365_BOOT: workflow_import_skipped_same_revision"
fi

SMOKE_ID="EG365CLOUDSMOKEV128"
if [ "${CLOUD_SMOKE_TEST:-false}" = "true" ]; then
  echo "EG365_SMOKE: preparing_dry_run_workflow"
  /opt/venv/bin/python - <<'PY'
from pathlib import Path
import json
src=Path('/opt/workflow/EG365_CLOUD_RENDER_V128.json')
dst=Path('/tmp/EG365_CLOUD_SMOKE_V128.json')
w=json.loads(src.read_text(encoding='utf-8'))
w['id']='EG365CLOUDSMOKEV128'
w['name']='EG365 CLOUD V128 - SMOKE DRY RUN'
w['active']=False
w['versionId']='12800000-0000-4000-8000-000000009999'
for n in w.get('nodes',[]):
    if n.get('name')=='CONFIG':
        code=((n.get('parameters') or {}).get('jsCode') or '')
        code=code.replace('dry_run: false','dry_run: true')
        n['parameters']['jsCode']=code
    if n.get('name')=='90 DAKİKADA BİR':
        n['parameters']={'rule':{'interval':[{'field':'minutes','minutesInterval':1}]}}
dst.write_text(json.dumps(w,ensure_ascii=False,indent=2),encoding='utf-8')
PY
  if ! timeout 120 n8n import:workflow --input=/tmp/EG365_CLOUD_SMOKE_V128.json >/tmp/eg365-smoke-import.log 2>&1; then
    echo "EG365_SMOKE_ERROR: import_failed"
    exit 1
  fi
  /opt/venv/bin/python - <<'PY'
import os,sqlite3
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
con=sqlite3.connect(db,timeout=20)
try:
    cols=[r[1] for r in con.execute("PRAGMA table_info(workflow_entity)").fetchall()]
    if 'staticData' in cols:
        con.execute("UPDATE workflow_entity SET staticData=NULL WHERE id='EG365CLOUDSMOKEV128'")
    con.execute("UPDATE workflow_entity SET active=0 WHERE id='EG365CLOUDSMOKEV128'")
    con.commit()
    print("EG365_SMOKE: static_state_cleared")
finally:
    con.close()
PY
  echo "EG365_SMOKE: executing_dry_run"
  if ! timeout 420 n8n execute --id="$SMOKE_ID" >/tmp/eg365-smoke.log 2>&1; then
    echo "EG365_SMOKE_ERROR: dry_run_execution_failed_or_timed_out"
    exit 1
  fi
  echo "EG365_SMOKE: dry_run_execution_ok"
  if ! /opt/venv/bin/python - <<'PY'
from pathlib import Path
import json,sys
p=Path('/tmp/eg365-smoke.log')
txt=p.read_text(encoding='utf-8',errors='replace') if p.exists() else ''
starts=[i for i,ch in enumerate(txt) if ch=='{']
obj=None
for i in starts:
    j=txt.rfind('}')
    if j<=i: continue
    try:
        cand=json.loads(txt[i:j+1])
        if isinstance(cand,dict) and ('data' in cand or 'status' in cand):
            obj=cand; break
    except Exception:
        pass
if not obj:
    print("EG365_SMOKE_VERIFY: cli_json_not_found")
    sys.exit(2)
status=str(obj.get('status') or '')
run=((obj.get('data') or {}).get('resultData') or {}).get('runData') or {}
safe=[]
for node,runs in run.items():
    if not isinstance(runs,list): continue
    for rr in runs:
        for branch in (((rr or {}).get('data') or {}).get('main') or []):
            for item in (branch or []):
                j=(item or {}).get('json') if isinstance(item,dict) else None
                if isinstance(j,dict) and (
                    'status_only' in j or 'content_quality_pass' in j or
                    'ai_status' in j or 'publish_telegram' in j
                ):
                    safe.append((node,j))
candidate=None
for node,j in reversed(safe):
    if j.get('status_only') is False and (
        j.get('content_quality_pass') is True or j.get('publish_telegram') is True
    ):
        candidate=(node,j); break
if status and status!='success':
    print("EG365_SMOKE_VERIFY: execution_status="+status)
    sys.exit(3)
if not candidate:
    node,j=safe[-1] if safe else ('',{})
    print("EG365_SMOKE_VERIFY: no_publishable_candidate node="+str(node)[:80]+
          " ai_status="+str(j.get('ai_status',''))[:80]+
          " ai_error="+str(j.get('ai_error',''))[:100]+
          " durum="+str(j.get('DURUM',''))[:140])
    sys.exit(4)
node,j=candidate
print("EG365_SMOKE_VERIFY: PASS node="+str(node)[:80]+
      " ai_status="+str(j.get('ai_status',''))[:80]+
      " model="+str(j.get('ai_model_used',''))[:60]+
      " editorial="+str(j.get('content_quality_pass',False))+
      " publish_tg="+str(j.get('publish_telegram',False))+
      " publish_ig="+str(j.get('publish_instagram',False))+
      " publish_th="+str(j.get('publish_threads',False))+
      " publish_fb="+str(j.get('publish_facebook',False)))
PY
  then
    echo "EG365_SMOKE_ERROR: semantic_verification_failed"
    exit 1
  fi
  /opt/venv/bin/python - <<'PY' || true
import os,sqlite3
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
con=sqlite3.connect(db,timeout=20)
try:
    con.execute("UPDATE workflow_entity SET active=0 WHERE id='EG365CLOUDSMOKEV128'")
    con.commit()
    print("EG365_SMOKE: verified_and_inactive")
finally:
    con.close()
PY
else
  /opt/venv/bin/python - <<'PY' || true
import os,sqlite3
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
if os.path.exists(db):
    con=sqlite3.connect(db,timeout=20)
    try:
        con.execute("UPDATE workflow_entity SET active=0 WHERE id='EG365CLOUDSMOKEV128'")
        con.commit()
        print("EG365_SMOKE: inactive")
    finally:
        con.close()
PY
fi

if [ "${CLOUD_ACTIVATE:-false}" = "true" ]; then
  echo "EG365_BOOT: publishing_workflow"
  if ! timeout 120 n8n publish:workflow --id=EG365CLOUDRENDERV128; then
    echo "EG365_BOOT_ERROR: publish_failed_or_timed_out"
    exit 1
  fi
  echo "EG365_BOOT: workflow_publish_ok"
else
  echo "EG365_BOOT: workflow_stays_inactive"
fi

echo "EG365_BOOT: starting_public_renderer"
/opt/venv/bin/uvicorn app:app --app-dir /opt/renderer --host 0.0.0.0 --port "$PUBLIC_PORT" >/tmp/renderer.log 2>&1 &
RPID=$!
i=0
until curl -fsS "http://127.0.0.1:$PUBLIC_PORT/health" >/dev/null 2>&1; do
  i=$((i+1))
  if ! kill -0 "$RPID" 2>/dev/null; then
    echo "EG365_BOOT_ERROR: renderer_exited"
    tail -80 /tmp/renderer.log || true
    exit 1
  fi
  if [ "$i" -gt 40 ]; then
    echo "EG365_BOOT_ERROR: renderer_health_timeout"
    tail -80 /tmp/renderer.log || true
    exit 1
  fi
  sleep 1
done
echo "EG365_BOOT: renderer_ready"

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
/opt/venv/bin/python - <<'PY' || true
import os,sqlite3
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
try:
    con=sqlite3.connect(db,timeout=20)
    row=con.execute("SELECT id,name,active FROM workflow_entity WHERE id=?",("EG365CLOUDRENDERV128",)).fetchone()
    print("EG365_VERIFY: workflow_row="+repr(row))
    count=con.execute("SELECT COUNT(*) FROM execution_entity").fetchone()[0]
    print("EG365_VERIFY: execution_count="+str(count))
    con.close()
except Exception as e:
    print("EG365_VERIFY_WARNING: "+str(e))
PY
echo "EG365_BOOT: cloud_ready"

(
  while true; do
    sleep 480
    if curl -fsS --connect-timeout 10 --max-time 30 "https://eg365-cloud.onrender.com/health" >/dev/null 2>&1; then
      echo "EG365_KEEPALIVE: ok"
    else
      echo "EG365_KEEPALIVE: warning"
    fi
  done
) &
KPID=$!

(
  while true; do
    sleep 30
    /opt/venv/bin/python - <<'PY' || true
import os,sqlite3
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
try:
    con=sqlite3.connect(db,timeout=10)
    for wid,label in [('EG365CLOUDRENDERV128','prod'),('EG365CLOUDSMOKEV128','smoke')]:
        row=con.execute("SELECT id,name,active FROM workflow_entity WHERE id=?",(wid,)).fetchone()
        try:
            cnt=con.execute("SELECT COUNT(*) FROM execution_entity WHERE workflowId=?",(wid,)).fetchone()[0]
            latest=con.execute("SELECT id,status,startedAt,stoppedAt FROM execution_entity WHERE workflowId=? ORDER BY id DESC LIMIT 1",(wid,)).fetchone()
        except Exception:
            cnt=-1; latest=None
        print(f"EG365_MONITOR: {label}_workflow={row} executions={cnt} latest={latest}",flush=True)
    con.close()
except Exception as e:
    print("EG365_MONITOR_WARNING: "+str(e),flush=True)
PY
  done
) &
MPID=$!

wait "$NPID"
