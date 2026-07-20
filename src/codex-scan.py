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
                    # `id` is this rollout's own id; `session_id` points at the
                    # PARENT thread for continued/sub-agent rollouts. Key by `id`:
                    # an archived thread's own rollout is moved out of sessions/,
                    # but child rollouts referencing it via session_id stay behind
                    # and would otherwise lend it a cwd, slipping it past the
                    # archived filter below (codex resume then hard-errors).
                    sid = p.get("id") or p.get("session_id")
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
    # session_index.jsonl is append-only: Codex appends a fresh line whenever a
    # thread's name/updated_at changes instead of rewriting the old one. Keep
    # only the LAST line per session id, or one session renders as duplicate
    # rows (duplicate SwiftUI ForEach ids — hovering one row highlights its
    # same-id twin elsewhere in the list).
    latest: dict[str, dict] = {}
    for line in lines:
        try:
            idx = json.loads(line)
        except Exception:
            continue
        if idx.get("id"):
            latest[idx["id"]] = idx
    for idx in latest.values():
        try:
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
