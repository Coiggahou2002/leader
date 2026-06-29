#!/usr/bin/env python3
"""leader/name.py — per-session nickname (Leader-only display name).

Store: ~/.claude/leader/names.json = {sid: nickname}

CLI:  python3 name.py set <sid> <nickname...>
      python3 name.py clear <sid>
      python3 name.py list
"""
import json, os, sys

PATH = os.path.expanduser("~/.claude/leader/names.json")

def _load() -> dict:
    try:
        return json.load(open(PATH))
    except Exception:
        return {}

def _save(d: dict):
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    json.dump(d, open(PATH, "w"), ensure_ascii=False)

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "err": "usage: name.py set|clear|list [sid] [nickname]"})); sys.exit(1)
    cmd, d = sys.argv[1], _load()
    if cmd == "list":
        print(json.dumps({"ok": True, "names": d}, ensure_ascii=False)); return
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "err": "missing sid"})); sys.exit(1)
    sid = sys.argv[2]
    if cmd == "set":
        nick = " ".join(sys.argv[3:]).strip()
        if nick:
            d[sid] = nick
        else:
            d.pop(sid, None)
    elif cmd == "clear":
        d.pop(sid, None)
    else:
        print(json.dumps({"ok": False, "err": f"unknown cmd {cmd}"})); sys.exit(1)
    _save(d)
    print(json.dumps({"ok": True, "sid": sid, "nickname": d.get(sid)}, ensure_ascii=False))

if __name__ == "__main__":
    main()
