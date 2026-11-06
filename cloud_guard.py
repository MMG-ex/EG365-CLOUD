#!/usr/bin/env python3
"""EG365 Cloud: restore durable dedup state from actual n8n execution receipts.
No external requests or publication. Never delete existing staticData entries.
"""
import json
import os
import re
import sqlite3
import time
from urllib.parse import urlsplit

DB = os.environ.get("N8N_DB_PATH", "/root/.n8n/database.sqlite")
WORKFLOWS = ("EG365CLOUDRENDERV128", "EG365CLOUDMANUALV128")
LOCAL_PREVIOUSLY_PUBLISHED = [
  "https://ogm.meb.gov.tr/www/turkiye-yuzyili-maarif-modeli-12-sinif-taslak-ders-kitaplarinin-yazimi-ve-incelenmesi-calistayi-gerceklestirildi/icerik/2665/tr",
  "https://sgb.meb.gov.tr/www/milli-egitim-bakanimiz-sayin-yusuf-tekin039in-29-ekim-cumhuriyet-bayrami-mesaji/icerik/922/tr",
  "https://www.meb.gov.tr/bakan-tekin-istanbul039da-ogrencilerle-ve-ogretmenlerle-bulustu/haber/42281/tr",
  "https://www.meb.gov.tr/bakan-tekin-malatya039da-iki-okulun-temel-atma-torenine-katildi/haber/42406/tr",
  "https://www.meb.gov.tr/bakan-tekin-quotkitap-kurtlari-yarisiyorquot-programinin-tanitim-toplantisi039na-katildi/haber/42407/tr",
  "https://www.meb.gov.tr/bakan-tekin039in-29-ekim-cumhuriyet-bayrami-mesaji/haber/42330/tr",
  "https://www.meb.gov.tr/cop31039in-ev-sahibi-turkiye-iklim-degisikligiyle-mucadeleyi-egitim-sisteminin-odagina-koydu/haber/42409/tr",
  "https://www.meb.gov.tr/lgs-kapsamindaki-merkezi-sinavin-tarihi-belli-oldu/haber/42348/tr",
  "https://www.meb.gov.tr/milli-egitim-bakanligi-cop31039de-gerceklestirecegi-uluslararasi-etkinliklere-hazir/haber/42416/tr",
  "https://www.meb.gov.tr/ogretmenlerin-kasim-donemi-mesleki-calismalari-oba-uzerinden-gerceklestirilecek/haber/42351/tr",
  "https://www.meb.gov.tr/ortak-yazili-sinav-sistemi039yle-ilgili-quotsikca-sorulan-sorularquot-rehberi-hazirlandi/haber/42290/tr",
  "https://www.meb.gov.tr/quot12-mart-istiklal-marsi039nin-kabulu-ve-mehmet-akif-ersoy039u-anma-gunuquot-etkinlikleri-quotakif039in-ulkusu-yuzyilin-oykusuquot-temasiyla-duzenlenecek/haber/42418/tr",
  "https://www.meb.gov.tr/quotmeb-soz-varligi-bilgi-agiquot-tanitim-programi-bakan-tekin039in-katilimiyla-gerceklesti/haber/42261/tr",
  "https://www.meb.gov.tr/quottalim-ve-terbiye-kurulu-100-yil-ozel-oturumuquot-bakan-tekin-baskanliginda-yapildi/haber/42382/tr",
  "https://www.meb.gov.tr/quotyoung-and-wisequot-dergisinin-dorduncu-sayisi-quotegitimquot-temasiyla-yayimlandi/haber/42362/tr",
  "https://yegitek.meb.gov.tr/www/dinamik-ders-dili-projesi-kapsaminda-quotyenilikci-yaklasimlar-ve-teknoloji-kullanimi-egitici-egitimleriquot-gerceklestirildi/icerik/4070/tr",
  "https://yegitek.meb.gov.tr/www/meb-canva-tasarim-laboratuvarlari-10-ilde-es-zamanli-hizmete-acildi/icerik/4068/tr",
  "https://yegitek.meb.gov.tr/www/pardus-meb-25-surumleri-kullanicilarla-bulustu/icerik/4069/tr",
  "https://yegitek.meb.gov.tr/www/quotmeb-etkim-yildizlari-hizlandirma-programiquot-demo-day-etkinligi-gerceklestirildi/icerik/4061/tr",
  "https://yyegm.meb.gov.tr/www/balkanlar-egitim-degerlendirme-calistayi-belgrad039da-gerceklestirildi/icerik/1202/tr"
]

CHANNELS = {
    "TELEGRAM YAYINLA": "telegram",
    "INSTAGRAM YAYINLA": "instagram",
    "THREADS YAYINLA": "threads",
    "FACEBOOK YAYINLA": "facebook",
}

def expand(raw):
    entries = json.loads(raw)
    if not isinstance(entries, list):
        return entries
    memo = {}
    def unpack(v):
        if isinstance(v, str) and v.isascii() and v.isdigit() and int(v) < len(entries):
            i = int(v)
            if i in memo:
                return memo[i]
            obj = entries[i]
            if not isinstance(obj, (list, dict)):
                return obj
            dest = [] if isinstance(obj, list) else {}
            memo[i] = dest
            if isinstance(obj, list):
                dest.extend(unpack(x) for x in obj)
            else:
                dest.update({k: unpack(x) for k, x in obj.items()})
            return dest
        return v
    return unpack("0")

def items(run, name):
    for rr in run.get(name, []):
        for branch in (rr.get("data") or {}).get("main") or []:
            for item in branch or []:
                val = item.get("json") if isinstance(item, dict) else None
                if isinstance(val, dict):
                    yield val

def sourcekey(url):
    u = urlsplit(str(url).strip())
    if not u.hostname:
        return ""
    host = u.hostname.lower()
    path = re.sub(r"/+", "/", u.path).rstrip("/").lower()
    m = re.search(r"/(?:haber|icerik)/(\d+)(?:/tr)?$", path)
    return (host[4:] if host.startswith("www.") else host) + "|" + (m.group(1) if m else path)

def urlkey(url):
    u = urlsplit(str(url).strip())
    host = (u.hostname or "").lower()
    return (host + u.path.rstrip("/")).lower()

def fnv(value):
    n = 2166136261
    for ch in value:
        n ^= ord(ch)
        n = (n * 16777619) & 0xffffffff
    return format(n, "x")

def is_success(channel, obj):
    if "error" in obj and obj["error"]:
        return False
    if channel == "telegram":
        return obj.get("ok") is True and isinstance(obj.get("result"), dict) and bool(obj["result"].get("message_id"))
    return bool(obj.get("id") or obj.get("post_id")) and not obj.get("error")

def receipt(channel, obj):
    if channel == "telegram":
        return str(obj.get("result", {}).get("message_id", ""))
    return str(obj.get("post_id") or obj.get("id") or "")

def scan(con):
    con.execute("CREATE TABLE IF NOT EXISTS eg365_receipts (source_key TEXT NOT NULL, channel TEXT NOT NULL, receipt TEXT NOT NULL, url TEXT NOT NULL, execution_id INTEGER NOT NULL, PRIMARY KEY(source_key,channel))")
    # Seed confirmed LOCAL receipts so Cloud does not republish old local news.
    # This is additive and never deletes the existing cloud ledger.
    for url in LOCAL_PREVIOUSLY_PUBLISHED:
        sid = sourcekey(url)
        if sid:
            con.execute("INSERT OR IGNORE INTO eg365_receipts (source_key,channel,receipt,url,execution_id) VALUES(?,?,?,?,?)",
                        (sid, "local_history", "confirmed_local_publication", url, 0))
    records = []
    rows = con.execute(
        "SELECT e.id,e.workflowId,d.data FROM execution_entity e JOIN execution_data d ON d.executionId=e.id WHERE e.workflowId IN (?,?) ORDER BY e.id DESC LIMIT 1200",
        WORKFLOWS,
    )
    scanned = 0
    # Stream rows: loading the entire execution history can exceed Render's 512-MiB limit.
    for eid, wid, raw in rows:
        try:
            run = (expand(raw).get("resultData") or {}).get("runData") or {}
            if not isinstance(run, dict):
                continue
            # Only the items that passed the final duplicate gate could publish.
            chosen = []
            for name in run:
                if "SON DUPLICATE KONTROL" in name:
                    chosen.extend(items(run, name))
            if not chosen:
                continue
            # Pair node outputs by item index: an editor's other suggestions are
            # NOT evidence of publication and must remain eligible in future.
            outs = {channel: list(items(run, name)) for name,channel in CHANNELS.items()}
            verified = False
            for index, obj in enumerate(chosen):
                url = obj.get("official_source_url") or obj.get("source_url") or obj.get("link")
                if not url:
                    continue
                sid = sourcekey(url)
                if not sid:
                    continue
                for channel, values in outs.items():
                    if index < len(values) and is_success(channel, values[index]):
                        records.append((sid, channel, receipt(channel, values[index]), url, eid))
                        verified = True
            if verified:
                scanned += 1
        except Exception as exc:
            print("EG365_GUARD: history_row_warning id="+str(eid)+" error="+type(exc).__name__, flush=True)
    # Do not replace earlier receipts with newer duplicates.
    con.executemany("INSERT OR IGNORE INTO eg365_receipts (source_key,channel,receipt,url,execution_id) VALUES(?,?,?,?,?)", records)
    return scanned

def reconcile(con):
    protected = con.execute(
        "SELECT source_key, url, MIN(execution_id) FROM eg365_receipts GROUP BY source_key"
    ).fetchall()
    result = []
    for wid in WORKFLOWS:
        row = con.execute("SELECT staticData FROM workflow_entity WHERE id=?", (wid,)).fetchone()
        if row is None:
            continue
        static = json.loads(row[0] or "{}")
        if not isinstance(static, dict):
            static = {}
        published = static.setdefault("publishedNews", {})
        now = int(time.time() * 1000)
        count = 0
        for sid, url, eid in protected:
            record = {"publishedAt":now, "officialUrl":url, "title":"Prior confirmed publication", "sourceName":"MEB", "sourceExecutionId":eid}
            for key in ("sid:"+sid, "url:"+fnv(urlkey(url))):
                if key not in published:
                    published[key] = record
                    count += 1
        if count:
            con.execute("UPDATE workflow_entity SET staticData=? WHERE id=?", (json.dumps(static, ensure_ascii=False), wid))
        result.append((wid, count))
    return len(protected), result

def main():
    con = sqlite3.connect(DB, timeout=30)
    try:
        con.execute("PRAGMA busy_timeout=30000")
        con.execute("BEGIN IMMEDIATE")
        completed = scan(con)
        total, delta = reconcile(con)
        con.commit()
        print("EG365_GUARD: ok histories="+str(completed)+" unique_sources="+str(total)+" added="+str(delta), flush=True)
    except Exception as exc:
        con.rollback()
        print("EG365_GUARD_ERROR: "+type(exc).__name__+": "+str(exc)[:150], flush=True)
        raise
    finally:
        con.close()
if __name__ == "__main__":
    main()
