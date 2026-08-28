#!/usr/bin/env python3
"""leader/hidden.py — manage the hidden-sessions blacklist.

Hidden sessions are dropped from scan.py entirely — they do NOT appear in the main
list, NOT under 已归档, nowhere. Use this for throwaway/eval/harness sessions you
never want to see again. Unhide with `remove`.

The blacklist DATA lives at ~/.claude/leader/hidden.json (outside the repo, on your
machine only) — it is never committed. Only this generic reader/writer is code.

Store: ~/.claude/leader/hidden.json = {"sids": [...]}

CLI:  python3 hidden.py add <sid> | remove <sid> | list
"""
import json, os, sys

PATH = os.path.expanduser("~/.claude/leader/hidden.json")

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
        print(json.dumps({"ok": False, "err": "usage: hidden.py add|remove|list [sid]"})); sys.exit(1)
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
    print(json.dumps({"ok": True, "hidden": cmd == "add", "sid": sid}))

if __name__ == "__main__":
    main()
