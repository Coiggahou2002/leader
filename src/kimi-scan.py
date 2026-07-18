#!/usr/bin/env python3
"""Read-only, best-effort inventory of locally saved Kimi Code CLI sessions.

`~/.kimi-code/session_index.jsonl` is the cheap session index.  `state.json`
inside each session directory holds the title / cwd / last update.  Neither file
format is written by Leader.
"""
from __future__ import annotations
import json, os, sys, uuid
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
KIMI = os.path.join(HOME, ".kimi-code")
INDEX = os.path.join(KIMI, "session_index.jsonl")


def parse_time(value: str | None) -> float:
    try:
        return datetime.fromisoformat((value or "").replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def state_json(session_dir: str) -> dict | None:
    path = os.path.join(session_dir, "state.json")
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def collect() -> list[dict]:
    items = []
    try:
        lines = open(INDEX, encoding="utf-8")
    except Exception:
        lines = []
    now = datetime.now(timezone.utc).timestamp()
    for line in lines:
        try:
            idx = json.loads(line)
            sid = idx.get("sessionId")
            if not sid:
                continue
            # Only accept normal session_<uuid> ids from the local index, never an
            # arbitrary string that could be interpreted as shell syntax.
            try:
                uuid.UUID(sid.removeprefix("session_") if sid.startswith("session_") else sid)
            except (ValueError, AttributeError, TypeError):
                continue
            session_dir = idx.get("sessionDir", "")
            st = state_json(session_dir)
            if st is None:
                # Kimi may archive sessions and move state.json elsewhere; skip
                # entries we cannot resume deterministically.
                continue
            ts = parse_time(st.get("updatedAt"))
            idle_h = (now - ts) / 3600 if ts else 0
            cwd = st.get("workDir") or idx.get("workDir")
            items.append({
                "full_sid": sid,
                "sid": sid.removeprefix("session_")[:8] if sid.startswith("session_") else sid[:8],
                "title": st.get("title"),
                "cwd": cwd,
                "resume_cwd": cwd,
                "idle_h": max(0, idle_h),
                "file": os.path.join(session_dir, "state.json"),
            })
        except Exception:
            continue
    return sorted(items, key=lambda x: x["idle_h"])


if __name__ == "__main__":
    print(json.dumps(collect(), ensure_ascii=False))
