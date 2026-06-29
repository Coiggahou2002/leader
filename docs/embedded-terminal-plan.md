# Embedding Claude sessions into the Leader app

## Why
Running many Claude Code sessions opens many terminal OS-windows; the desktop
becomes an unmanageable pile. Leader already triages sessions in a side panel —
so let it also **host** the sessions: sidebar + an embedded terminal in the main
area. Click a session → it runs inside the app. No more window clutter.

## Decisions (confirmed)
- **Hybrid**, not pure-embed: sessions embed by default; right-click → "open in
  kitty window" stays as an escape hatch. It also works around the one known
  embed limitation (below). So the kitty path (`launch.py`) is kept.
- **Layout**: the left-edge strip becomes a resizable window — sidebar (the
  existing rich list) + main content area (the embedded terminal).

## Known limitation
`/tui fullscreen` (claude's alt-screen TUI) **does not scroll cleanly** when
embedded: SwiftTerm's `drawTerminalContents` only repaints the dirtyRect rows,
and claude's async region-scroll redraw leaves stale cells (garbling). Forwarding
the wheel + forcing full repaints did not fully fix it from outside the library;
a real fix needs patching SwiftTerm itself. Workaround: `/tui default` scrolls
fine embedded, and the kitty pop-out handles fullscreen. Documented, not blocking.

## Building block (proven in spike/, branch spike/embedded-terminal)
- `TerminalManager` — one live `LocalProcessTerminalView` per sid, kept alive
  across selection switches; close kills the process but keeps the list item.
- `EmbeddedTerminalView` — wheel handling via a `.scrollWheel` local monitor.
- env hygiene — strips `CLAUDE_CODE_*`/`CODEX_COMPANION_*` (else the embedded
  `claude` runs as a nested child and does NOT persist its transcript), keeps the
  proxy so the API is reachable.

## Plan (phases = tasks)
- **P0 build system** — SwiftPM (`Package.swift`) + SwiftTerm; `build.sh` →
  `swift build` + existing .app assembly. Verify kitty-mode still builds/runs
  before touching UI. ✅
- **P1 layout** — strip → `NavigationSplitView` (sidebar + content). Keep the
  existing row interactions (pin/archive hit-zones, right-click rename).
- **P2 click = embed** — port the spike's terminal stack; `Store.selectedSID`;
  the "open" hit-zone selects + embeds `claude --resume` instead of launching
  kitty. Keep-alive + per-session close.
- **P3 features** — confirm pin/archive/rename/search/grouping/stale/archived
  work in the new sidebar; add embed status dots (opened/running/exited).
- **P4 "+" new session** — spawn embedded, capture the new sid (no 12s race
  since we hold the process).
- **P5 hybrid** — right-click "open in kitty window" (reuse `launch.py`).
- **P6 polish** — quit confirm, terminal theming (light/dark + frosted), float.

## Isolation
Done on branch `feat/embedded-app` (worktree). Does not touch `main`, the spike
branch, or the running `~/Applications/Leader.app`. Builds to `dist/`.
