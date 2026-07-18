#!/usr/bin/env python3
"""Read-only, best-effort inventory of locally saved Codex CLI sessions.

`session_index.jsonl` is the cheap title/time index.  The session event files hold
the original cwd required to resume a useful terminal, so we read only each file's
first session_meta record.  Neither file format is written by Leader.
"""
from __future__ import annotations
import glob, json, os, sys, uuid
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CODEX = os.path.join(HOME, ".codex")
INDEX = os.path.join(CODEX, "session_index.jsonl")

def parse_time(value: str | None) -> float:
    try:
        return datetime.fromisoformat((value or "").replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0

def metadata() -> dict[str, dict]:
    result = {}
    for path in glob.glob(os.path.join(CODEX, "sessions", "*", "*", "*", "*.jsonl")):
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    entry = json.loads(line)
                    if entry.get("type") != "session_meta":
                        continue
                    p = entry.get("payload") or {}
                    sid = p.get("session_id") or p.get("id")
                    if sid:
                        result[sid] = {"cwd": p.get("cwd"), "path": path}
                    break
        except Exception:
            continue
    return result

def collect() -> list[dict]:
    metas = metadata()
    items = []
    try:
        lines = open(INDEX, encoding="utf-8")
    except Exception:
        lines = []
    now = datetime.now(timezone.utc).timestamp()
    for line in lines:
        try:
            idx = json.loads(line)
            sid = idx.get("id")
            if not sid:
                continue
            # The resume command is assembled by a shell-hosted terminal.  Only
            # accept normal UUID session ids from the local index, never an
            # arbitrary string that could be interpreted as shell syntax.
            try:
                uuid.UUID(sid)
            except (ValueError, AttributeError, TypeError):
                continue
            # Codex leaves archived sessions in session_index.jsonl but moves their
            # transcript out of ~/.codex/sessions into archived_sessions. They cannot
            # be resumed until the user explicitly unarchives them, so omit them
            # entirely rather than showing a row that deterministically errors.
            meta = metas.get(sid)
            if meta is None:
                continue
            ts = parse_time(idx.get("updated_at"))
            idle_h = (now - ts) / 3600 if ts else 0
            items.append({
                "full_sid": sid, "sid": sid[:8], "title": idx.get("thread_name"),
                "cwd": meta.get("cwd"), "resume_cwd": meta.get("cwd"),
                "idle_h": max(0, idle_h), "file": meta.get("path"),
            })
        except Exception:
            continue
    return sorted(items, key=lambda x: x["idle_h"])

if __name__ == "__main__":
    print(json.dumps(collect(), ensure_ascii=False))
