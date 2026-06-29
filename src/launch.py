#!/usr/bin/env python3
"""leader/launch.py — open or reuse a session's terminal window via kitty.

kitty's remote-control protocol gives EXACT window management (by window id),
which Kaku/Ghostty/iTerm could not do reliably:
  - fresh: `kitty @ launch --type=os-window` -> returns the new window id
  - reuse: `kitty @ focus-window --match id:<id>` -> focuses that exact window,
           even when many windows share the same cwd.

Single source of truth, used by the native app (CLI) and server.py (import).
CLI:  python3 launch.py <sid> [cwd]   ->  prints JSON {ok, reused, win}
"""
import json, os, subprocess, sys, time
import config

KITTY = config.KITTY
SOCK = config.SOCK
WINMAP = config.data_file("windows.json")   # sid -> kitty win id

def _k(*args):
    return subprocess.run([KITTY, "@", "--to", SOCK, *args],
                          capture_output=True, text=True)

# CRITICAL: Leader runs from inside a Claude Code session, so its env carries
# CLAUDE_CODE_*/CLAUDECODE/CODEX_COMPANION_*. If a `claude` is launched with those
# set, it thinks it's a NESTED child session and does NOT persist its transcript
# (data loss on close!). We must strip them from the kitty daemon's env AND unset
# them in each window's command (the daemon propagates env to every window).
POISON_PREFIXES = ("CLAUDE_CODE", "CODEX_COMPANION")
POISON_EXACT = ("CLAUDECODE", "CLAUDE_PLUGIN_DATA", "CLAUDE_EFFORT")
POISON_VARS = [
    "CLAUDECODE", "CLAUDE_PLUGIN_DATA", "CLAUDE_EFFORT",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_SESSION_ID", "CODEX_COMPANION_SESSION_ID",
]

def _clean_env() -> dict:
    env = dict(os.environ)
    for k in list(env):
        if k.startswith(POISON_PREFIXES) or k in POISON_EXACT:
            env.pop(k, None)
    return env

def _ensure_kitty() -> bool:
    """Make sure a kitty instance with our remote-control socket is running."""
    if _k("ls").returncode == 0:
        return True
    subprocess.Popen(
        [KITTY, "--single-instance", "-o", "allow_remote_control=yes",
         "--listen-on", SOCK, "-o", "macos_quit_when_last_window_closed=no"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=_clean_env())
    for _ in range(40):
        time.sleep(0.2)
        if _k("ls").returncode == 0:
            return True
    return False

# 台前调度:试过用 `resize-os-window --action hide` 收起其它窗口,但与
# `osascript activate`(把目标提前必需)互斥——激活 app 会把 hide 的窗口重新唤出,
# 且 kitty hide/show 对快速程序化切换不稳。故改用"固定大窗口 + 聚焦置前":
# 大号目标窗口提到最前即把其它会话盖在后面,实质等效"一次只见一个"。
STAGE = False

def _live_ids() -> set:
    r = _k("ls")
    if r.returncode != 0:
        return set()
    ids = set()
    try:
        for o in json.loads(r.stdout):
            for t in o["tabs"]:
                for w in t["windows"]:
                    ids.add(w["id"])
    except Exception:
        pass
    return ids

def _show(win_id) -> bool:
    # show is idempotent and returns rc 0 iff the os-window still exists
    # (even when hidden, where it drops out of `ls`); also un-hides it.
    return _k("resize-os-window", "--match", f"id:{win_id}", "--action", "show").returncode == 0

def _hide_others(keep_id, winmap: dict):
    for wid in set(winmap.values()):
        if wid != keep_id:
            _k("resize-os-window", "--match", f"id:{wid}", "--action", "hide")

def _front():
    subprocess.run(["osascript", "-e", 'tell application "kitty" to activate'],
                   capture_output=True)

def _load() -> dict:
    try:
        return json.load(open(WINMAP))
    except Exception:
        return {}

def _save(m: dict):
    os.makedirs(os.path.dirname(WINMAP), exist_ok=True)
    json.dump(m, open(WINMAP, "w"))

def launch(sid: str, cwd: str = "") -> dict:
    if not _ensure_kitty():
        return {"ok": False, "err": "kitty 启动失败"}
    winmap = _load()
    prev = winmap.get(sid)
    if prev is not None and _show(prev):                 # reuse exact window
        _k("focus-window", "--match", f"id:{prev}")
        if STAGE:
            _hide_others(prev, winmap)
        _front()
        return {"ok": True, "reused": True, "win": prev}
    safe_cwd = cwd if cwd and os.path.isdir(cwd) else os.path.expanduser("~")
    # unset poison vars so claude runs as a real TOP-LEVEL session and persists
    # its transcript (the kitty daemon may have inherited them — see _clean_env).
    unset = "unset " + " ".join(POISON_VARS)
    # NOT exec: keep claude as a child of the shell, so Ctrl+C / claude exit
    # drops back to an interactive shell instead of killing the whole window.
    cmd = (f"{unset}; {config.proxy_cmd()}; "
           f"CLAUDE=\"$(command -v claude || echo {config.claude_fallback()})\"; "
           f"\"$CLAUDE\" --dangerously-skip-permissions --resume {sid}; exec /bin/zsh -i")
    r = _k("launch", "--type=os-window", "--cwd", safe_cwd,
           "--", "/bin/zsh", "-lc", cmd)
    wid = r.stdout.strip()
    try:
        winmap[sid] = int(wid)
        _save(winmap)
    except (ValueError, TypeError):
        return {"ok": False, "err": f"launch 未返回 id: {wid[:60]} {r.stderr[:80]}"}
    if STAGE:
        _hide_others(winmap[sid], winmap)
    _front()
    return {"ok": True, "reused": False, "win": winmap[sid]}

def _project_dir(cwd: str) -> str:
    enc = cwd.rstrip("/").replace("/", "-")
    return os.path.join(config.projects_dir(), enc)

def new_session(cwd: str) -> dict:
    """Start a BRAND-NEW claude session (no --resume) in cwd, then detect the
    new transcript's sid and add it to the tracking map."""
    if not _ensure_kitty():
        return {"ok": False, "err": "kitty 启动失败"}
    safe_cwd = cwd if cwd and os.path.isdir(cwd) else config.new_session_cwd()
    import glob as _glob
    proj = _project_dir(safe_cwd)
    before = set(_glob.glob(os.path.join(proj, "*.jsonl")))
    unset = "unset " + " ".join(POISON_VARS)   # 同 resume:防止跑成嵌套子会话→不落盘
    cmd = (f"{unset}; {config.proxy_cmd()}; "
           f"CLAUDE=\"$(command -v claude || echo {config.claude_fallback()})\"; "
           f"\"$CLAUDE\" --dangerously-skip-permissions; exec /bin/zsh -i")
    wid = _k("launch", "--type=os-window", "--cwd", safe_cwd,
             "--", "/bin/zsh", "-lc", cmd).stdout.strip()
    try:
        wid = int(wid)
    except ValueError:
        return {"ok": False, "err": f"launch 未返回 id: {wid[:60]}"}
    _front()
    # poll for the new transcript file to learn the new sid, then track it
    sid = None
    for _ in range(48):
        time.sleep(0.25)
        new = set(_glob.glob(os.path.join(proj, "*.jsonl"))) - before
        if new:
            newest = max(new, key=os.path.getmtime)
            sid = os.path.basename(newest)[:-6]
            break
    if sid:
        winmap = _load(); winmap[sid] = wid; _save(winmap)
    return {"ok": True, "win": wid, "sid": sid}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "err": "usage: launch.py <sid> [cwd] | new <cwd>"}))
        sys.exit(1)
    if sys.argv[1] == "new":
        print(json.dumps(new_session(sys.argv[2] if len(sys.argv) > 2 else "")))
    else:
        print(json.dumps(launch(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")))
