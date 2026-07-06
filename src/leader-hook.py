#!/usr/bin/env python3
"""leader/leader-hook.py — Claude Code hook that reports turn lifecycle to Leader.

Installed only for Leader-launched sessions via `claude --settings <leader-hooks.json>`
(see ensureLeaderHookSettings() in LeaderApp.swift). Claude Code invokes it on
`UserPromptSubmit` / `Stop` / `SessionEnd`, piping a JSON event on stdin. We write a
tiny per-session record into the activity dir; Leader watches that dir (FSEvents) and
pulses the sidebar row when a *non-focused* session finishes (Stop).

Contract (do NOT break — hooks run synchronously inside every turn):
  * stdlib only, no network, no sleeps — must add ~zero latency.
  * print NOTHING to stdout: for UserPromptSubmit, stdout is injected into the
    prompt context; for Stop, a nonzero exit blocks stopping. Always exit 0.
  * write atomically (tmp + os.replace) so Leader never reads a half file.

Usage:  leader-hook.py <activity_dir>   (stdin = hook event JSON)
"""
import sys, os, json, time


def main() -> None:
    if len(sys.argv) < 2:
        return
    act_dir = os.path.expanduser(sys.argv[1])
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    sid = data.get("session_id")
    if not sid:
        return
    rec = {
        "sid": sid,
        "event": data.get("hook_event_name") or "?",
        "ts": time.time(),
        "cwd": data.get("cwd"),
        "ppid": os.getppid(),  # the claude process; lets scan.py check liveness
    }
    try:
        os.makedirs(act_dir, exist_ok=True)
        tmp = os.path.join(act_dir, f".{sid}.tmp")
        with open(tmp, "w") as f:
            json.dump(rec, f)
        os.replace(tmp, os.path.join(act_dir, f"{sid}.json"))
    except Exception:
        pass  # never surface an error to the parent claude


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
