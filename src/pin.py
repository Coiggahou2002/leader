#!/usr/bin/env python3
"""leader/pin.py — manage the pinned-sessions list.

Pinned sessions show in a flat 置顶 section at the very top (no folder grouping).
Store: ~/.claude/leader/pinned.json = {"sids": [...]}

CLI:  python3 pin.py add <sid> | remove <sid> | list
"""
import json, os, sys

PATH = os.path.expanduser("~/.claude/leader/pinned.json")

def _load() -> set:
    try:
        return set(json.load(open(PATH)).get("sids", []))
    except Exception:
        return set()

def _save(s: set):
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    json.dump({"sids": sorted(s)}, open(PATH, "w"))

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "err": "usage: pin.py add|remove|list [sid]"})); sys.exit(1)
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
    print(json.dumps({"ok": True, "pinned": cmd == "add", "sid": sid}))

if __name__ == "__main__":
    main()
