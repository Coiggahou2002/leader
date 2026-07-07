#!/usr/bin/env python3
"""leader/pin.py — manage the pinned-sessions list.

Pinned sessions show in a flat 置顶 section at the very top (no folder grouping).
Store: ~/.claude/leader/pinned.json = {"sids": [...]}

The list is ORDERED (by pin time: add appends, remove filters) — the app sorts
the 置顶 section by this order so pinned rows never reshuffle as activity
recency changes. Do not sort it.

CLI:  python3 pin.py add <sid> | remove <sid> | list
"""
import json, os, sys

PATH = os.path.expanduser("~/.claude/leader/pinned.json")

def _load() -> list:
    try:
        sids = json.load(open(PATH)).get("sids", [])
        return [s for i, s in enumerate(sids) if s not in sids[:i]]  # de-dup, keep order
    except Exception:
        return []

def _save(sids: list):
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    json.dump({"sids": sids}, open(PATH, "w"))

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "err": "usage: pin.py add|remove|list [sid]"})); sys.exit(1)
    cmd, sids = sys.argv[1], _load()
    if cmd == "list":
        print(json.dumps({"ok": True, "sids": sids})); return
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "err": "missing sid"})); sys.exit(1)
    sid = sys.argv[2]
    if cmd == "add":
        if sid not in sids:
            sids.append(sid)
    elif cmd == "remove":
        sids = [x for x in sids if x != sid]
    else:
        print(json.dumps({"ok": False, "err": f"unknown cmd {cmd}"})); sys.exit(1)
    _save(sids)
    print(json.dumps({"ok": True, "pinned": cmd == "add", "sid": sid}))

if __name__ == "__main__":
    main()
