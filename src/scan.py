#!/usr/bin/env python3
"""leader/scan.py — read-only fleet scanner (the JSON backend for the Leader app).

Scans ~/.claude/projects/*/*.jsonl session transcripts + git worktrees, buckets
every session into (b) can-wait / (c) reap, and prints the fleet as JSON on
stdout — the app's sole data source.

Pure stdlib, read-only. Tunable thresholds live in CONFIG below.
Usage:  python3 scan.py [--repo SUBSTR] [--all]   # always prints JSON
  --repo SUBSTR : only sessions whose cwd contains SUBSTR
  --all         : include the long tail of unrelated projects
"""
from __future__ import annotations
import json, os, sys, time, subprocess, glob, re
from datetime import datetime
import config

# ---- tunable thresholds (the priority rules, in one place) -----------------
CONFIG = {
    "canwait_days": 7,       # younger than this & clean             -> (b)
    "reap_days": 14,         # older than this                       -> (c)
    "tiny_msgs": 3,          # fewer user+assistant msgs than this   -> tiny
    "tiny_idle_days": 2,     #            ... & idle this long        -> (c)
    "tail_bytes": 60_000,    # only json-parse the last N bytes/file (cost guard)
}
# does the last assistant turn actually ask the user something?
ASK = re.compile(r"[?？]|要不要|要我|还是.{0,8}[?？]?$|请确认|你想|你要|"
                 r"哪一个|需要你|确认一下|帮你.{0,6}吗|是否")
PROJECTS = config.projects_dir()
REGISTRY = config.data_file("registry")  # written by the hook (unused for now)
NOW = time.time()

# ---- live session detection (where is each session running?) ----------------
def live_map() -> tuple[dict, dict]:
    """Return (sid->tty exact, cwd->[ttys] fuzzy) for running claude REPLs.

    Exact mapping only exists for sessions launched with `--resume <sid>` OR
    recorded by the leader hook in REGISTRY. Everything else can only be
    narrowed to "one of the live panes sharing this cwd".
    """
    sid2tty, cwd2ttys = {}, {}
    # 1) hook-written registry is authoritative
    if os.path.isdir(REGISTRY):
        for fn in os.listdir(REGISTRY):
            try:
                r = json.load(open(os.path.join(REGISTRY, fn)))
                if r.get("pid") and os.path.exists(f"/proc/{r['pid']}"):
                    pass  # linux only; mac falls through to pid check below
                alive = _pid_alive(r.get("pid"))
                if alive:
                    sid2tty[r["sid"]] = r.get("tty")
            except Exception:
                continue
    # 2) scan live claude REPLs for tty/cwd + argv sid
    try:
        ps = subprocess.run(["ps", "-axo", "pid,tty,command"],
                            capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return sid2tty, cwd2ttys
    for line in ps.splitlines():
        # NOTE: no leading space in the "claude" test — Leader's embedded panes
        # exec the FULL PATH (/…/.local/bin/claude), which " claude" never
        # matched, so embedded sessions were invisible to alive-detection.
        # /bin/zsh still excluded: the wrapper line duplicates the child's argv.
        if "claude" not in line or "OpenIsland" in line or "/bin/zsh" in line:
            continue
        m = re.match(r"\s*(\d+)\s+(ttys\d+)\s+(.*claude.*)", line)
        if not m:
            continue
        pid, tty, cmd = m.group(1), m.group(2), m.group(3)
        sid_m = re.search(r"--resume\s+([0-9a-f-]{36})|-r\s+([0-9a-f-]{36})", cmd)
        if sid_m:
            sid2tty[sid_m.group(1) or sid_m.group(2)] = tty
        cwd = _pid_cwd(pid)
        if cwd:
            cwd2ttys.setdefault(cwd, []).append(tty)
    return sid2tty, cwd2ttys

def _pid_alive(pid) -> bool:
    try:
        return bool(pid) and subprocess.run(["kill", "-0", str(pid)],
                    capture_output=True).returncode == 0
    except Exception:
        return False

def _pid_cwd(pid: str) -> str | None:
    try:
        out = subprocess.run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
                            capture_output=True, text=True, timeout=8).stdout
        for ln in out.splitlines():
            if ln.startswith("n"):
                return ln[1:]
    except Exception:
        pass
    return None

# ---- git worktree state ----------------------------------------------------
def worktrees(repo: str) -> dict:
    """branch -> {dirty, ahead, merged, path} for one repo's worktrees."""
    out = {}
    try:
        raw = subprocess.run(["git", "-C", repo, "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return out
    cur = {}
    for line in raw.splitlines():
        if line.startswith("worktree "):
            cur = {"path": line[9:]}
        elif line.startswith("branch "):
            cur["branch"] = line.split("/")[-1]
            out[cur["path"]] = cur
    # enrich: dirty + ahead, but skip the 40 locked agent-* trees (cheap signal)
    for path, wt in out.items():
        wt["agent_tree"] = "/.claude/worktrees/agent-" in path + "/"
        if wt.get("agent_tree"):
            continue
        try:
            st = subprocess.run(["git", "-C", path, "status", "--porcelain"],
                                capture_output=True, text=True, timeout=15).stdout
            wt["dirty"] = bool(st.strip())
            ab = subprocess.run(["git", "-C", path, "rev-list", "--count",
                                 "@{upstream}..HEAD"], capture_output=True,
                                text=True, timeout=15)
            wt["ahead"] = int(ab.stdout.strip()) if ab.returncode == 0 else 0
        except Exception:
            wt["dirty"], wt["ahead"] = None, None
    return out

# ---- per-session digest ----------------------------------------------------
def _ts(s: str) -> float:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0

def _encode(p: str) -> str:
    """claude's project-folder encoding: every non-alphanumeric -> '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", p)

def _resume_dir(path: str, cwds: list[str]) -> str | None:
    """Directory `claude --resume <sid>` MUST run from: the one whose encoding
    matches the transcript's parent folder (that folder is fixed at session
    START cwd; the session may `cd` elsewhere later, so the last-seen cwd is
    often wrong). The folder name is lossy (/, _, ., - all collapse to '-') so
    it can't be decoded — instead forward-encode each recorded cwd and match."""
    folder = os.path.basename(os.path.dirname(path))
    matches = [c for c in cwds if _encode(c) == folder]
    for c in matches:                       # prefer one that still exists
        if os.path.isdir(c):
            return c
    if matches:
        return matches[0]
    return cwds[0] if cwds else None

def digest(path: str) -> dict:
    st = os.stat(path)
    d = {"file": path, "sid": os.path.basename(path)[:8], "idle_h": None,
         "title": None, "last_prompt": None, "cwd": None, "resume_cwd": None,
         "branch": None, "msgs": 0, "out_tok": 0, "last_role": None,
         "last_stop": None, "asks": False}
    cwds_seen: list[str] = []   # ordered-unique cwds, to pick the resume dir
    # last activity = newest in-transcript message timestamp, NOT file mtime
    # (a background indexer rewrites these files and pollutes mtime).
    last_ts = 0.0
    last_assistant_stop = None
    last_assistant_text = ""
    last_msg_role = None
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except Exception:
        return d
    for line in data.decode("utf-8", "replace").splitlines():
        if not line:
            continue
        # substring prefilter to avoid parsing every huge content blob
        if ('"ai-title"' not in line and '"last-prompt"' not in line
                and '"type":"user"' not in line and '"type":"assistant"' not in line):
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        t = e.get("type")
        if t == "ai-title":
            d["title"] = e.get("aiTitle")
        elif t == "last-prompt":
            d["last_prompt"] = (e.get("lastPrompt") or "")[:90]
        elif t in ("user", "assistant"):
            d["msgs"] += 1
            last_msg_role = t
            if e.get("cwd"):
                d["cwd"] = e["cwd"]
                if e["cwd"] not in cwds_seen:
                    cwds_seen.append(e["cwd"])
            if e.get("gitBranch"):
                d["branch"] = e["gitBranch"]
            if e.get("timestamp"):
                last_ts = max(last_ts, _ts(e["timestamp"]))
            if t == "assistant":
                m = e.get("message", {})
                u = m.get("usage", {})
                d["out_tok"] += u.get("output_tokens", 0) or 0
                last_assistant_stop = m.get("stop_reason")
                c = m.get("content", "")
                txt = c if isinstance(c, str) else " ".join(
                    b.get("text", "") for b in c if isinstance(b, dict))
                if txt.strip():
                    last_assistant_text = txt
    d["last_role"] = last_msg_role
    d["last_stop"] = last_assistant_stop
    d["resume_cwd"] = _resume_dir(path, cwds_seen) or d["cwd"]
    d["idle_h"] = (NOW - last_ts) / 3600 if last_ts else (NOW - st.st_mtime) / 3600
    # only the tail of the last assistant turn matters for this signal
    d["asks"] = bool(ASK.search(last_assistant_text[-300:]))
    return d

# ---- bucketing (apply the rules) -------------------------------------------
# There is deliberately NO "needs you" tier: every transcript heuristic we tried
# (answered-and-asking, unpushed commits, bad-state tails) fired far too often,
# so it was removed. Attention now comes from the live hook signals in the app
# (shimmer / breathing dot / unread), not transcript archaeology. Only the bucket
# (b/c) is kept — purely to order sessions within a list.
def classify(d: dict) -> str:
    c = CONFIG
    idle_d = d["idle_h"] / 24
    # (c) reap: long-idle, or a near-empty session left sitting
    if idle_d > c["reap_days"]:
        return "c"
    if d["msgs"] < c["tiny_msgs"] and idle_d > c["tiny_idle_days"]:
        return "c"
    # (b) everything else can wait
    return "b"

# ---- collect ---------------------------------------------------------------
def _flag_set(name: str) -> set:
    try:
        return set(json.load(open(config.data_file(f"{name}.json"))).get("sids", []))
    except Exception:
        return set()

def _flag_list(name: str) -> list:
    """Like _flag_set but ORDER-PRESERVING (pinned.json is ordered by pin time)."""
    try:
        return list(json.load(open(config.data_file(f"{name}.json"))).get("sids", []))
    except Exception:
        return []

def collect(repo_filter: str | None = None, show_all: bool = False) -> list:
    wt_all = {}
    for repo in config.worktree_repos():
        wt_all.update(worktrees(repo))
    sid2tty, cwd2ttys = live_map()
    archived = _flag_set("archived")
    # pin order = position in pinned.json (pin time); drives the stable 置顶 sort
    pin_idx = {sid: i for i, sid in enumerate(_flag_list("pinned"))}
    unread = _flag_set("unread")
    try:
        names = json.load(open(config.data_file("names.json")))
    except Exception:
        names = {}

    sessions = []
    for jf in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")):
        d = digest(jf)
        cwd = d.get("cwd") or ""
        if repo_filter and repo_filter not in cwd:
            continue
        wt = wt_all.get(cwd)
        bucket = classify(d)
        full_sid = os.path.basename(d["file"])[:-6]
        # "alive" = exactly identified as running (only --resume/hook sessions).
        # cwd-sibling liveness is too fuzzy to label a specific session active.
        alive = full_sid in sid2tty
        if full_sid in sid2tty:
            where = f"🟢 活着 @ {sid2tty[full_sid]}"
        elif cwd in cwd2ttys:
            where = f"↻ 同目录另有 {len(cwd2ttys[cwd])} 个活 pane"
        else:
            where = "⚪ 已关"
        d.update(bucket=bucket, wt=wt, full_sid=full_sid,
                 alive=alive, where=where, archived=full_sid in archived,
                 pinned=full_sid in pin_idx, pin_order=pin_idx.get(full_sid),
                 unread=full_sid in unread, nickname=names.get(full_sid))
        sessions.append(d)

    home = os.path.expanduser("~")
    def relevance(d):
        cwd = d.get("cwd") or ""
        if not cwd.startswith(home):
            return False
        # drop only throwaway dirs: tmp, agent scratchpads, harness scratch
        # worktrees. KEEP named worktrees like impl/.claude/worktrees/aim-480.
        return not any(x in cwd for x in
                       ("/private/tmp", "/scratchpad", "/.claude/worktrees/agent-"))
    if not show_all and not repo_filter:
        sessions = [s for s in sessions if relevance(s)]
    order = {"a": 0, "b": 1, "c": 2}
    sessions.sort(key=lambda s: (order[s["bucket"]], s["idle_h"]))
    return sessions

# ---- main ------------------------------------------------------------------
def main():
    args = sys.argv[1:]
    show_all = "--all" in args
    repo_filter = None
    if "--repo" in args:
        repo_filter = args[args.index("--repo") + 1]
    sessions = collect(repo_filter, show_all)
    print(json.dumps(sessions, ensure_ascii=False, default=str))

if __name__ == "__main__":
    main()
