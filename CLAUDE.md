# CLAUDE.md — Leader (embedded-app)

Native macOS cockpit for many Claude Code sessions. SwiftUI shell (`src/LeaderApp.swift`,
`src/EmbeddedTerminal.swift`, `src/QuakeTerminal.swift`) over read-only Python
(`src/*.py`, bundled into the app). Build+install: `./build.sh` → `dist/Leader.app`,
then `rm -rf ~/Applications/Leader.app && cp -R dist/Leader.app ~/Applications/`.

## Hard-won lessons (read before touching sidebar / terminal state)

These are not style preferences. Each one cost a full debug cycle. The sidebar has
four tabs (会话 / 活跃 / 陈旧 / 已归档); almost every bug we hit lived in how row
state flows between SwiftUI, `TerminalManager`, and the 6 s `scan.py` refresh.

### 1. Don't compute row state in the parent and feed it into a `LazyVStack`
A `LazyVStack` does **not** reliably re-render its children when a parent `@State`
they depend on changes, if that state is only read *inside the lazy child* (e.g.
`Row(selected: selectedID == s.id)`). Symptom we hit: clicking a row switched the
terminal pane (`activeSID`, read eagerly in `body`) but the sidebar highlight stayed
on the previous row (`selected`, read lazily). The terminal updated, the list didn't.

**Rule:** for a bounded, selectable list, use an eager **`VStack`**. It re-renders
every row on any parent state change, so `selected`/hover track by construction. The
sidebar is ≈ session-count rows and each is light — eager layout is cheap. Only reach
for `LazyVStack` when the row count is genuinely large *and* rows don't carry
parent-computed visual state. (If you must, make each row observe the selection
itself instead of receiving a precomputed `Bool`.)

### 2. Never call a mutating factory from `updateNSView`, and don't `@ObservedObject`
a manager that `updateNSView` mutates.
`TerminalContainer.updateNSView` called `mgr.terminal(forSid:)` (which creates the
view, spawns the process, and mutates `@Published running`). The container also
`@ObservedObject`'d `mgr`. So `close()` doing `running.remove` re-triggered
`updateNSView`, which **re-created the terminal it had just killed** (a fresh
`claude` process) and re-inserted `running` — the row "wouldn't close", it popped
back. Fix: the representable holds a plain `let mgr` (does not observe it) and its
lifecycle is driven only by the parent passing `sid`. Also: on close, unmount first
(`activeSID = nil`) *then* `close()`.

Related SwiftUI trap already fixed: mutating `@Published` from *within* a view update
("Publishing changes from within view updates") silently drops that transaction's
other invalidations. Defer such mutations to the next runloop tick.

### 3. Tab membership must come from ONE synchronous source of truth
Bugs multiplied when a tab's predicate mixed three unsynchronized sources: 6 s
`scan.py` fields (`alive`, …), optimistic struct mutations, and the `@Published`
sets in `TerminalManager`/`Activity`. Each action updated only some, so rows failed
to move whenever the predicate read a source the action didn't touch.
- **`archived` is exclusive:** an archived session shows ONLY in 已归档; every other
  list filters `!archived`. (Keep this invariant — grep all `store.sessions.filter`.)
- **活跃 = `TerminalManager.running` only** (in-app terminals, mutated synchronously
  by open/close). Do NOT fold in scan-derived `alive` — it's 6 s-laggy and racy on
  close, and made rows flicker back after closing.

### 4. Verify end-to-end with instrumentation + a real repro — never by reasoning alone
This saga's fixes only stuck once we added `os.Logger` (`subsystem "com.leader.app"`),
had the user reproduce once, and read `log show --predicate 'subsystem ==
"com.leader.app"'`. Static reasoning about SwiftUI update timing was wrong twice.
When a UI state bug resists a fix: instrument the exact mutation/render sites, get
one real repro, let the log tell you which of "state never set / set-then-reverted /
set-but-not-rendered" is happening, then fix that. Remove the logging when done.

### 5. Actually install the build before claiming a fix
`./build.sh` only writes `dist/`. A fix isn't testable until it's copied to
`~/Applications/Leader.app` **and** the app is restarted (it holds its binary by
inode, so a running instance keeps the old code). One whole cycle was lost to a
"fixed it" that was never installed. Always do the `cp -R` and confirm the running
process is the new binary (check the exe mtime).
