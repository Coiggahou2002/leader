#!/usr/bin/env python3
"""leader/server.py — persistent local GUI for the session fleet.

A zero-dependency (stdlib only) web app bound to 127.0.0.1. Lists every
Claude Code session bucketed into 需处理 / 活跃 / 最近, and a click resumes
that session in a fresh Kaku window via:  proxy && claude --resume <sid>

Run:   python3 server.py        # then open http://127.0.0.1:8799
Safe:  localhost-only; /open only accepts session ids it already scanned
       (prevents command injection).
"""
import json, os, sys, time, html, subprocess, re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan  # noqa: E402

PORT = 8799
from launch import launch  # noqa: E402  shared window logic (also a CLI)

_cache = {"t": 0.0, "data": []}

def sessions(ttl=4.0):
    if time.time() - _cache["t"] > ttl:
        _cache["data"] = scan.collect()
        _cache["t"] = time.time()
    return _cache["data"]

PAGE = """<!doctype html><html lang=zh><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Leader · 会话舰队</title><style>
*{box-sizing:border-box;margin:0}body{font:14px/1.5 -apple-system,system-ui,sans-serif;
background:#0d1117;color:#e6edf3;padding:18px 20px 60px}
h1{font-size:16px;font-weight:600;margin-bottom:2px}
.sub{color:#7d8590;font-size:12px;margin-bottom:18px}
h2{font-size:12px;font-weight:600;letter-spacing:.04em;color:#7d8590;
margin:22px 0 8px;text-transform:uppercase}
.card{background:#161b22;border:1px solid #21262d;border-radius:9px;padding:11px 13px;
margin-bottom:7px;cursor:pointer;transition:.12s;display:flex;align-items:center;gap:12px}
.card:hover{border-color:#388bfd;background:#1c2530;transform:translateX(2px)}
.dot{width:8px;height:8px;border-radius:50%;flex:0 0 8px}
.live{background:#3fb950;box-shadow:0 0 6px #3fb950}.dead{background:#484f58}
.maybe{background:#d29922}
.body{flex:1;min-width:0}.title{font-weight:600;white-space:nowrap;overflow:hidden;
text-overflow:ellipsis}.meta{color:#7d8590;font-size:12px;white-space:nowrap;
overflow:hidden;text-overflow:ellipsis;margin-top:1px}
.why{color:#f0883e;font-size:11.5px;margin-top:2px}
.go{color:#388bfd;font-size:18px;opacity:0;transition:.12s}.card:hover .go{opacity:1}
.a h2{color:#f85149}.empty{color:#484f58;font-size:12px;padding:4px 2px}
#toast{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:#238636;
color:#fff;padding:9px 18px;border-radius:8px;opacity:0;transition:.2s;pointer-events:none;
font-weight:600}#toast.show{opacity:1}
details summary{color:#7d8590;font-size:12px;cursor:pointer;margin-top:20px}
.foot{color:#484f58;font-size:11px;margin-top:24px;border-top:1px solid #21262d;padding-top:10px}
</style></head><body>
<h1>🎯 Leader · 会话舰队</h1>
<div class=sub id=sub>加载中…</div>
<div id=app></div>
<div id=toast></div>
<div class=foot>点任意会话 → 新 Kaku 窗口运行 <code>proxy && claude --resume</code>。每 5 秒自动刷新。</div>
<script>
const HOME=__HOME__;
const $=s=>document.querySelector(s);
function card(s){
  const dot=s.alive?(s.where.includes('?')?'maybe':'live'):'dead';
  const repo=(s.cwd||'?').replace(HOME+'/dev/','').replace(HOME+'/','~/');
  const ago=s.idle_h<48?Math.round(s.idle_h)+'h':Math.round(s.idle_h/24)+'d';
  const tok=s.out_tok>=1000?Math.round(s.out_tok/1000)+'k':s.out_tok;
  return `<div class=card onclick="go('${s.full_sid}')">
    <div class="dot ${dot}"></div>
    <div class=body>
      <div class=title>${esc(s.title||s.last_prompt||'(无标题)')}</div>
      <div class=meta>${esc(repo)}@${esc(s.branch||'?')} · ${ago}前 · ${s.msgs}条/${tok} · ${esc(s.where)}</div>
      ${s.why.length?`<div class=why>${esc(s.why.join(' · '))}</div>`:''}
    </div><div class=go>→</div></div>`;
}
function esc(t){const d=document.createElement('div');d.textContent=t;return d.innerHTML;}
function section(t,arr,cls){
  return `<div class="${cls||''}"><h2>${t} (${arr.length})</h2>`+
    (arr.length?arr.map(card).join(''):'<div class=empty>—</div>')+'</div>';}
async function load(){
  const s=await(await fetch('/api')).json();
  const a=s.filter(x=>x.bucket==='a');
  const recent=s.filter(x=>x.bucket==='b').slice(0,15);
  const reap=s.filter(x=>x.bucket==='c');
  $('#sub').textContent=`${s.length} 个会话 · ${a.length} 需处理 · ${s.filter(x=>x.alive).length} 个已知活跃`;
  $('#app').innerHTML=
    section('🔴 需处理',a,'a')+
    section('🕐 最近',recent)+
    `<details><summary>⚪ 可清理 (${reap.length})</summary>${reap.map(card).join('')}</details>`;
}
async function go(sid){
  const r=await(await fetch('/open?sid='+sid)).json();
  toast(r.ok?(r.reused?'↩︎ 已切回原窗口':'✅ 已开新 Kaku 窗口'):'❌ '+(r.err||'失败'));
}
function toast(m){const t=$('#toast');t.textContent=m;t.classList.add('show');
  setTimeout(()=>t.classList.remove('show'),2200);}
load();setInterval(load,5000);
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            page = PAGE.replace("__HOME__", json.dumps(os.path.expanduser("~")))
            return self._send(200, page, "text/html")
        if u.path == "/api":
            return self._send(200, json.dumps(sessions(), default=str))
        if u.path == "/open":
            sid = (parse_qs(u.query).get("sid") or [""])[0]
            known = {s["full_sid"]: s for s in sessions(ttl=0.5)}
            if not re.fullmatch(r"[0-9a-f-]{36}", sid) or sid not in known:
                return self._send(400, json.dumps({"ok": False, "err": "未知会话"}))
            try:
                res = launch(sid, known[sid].get("cwd") or "")
                return self._send(200 if res.get("ok") else 500,
                                  json.dumps(res))
            except Exception as e:
                return self._send(500, json.dumps({"ok": False, "err": str(e)}))
        return self._send(404, json.dumps({"err": "not found"}))

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"Leader GUI → http://127.0.0.1:{PORT}  (Ctrl-C 退出)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
