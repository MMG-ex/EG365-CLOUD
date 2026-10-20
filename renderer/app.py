import os, io, re, uuid, mimetypes, math, urllib.request, urllib.parse
from typing import List, Optional, Any
from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import Response, FileResponse
from pydantic import BaseModel
from PIL import Image, ImageDraw, ImageFont, ImageFilter

APP_NAME="MMG EG365 Newsroom Renderer V6"
BASE=os.path.dirname(os.path.abspath(__file__))
OUTPUT=os.environ.get("OUTPUT_DIR",os.path.join(BASE,"output"))
PUBLIC_BASE=os.environ.get("PUBLIC_BASE_URL","http://host.docker.internal:8787").rstrip("/")
FONT_REG="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_BOLD="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
os.makedirs(OUTPUT,exist_ok=True)
app=FastAPI(title=APP_NAME)

class Card(BaseModel):
    title: str=""
    body: str=""

class RenderRequest(BaseModel):
    category: str="GÜNDEM"
    title: str=""
    headline_top: Optional[str]=""
    headline_highlight: Optional[str]=""
    hook: Optional[str]=""
    summary: str=""
    lead: Optional[str]=""
    bullets: List[Any]=[]
    cards: List[Card]=[]
    source: str="MEB"
    source_url: Optional[str]=""
    source_image_url: Optional[str]=""
    source_image_credit: Optional[str]=""
    source_image_b64: Optional[str]=""
    news_id: Optional[str]=""

def clean(s=""):
    s=re.sub(r"https?://\S+"," ",str(s or ""))
    s=re.sub(r"<[^>]*>"," ",s)
    return re.sub(r"\s+"," ",s).strip()

def fnt(size,bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REG,size)

def wrap(draw,text,font,max_w):
    words=clean(text).split()
    lines=[]; cur=""
    for w in words:
        t=w if not cur else cur+" "+w
        if draw.textbbox((0,0),t,font=font)[2] <= max_w or not cur:
            cur=t
        else:
            lines.append(cur); cur=w
    if cur: lines.append(cur)
    return lines

def fit_lines(draw,text,box,max_size,min_size,max_lines,bold=False,spacing=1.06):
    x1,y1,x2,y2=box
    for size in range(max_size,min_size-1,-1):
        font=fnt(size,bold)
        lines=wrap(draw,text,font,x2-x1)
        if len(lines)>max_lines: continue
        asc,desc=font.getmetrics()
        lh=(asc+desc)*spacing
        if len(lines)*lh <= (y2-y1):
            return font,lines,lh
    # safe truncation
    s=clean(text)
    while len(s)>28:
        s=s[:-8].rstrip(" ,;:-")+"…"
        for size in range(max_size,min_size-1,-1):
            font=fnt(size,bold); lines=wrap(draw,s,font,x2-x1)
            if len(lines)<=max_lines:
                asc,desc=font.getmetrics(); lh=(asc+desc)*spacing
                if len(lines)*lh <= (y2-y1): return font,lines,lh
    # Son güvenlik: minimum fontta metni kutuya kesin sığdır.
    font=fnt(min_size,bold)
    lines=wrap(draw,clean(text),font,x2-x1)
    lines=lines[:max_lines] if lines else [""]
    if lines:
        last=lines[-1]
        # Taşan son satırı piksel genişliğine göre kısalt.
        while last and draw.textbbox((0,0),last+"…",font=font)[2] > (x2-x1):
            last=last[:-1].rstrip()
        if len(lines)==max_lines and (" ".join(lines) != clean(text) or len(wrap(draw,clean(text),font,x2-x1))>max_lines):
            lines[-1]=(last.rstrip(" ,;:-")+"…") if last else "…"
    asc,desc=font.getmetrics(); lh=(asc+desc)*spacing
    # Dikey sığma için gerekirse satır sayısını azalt.
    max_by_h=max(1,int((y2-y1)//max(1,lh)))
    lines=lines[:min(max_lines,max_by_h)]
    return font,lines,lh

def draw_text(draw,text,box,max_size,min_size,max_lines,color,bold=False,spacing=1.06):
    font,lines,lh=fit_lines(draw,text,box,max_size,min_size,max_lines,bold,spacing)
    x1,y1,x2,y2=box
    y=y1
    for line in lines:
        draw.text((x1,y),line,font=font,fill=color)
        y+=lh
    return y

def vertical_gradient(w,h,top,bottom):
    im=Image.new("RGB",(w,h),top)
    px=im.load()
    for y in range(h):
        t=y/max(1,h-1)
        c=tuple(int(top[i]*(1-t)+bottom[i]*t) for i in range(3))
        for x in range(w): px[x,y]=c
    return im

def add_background(im):
    d=ImageDraw.Draw(im,"RGBA")
    # diagonal luminous blue washes
    for r,a in [(760,20),(600,24),(450,28)]:
        d.ellipse((560-r,110-r,560+r,110+r),outline=(0,103,255,a),width=3)
    # globe-like dotted arcs
    cx,cy=830,180
    for rr in [170,220,270,320]:
        d.arc((cx-rr,cy-rr,cx+rr,cy+rr),195,350,fill=(28,145,255,45),width=2)
    for ang in range(-65,70,15):
        x2=cx+int(430*math.cos(math.radians(ang)))
        y2=cy+int(240*math.sin(math.radians(ang)))
        d.line((cx-150,cy+40,x2,y2),fill=(41,135,255,24),width=1)
    # bottom network
    for x in range(0,1080,90):
        d.line((540,1180,x,1340),fill=(0,106,255,24),width=1)
    for y in range(1080,1340,55):
        d.line((0,y,1080,y-80),fill=(0,106,255,18),width=1)
    return im

def fetch_image(url="",b64data=""):
    try:
        raw=b""
        if b64data:
            import base64
            raw=base64.b64decode(str(b64data).split(",")[-1])
        elif url:
            req=urllib.request.Request(str(url),headers={"User-Agent":"Mozilla/5.0","Accept":"image/*,*/*;q=0.8"})
            with urllib.request.urlopen(req,timeout=18) as r:
                raw=r.read(9*1024*1024)
        if not raw: return None
        return Image.open(io.BytesIO(raw)).convert("RGB")
    except Exception:
        return None

def cover(src,size):
    w,h=size
    ratio=max(w/src.width,h/src.height)
    nw=max(1,int(src.width*ratio)); nh=max(1,int(src.height*ratio))
    src=src.resize((nw,nh),Image.LANCZOS)
    l=max(0,(nw-w)//2); t=max(0,(nh-h)//2)
    return src.crop((l,t,l+w,t+h))

def round_paste(base,src,box,radius=24):
    x1,y1,x2,y2=box; w=x2-x1; h=y2-y1
    src=cover(src,(w,h))
    mask=Image.new("L",(w,h),0); md=ImageDraw.Draw(mask)
    md.rounded_rectangle((0,0,w-1,h-1),radius=radius,fill=255)
    base.paste(src,(x1,y1),mask)

def draw_icon(d,cx,cy,kind):
    red=(230,0,35,255); white=(255,255,255,255)
    d.ellipse((cx-49,cy-49,cx+49,cy+49),fill=red)
    if kind==0:
        d.ellipse((cx-12,cy-26,cx+12,cy-2),fill=white)
        d.ellipse((cx-34,cy-18,cx-16,cy),fill=white)
        d.ellipse((cx+16,cy-18,cx+34,cy),fill=white)
        d.rounded_rectangle((cx-18,cy+2,cx+18,cy+29),radius=9,fill=white)
        d.rounded_rectangle((cx-42,cy+5,cx-20,cy+28),radius=7,fill=white)
        d.rounded_rectangle((cx+20,cy+5,cx+42,cy+28),radius=7,fill=white)
    elif kind==1:
        d.polygon([(cx-35,cy-4),(cx,cy-34),(cx+35,cy-4)],fill=white)
        d.rectangle((cx-28,cy-4,cx+28,cy+30),fill=white)
        d.rectangle((cx-7,cy+8,cx+7,cy+30),fill=red)
        d.rectangle((cx-22,cy+5,cx-12,cy+15),fill=red)
        d.rectangle((cx+12,cy+5,cx+22,cy+15),fill=red)
        d.rectangle((cx-4,cy-47,cx+4,cy-31),fill=white)
    else:
        # gear
        d.ellipse((cx-29,cy-29,cx+29,cy+29),fill=white)
        for a in range(0,360,45):
            rad=math.radians(a)
            x=cx+int(35*math.cos(rad)); y=cy+int(35*math.sin(rad))
            d.rectangle((x-9,y-9,x+9,y+9),fill=white)
        d.ellipse((cx-12,cy-12,cx+12,cy+12),fill=red)

def split_title(req):
    top=clean(req.headline_top)
    hi=clean(req.headline_highlight)
    title=clean(req.title)
    if top or hi:
        return top or title, hi
    # heuristic: first clause white, rest yellow
    if ":" in title:
        a,b=title.split(":",1); return a.strip()+":",b.strip()
    words=title.split()
    cut=max(3,min(len(words)-2,int(len(words)*0.45))) if len(words)>6 else max(1,len(words)//2)
    return " ".join(words[:cut])," ".join(words[cut:])

def normalize_cards(req):
    out=[]
    for c in req.cards or []:
        t=clean(c.title); b=clean(c.body)
        if t or b: out.append((t,b))
    if not out:
        for b in req.bullets or []:
            if isinstance(b,dict):
                t=clean(b.get("title","")); body=clean(b.get("body",""))
            else:
                s=clean(b)
                parts=s.split(":",1)
                if len(parts)==2 and len(parts[0])<65: t,body=parts[0].strip(),parts[1].strip()
                else: t,body="",s
            if t or body: out.append((t,body))
    return out[:3]

def render(req):
    W,H=1080,1350
    im=vertical_gradient(W,H,(3,16,52),(0,45,110))
    add_background(im)
    d=ImageDraw.Draw(im,"RGBA")

    # category
    d.rectangle((50,42,300,106),fill=(232,0,35,255))
    draw_text(d,clean(req.category).upper(),(78,57,284,100),38,27,1,"#FFFFFF",True,1.0)

    # source image card
    img_box=(610,220,1025,535)
    src=fetch_image(req.source_image_url,req.source_image_b64)
    if src:
        round_paste(im,src,img_box,24)
    else:
        # tasteful placeholder
        d.rounded_rectangle(img_box,radius=24,fill=(11,54,112,255),outline=(255,255,255,230),width=3)
        d.ellipse((730,305,890,465),outline=(255,255,255,80),width=4)
        d.text((765,355),"EG365",font=fnt(36,True),fill=(255,255,255,100))
    d.rounded_rectangle(img_box,radius=24,outline=(255,255,255,240),width=4)

    credit=clean(req.source_image_credit or req.source)
    if credit:
        label="Görsel: "+credit[:30]
        ff=fnt(15,True); tw=d.textbbox((0,0),label,font=ff)[2]
        x=img_box[2]-tw-30; y=img_box[3]-38
        d.rounded_rectangle((x-12,y-6,img_box[2]-8,img_box[3]-8),radius=10,fill=(3,32,77,230))
        d.text((x,y),label,font=ff,fill="white")

    top,hi=split_title(req)
    # title left
    y=145
    if top:
        y=draw_text(d,top,(60,y,575,300),52,34,3,"#FFFFFF",True,1.00)+5
    if hi:
        draw_text(d,hi,(60,y,575,430),52,34,4,"#FFC928",True,1.00)

    lead=clean(req.lead or req.summary or req.hook)
    if lead:
        draw_text(d,lead,(60,445,575,625),27,18,6,"#FFFFFF",False,1.10)

    cards=normalize_cards(req)
    card_y=[650,805,960]
    for i in range(3):
        y1=card_y[i]; y2=y1+132
        if i < len(cards):
            d.rounded_rectangle((65,y1,1015,y2),radius=23,fill=(7,55,112,235),outline=(0,116,220,150),width=2)
            ct,cb=cards[i]
            if ct:
                draw_text(d,ct,(95,y1+18,985,y1+58),25,18,1,"#FFFFFF",True,1.0)
                if cb:
                    draw_text(d,cb,(95,y1+60,985,y2-12),23,16,2,"#FFFFFF",False,1.04)
            else:
                draw_text(d,cb,(95,y1+28,985,y2-15),24,16,3,"#FFFFFF",False,1.06)

    # brand footer
    d.text((48,1130),"EG",font=fnt(82,True),fill="#FFFFFF")
    d.text((175,1130),"365",font=fnt(82,True),fill="#E60023")
    d.text((58,1226),"G Ü N C E L   H A B E R İ N   A D R E S İ",font=fnt(14,False),fill="#FFFFFF")

    # red web ribbon
    d.polygon([(705,1150),(1080,1150),(1080,1240),(650,1240)],fill=(224,0,29,255))
    d.polygon([(650,1240),(705,1150),(735,1150),(680,1240)],fill=(123,0,32,255))
    d.text((760,1172),"www.eg365.com",font=fnt(31,True),fill="#FFFFFF")
    # social row
    d.text((790,1260),"✈  |  ◎  |  X  |  f  |  ▶",font=fnt(22,True),fill="#FFFFFF")

    return im,len(cards)

@app.get("/health")
def health():
    return {"ok":True,"service":APP_NAME,"renderer_version":"NEWSROOM_V6","size":"1080x1350","public_base_url":PUBLIC_BASE}

@app.post("/render")
def render_api(req:RenderRequest):
    try:
        im,count=render(req)
    except Exception as e:
        raise HTTPException(400,str(e))
    b=io.BytesIO(); im.save(b,"JPEG",quality=94,optimize=True,progressive=True)
    return Response(b.getvalue(),media_type="image/jpeg",headers={"X-Bullet-Count":str(count),"X-Renderer-Version":"NEWSROOM_V6"})

@app.post("/publish")
async def publish(data:Optional[UploadFile]=File(None),file:Optional[UploadFile]=File(None),filename:Optional[str]=Form("")):
    up=data or file
    if up is None: raise HTTPException(400,"No file")
    raw=await up.read()
    if not raw: raise HTTPException(400,"Empty file")
    ext=os.path.splitext(filename or up.filename or "")[1].lower()
    if ext not in [".jpg",".jpeg",".png",".webp"]: ext=".jpg"
    name="eg365_"+uuid.uuid4().hex[:14]+ext
    path=os.path.join(OUTPUT,name); open(path,"wb").write(raw)
    public_base=PUBLIC_BASE
    try:
        public_base_file=os.path.join(OUTPUT,"public_base.txt")
        if os.path.exists(public_base_file):
            candidate=open(public_base_file,"r",encoding="utf-8").read().strip().rstrip("/")
            if candidate.startswith("https://"): public_base=candidate
    except Exception:
        pass
    url=public_base+"/media/"+name
    return {"ok":True,"filename":name,"public_upload_url":url,"url":url}

@app.get("/media/{filename}")
def media(filename:str):
    path=os.path.join(OUTPUT,os.path.basename(filename))
    if not os.path.exists(path): raise HTTPException(404,"Not found")
    return FileResponse(path,media_type=mimetypes.guess_type(path)[0] or "image/jpeg")


# -------- Free cloud AI editor: Pollinations anonymous OpenAI-compatible --------
class FreeAIRequest(BaseModel):
    prompt: str
    model: Optional[str]="openai"

def _compact_free_editor_prompt(prompt:str)->str:
    p=str(prompt or "")
    if len(p)<=4300:
        return p
    return p[:1500]+"\n\n[...SOURCE_ARTICLE KISALTILDI...]\n\n"+p[-2700:]

def _extract_results_obj(value):
    import json,re
    seen=set()
    def walk(v,depth=0):
        if depth>7: return None
        if isinstance(v,dict):
            if isinstance(v.get("results"),list) and v.get("results"):
                return {"results":v["results"]}
            for k in ("content","text","output","response","reasoning","arguments","tool_calls","message","data"):
                if k in v:
                    r=walk(v.get(k),depth+1)
                    if r: return r
            for x in v.values():
                r=walk(x,depth+1)
                if r: return r
            return None
        if isinstance(v,list):
            for x in v:
                r=walk(x,depth+1)
                if r: return r
            return None
        if not isinstance(v,str): return None
        t=v.strip()
        if not t or t in seen: return None
        seen.add(t)
        t=re.sub(r"^```(?:json)?\\s*","",t,flags=re.I)
        t=re.sub(r"\\s*```$","",t)
        try:
            obj=json.loads(t)
            r=walk(obj,depth+1)
            if r: return r
        except Exception:
            pass
        for m in re.finditer(r'\\{\\s*"results"\\s*:',t):
            start=m.start(); dep=0; ins=False; esc=False
            for i,ch in enumerate(t[start:],start):
                if ins:
                    if esc: esc=False
                    elif ch=="\\\\": esc=True
                    elif ch=='"': ins=False
                    continue
                if ch=='"': ins=True; continue
                if ch=="{": dep+=1
                elif ch=="}":
                    dep-=1
                    if dep==0:
                        cand=t[start:i+1]
                        try:
                            obj=json.loads(cand)
                            r=walk(obj,depth+1)
                            if r: return r
                        except Exception:
                            pass
                        break
        return None
    return walk(value)

def _pollinations_chat(prompt:str, model:str="openai"):
    import json, time
    last=None
    prompt=_compact_free_editor_prompt(prompt)
    # Free API Classic direct endpoint. This path is separate from the
    # OpenAI-compat /openai route, which can return 402 from cloud IPs.
    payload={
        "messages":[
            {"role":"system","content":"Türkçe profesyonel haber editörüsün. Kullanıcının istediği biçimi eksiksiz uygula. Yalnız geçerli JSON isteniyorsa yalnız JSON döndür."},
            {"role":"user","content":prompt}
        ],
        "model":"openai",
        "temperature":0.1,
        "jsonMode":True,
        "private":True
    }
    raw=json.dumps(payload,ensure_ascii=False).encode("utf-8")
    for attempt in range(2):
        try:
            req=urllib.request.Request(
                "https://text.pollinations.ai/",
                data=raw,method="POST",
                headers={
                    "User-Agent":"EG365-Cloud/1.0",
                    "Content-Type":"application/json",
                    "Accept":"text/plain,application/json"
                }
            )
            with urllib.request.urlopen(req,timeout=45) as r:
                body=r.read().decode("utf-8","replace").strip()
            if body:
                try:
                    obj=json.loads(body)
                    normalized=_extract_results_obj(obj)
                    if normalized:
                        return json.dumps(normalized,ensure_ascii=False),"openai-classic-post-normalized"
                    if isinstance(obj,str):
                        normalized=_extract_results_obj(obj)
                        if normalized:
                            return json.dumps(normalized,ensure_ascii=False),"openai-classic-post-normalized"
                except Exception:
                    normalized=_extract_results_obj(body)
                    if normalized:
                        return json.dumps(normalized,ensure_ascii=False),"openai-classic-post-normalized"
                last=RuntimeError("Pollinations semantic wrapper without results")
            else:
                last=RuntimeError("empty Pollinations classic POST response")
        except Exception as e:
            last=e
        if attempt==0:
            time.sleep(31)
    raise last or RuntimeError("Pollinations classic request failed")

@app.get("/ai-free/health")
def ai_free_health():
    return {"ok":True,"provider":"pollinations-free-classic","endpoint":"text.pollinations.ai","model":"openai"}

@app.post("/ai-free")
def ai_free(req:FreeAIRequest):
    prompt=str(req.prompt or "").strip()
    if not prompt:
        raise HTTPException(400,"prompt required")
    if len(prompt)>14000:
        prompt=prompt[:14000]
    print("EG365_FREE_AI_CALL: start prompt_chars="+str(len(prompt)),flush=True)
    try:
        text,model=_pollinations_chat(prompt,"openai")
        print("EG365_FREE_AI_CALL: ok model="+str(model)+" output_chars="+str(len(text)),flush=True)
        return {"ok":True,"output_text":text,"model":"pollinations/"+model}
    except Exception as e:
        print("EG365_FREE_AI_CALL: error type="+type(e).__name__+" message="+str(e)[:220],flush=True)
        raise HTTPException(502,"Pollinations free editor failed: "+str(e)[:240])

# -------- Official MEB discovery/article endpoints --------
def _fetch_remote(url:str):
    headers={"User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/154 Safari/537.36","Accept-Language":"tr-TR,tr;q=0.9","Connection":"close"}
    raw=b""; enc=None; last=None
    try:
        import requests
        rr=requests.get(url,headers=headers,timeout=(5,10),verify=False,allow_redirects=True)
        rr.raise_for_status()
        raw=rr.content; enc=rr.encoding
    except Exception as e:
        last=e
        try:
            import ssl
            ctx=ssl.create_default_context()
            ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
            req=urllib.request.Request(url,headers=headers)
            with urllib.request.urlopen(req,timeout=10,context=ctx) as r:
                raw=r.read(); enc=r.headers.get_content_charset()
        except Exception as e2:
            raise e2 from last
    for e in ("utf-8",enc,"iso-8859-9","windows-1254"):
        if not e: continue
        try: return raw.decode(e)
        except Exception: pass
    return raw.decode("utf-8","replace")

def _tag_text(s:str):
    import html
    s=re.sub(r"<script[\s\S]*?</script>|<style[\s\S]*?</style>"," ",str(s or ""),flags=re.I)
    s=re.sub(r"<[^>]+>"," ",s)
    return re.sub(r"\s+"," ",html.unescape(s)).strip()

def _attrs(tag:str):
    import html
    out={}
    for m in re.finditer(r"([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))",tag):
        out[m.group(1).lower()]=html.unescape(m.group(2) or m.group(3) or m.group(4) or "")
    return out

def _parse_date(s:str):
    import datetime
    t=_tag_text(s)
    m=re.search(r"(\d{1,2})[./-](\d{1,2})[./-](\d{4})(?:\s*(?:/|-)?\s*(\d{1,2})[:.](\d{2}))?",t)
    if m:
        try:
            dt=datetime.datetime(int(m.group(3)),int(m.group(2)),int(m.group(1)),int(m.group(4) or 12),int(m.group(5) or 0))
            return dt.isoformat(),int(dt.timestamp()*1000)
        except Exception: pass
    return "",0

def _allowed_news_url(url:str):
    try:
        u=urllib.parse.urlparse(url); h=(u.hostname or "").lower()
        if not (h=="meb.gov.tr" or h.endswith(".meb.gov.tr")): return False
        return bool(re.search(r"/(?:icerik|haber)/\d+(?:/tr)?/?$",u.path,re.I))
    except Exception: return False

@app.get("/discover")
def discover(url:str,source_name:str=""):
    import time
    raw=None; last=None
    for attempt in range(1):
        try:
            raw=_fetch_remote(url)
            break
        except Exception as e:
            last=e
            time.sleep(1.2*(attempt+1))
    if raw is None:
        return {"ok":False,"url":url,"error":str(last),"items":[]}
    items={}
    anchor_re=re.compile(r"<a\b([^>]*?)href\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s>]+))([^>]*)>([\s\S]*?)</a>",re.I)
    for m in anchor_re.finditer(raw):
        href=m.group(2) or m.group(3) or m.group(4) or ""
        link=urllib.parse.urljoin(url,href)
        if not _allowed_news_url(link): continue
        attrs=(m.group(1)+" "+m.group(5)).lower(); label=_tag_text(m.group(6))
        context=_tag_text(raw[m.end():min(len(raw),m.end()+520)])
        iso,ts=_parse_date((label+" "+context).strip())
        rank=4 if "news-title" in attrs else (2 if label and "[...]" not in label else 1)
        old=items.get(link); cand={"title":label,"link":link,"published":iso,"ts":ts,"summary":context[:1200],"source_name":source_name,"_rank":rank}
        if old is None: items[link]=cand
        else:
            if rank>old.get("_rank",0) and label: old["title"]=label; old["_rank"]=rank
            if ts>old.get("ts",0): old["ts"]=ts; old["published"]=iso; old["summary"]=context[:1200]
    out=[]
    for v in items.values():
        v.pop("_rank",None)
        if v.get("title"): out.append(v)
    out.sort(key=lambda x:x.get("ts",0),reverse=True)
    # Cloud optimization: article details are fetched later by the V128 article stage.
    # Keeping discovery link-only avoids N x article requests and n8n's 45s request timeout.
    return {"ok":True,"url":url,"count":len(out),"items":out[:40]}

@app.get("/article")
def article(url:str,source_name:str=""):
    import html
    if not _allowed_news_url(url): raise HTTPException(status_code=400,detail="Only official MEB article URLs are allowed")
    import time
    raw=None; last=None
    for attempt in range(1):
        try:
            raw=_fetch_remote(url)
            break
        except Exception as e:
            last=e
            time.sleep(1.2*(attempt+1))
    if raw is None:
        raise HTTPException(status_code=502,detail=str(last))
    metas={}
    for mt in re.findall(r"<meta\b[^>]*>",raw,re.I):
        a=_attrs(mt); key=(a.get("property") or a.get("name") or "").lower(); val=a.get("content","")
        if key and val: metas[key]=html.unescape(val).strip()
    title=metas.get("og:title") or _tag_text((re.search(r"<title[^>]*>([\s\S]*?)</title>",raw,re.I) or [None,""])[1])
    desc=metas.get("og:description") or metas.get("description","")
    img=metas.get("og:image") or metas.get("twitter:image") or metas.get("twitter:image:src") or ""
    if img: img=urllib.parse.urljoin(url,img)
    # prefer article-detail region, never whole <main>
    marker=re.search(r"class\s*=\s*(?:\"[^\"]*(?:content\s+article-detay|article-detay|haber-detay|icerik)[^\"]*\"|'[^']*(?:content\s+article-detay|article-detay|haber-detay|icerik)[^']*')",raw,re.I)
    region=raw[marker.start():marker.start()+36000] if marker else raw
    cut=re.search(r"(?:>\s*Paylaş\s*<|<footer\b|class\s*=\s*[\"'][^\"']*(?:share|footer))",region,re.I)
    if cut: region=region[:cut.start()]
    # Haber gövdesindeki gerçek fotoğrafı sosyal og:image kartına tercih et.
    body_img=""
    for itag in re.findall(r"<img\b[^>]*>",region,re.I):
        ia=_attrs(itag)
        cand=(ia.get("data-src") or ia.get("data-original") or ia.get("src") or "").strip()
        if not cand: continue
        cand=urllib.parse.urljoin(url,cand)
        info=(cand+" "+ia.get("alt","")).lower()
        if re.search(r"logo|icon|sprite|avatar|banner|loading|blank",info): continue
        if not re.search(r"\.(?:jpe?g|png|webp)(?:$|\?)",cand,re.I) and "meb_iys_dosyalar" not in cand.lower(): continue
        body_img=cand
        break
    if body_img: img=body_img
    paras=[]
    if desc: paras.append(_tag_text(desc))
    # MEB ana haber sayfası gövde paragraflarını çoğunlukla <div style="text-align:justify"> içinde tutuyor.
    # Önce gerçek paragraf etiketlerini, sonra yalnız metin hizalı gövde divlerini al; menü/yan haber alanlarını alma.
    blocks=[]
    for pm in re.finditer(r"<p\b[^>]*>([\s\S]*?)</p>",region,re.I):
        blocks.append(pm.group(1))
    for dm in re.finditer(r"<div\b[^>]*style\s*=\s*(?:\"[^\"]*text-align\s*:\s*justify[^\"]*\"|'[^']*text-align\s*:\s*justify[^']*')[^>]*>([\s\S]*?)</div>",region,re.I):
        blocks.append(dm.group(1))
    for block in blocks:
        t=_tag_text(block)
        if len(t)<35: continue
        if re.search(r"^(Adres|Telefon|İletişim)\s*:",t,re.I): continue
        if t not in paras: paras.append(t)
        if len(paras)>=20: break
    source_content=" ".join(paras).strip()
    pub,ts=_parse_date(_tag_text(region[:5000]))
    return {"ok":True,"title":_tag_text(title),"summary":_tag_text(desc),"source_content":source_content[:9000],"source_image_url":img,"source_image_credit":source_name or "MEB","official_source_url":url,"link":url,"published":pub,"ts":ts,"source_name":source_name or "Millî Eğitim Bakanlığı","content_chars":len(source_content)}

# -------- Encrypted n8n state backup for ephemeral cloud filesystems --------
@app.get("/")
def root_health():
    return health()

@app.get("/eg365-state-backup")
def eg365_state_backup():
    from pathlib import Path
    import sqlite3, tempfile
    from cryptography.fernet import Fernet

    key=os.environ.get("STATE_BACKUP_KEY","").strip()
    db_path=os.environ.get("N8N_DB_PATH","/root/.n8n/database.sqlite")
    if not key:
        raise HTTPException(503,"STATE_BACKUP_KEY not configured")
    if not os.path.exists(db_path):
        raise HTTPException(404,"n8n state database not ready")

    fd,tmp=tempfile.mkstemp(prefix="eg365-state-",suffix=".sqlite")
    os.close(fd)
    try:
        src=sqlite3.connect("file:"+db_path+"?mode=ro",uri=True,timeout=30)
        dst=sqlite3.connect(tmp,timeout=30)
        try:
            src.backup(dst)
            dst.commit()
        finally:
            dst.close()
            src.close()
        raw=Path(tmp).read_bytes()
        encrypted=Fernet(key.encode("utf-8")).encrypt(raw)
        return Response(
            encrypted,
            media_type="application/octet-stream",
            headers={"Cache-Control":"no-store","X-EG365-State":"encrypted"}
        )
    finally:
        try: os.unlink(tmp)
        except OSError: pass


# -------- One-time bootstrap: import runtime secrets from the verified V128 JSON --------
@app.get("/bootstrap/{token}")
def eg365_bootstrap_page(token:str):
    import html
    expected=os.environ.get("BOOTSTRAP_TOKEN","")
    if not expected or token != expected:
        raise HTTPException(404,"Not found")
    page="""<!doctype html><html><head><meta charset="utf-8"><title>EG365 CLOUD Bootstrap</title>
<style>body{font-family:system-ui;max-width:720px;margin:60px auto;padding:24px;background:#071c3d;color:white}
.card{background:#0d3268;padding:28px;border-radius:18px}input,button{font-size:16px;margin-top:16px}
button{padding:12px 18px;background:#e60023;color:white;border:0;border-radius:10px}</style></head>
<body><div class="card"><h1>EG365 CLOUD</h1><p>Çalışan V128 JSON dosyanı seç. Dosya sunucuda public olarak saklanmaz; yalnız gerekli anahtarlar n8n state veritabanına alınır.</p>
<form method="post" enctype="multipart/form-data"><input type="file" name="file" accept=".json,application/json" required><br>
<button type="submit">V128'i Cloud'a Aktar</button></form></div></body></html>"""
    return Response(page,media_type="text/html")

@app.post("/bootstrap/{token}")
async def eg365_bootstrap_import(token:str,file:UploadFile=File(...)):
    import json, sqlite3
    expected=os.environ.get("BOOTSTRAP_TOKEN","")
    if not expected or token != expected:
        raise HTTPException(404,"Not found")
    raw=await file.read()
    if not raw:
        raise HTTPException(400,"Empty file")
    try:
        obj=json.loads(raw.decode("utf-8-sig"))
    except Exception as e:
        raise HTTPException(400,"Invalid JSON")
    if isinstance(obj,list):
        if not obj: raise HTTPException(400,"Empty workflow list")
        obj=obj[0]
    nodes=obj.get("nodes") or []
    cfg=next((n for n in nodes if n.get("name")=="CONFIG"),None)
    if not cfg:
        raise HTTPException(400,"CONFIG node not found")
    code=((cfg.get("parameters") or {}).get("jsCode") or "")
    mapping={
      "OPENAI_API_KEY":"openai_api_key",
      "TELEGRAM_BOT_TOKEN":"telegram_bot_token",
      "TELEGRAM_CHAT_ID":"telegram_chat_id",
      "TELEGRAM_PUBLIC_URL":"telegram_public_url",
      "INSTAGRAM_USER_ID":"instagram_user_id",
      "INSTAGRAM_ACCESS_TOKEN":"instagram_access_token",
      "THREADS_ACCESS_TOKEN":"threads_access_token",
      "FACEBOOK_USER_ACCESS_TOKEN":"facebook_user_access_token",
      "FACEBOOK_PAGE_ID":"facebook_page_id",
      "FACEBOOK_PAGE_ACCESS_TOKEN":"facebook_page_access_token",
    }
    values={}
    for env_key,cfg_key in mapping.items():
        line=next((ln.strip() for ln in code.splitlines() if ln.strip().startswith(cfg_key+":")), "")
        if line:
            rhs=line.split(":",1)[1].strip().rstrip(",").strip()
            if len(rhs)>=2 and rhs[0] in (chr(34),chr(39),chr(96)) and rhs[-1]==rhs[0]:
                val=rhs[1:-1].strip()
                if val:
                    values[env_key]=val
    required=[k for k in mapping if k!="FACEBOOK_USER_ACCESS_TOKEN"]
    missing=[k for k in required if not values.get(k)]
    if missing:
        raise HTTPException(400,"Missing required V128 values: "+",".join(missing))
    db_path=os.environ.get("N8N_DB_PATH","/root/.n8n/database.sqlite")
    os.makedirs(os.path.dirname(db_path),exist_ok=True)
    con=sqlite3.connect(db_path,timeout=30)
    try:
        con.execute("CREATE TABLE IF NOT EXISTS eg365_secrets (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
        for k,v in values.items():
            con.execute("INSERT INTO eg365_secrets(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(k,v))
        con.execute("CREATE TABLE IF NOT EXISTS eg365_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
        con.execute("INSERT INTO eg365_meta(k,v) VALUES('bootstrap_done','1') ON CONFLICT(k) DO UPDATE SET v='1'")
        con.execute("DELETE FROM eg365_meta WHERE k='workflow_sha'")
        con.commit()
    finally:
        con.close()
    return Response("""<!doctype html><html><body style="font-family:system-ui;background:#071c3d;color:white;padding:50px">
<h1>EG365 CLOUD</h1><h2>V128 anahtarları güvenli şekilde alındı.</h2><p>Bu pencereyi kapatabilirsin.</p></body></html>""",media_type="text/html")


# -------- Protected one-click manual production trigger --------
@app.get("/run-now/{token}")
def eg365_run_now(token:str):
    import hmac, time
    expected=os.environ.get("MANUAL_RUN_KEY","").strip()
    if not expected or not hmac.compare_digest(token,expected):
        raise HTTPException(404,"Not found")
    trigger=os.environ.get("MANUAL_TRIGGER_FILE","/tmp/eg365-run-now.trigger")
    already=os.path.exists(trigger)
    if not already:
        with open(trigger,"w",encoding="utf-8") as f:
            f.write(str(int(time.time())))
    page="""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>EG365 Manuel Çalıştırma</title>
<style>body{font-family:system-ui;background:#071c3d;color:#fff;margin:0;padding:40px}.card{max-width:680px;margin:40px auto;background:#0d3268;padding:30px;border-radius:18px}.ok{font-size:24px;font-weight:800;color:#8cffb0}.note{opacity:.9}</style></head><body><div class="card"><div class="ok">EG365 manuel çalışma tetiklendi ✅</div><p>Cloud workflow tek seferlik çalışma kuyruğuna alındı.</p><p class="note">90 dakikalık otomatik yayın döngüsü aktif kalmaya devam eder. Bilgisayarın açık olması gerekmez.</p></div></body></html>"""
    return Response(page,media_type="text/html",headers={"Cache-Control":"no-store"})


@app.get("/meta-token/{token}")
def eg365_meta_token_page(token:str):
    import html
    expected=os.environ.get("MANUAL_RUN_KEY","").strip()
    if not expected or token != expected:
        raise HTTPException(404,"Not found")
    page="""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>EG365 Meta Token Güncelle</title><style>
body{font-family:system-ui;background:#071c3d;color:#fff;margin:0;padding:30px}.card{max-width:760px;margin:40px auto;background:#0d3268;padding:30px;border-radius:18px}
textarea{width:100%;min-height:170px;font-size:15px;padding:12px;border-radius:10px;box-sizing:border-box}button{margin-top:16px;padding:12px 20px;font-size:16px;background:#e60023;color:#fff;border:0;border-radius:10px}
.note{opacity:.85}</style></head><body><div class="card"><h1>EG365 Meta Token Güncelle</h1>
<p>Yeni Meta user access tokenını aşağıya yapıştır. Token yalnızca cloud n8n state veritabanına kaydedilir.</p>
<form method="post"><textarea name="user_token" required></textarea><br><button type="submit">Tokenı Doğrula ve Facebook'u Onar</button></form>
<p class="note">Telegram / Instagram / Threads / 90 dakikalık çalışma düzeni değiştirilmez.</p></div></body></html>"""
    return Response(page,media_type="text/html",headers={"Cache-Control":"no-store"})

@app.post("/meta-token/{token}")
def eg365_meta_token_save(token:str,user_token:str=Form(...)):
    import json, sqlite3, urllib.parse, urllib.request, urllib.error
    expected=os.environ.get("MANUAL_RUN_KEY","").strip()
    if not expected or token != expected:
        raise HTTPException(404,"Not found")
    user_token=(user_token or "").strip()
    if not user_token:
        raise HTTPException(400,"Token boş")
    db_path=os.environ.get("N8N_DB_PATH","/root/.n8n/database.sqlite")
    con=sqlite3.connect(db_path,timeout=20)
    try:
        con.execute("CREATE TABLE IF NOT EXISTS eg365_secrets (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
        vals=dict(con.execute("SELECT k,v FROM eg365_secrets").fetchall())
        wanted=(vals.get("FACEBOOK_PAGE_ID") or os.environ.get("FACEBOOK_PAGE_ID") or "").strip()
        q=urllib.parse.urlencode({"fields":"id,name,access_token","limit":"100","access_token":user_token})
        req=urllib.request.Request("https://graph.facebook.com/v24.0/me/accounts?"+q,headers={"User-Agent":"EG365-Cloud/1.0"})
        try:
            with urllib.request.urlopen(req,timeout=30) as r:
                obj=json.loads(r.read().decode("utf-8","replace"))
        except urllib.error.HTTPError as e:
            try:
                er=(json.loads(e.read().decode("utf-8","replace")).get("error") or {})
                msg=str(er.get("message") or "Meta token doğrulanamadı")[:180]
            except Exception:
                msg="Meta token doğrulanamadı"
            raise HTTPException(400,msg)
        pages=obj.get("data") or []
        page=next((x for x in pages if str(x.get("id") or "")==wanted and x.get("access_token")),None)
        if not page:
            page=next((x for x in pages if x.get("access_token") and any(t in str(x.get("name") or "").lower() for t in ("eğitim gündem 365","egitim gundem 365","egitimgundem365"))),None)
        if not page:
            raise HTTPException(400,"Eğitim Gündem 365 sayfası bu token ile bulunamadı")
        page_id=str(page.get("id") or wanted)
        page_token=str(page.get("access_token") or "")
        con.execute("INSERT INTO eg365_secrets(k,v) VALUES('FACEBOOK_USER_ACCESS_TOKEN',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(user_token,))
        con.execute("INSERT INTO eg365_secrets(k,v) VALUES('FACEBOOK_PAGE_ID',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(page_id,))
        con.execute("INSERT INTO eg365_secrets(k,v) VALUES('FACEBOOK_PAGE_ACCESS_TOKEN',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(page_token,))
        con.commit()

        # Apply the freshly validated Page token to the already-running cloud workflow immediately.
        # This avoids waiting for a restart and prevents an older boot-time token from being used.
        try:
            from pathlib import Path
            import subprocess, re as _re
            wf=Path("/opt/workflow/EG365_CLOUD_RENDER_V128.json")
            txt=wf.read_text(encoding="utf-8")
            txt=_re.sub(r"(facebook_page_id:\\s*')[^']*(')",lambda m:m.group(1)+page_id+m.group(2),txt,count=1)
            txt=_re.sub(r"(facebook_page_access_token:\\s*')[^']*(')",lambda m:m.group(1)+page_token+m.group(2),txt,count=1)
            wf.write_text(txt,encoding="utf-8")
            cp=subprocess.run(["n8n","import:workflow","--input="+str(wf)],capture_output=True,text=True,timeout=150)
            if cp.returncode!=0:
                raise RuntimeError("workflow re-import failed")
            con.execute("CREATE TABLE IF NOT EXISTS eg365_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
            con.execute("DELETE FROM eg365_meta WHERE k='workflow_sha'")
            con.commit()
        except Exception as e:
            raise HTTPException(500,"Token kaydedildi ancak workflow yenilenemedi: "+str(e)[:140])

        safe_name=str(page.get("name") or "")[:100]
        return Response(f"""<!doctype html><html><body style="font-family:system-ui;background:#071c3d;color:white;padding:50px">
<div style="max-width:720px;margin:auto;background:#0d3268;padding:30px;border-radius:18px"><h1>EG365 Meta</h1>
<h2>Token doğrulandı ve Facebook Page token yenilendi ✅</h2><p>Sayfa: {safe_name}</p><p>Page ID: {page_id}</p>
<p>Bu pencereyi kapatabilirsin.</p></div></body></html>""",media_type="text/html",headers={"Cache-Control":"no-store"})
    finally:
        con.close()


@app.get("/channels-diag/{token}")
def eg365_channels_diag(token:str):
    import json, re, urllib.parse, urllib.request, urllib.error, hmac
    expected=os.environ.get("MANUAL_RUN_KEY","").strip()
    if not expected or not hmac.compare_digest(token,expected):
        raise HTTPException(404,"Not found")
    wf_path="/opt/workflow/EG365_CLOUD_RENDER_V128.json"
    out={"telegram":{"configured":False,"ok":False},"instagram":{"configured":False,"ok":False},"threads":{"configured":False,"ok":False}}
    try:
        w=json.loads(open(wf_path,"r",encoding="utf-8").read())
        cfg=next((n for n in w.get("nodes",[]) if n.get("name")=="CONFIG"),None) or {}
        code=((cfg.get("parameters") or {}).get("jsCode") or "")
        def val(key):
            m=re.search(r"(?m)^\\s*"+re.escape(key)+r":\\s*['\"]([^'\"]*)['\"]",code)
            return (m.group(1).strip() if m else "")
        tg=(os.environ.get("TELEGRAM_BOT_TOKEN") or val("telegram_bot_token")).strip()
        ig_uid=(os.environ.get("INSTAGRAM_USER_ID") or val("instagram_user_id")).strip()
        ig=(os.environ.get("INSTAGRAM_ACCESS_TOKEN") or val("instagram_access_token")).strip()
        th=(os.environ.get("THREADS_ACCESS_TOKEN") or val("threads_access_token")).strip()
        out["telegram"]["configured"]=bool(tg)
        out["instagram"]["configured"]=bool(ig_uid and ig)
        out["threads"]["configured"]=bool(th)

        if tg:
            try:
                req=urllib.request.Request("https://api.telegram.org/bot"+tg+"/getMe",headers={"User-Agent":"EG365-Cloud/1.0"})
                with urllib.request.urlopen(req,timeout=20) as r:
                    j=json.loads(r.read().decode("utf-8","replace"))
                out["telegram"]={"configured":True,"ok":bool(j.get("ok")),"username":str((j.get("result") or {}).get("username") or "")[:80]}
            except Exception as e:
                out["telegram"]={"configured":True,"ok":False,"error":str(e)[:160]}

        if ig_uid and ig:
            try:
                q=urllib.parse.urlencode({"fields":"id,username","access_token":ig})
                req=urllib.request.Request("https://graph.instagram.com/v23.0/"+urllib.parse.quote(ig_uid)+"?"+q,headers={"User-Agent":"EG365-Cloud/1.0"})
                with urllib.request.urlopen(req,timeout=20) as r:
                    j=json.loads(r.read().decode("utf-8","replace"))
                out["instagram"]={"configured":True,"ok":bool(j.get("id")),"id":str(j.get("id") or "")[:40],"username":str(j.get("username") or "")[:80]}
            except urllib.error.HTTPError as e:
                try:
                    er=(json.loads(e.read().decode("utf-8","replace")).get("error") or {})
                    msg=str(er.get("message") or "")[:160]; code_=er.get("code")
                except Exception:
                    msg="HTTP error"; code_=e.code
                out["instagram"]={"configured":True,"ok":False,"error_code":code_,"error":msg}
            except Exception as e:
                out["instagram"]={"configured":True,"ok":False,"error":str(e)[:160]}

        if th:
            try:
                q=urllib.parse.urlencode({"fields":"id,username","access_token":th})
                req=urllib.request.Request("https://graph.threads.net/v1.0/me?"+q,headers={"User-Agent":"EG365-Cloud/1.0"})
                with urllib.request.urlopen(req,timeout=20) as r:
                    j=json.loads(r.read().decode("utf-8","replace"))
                out["threads"]={"configured":True,"ok":bool(j.get("id")),"id":str(j.get("id") or "")[:40],"username":str(j.get("username") or "")[:80]}
            except urllib.error.HTTPError as e:
                try:
                    er=(json.loads(e.read().decode("utf-8","replace")).get("error") or {})
                    msg=str(er.get("message") or "")[:160]; code_=er.get("code")
                except Exception:
                    msg="HTTP error"; code_=e.code
                out["threads"]={"configured":True,"ok":False,"error_code":code_,"error":msg}
            except Exception as e:
                out["threads"]={"configured":True,"ok":False,"error":str(e)[:160]}
    except Exception as e:
        out["error"]="diag_failed: "+str(e)[:180]
    out["all_ok"]=bool(out["telegram"].get("ok") and out["instagram"].get("ok") and out["threads"].get("ok"))
    return out


@app.get("/fb-diag")
def eg365_fb_diag():
    import json, urllib.parse, urllib.request, urllib.error, sqlite3
    db_path=os.environ.get("N8N_DB_PATH","/root/.n8n/database.sqlite")
    stored={}
    try:
        if os.path.exists(db_path):
            con=sqlite3.connect(db_path,timeout=10)
            try:
                con.execute("CREATE TABLE IF NOT EXISTS eg365_secrets (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
                stored=dict(con.execute("SELECT k,v FROM eg365_secrets").fetchall())
            finally:
                con.close()
    except Exception:
        pass
    token=(stored.get("FACEBOOK_PAGE_ACCESS_TOKEN") or os.environ.get("FACEBOOK_PAGE_ACCESS_TOKEN") or "").strip()
    page_id=(stored.get("FACEBOOK_PAGE_ID") or os.environ.get("FACEBOOK_PAGE_ID") or "").strip()
    out={"configured":bool(token and token!="PENDING"),"configured_page_id":page_id,"me":None,"pages":[],"errors":[]}
    if not out["configured"]:
        return out
    def call(path,fields):
        q=urllib.parse.urlencode({"fields":fields,"access_token":token})
        req=urllib.request.Request("https://graph.facebook.com/v24.0/"+path+"?"+q,headers={"User-Agent":"EG365-Cloud/1.0"})
        try:
            with urllib.request.urlopen(req,timeout=20) as r:
                return json.loads(r.read().decode("utf-8","replace")),None
        except urllib.error.HTTPError as e:
            try:
                er=(json.loads(e.read().decode("utf-8","replace")).get("error") or {})
                return None,{"path":path,"code":er.get("code"),"message":str(er.get("message") or "")[:180]}
            except Exception:
                return None,{"path":path,"code":e.code,"message":"HTTP error"}
        except Exception as e:
            return None,{"path":path,"code":None,"message":str(e)[:180]}
    me,err=call("me","id,name")
    if err: out["errors"].append(err)
    elif me: out["me"]={"id":str(me.get("id") or ""),"name":str(me.get("name") or "")[:80]}
    accounts,err=call("me/accounts","id,name,tasks")
    if err: out["errors"].append(err)
    elif accounts:
        out["pages"]=[{"id":str(x.get("id") or ""),"name":str(x.get("name") or "")[:80],"tasks":x.get("tasks") or []} for x in (accounts.get("data") or [])[:20]]
    target,err=call(page_id,"id,name") if page_id else (None,None)
    if err: out["errors"].append(err)
    elif target: out["target"]={"id":str(target.get("id") or ""),"name":str(target.get("name") or "")[:80]}
    return out


@app.get("/fb-probe-page")
def eg365_fb_probe_page():
    import json, urllib.parse, urllib.request, urllib.error, sqlite3
    db_path=os.environ.get("N8N_DB_PATH","/root/.n8n/database.sqlite")
    stored={}
    if os.path.exists(db_path):
        con=sqlite3.connect(db_path,timeout=10)
        try:
            con.execute("CREATE TABLE IF NOT EXISTS eg365_secrets (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
            stored=dict(con.execute("SELECT k,v FROM eg365_secrets").fetchall())
        finally:
            con.close()

    seed=(stored.get("FACEBOOK_USER_ACCESS_TOKEN") or os.environ.get("FACEBOOK_USER_ACCESS_TOKEN") or stored.get("FACEBOOK_PAGE_ACCESS_TOKEN") or os.environ.get("FACEBOOK_PAGE_ACCESS_TOKEN") or "").strip()
    wanted=(stored.get("FACEBOOK_PAGE_ID") or os.environ.get("FACEBOOK_PAGE_ID") or "").strip()
    if not seed or seed=="PENDING":
        return {"pass":False,"stage":"missing_seed"}

    def api_get(path,params):
        q=urllib.parse.urlencode(params)
        req=urllib.request.Request("https://graph.facebook.com/v24.0/"+path+"?"+q,headers={"User-Agent":"EG365-Cloud/1.0"})
        with urllib.request.urlopen(req,timeout=25) as r:
            return json.loads(r.read().decode("utf-8","replace"))

    try:
        acc=api_get("me/accounts",{"fields":"id,name,access_token","limit":"100","access_token":seed})
        pages=acc.get("data") or []
        page=next((x for x in pages if str(x.get("id") or "")==wanted and x.get("access_token")),None)
        if not page:
            page=next((x for x in pages if x.get("access_token") and "365" in str(x.get("name") or "")),None)
        if not page:
            return {"pass":False,"stage":"page_not_found","pages":[{"id":str(x.get("id") or ""),"name":str(x.get("name") or "")[:80]} for x in pages[:20]]}

        page_id=str(page.get("id") or "")
        page_token=str(page.get("access_token") or "")
        data=urllib.parse.urlencode({
            "message":"EG365 CLOUD Facebook bağlantı doğrulama testi",
            "published":"false",
            "access_token":page_token
        }).encode()
        req=urllib.request.Request(
            "https://graph.facebook.com/v24.0/"+page_id+"/feed",
            data=data,method="POST",
            headers={"User-Agent":"EG365-Cloud/1.0"}
        )
        with urllib.request.urlopen(req,timeout=30) as r:
            created=json.loads(r.read().decode("utf-8","replace"))
        post_id=str(created.get("id") or "")
        if not post_id:
            return {"pass":False,"stage":"create_no_id","page_id":page_id}

        deleted=False
        try:
            dd=urllib.parse.urlencode({"access_token":page_token}).encode()
            dr=urllib.request.Request(
                "https://graph.facebook.com/v24.0/"+post_id,
                data=dd,method="DELETE",
                headers={"User-Agent":"EG365-Cloud/1.0"}
            )
            with urllib.request.urlopen(dr,timeout=25) as r:
                dobj=json.loads(r.read().decode("utf-8","replace"))
            deleted=bool(dobj.get("success"))
        except Exception:
            deleted=False

        con=sqlite3.connect(db_path,timeout=10)
        try:
            con.execute("CREATE TABLE IF NOT EXISTS eg365_secrets (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
            con.execute("INSERT INTO eg365_secrets(k,v) VALUES('FACEBOOK_PAGE_ID',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(page_id,))
            con.execute("INSERT INTO eg365_secrets(k,v) VALUES('FACEBOOK_PAGE_ACCESS_TOKEN',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",(page_token,))
            con.commit()
        finally:
            con.close()

        return {"pass":True,"stage":"write_ok","page_id":page_id,"post_id":post_id,"deleted":deleted}
    except urllib.error.HTTPError as e:
        try:
            er=(json.loads(e.read().decode("utf-8","replace")).get("error") or {})
            return {"pass":False,"stage":"graph_error","code":er.get("code"),"message":str(er.get("message") or "")[:180]}
        except Exception:
            return {"pass":False,"stage":"http_error","code":e.code}
    except Exception as e:
        return {"pass":False,"stage":"exception","message":str(e)[:180]}
