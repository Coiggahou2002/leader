#!/usr/bin/env python3
"""leader/unread.py — manage the manually-marked "unread" session list.

A session marked unread shows a red "1" badge in the sidebar (see Row/UnreadBadge).
It's a manual flag: right-click -> 标记未读; opening the session auto-clears it
(email-like), and right-click -> 标记已读 clears it too.
Store: ~/.claude/leader/unread.json = {"sids": [...]}

CLI:  python3 unread.py add <sid> | remove <sid> | list
"""
import json, os, sys

PATH = os.path.expanduser("~/.claude/leader/unread.json")

def _load() -> set:
    try:
        return set(json.load(open(PATH)).get("sids", []))
    except Exception:
        return set()

def _save(s: set):
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    tmp = f"{PATH}.{os.getpid()}.tmp"   # pid-unique: concurrent writers must not truncate each other's tmp
    with open(tmp, "w") as f:
        json.dump({"sids": sorted(s)}, f)
    os.replace(tmp, PATH)   # atomic: scan.py's 6s reader must never see a half file

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "err": "usage: unread.py add|remove|list [sid]"})); sys.exit(1)
    cmd, s = sys.argv[1], _load()
    if cmd == "list":
        print(json.dumps({"ok": True, "sids": sorted(s)})); return
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "err": "missing sid"})); sys.exit(1)
    sid = sys.argv[2]
    if cmd == "add": s.add(sid)
    elif cmd == "remove": s.discard(sid)
    else: print(json.dumps({"ok": False, "err": f"unknown cmd {cmd}"})); sys.exit(1)
    _save(s)
    print(json.dumps({"ok": True, "unread": cmd == "add", "sid": sid}))

if __name__ == "__main__":
    main()
