#!/bin/sh
set -eu

export PUBLIC_PORT="${PORT:-10000}"
export N8N_PORT="${N8N_PORT:-5678}"
export N8N_LISTEN_ADDRESS="${N8N_LISTEN_ADDRESS:-127.0.0.1}"
export N8N_PROTOCOL="http"

mkdir -p /root/.n8n /tmp/eg365-output

RPID=""
NPID=""
MPID=""
KPID=""
TPID=""

cleanup() {
  [ -n "${RPID:-}" ] && kill "$RPID" 2>/dev/null || true
  [ -n "${NPID:-}" ] && kill "$NPID" 2>/dev/null || true
  [ -n "${MPID:-}" ] && kill "$MPID" 2>/dev/null || true
  [ -n "${KPID:-}" ] && kill "$KPID" 2>/dev/null || true
  [ -n "${TPID:-}" ] && kill "$TPID" 2>/dev/null || true
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

# Auto-repair the Facebook Page token from the still-valid Meta/Instagram user token.
# This keeps credentials out of GitHub and fixes Graph error 190 without touching the local V128.
if [ "${EG365_REFRESH_FACEBOOK_TOKEN:-true}" = "true" ]; then
  /opt/venv/bin/python - <<'PY' || true
import os,sqlite3,json,urllib.parse,urllib.request,urllib.error
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
con=sqlite3.connect(db,timeout=20)
try:
    con.execute("CREATE TABLE IF NOT EXISTS eg365_secrets (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
    vals=dict(con.execute("SELECT k,v FROM eg365_secrets").fetchall())
    page_id=(vals.get('FACEBOOK_PAGE_ID') or os.environ.get('FACEBOOK_PAGE_ID') or '').strip()
    candidates=[
        ('stored_user', vals.get('FACEBOOK_USER_ACCESS_TOKEN')),
        ('env_user', os.environ.get('FACEBOOK_USER_ACCESS_TOKEN')),
        ('stored_instagram', vals.get('INSTAGRAM_ACCESS_TOKEN')),
        ('env_instagram', os.environ.get('INSTAGRAM_ACCESS_TOKEN')),
        ('stored_page', vals.get('FACEBOOK_PAGE_ACCESS_TOKEN')),
        ('env_page', os.environ.get('FACEBOOK_PAGE_ACCESS_TOKEN')),
    ]
    seen=set()
    sources=[]
    for label,tok in candidates:
        tok=(tok or '').strip()
        if not tok or tok=='PENDING' or tok in seen:
            continue
        seen.add(tok); sources.append((label,tok))
    if not sources or not page_id or page_id=='PENDING':
        print("EG365_FB_TOKEN_REPAIR: skipped_missing_source",flush=True)
    else:
        base='https://graph.facebook.com/v24.0/me/accounts'
        repaired=False
        last_error=''
        for label,user_token in sources:
            qs=urllib.parse.urlencode({'fields':'id,name,access_token','limit':'100','access_token':user_token})
            req=urllib.request.Request(base+'?'+qs,headers={'User-Agent':'EG365-Cloud/1.0'})
            try:
                with urllib.request.urlopen(req,timeout=30) as r:
                    obj=json.loads(r.read().decode('utf-8','replace'))
                match=next((x for x in (obj.get('data') or []) if str(x.get('id') or '')==page_id and x.get('access_token')),None)
                if not match:
                    pages=obj.get('data') or []
                    match=next((x for x in pages if x.get('access_token') and any(t in str(x.get('name') or '').lower() for t in ('eğitim gündem 365','egitim gundem 365','egitimgundem365'))),None)
                if match:
                    con.execute("INSERT INTO eg365_secrets(k,v) VALUES('FACEBOOK_PAGE_ACCESS_TOKEN',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(str(match['access_token']),))
                    con.execute("INSERT INTO eg365_secrets(k,v) VALUES('FACEBOOK_PAGE_ID',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(str(match.get('id') or page_id),))
                    if label in ('stored_user','env_user'):
                        con.execute("INSERT INTO eg365_secrets(k,v) VALUES('FACEBOOK_USER_ACCESS_TOKEN',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(user_token,))
                    con.commit()
                    print("EG365_FB_TOKEN_REPAIR: success source="+label+" page_id="+str(match.get('id') or page_id),flush=True)
                    repaired=True
                    break
                last_error='page_not_found source='+label
            except urllib.error.HTTPError as e:
                msg=''; code=''
                try:
                    er=json.loads(e.read().decode('utf-8','replace')).get('error') or {}
                    code=str(er.get('code') or '')
                    msg=str(er.get('message') or '')[:120]
                except Exception: pass
                last_error='source='+label+' code='+code+' message='+msg
                print("EG365_FB_TOKEN_REPAIR_TRY: "+last_error,flush=True)
            except Exception as e:
                last_error='source='+label+' request_failed '+str(e)[:120]
                print("EG365_FB_TOKEN_REPAIR_TRY: "+last_error,flush=True)
        if not repaired:
            print("EG365_FB_TOKEN_REPAIR: all_sources_failed "+last_error,flush=True)
finally:
    con.close()
PY
fi

# Persist a valid Page token supplied by the cloud environment into encrypted state.
# Cloud-only Facebook write probe creates an unpublished Page post, then deletes it.
if [ "${EG365_FACEBOOK_PROBE:-false}" = "true" ] || { [ -n "${FACEBOOK_PAGE_ACCESS_TOKEN:-}" ] && [ "${FACEBOOK_PAGE_ACCESS_TOKEN:-}" != "PENDING" ]; }; then
  /opt/venv/bin/python - <<'PY' || true
import os,sqlite3,json,urllib.request,urllib.parse,urllib.error
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
con=sqlite3.connect(db,timeout=20)
try:
    con.execute("CREATE TABLE IF NOT EXISTS eg365_secrets (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
    vals=dict(con.execute("SELECT k,v FROM eg365_secrets").fetchall())
    # A freshly repaired Page token in encrypted state is authoritative.
    # Render env may contain an older token, so it must never overwrite a newer stored token.
    stored_page_token=(vals.get('FACEBOOK_PAGE_ACCESS_TOKEN') or '').strip()
    env_page_token=(os.environ.get('FACEBOOK_PAGE_ACCESS_TOKEN') or '').strip()
    page_token=(stored_page_token or env_page_token).strip()
    page_id=(vals.get('FACEBOOK_PAGE_ID') or os.environ.get('FACEBOOK_PAGE_ID') or '').strip()
    if page_token and page_token!='PENDING':
        if not stored_page_token and env_page_token:
            con.execute("INSERT INTO eg365_secrets(k,v) VALUES('FACEBOOK_PAGE_ACCESS_TOKEN',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(env_page_token,))
            con.commit()
            print("EG365_FB_TOKEN_SYNC: env_seeded_once",flush=True)
        else:
            print("EG365_FB_TOKEN_SYNC: stored_token_authoritative",flush=True)
    if os.environ.get('EG365_FACEBOOK_PROBE','false').lower()=='true':
        if not page_token or page_token=='PENDING' or not page_id or page_id=='PENDING':
            print("EG365_FB_PROBE: skipped_missing_credentials",flush=True)
        else:
            data=urllib.parse.urlencode({
              'message':'EG365 CLOUD bağlantı doğrulama testi',
              'published':'false',
              'access_token':page_token
            }).encode()
            req=urllib.request.Request(
              f'https://graph.facebook.com/v24.0/{page_id}/feed',
              data=data,method='POST',
              headers={'User-Agent':'EG365-Cloud/1.0'}
            )
            try:
                with urllib.request.urlopen(req,timeout=30) as r:
                    obj=json.loads(r.read().decode('utf-8','replace'))
                pid=str(obj.get('id') or '')
                if pid:
                    print("EG365_FB_PROBE: create_ok unpublished=true id="+pid[:64],flush=True)
                    q=urllib.parse.urlencode({'access_token':page_token}).encode()
                    dreq=urllib.request.Request(f'https://graph.facebook.com/v24.0/{pid}',data=q,method='DELETE',headers={'User-Agent':'EG365-Cloud/1.0'})
                    try:
                        with urllib.request.urlopen(dreq,timeout=30) as dr:
                            dobj=json.loads(dr.read().decode('utf-8','replace'))
                        print("EG365_FB_PROBE: delete_ok="+str(bool(dobj.get('success'))).lower(),flush=True)
                    except Exception:
                        print("EG365_FB_PROBE: delete_warning",flush=True)
                else:
                    print("EG365_FB_PROBE: create_no_id",flush=True)
            except urllib.error.HTTPError as e:
                code='';msg=''
                try:
                    er=json.loads(e.read().decode('utf-8','replace')).get('error') or {}
                    code=str(er.get('code') or '')
                    msg=str(er.get('message') or '')[:180]
                except Exception: pass
                print("EG365_FB_PROBE: graph_error code="+code+" message="+msg,flush=True)
            except Exception as e:
                print("EG365_FB_PROBE: request_failed "+str(e)[:180],flush=True)
finally:
    con.close()
PY
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
    if k in ('FACEBOOK_PAGE_ID','FACEBOOK_PAGE_ACCESS_TOKEN') and stored.get(k):
        val=stored.get(k,'')
    else:
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

# Temporary cloud-origin marker: append MMG and @mmuratg at the very bottom of every social caption.
# This is applied only to the ephemeral cloud workflow and is easy to remove later.
python3 - <<'PY'
from pathlib import Path
import json, os
p=Path('/opt/workflow/EG365_CLOUD_RENDER_V128.json')
w=json.loads(p.read_text(encoding='utf-8'))
for n in w.get('nodes',[]):
    name=n.get('name')
    params=n.get('parameters') or {}
    if name in ('TELEGRAM YAYINLA','INSTAGRAM CONTAINER','FACEBOOK YAYINLA'):
        for x in (((params.get('bodyParameters') or {}).get('parameters')) or []):
            if x.get('name')=='caption':
                base=str(x.get('value') or '')
                if 'MMG' not in base:
                    if name=='TELEGRAM YAYINLA':
                        x['value']="={{ ($json.telegram_caption_html || $json.telegram_caption || '') + '\\n\\nMMG\\n@mmuratg' }}"
                    elif name=='INSTAGRAM CONTAINER':
                        x['value']="={{ ($json.instagram_caption || '') + '\\n\\nMMG\\n@mmuratg' }}"
                    else:
                        x['value']="={{ ($json.facebook_caption || '') + '\\n\\nMMG\\n@mmuratg' }}"
    elif name=='THREADS CONTAINER':
        for x in (((params.get('queryParameters') or {}).get('parameters')) or []):
            if x.get('name')=='text' and 'MMG' not in str(x.get('value') or ''):
                x['value']="={{ ($json.threads_caption || '') + '\\n\\nMMG\\n@mmuratg' }}"
# Align every container-internal renderer call with Render's actual listening port.
port=(os.environ.get('PUBLIC_PORT') or '10000').strip()
raw=json.dumps(w,ensure_ascii=False)
raw=raw.replace('http://127.0.0.1:8787',f'http://127.0.0.1:{port}')
raw=raw.replace('http://localhost:8787',f'http://127.0.0.1:{port}')
w=json.loads(raw)
p.write_text(json.dumps(w,ensure_ascii=False,indent=2),encoding='utf-8')
print('EG365_BOOT: temporary_mmg_marker_enabled',flush=True)
print('EG365_BOOT: internal_renderer_port='+port,flush=True)
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

# Build a separate manual-only workflow. Normal production keeps all duplicate protection.
# The manual copy may republish the newest verified official item when the user explicitly requests it.
MANUAL_ID="EG365CLOUDMANUALV128"
echo "EG365_MANUAL_BOOT: preparing_manual_workflow"
if ! /opt/venv/bin/python - <<'PY'
from pathlib import Path
import json
src=Path('/opt/workflow/EG365_CLOUD_RENDER_V128.json')
dst=Path('/tmp/EG365_CLOUD_MANUAL_V128.json')
w=json.loads(src.read_text(encoding='utf-8'))
w['id']='EG365CLOUDMANUALV128'
w['name']='EG365 CLOUD V128 - MANUAL VERIFIED PUBLISH'
w['active']=False
w['versionId']='12800000-0000-4000-8000-00000000a128'

for n in w.get('nodes',[]):
    name=n.get('name')
    p=n.get('parameters') or {}
    code=p.get('jsCode')
    if name=='CONFIG' and isinstance(code,str):
        old="const __runMode=String($json?.run_mode||'normal');"
        if old not in code:
            raise SystemExit('CONFIG run_mode anchor missing')
        p['jsCode']=code.replace(old,"const __runMode='manual';",1)
    elif name=='ÖN FİLTRE + TEKRAR KONTROLÜ' and isinstance(code,str):
        old="const found=[];\nlet ok=0,failed=0,discovered=0,seen=0;"
        new="const manualForce=String(cfg.run_mode||'')==='manual';\nconst found=[];\nlet ok=0,failed=0,discovered=0,seen=0;"
        if old not in code:
            raise SystemExit('prefilter manual anchor missing')
        code=code.replace(old,new,1)
        old2="if(store.directSeen[directKey]||keys.some(k=>store.publishedNews[k])){seen++;continue;}"
        new2="if(!manualForce && (store.directSeen[directKey]||keys.some(k=>store.publishedNews[k]))){seen++;continue;}"
        if old2 not in code:
            raise SystemExit('prefilter duplicate anchor missing')
        p['jsCode']=code.replace(old2,new2,1)
    elif name=='SON DUPLICATE KONTROLÜ' and isinstance(code,str):
        old="const isDup=keys.some(k=>store.publishedNews[k]||store.inflightNews[k]);"
        new="const manualForce=String(j.run_mode||'')==='manual';\n  const isDup=manualForce?false:keys.some(k=>store.publishedNews[k]||store.inflightNews[k]);"
        if old not in code:
            raise SystemExit('final duplicate anchor missing')
        p['jsCode']=code.replace(old,new,1)
    elif name=='YAYIN ADAYI VARSA DEVAM':
        p['jsCode']=r"""const out=[];
for(const item of $input.all()){
  const j=item?.json||{};
  if(j.status_only===true)continue;
  const url=String(j.official_source_url||j.source_url||j.link||'').trim();
  const imageUrl=String(j.source_image_url||'').trim();
  const verified=j.verified===true && /^https:\/\/[^/]*meb\.gov\.tr\//i.test(url);
  const imageOK=j.source_image_found===true && /^https?:\/\//i.test(imageUrl) && String(j.source_image_method||'').toLowerCase()!=='placeholder';
  const editorOK=j._newsroom?.quality_gate==='PASS';
  const lead=String(j.lead||j.summary||'').trim();
  const title=String(j.title_main||j.title||'').trim();
  if(!verified||!imageOK||!editorOK||title.length<25||lead.length<80)continue;
  const bullets=(Array.isArray(j.bullets)?j.bullets:[j.bullet_1,j.bullet_2,j.bullet_3]).map(x=>String(x||'').trim()).filter(Boolean).slice(0,3);
  out.push({json:{...j,status_only:false,bullets,bullet_1:bullets[0]||'',bullet_2:bullets[1]||'',bullet_3:bullets[2]||'',bullet_count:bullets.length,_candidate_gate_passed:true,_candidate_gate_version:'MANUAL_OFFICIAL_SAFE_V1'}});
}
return out;"""
    elif name=='X CANLI FILTRE1':
        # X is not part of the requested manual EG365 publish set.
        # Current credential is app-only and would turn an otherwise successful
        # Telegram/Instagram/Threads/Facebook run into a false execution error.
        p['jsCode']="return [];"
    elif name=='AI SONUÇLARI AÇ + YAYIN FİLTRESİ':
        p['jsCode']=r"""const bundle=$('OPENAI TOPLU İSTEK HAZIRLA').first().json||{};
const src=(bundle.sources||[])[0]||null;
if(!src)return [{json:{status_only:true,DURUM:'MANUEL: DOĞRULANMIŞ KAYNAK BULUNAMADI',publish_telegram:false,publish_instagram:false,publish_threads:false,publish_facebook:false}}];

function clean(v=''){return String(v??'').replace(/<[^>]*>/g,' ').replace(/&nbsp;/gi,' ').replace(/\s+/g,' ').trim();}
function trimWords(s,max){let t=clean(s);if(t.length<=max)return t.replace(/[,:;\-–—\s]+$/,'');const ws=t.split(' ');let out='';for(const w of ws){const n=(out?out+' ':'')+w;if(n.length>max)break;out=n;}return out.replace(/[,:;\-–—\s]+$/,'');}
function sents(s=''){return clean(s).match(/[^.!?]+[.!?](?=\s|$)/g)||[];}
function leadFrom(s=''){
  const ss=sents(s).map(clean).filter(x=>x.length>=35);
  let acc='';
  for(const x of ss){const n=(acc?acc+' ':'')+x;if(n.length>220)break;acc=n;if(acc.length>=120)break;}
  if(acc.length>=80){if(!/[.!?]$/.test(acc))acc+='.';return acc;}
  let t=trimWords(clean(s),205); if(t.length<80)t='Millî Eğitim Bakanlığının resmî internet sitesinde yayımlanan duyuruda konuya ilişkin ayrıntılar ve uygulamaya dair bilgiler kamuoyuyla paylaşıldı.';
  if(!/[.!?]$/.test(t))t+='.'; return t;
}
function categoryOf(t=''){t=clean(t).toLocaleLowerCase('tr-TR');if(/sınav|yazılı|ölçme|değerlendirme|lgs|iokbs/.test(t))return'SINAV';if(/öğretmen|atama|yer değiş|personel/.test(t))return'ÖĞRETMEN';if(/mesleki|meslek/.test(t))return'MESLEKİ EĞİTİM';if(/teknoloji|dijital|yapay zek|yegitek/.test(t))return'TEKNOLOJİ';if(/müfredat|maarif|öğretim program/.test(t))return'MÜFREDAT';if(/proje|açılış|program/.test(t))return'PROJE';return'DİĞER MEB';}
const full=clean(src.source_content||src.summary||'');
let main=trimWords(src.title||'MEB resmî duyurusu',96);
if(main.length<28)main=trimWords('Millî Eğitim Bakanlığından yeni resmî duyuru: '+main,96);
let hi='Resmî kaynakta kapsam ve ayrıntılar paylaşıldı';
if(hi.length<12)hi='MEB ayrıntıları paylaştı';
const lead=leadFrom(full||src.summary||src.title);
const facts=sents(full).map(clean).filter(x=>x.length>=35&&x.length<=165&&x!==lead).slice(0,3);
const bullets=facts.map(x=>/[.!?]$/.test(x)?x:x+'.');
const url=String(src.official_source_url||src.link||'');
const source=clean(src.source_name||'Millî Eğitim Bakanlığı');
const tags=['#MEB','#Eğitim','#MilliEğitim','#EğitimGündemi','#Öğretmen'];
return [{json:{...src,status_only:false,run_mode:'manual',verified:true,meb_relevant:true,confidence:100,importance:80,category:categoryOf(main+' '+full),title_main:main,title_highlight:hi,hook:hi,summary:lead,lead,bullets,bullet_1:bullets[0]||'',bullet_2:bullets[1]||'',bullet_3:bullets[2]||'',bullet_count:bullets.length,source_name:source,official_source_url:url,source_url:url,preferred_source_url:url,hashtags:tags,content_quality_pass:true,content_quality_version:'MANUAL_OFFICIAL_SOURCE_FALLBACK',ai_status:'MANUAL_OFFICIAL_SOURCE_FALLBACK',ai_model_used:'none',publication_basis:'RESMÎ MEB KAYNAĞI',publish_telegram:true,publish_instagram:true,publish_threads:true,publish_facebook:true}}];"""

dst.write_text(json.dumps(w,ensure_ascii=False,indent=2),encoding='utf-8')
print('EG365_MANUAL_BOOT: manual_workflow_built')
PY
then
  echo "EG365_MANUAL_BOOT_ERROR: build_failed"
  exit 1
fi

if ! timeout 150 n8n import:workflow --input=/tmp/EG365_CLOUD_MANUAL_V128.json >/tmp/eg365-manual-import.log 2>&1; then
  echo "EG365_MANUAL_BOOT_ERROR: import_failed_or_timed_out"
  tail -60 /tmp/eg365-manual-import.log || true
  exit 1
fi
echo "EG365_MANUAL_BOOT: workflow_import_ok"

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
    if n.get('name')=='ÖN FİLTRE + TEKRAR KONTROLÜ':
        n['parameters']['jsCode']="""return [{json:{
  title:'MEB RESMÎ HABER DOĞRULAMA TESTİ',
  link:'https://www.meb.gov.tr/bakan-tekin-haberimiz-olsun-bulteninde-ogrencilerin-sorularini-yanitladi/haber/42086/tr',
  official_source_url:'https://www.meb.gov.tr/bakan-tekin-haberimiz-olsun-bulteninde-ogrencilerin-sorularini-yanitladi/haber/42086/tr',
  published:'2026-10-04T12:11:00',
  summary:'Millî Eğitim Bakanlığının resmî haber sayfası cloud zincirinin doğrulanması amacıyla kuru test girdisi olarak kullanılmaktadır.',
  source_name:'Millî Eğitim Bakanlığı',source_host:'www.meb.gov.tr',source_type:'SMOKE_OFFICIAL',
  verified:true,meb_relevant:true,direct_seen_key:'eg365-cloud-smoke-42086',
  ts:Date.now(),article_enriched:false,article_fetch_ok:false,item_id:0,run_mode:'normal'
}}];"""
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

# Cloud production runs via short-lived n8n CLI executions.
# This avoids the persistent n8n server's ~512 MiB memory pressure on Render Free.
echo "EG365_BOOT: production_cli_mode"

# Keep workflow inactive in the DB so no duplicate schedule can fire if n8n server is ever started.
 /opt/venv/bin/python - <<'PY' || true
import os,sqlite3
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
con=sqlite3.connect(db,timeout=20)
try:
    con.execute("UPDATE workflow_entity SET active=0 WHERE id IN ('EG365CLOUDRENDERV128','EG365CLOUDSMOKEV128','EG365CLOUDMANUALV128')")
    con.commit()
    print("EG365_BOOT: db_schedules_disabled")
finally:
    con.close()
PY

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
echo "EG365_BOOT: cloud_ready"

audit_last_prod() {
  /opt/venv/bin/python - <<'PY' || true
import os,sqlite3,json,re
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
wid='EG365CLOUDRENDERV128'
con=sqlite3.connect(db,timeout=20)
try:
    row=con.execute("SELECT id,status,startedAt,stoppedAt FROM execution_entity WHERE workflowId=? ORDER BY id DESC LIMIT 1",(wid,)).fetchone()
    if not row:
        print("EG365_AUDIT: no_execution",flush=True); raise SystemExit
    drow=con.execute("SELECT data FROM execution_data WHERE executionId=?",(row[0],)).fetchone()
    if not drow or not drow[0]:
        print("EG365_AUDIT: no_execution_data id="+str(row[0]),flush=True); raise SystemExit
    raw=json.loads(drow[0])
    if isinstance(raw,list):
        arr=raw; memo={}
        def top(i):
            if i in memo:return memo[i]
            if i<0 or i>=len(arr):return None
            x=arr[i]
            if isinstance(x,str):return x
            if isinstance(x,dict):
                out={}; memo[i]=out
                for k,v in x.items():out[k]=nested(v)
                return out
            if isinstance(x,list):
                out=[]; memo[i]=out
                out.extend(nested(v) for v in x); return out
            return x
        def nested(v):
            if isinstance(v,str) and re.fullmatch(r'\d+',v):
                n=int(v)
                if 0<=n<len(arr):return top(n)
            if isinstance(v,dict):return {k:nested(x) for k,x in v.items()}
            if isinstance(v,list):return [nested(x) for x in v]
            return v
        root=top(0)
    else:
        root=raw
    run=((root or {}).get('resultData') or {}).get('runData') or {}
    def last_json(name):
        runs=run.get(name) or []
        for rr in reversed(runs):
            mains=((rr or {}).get('data') or {}).get('main') or []
            for branch in reversed(mains):
                if not branch: continue
                for item in reversed(branch):
                    if isinstance(item,dict) and isinstance(item.get('json'),dict):
                        return item['json']
        return None
    def has_error(x):
        if isinstance(x,dict):
            for k,v in x.items():
                if str(k).lower() in ('error','errors') and v not in (None,'',False,[],{}): return True
                if has_error(v): return True
        elif isinstance(x,list):
            return any(has_error(v) for v in x)
        return False
    def first_id(x):
        if isinstance(x,dict):
            for k in ('message_id','post_id','creation_id','id'):
                v=x.get(k)
                if isinstance(v,(str,int)) and str(v): return str(v)[:48]
            for v in x.values():
                z=first_id(v)
                if z:return z
        elif isinstance(x,list):
            for v in x:
                z=first_id(v)
                if z:return z
        return ''
    def safe_error(x):
        out={'code':'','message':''}
        def walk(v):
            if out['message']: return
            if isinstance(v,dict):
                if isinstance(v.get('error'),dict):
                    e=v['error']
                    out['code']=str(e.get('code') or e.get('status') or '')[:24]
                    out['message']=str(e.get('message') or e.get('error_user_msg') or e.get('type') or '')[:180]
                    if out['message']: return
                if isinstance(v.get('error'),str) and v.get('error'):
                    out['message']=str(v.get('error'))[:180]; return
                for vv in v.values(): walk(vv)
            elif isinstance(v,list):
                for vv in v: walk(vv)
        walk(x)
        return out
    def status_code(x):
        if not isinstance(x,dict): return 0
        for k in ('statusCode','status_code','status'):
            v=x.get(k)
            try:
                n=int(v)
                if 100<=n<=599:return n
            except Exception: pass
        return 0
    def channel(name):
        x=last_json(name)
        if x is None:return {'ran':False,'success':False}
        ident=first_id(x)
        explicit=x.get('ok') is True if isinstance(x,dict) else False
        data_ok=isinstance(x,dict) and isinstance(x.get('data'),list) and len(x.get('data'))>0
        sc=status_code(x)
        err=safe_error(x)
        success=(not has_error(x)) and (explicit or bool(ident) or data_ok or (200<=sc<300))
        return {'ran':True,'success':bool(success),'id':ident,'status_code':sc,'error_code':err['code'],'error_message':err['message']}
    cand=last_json('AI SONUÇLARI AÇ + YAYIN FİLTRESİ') or {}
    cat=last_json('CATBOX PUBLIC URL YÜKLE') or {}
    caturl=''
    if isinstance(cat,dict):
        for k in ('public_image_url','image_url','url','body','data'):
            v=cat.get(k)
            if isinstance(v,str) and 'files.catbox.moe' in v:
                m=re.search(r'https://files\\.catbox\\.moe/[A-Za-z0-9._-]+',v)
                if m:caturl=m.group(0);break
    audit={
      'execution_id':row[0],'status':row[1],
      'candidate':{
        'status_only':cand.get('status_only'),
        'content_quality_pass':cand.get('content_quality_pass'),
        'ai_status':str(cand.get('ai_status') or '')[:60],
        'ai_model_used':str(cand.get('ai_model_used') or '')[:60],
        'publish_telegram':cand.get('publish_telegram'),
        'publish_instagram':cand.get('publish_instagram'),
        'publish_threads':cand.get('publish_threads'),
        'publish_facebook':cand.get('publish_facebook'),
        'title':str(cand.get('title') or '')[:140]
      },
      'catbox':{'ran':bool(cat),'success':bool(caturl) or (200<=status_code(cat)<300 and not has_error(cat)),'host':('files.catbox.moe' if 'files.catbox.moe' in caturl else ''),'status_code':status_code(cat),'error':safe_error(cat).get('message','')},
      'telegram':channel('TELEGRAM YAYINLA'),
      'instagram_create':channel('INSTAGRAM CONTAINER'),
      'instagram_publish':channel('INSTAGRAM YAYINLA'),
      'instagram_verify':channel('INSTAGRAM YAYIN DOĞRULA'),
      'threads_create':channel('THREADS CONTAINER'),
      'threads_publish':channel('THREADS YAYINLA'),
      'threads_verify':channel('THREADS YAYIN DOĞRULA'),
      'facebook':channel('FACEBOOK YAYINLA'),
      'memory':{'ran':last_json('YAYIN HAFIZASINA KAYDET') is not None}
    }
    print("EG365_AUDIT: "+json.dumps(audit,ensure_ascii=False),flush=True)
except SystemExit:
    pass
except Exception as e:
    print("EG365_AUDIT_WARNING: "+str(e),flush=True)
finally:
    con.close()
PY
}

audit_last_manual() {
  /opt/venv/bin/python - <<'PY' || true
import os,sqlite3,json,re
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
wid='EG365CLOUDMANUALV128'
con=sqlite3.connect(db,timeout=20)
try:
    row=con.execute("SELECT id,status,startedAt,stoppedAt FROM execution_entity WHERE workflowId=? ORDER BY id DESC LIMIT 1",(wid,)).fetchone()
    if not row:
        print("EG365_MANUAL_AUDIT: no_execution",flush=True); raise SystemExit
    drow=con.execute("SELECT data FROM execution_data WHERE executionId=?",(row[0],)).fetchone()
    if not drow or not drow[0]:
        print("EG365_MANUAL_AUDIT: no_execution_data id="+str(row[0]),flush=True); raise SystemExit
    raw=json.loads(drow[0])
    if isinstance(raw,list):
        arr=raw; memo={}
        def top(i):
            if i in memo:return memo[i]
            if i<0 or i>=len(arr):return None
            x=arr[i]
            if isinstance(x,str):return x
            if isinstance(x,dict):
                out={}; memo[i]=out
                for k,v in x.items():out[k]=nested(v)
                return out
            if isinstance(x,list):
                out=[]; memo[i]=out
                out.extend(nested(v) for v in x); return out
            return x
        def nested(v):
            if isinstance(v,str) and re.fullmatch(r'\d+',v):
                n=int(v)
                if 0<=n<len(arr):return top(n)
            if isinstance(v,dict):return {k:nested(x) for k,x in v.items()}
            if isinstance(v,list):return [nested(x) for x in v]
            return v
        root=top(0)
    else:
        root=raw
    run=((root or {}).get('resultData') or {}).get('runData') or {}
    def last_json(name):
        runs=run.get(name) or []
        for rr in reversed(runs):
            mains=((rr or {}).get('data') or {}).get('main') or []
            for branch in reversed(mains):
                if not branch: continue
                for item in reversed(branch):
                    if isinstance(item,dict) and isinstance(item.get('json'),dict):
                        return item['json']
        return None
    def has_error(x):
        if isinstance(x,dict):
            for k,v in x.items():
                if str(k).lower() in ('error','errors') and v not in (None,'',False,[],{}): return True
                if has_error(v): return True
        elif isinstance(x,list):
            return any(has_error(v) for v in x)
        return False
    def first_id(x):
        if isinstance(x,dict):
            for k in ('message_id','post_id','creation_id','id'):
                v=x.get(k)
                if isinstance(v,(str,int)) and str(v): return str(v)[:48]
            for v in x.values():
                z=first_id(v)
                if z:return z
        elif isinstance(x,list):
            for v in x:
                z=first_id(v)
                if z:return z
        return ''
    def safe_error(x):
        out={'code':'','message':''}
        def walk(v):
            if out['message']: return
            if isinstance(v,dict):
                if isinstance(v.get('error'),dict):
                    e=v['error']
                    out['code']=str(e.get('code') or e.get('status') or '')[:24]
                    out['message']=str(e.get('message') or e.get('error_user_msg') or e.get('type') or '')[:180]
                    if out['message']: return
                if isinstance(v.get('error'),str) and v.get('error'):
                    out['message']=str(v.get('error'))[:180]; return
                for vv in v.values(): walk(vv)
            elif isinstance(v,list):
                for vv in v: walk(vv)
        walk(x)
        return out
    def status_code(x):
        if not isinstance(x,dict): return 0
        for k in ('statusCode','status_code','status'):
            v=x.get(k)
            try:
                n=int(v)
                if 100<=n<=599:return n
            except Exception: pass
        return 0
    def channel(name):
        x=last_json(name)
        if x is None:return {'ran':False,'success':False}
        ident=first_id(x)
        explicit=x.get('ok') is True if isinstance(x,dict) else False
        data_ok=isinstance(x,dict) and isinstance(x.get('data'),list) and len(x.get('data'))>0
        sc=status_code(x)
        err=safe_error(x)
        success=(not has_error(x)) and (explicit or bool(ident) or data_ok or (200<=sc<300))
        return {'ran':True,'success':bool(success),'id':ident,'status_code':sc,'error_code':err['code'],'error_message':err['message']}
    cand=last_json('AI SONUÇLARI AÇ + YAYIN FİLTRESİ') or {}
    cat=last_json('CATBOX PUBLIC URL YÜKLE') or {}
    caturl=''
    if isinstance(cat,dict):
        for k in ('public_image_url','image_url','url','body','data'):
            v=cat.get(k)
            if isinstance(v,str) and 'files.catbox.moe' in v:
                m=re.search(r'https://files\\.catbox\\.moe/[A-Za-z0-9._-]+',v)
                if m:caturl=m.group(0);break
    audit={
      'execution_id':row[0],'status':row[1],
      'candidate':{
        'status_only':cand.get('status_only'),
        'content_quality_pass':cand.get('content_quality_pass'),
        'ai_status':str(cand.get('ai_status') or '')[:60],
        'ai_model_used':str(cand.get('ai_model_used') or '')[:60],
        'publish_telegram':cand.get('publish_telegram'),
        'publish_instagram':cand.get('publish_instagram'),
        'publish_threads':cand.get('publish_threads'),
        'publish_facebook':cand.get('publish_facebook'),
        'title':str(cand.get('title') or '')[:140]
      },
      'catbox':{'ran':bool(cat),'success':bool(caturl) or (200<=status_code(cat)<300 and not has_error(cat)),'host':('files.catbox.moe' if 'files.catbox.moe' in caturl else ''),'status_code':status_code(cat),'error':safe_error(cat).get('message','')},
      'telegram':channel('TELEGRAM YAYINLA'),
      'instagram_create':channel('INSTAGRAM CONTAINER'),
      'instagram_publish':channel('INSTAGRAM YAYINLA'),
      'instagram_verify':channel('INSTAGRAM YAYIN DOĞRULA'),
      'threads_create':channel('THREADS CONTAINER'),
      'threads_publish':channel('THREADS YAYINLA'),
      'threads_verify':channel('THREADS YAYIN DOĞRULA'),
      'facebook':channel('FACEBOOK YAYINLA'),
      'memory':{'ran':last_json('YAYIN HAFIZASINA KAYDET') is not None}
    }
    print("EG365_MANUAL_AUDIT: "+json.dumps(audit,ensure_ascii=False),flush=True)
except SystemExit:
    pass
except Exception as e:
    print("EG365_MANUAL_AUDIT_WARNING: "+str(e),flush=True)
finally:
    con.close()
PY
}

# Audit the restored state before the next run. This confirms the previous cloud run without republishing it.
audit_last_prod
audit_last_manual

run_prod() {
  if ! mkdir /tmp/eg365-prod.lock 2>/dev/null; then
    echo "EG365_PROD: already_running"
    return 0
  fi
  echo "EG365_PROD: execution_start"
  if timeout 480 n8n execute --id=EG365CLOUDRENDERV128 >/tmp/eg365-prod.log 2>&1; then
    echo "EG365_PROD: execution_ok"
  else
    rc=$?
    echo "EG365_PROD_ERROR: execution_failed rc=$rc"
    tail -50 /tmp/eg365-prod.log | sed -E 's/(Bearer )[A-Za-z0-9._-]+/\1[REDACTED]/g; s/([A-Za-z0-9_]*(token|api[_ -]?key)[A-Za-z0-9_]*["'"'"']?[=:]["'"'"']?)[^ ,}"'"'"']+/\1[REDACTED]/Ig' || true
    rm -rf /tmp/eg365-prod.lock
    return $rc
  fi

  /opt/venv/bin/python - <<'PY' || true
import os,sqlite3,json
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
con=sqlite3.connect(db,timeout=20)
try:
    row=con.execute("SELECT id,status,startedAt,stoppedAt FROM execution_entity WHERE workflowId=? ORDER BY id DESC LIMIT 1",('EG365CLOUDRENDERV128',)).fetchone()
    print("EG365_PROD_VERIFY: latest="+repr(row),flush=True)
    if row:
        drow=con.execute("SELECT data FROM execution_data WHERE executionId=?",(row[0],)).fetchone()
        obj={}
        if drow and drow[0]:
            try: obj=json.loads(drow[0])
            except Exception: obj={}
        found=[]
        def walk(x):
            if isinstance(x,dict):
                if any(k in x for k in ('status_only','content_quality_pass','ai_status','publish_telegram')):
                    found.append(x)
                for v in x.values(): walk(v)
            elif isinstance(x,list):
                for v in x: walk(v)
        walk(obj)
        best=None
        for x in reversed(found):
            if x.get('content_quality_pass') is True or x.get('status_only') is True:
                best=x; break
        if best:
            safe={'status_only':best.get('status_only'),'ai_status':best.get('ai_status'),'ai_model_used':best.get('ai_model_used'),'content_quality_pass':best.get('content_quality_pass'),'publish_telegram':best.get('publish_telegram'),'publish_instagram':best.get('publish_instagram'),'publish_threads':best.get('publish_threads'),'publish_facebook':best.get('publish_facebook'),'title':str(best.get('title') or '')[:140],'durum':str(best.get('DURUM') or '')[:160]}
            print("EG365_PROD_RESULT: "+json.dumps(safe,ensure_ascii=False),flush=True)
except Exception as e:
    print("EG365_PROD_VERIFY_WARNING: "+str(e),flush=True)
finally:
    con.close()
PY
  audit_last_prod
  rm -rf /tmp/eg365-prod.lock
}

# First cloud production pass is configurable. Final audit deploys disable it to avoid duplicate posts.
if [ "${EG365_RUN_ON_BOOT:-true}" = "true" ]; then
  run_prod || true
else
  echo "EG365_PROD: boot_run_disabled"
fi

# Production cadence: every 120 minutes.
(
  while true; do
    sleep 7200
    if [ "${CLOUD_ACTIVATE:-false}" = "true" ]; then
      run_prod || true
    else
      echo "EG365_PROD: skipped_cloud_inactive"
    fi
  done
) &
MPID=$!

# Protected one-click manual trigger. The public endpoint only drops a local
# trigger file; this loop consumes it and runs the same production path once.
(
  while true; do
    if [ -f /tmp/eg365-run-now.trigger ]; then
      if [ -d /tmp/eg365-prod.lock ]; then
        echo "EG365_MANUAL: waiting_for_current_run"
      else
        rm -f /tmp/eg365-run-now.trigger
        echo "EG365_MANUAL: trigger_received"
        echo "EG365_MANUAL: execution_start"
        if timeout 480 n8n execute --id="$MANUAL_ID" >/tmp/eg365-manual.log 2>&1; then
          echo "EG365_MANUAL: execution_ok"
        else
          rc=$?
          echo "EG365_MANUAL_ERROR: execution_failed rc=$rc"
          tail -60 /tmp/eg365-manual.log | sed -E 's/Bearer [A-Za-z0-9._-]+/Bearer [REDACTED]/g' || true
        fi
        /opt/venv/bin/python - <<'PY' || true
import os,sqlite3
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
con=sqlite3.connect(db,timeout=20)
try:
    row=con.execute("SELECT id,status,startedAt,stoppedAt FROM execution_entity WHERE workflowId=? ORDER BY id DESC LIMIT 1",('EG365CLOUDMANUALV128',)).fetchone()
    print("EG365_MANUAL_VERIFY: latest="+repr(row),flush=True)
finally:
    con.close()
PY
        /opt/venv/bin/python - <<'PY' || true
import os,sqlite3,json,re
db=os.environ.get('N8N_DB_PATH','/root/.n8n/database.sqlite')
wid='EG365CLOUDMANUALV128'
con=sqlite3.connect(db,timeout=20)
try:
    row=con.execute("SELECT id FROM execution_entity WHERE workflowId=? ORDER BY id DESC LIMIT 1",(wid,)).fetchone()
    if not row:
        print("EG365_MANUAL_TRACE: no_execution",flush=True); raise SystemExit
    drow=con.execute("SELECT data FROM execution_data WHERE executionId=?",(row[0],)).fetchone()
    if not drow or not drow[0]:
        print("EG365_MANUAL_TRACE: no_data",flush=True); raise SystemExit
    raw=json.loads(drow[0])
    if isinstance(raw,list):
        arr=raw; memo={}
        def top(i):
            if i in memo:return memo[i]
            if i<0 or i>=len(arr):return None
            x=arr[i]
            if isinstance(x,str):return x
            if isinstance(x,dict):
                out={}; memo[i]=out
                for k,v in x.items():out[k]=nested(v)
                return out
            if isinstance(x,list):
                out=[]; memo[i]=out; out.extend(nested(v) for v in x); return out
            return x
        def nested(v):
            if isinstance(v,str) and re.fullmatch(r'\d+',v):
                n=int(v)
                if 0<=n<len(arr): return top(n)
            if isinstance(v,dict): return {k:nested(x) for k,x in v.items()}
            if isinstance(v,list): return [nested(x) for x in v]
            return v
        root=top(0)
    else:
        root=raw
    run=((root or {}).get('resultData') or {}).get('runData') or {}
    nodes=list(run.keys())
    watch=['RSS OKU','ÖN FİLTRE + TEKRAR KONTROLÜ','HABER DETAYINI AÇ','OPENAI TOPLU İSTEK HAZIRLA','AI SONUÇLARI AÇ + YAYIN FİLTRESİ','YAYIN ADAYI VARSA DEVAM','SON DUPLICATE KONTROLÜ','TELEGRAM CANLI FİLTRE','TELEGRAM YAYINLA','INSTAGRAM CANLI FİLTRE','INSTAGRAM CONTAINER','INSTAGRAM YAYINLA','THREADS CANLI FİLTRE','THREADS CONTAINER','THREADS YAYINLA','FACEBOOK CANLI FİLTRE','FACEBOOK YAYINLA']
    def last_json(name):
        runs=run.get(name) or []
        for rr in reversed(runs):
            mains=((rr or {}).get('data') or {}).get('main') or []
            for branch in reversed(mains):
                if not branch: continue
                for item in reversed(branch):
                    if isinstance(item,dict) and isinstance(item.get('json'),dict): return item['json']
        return None
    out={'execution_id':row[0],'nodes':nodes}
    for name in watch:
        j=last_json(name)
        if j is None: continue
        out[name]={
          'status_only':j.get('status_only'),'run_mode':j.get('run_mode'),
          'title':str(j.get('title') or j.get('title_main') or '')[:120],
          'DURUM':str(j.get('DURUM') or '')[:140],
          'scan_debug':j.get('scan_debug'),
          'article_enriched':j.get('article_enriched'),
          'source_content_chars':j.get('source_content_chars'),
          'content_quality_pass':j.get('content_quality_pass'),
          'publish_telegram':j.get('publish_telegram'),
          'publish_instagram':j.get('publish_instagram'),
          'publish_threads':j.get('publish_threads'),
          'publish_facebook':j.get('publish_facebook'),
          'statusCode':j.get('statusCode') or j.get('status_code'),
          'error':str(j.get('error') or '')[:220],
          'raw_type':type(j.get('raw')).__name__ if 'raw' in j else None,
          'raw_preview':str(j.get('raw') or j.get('data') or j.get('body') or '')[:260]
        }
    print("EG365_MANUAL_TRACE: "+json.dumps(out,ensure_ascii=False),flush=True)
finally:
    con.close()
PY
        audit_last_manual
        echo "EG365_MANUAL: trigger_complete"
      fi
    fi
    sleep 2
  done
) &
TPID=$!

# Public self-ping every 8 minutes keeps Render Free warm without a local PC.
(
  while true; do
    sleep 480
    curl -fsS --connect-timeout 10 --max-time 30 "https://eg365-cloud.onrender.com/health" >/dev/null 2>&1       && echo "EG365_KEEPALIVE: ok"       || echo "EG365_KEEPALIVE: warning"
  done
) &
KPID=$!

wait "$RPID"
