#!/usr/bin/env python3
"""leader/config.py — single place for all paths & machine-specific settings.

Defaults are sensible & path-portable ($HOME based). Override any of them in
  ~/.config/leader/config.json
e.g.  {"proxy": "127.0.0.1:6789", "new_session_cwd": "~/dev/impl",
       "worktree_repos": ["~/dev/impl"]}
"""
import json, os

HOME = os.path.expanduser("~")

_DEFAULTS = {
    # where leader keeps its own state (windows/archived/pinned/names)
    "data_dir": "~/.claude/leader",
    # claude transcripts live here (fixed by Claude Code)
    "projects_dir": "~/.claude/projects",
    "kitty_bin": "/Applications/kitty.app/Contents/MacOS/kitty",
    "kitty_socket": "unix:/tmp/leader-kitty.sock",
    # "" -> resolve via `command -v claude` at launch time
    "claude_bin": "",
    # "" -> resolve via `command -v kimi` at launch time (Kimi Code CLI)
    "kimi_bin": "",
    # "" -> no proxy; or "host:port" (http for http/https, socks5 for all_proxy)
    "proxy": "",
    # default folder for the "+" new-session button
    "new_session_cwd": "~",
    # optional: git repos to enrich with ahead/dirty + agent-worktree cleanup
    "worktree_repos": [],
}

def _load() -> dict:
    cfg = dict(_DEFAULTS)
    try:
        with open(os.path.expanduser("~/.config/leader/config.json")) as f:
            cfg.update(json.load(f))
    except Exception:
        pass
    return cfg

_C = _load()

def data_dir() -> str:
    d = os.path.expanduser(_C["data_dir"])
    os.makedirs(d, exist_ok=True)
    return d

def data_file(name: str) -> str:
    return os.path.join(data_dir(), name)

def projects_dir() -> str:
    return os.path.expanduser(_C["projects_dir"])

KITTY = os.path.expanduser(_C["kitty_bin"])
SOCK = _C["kitty_socket"]

def proxy_cmd(provider: str = "claude") -> str:
    """Shell snippet to export proxy vars for a provider. proxy_<provider> in
    config.json: "off" actively unsets inherited vars (genuine direct), missing/
    "inherit" falls back to the global `proxy` (':' = no-op), anything else is a
    custom host:port. Only Claude terminals round through launch.py, so callers
    use the default."""
    v = (_C.get(f"proxy_{provider}") or "inherit").strip()
    if v == "off":
        return "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    p = (_C.get("proxy") or "").strip() if v in ("", "inherit") else v
    if not p:
        return ":"
    return f"export https_proxy=http://{p} http_proxy=http://{p} all_proxy=socks5://{p}"

def claude_fallback() -> str:
    cb = (_C.get("claude_bin") or "").strip()
    return os.path.expanduser(cb) if cb else os.path.join(HOME, ".local/bin/claude")

def kimi_fallback() -> str:
    kb = (_C.get("kimi_bin") or "").strip()
    return os.path.expanduser(kb) if kb else os.path.join(HOME, ".kimi-code/bin/kimi")

def new_session_cwd() -> str:
    return os.path.expanduser(_C.get("new_session_cwd") or "~")

def worktree_repos() -> list:
    return [os.path.expanduser(r) for r in (_C.get("worktree_repos") or [])]

def short_path(p: str) -> str:
    """~/dev/foo  <- /Users/you/dev/foo  (display helper)"""
    return (p or "").replace(HOME + "/", "~/")
