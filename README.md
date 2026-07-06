# Leader — a context-switching cockpit for many Claude Code sessions

When you run lots of Claude Code sessions across many folders / git worktrees /
repos, you lose track of what's open and what needs you — and the desktop fills
with terminal windows. **Leader** is a native macOS **cockpit**: a resizable
window with a session **sidebar** on the left and an **embedded terminal** on
the right that runs the actual `claude` session *inside the app*. No more window
pile. It lets you:

- see every session bucketed into **需处理 / 最近 / 陈旧 / 已归档**
- **click a session → it runs embedded** in the main area (`claude --resume`);
  opened sessions stay alive in the background for instant switching
- a per-session **close** button kills that embedded process but keeps the list
  item; an **open in kitty window** button is the escape hatch (e.g. for
  `/tui fullscreen`, which doesn't scroll cleanly when embedded)
- a session that is **actively reasoning shimmers**: its title dims and a bright
  band sweeps across it (ChatGPT "Working…"-style); a quiet grey **embed badge**
  marks rows whose in-app claude process is alive (filled) or has exited (hollow)
- **pin** frequently-used sessions via right-click — they gather under a 置顶
  section with a single golden star on the header; **archive** (icon appears on
  hover) ones you're done with, **rename** any session (a Leader-only nickname),
  **search** by title / folder / last message, group by folder or sort by recency
- **+** to start a brand-new session embedded right here — the session id is
  minted up front (`claude --session-id`), so there's no race to find it
- the window is normal-level by default; a **pin** toolbar button toggles
  always-on-top when you want it

It's a SwiftUI shell embedding [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
over a few read-only Python scripts. Conversation data is never modified — Leader
only reads `~/.claude/projects/*` and manages its own small state files. The
embedded `claude` runs with `CLAUDE_CODE_*` / `CODEX_COMPANION_*` stripped from
its environment, so it persists its own transcript instead of nesting as a child.

## Requirements

- macOS 14+ (Apple Silicon or Intel — you build it locally)
- Xcode Command Line Tools (`swiftc`) — `xcode-select --install`
- [kitty](https://sw.kovidgoyal.net/kitty/) terminal — `brew install --cask kitty`
  (optional now — only the "open in kitty window" escape hatch uses it)
- Claude Code (`claude` on your `PATH`)
- Optional: `brew install --cask font-jetbrains-mono`

## Build & install

```bash
./build.sh                      # -> dist/Leader.app (self-contained)
cp -R dist/Leader.app ~/Applications/
open ~/Applications/Leader.app
```

The Python backend is bundled **inside** the app, so the installed app does not
depend on this source tree.

## Configure (optional)

All machine-specific settings have defaults; override any in
`~/.config/leader/config.json`:

```jsonc
{
  "proxy": "127.0.0.1:6789",          // "" = none (default). Sets http/https/all_proxy for launched sessions
  "new_session_cwd": "~/dev/myrepo",  // folder the "+" button opens a new session in (default ~)
  "worktree_repos": ["~/dev/myrepo"], // git repos to show ahead/dirty + offer agent-worktree cleanup
  "claude_bin": "",                    // "" = resolve via `command -v claude`
  "kitty_bin": "/Applications/kitty.app/Contents/MacOS/kitty",
  "data_dir": "~/.claude/leader"       // where Leader stores windows/archived/pinned/names
}
```
See `config.example.json`.

## Architecture

```
LeaderApp.swift  native panel (SwiftUI). Shells out to the python backend.
  └─ scan.py     read ~/.claude/projects/*.jsonl -> bucket/sort sessions (JSON)
  └─ launch.py   open/switch a session's kitty window (kitty remote control)
  └─ archive.py / pin.py / name.py   manage per-session flags & nicknames
  └─ config.py   defaults + ~/.config/leader/config.json
server.py        optional browser version of the same board (no native app)
```

Window management uses **kitty's remote control** (`kitty @ launch / focus-window
--match id:`), which is the only terminal that can open and re-focus an exact OS
window reliably — including many sessions sharing one folder.

## Notes / known issues

- **Env hygiene**: a `claude` started with `CLAUDECODE` / `CLAUDE_CODE_*` /
  `CODEX_COMPANION_*` in its environment runs as a *nested child session* and
  does NOT persist its transcript. Leader strips these before launching, both for
  the kitty daemon and per-window. Keep that in mind if you hack on `launch.py`.
- **`+` new-session sid capture (to fix)**: a new session's id is unknown until
  its first message lands; `new_session()` polls the project dir up to ~12s to
  capture it for precise window-reuse. Clicking `+` twice within that window can
  mis-map or drop a windows.json entry (no conversation loss). Planned fix:
  drop windows.json + the poll and identify windows at click time via
  `kitty @ ls` cmdline (`--resume <sid>`) — deterministic, race-free.

## License

TBD.
