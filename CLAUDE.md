# CLAUDE.md — Leader (embedded-app)

Native macOS cockpit for Claude Code, Codex and Kimi sessions, in ONE unified
list. SwiftUI shell (`src/LeaderApp.swift` = app entry + provider rail,
`src/SessionsView.swift` = the single sessions view used for every rail tab,
`src/SessionStore.swift` = merged store, `src/UnifiedSession.swift` = the
cross-provider model, `src/EmbeddedTerminal.swift`, `src/QuakeTerminal.swift`)
over read-only Python (`src/*.py`, bundled into the app). Build+install:
`./build.sh` → `dist/Leader.app`, then
`rm -rf ~/Applications/Leader.app && cp -R dist/Leader.app ~/Applications/`.

## Unified architecture (All-in-One)

The left rail has four entries — **All** (`square.grid.2x2` SF Symbol) then the
three brand logos — persisted in `@AppStorage("leader.providerFilter")`. Every
entry renders the SAME `SessionsView(filter:)`; the filter is just a parameter,
so there is exactly one list implementation and one set of shortcuts.

- **`AnySession`** (UnifiedSession.swift) is the union model: the 7 fields all
  three scanners share, plus Optional/defaulted Claude-only enrichment
  (`alive/asks/errored/branch/…`). `id` = `"kind:sid"` (list identity);
  `termKey` = TerminalManager key (claude stays BARE — legacy restore.json
  contract). Capability flags (`hasActivitySignals` / `canOpenInKitty` /
  `canCreate`) drive which menu items and row decorations a provider gets;
  Codex/Kimi rows honestly degrade (no shimmer/breathing-dot/ErrorPulse).
- **`SessionStore`** (SessionStore.swift) merges the three scan loops (Claude
  6 s, Codex/Kimi 10 s) into one `[AnySession]`. Claude mutations keep the old
  epoch guard (scan.py round-trip); Codex/Kimi mutations write a JSON override
  store synchronously and replay after each scan, so no epoch is needed there.
  Also owns `~/.config/leader/last-opened.json` — the LRU sort's data source
  (app UI state, not provider data).
- **Overrides** (`SessionOverrideStore` protocol): Claude keeps its python
  scripts + `~/.claude/leader/*.json` (external contract, scan.py merges);
  Kimi keeps `~/.config/leader/kimi-overrides.json` (same format as the old
  `KimiOverrides`); Codex gained the same mechanism via
  `~/.config/leader/codex-overrides.json` — archive/pin/unread/rename now work
  for Codex too. Archiving also unpins, uniformly.
- **Sorting** (会话 tab, bottom-bar cycle, `@AppStorage("leader.sortMode")`):
  folder (repo groups, cross-provider in All view) → activity (attention-ranked;
  Claude hook signals, others idle_h) → LRU (`last-opened.json`, never-opened
  fall back to idle_h). Row left edge shows the provider logo (15 pt, from the
  shared pre-downsampled `ProviderLogos`).
- The three decode structs (`Session`/`CodexSession`/`KimiSession`) remain the
  wire contract with the python backend; the UI only sees `AnySession`.

The rail brand logos live in `assets/{claude,openai,kimi}-logo.png` (copied into
the bundle by `build.sh`) and are loaded ONCE, pre-downsampled to 108 px with
high-quality interpolation (`ProviderLogos`) — drawing the 1000 px sources at
15–28 pt aliases. Selection uses `Color.primary.opacity` instead of accentColor.

## Codex fleet boundary

`src/codex-scan.py` implements a read-only integration: enumerate
`~/.codex/session_index.jsonl`, obtain the original cwd from the session's
`session_meta`, and host `codex resume <uuid>` in the existing SwiftTerm shell.
Leader-side flags (archive/pin/unread/nickname) are Leader-owned state in
`codex-overrides.json`, NOT Codex data.

Do **not** route Codex through `leader-hook.py`, Claude's JSONL scanner, or
`--dangerously-skip-permissions`. Codex's local event format is not a Leader-owned
contract, and this integration preserves Codex's own approval and sandbox defaults.
Codex has no `--session-id` equivalent, so ⌘⇧O quick-create is unavailable there
(`canCreate == false`).

## Kimi fleet boundary

`src/kimi-scan.py` implements a read-only integration: enumerate
`~/.kimi-code/session_index.jsonl`, read title/cwd from the session's
`state.json`, and host `kimi -S <session-id>` in the existing SwiftTerm shell.

⌘⇧O creates a new Kimi session via `TerminalManager.newKimiSession`, keyed under
a synthetic `new-<hex>` sid because Kimi has no `--session-id`; the real sid
lands in the index on the next scan. When it does, `SessionsView.reconcileAfterScan()`
ADOPTS it: candidates must share the cwd, be fresh (< 3 min idle), and be unseen
in earlier scans (tracked in `knownKimiSids`) — exactly one match means
`TerminalManager.rekey(from:to:)` moves the LIVE terminal to the real sid (no
respawn, so clicking the row never spawns a second CLI on the same session) and
the row becomes selected. Zero or 2+ matches → stay unselected rather than adopt
the wrong session. Claude needs none of this: its sid is minted up front via
`claude --session-id`. Tab membership follows the same invariant
as Claude: archived is exclusive; 活跃 = `TerminalManager.running` only.

Do **not** route Kimi through `leader-hook.py`, Claude's JSONL scanner, or
`--dangerously-skip-permissions`. Kimi's local event format is not a Leader-owned
contract, and this integration preserves Kimi's own approval and sandbox defaults.
Kimi sids are namespaced as `kimi:<sid>` inside `TerminalManager` so they never
collide with Claude/Codex terminals. (`RenameSheet` is provider-agnostic: pass
`originalTitle`, not a session.)

`QuakeTerminal` anchors its floating scratch panel to the detail pane via
`TerminalAreaProbe()`. `SessionsView` sets this probe as the terminal pane's
background — without it, double-tap Control falls back to screen-centered
geometry and the panel looks misplaced. The scratch terminal's cwd follows the
active session of ANY provider: `SessionsView.updateQuakeCwd()` resolves the
active termKey back to a session (`kindAndSid(fromTermKey:)`) and writes
`QuakeTerminal.shared.currentCwd`; `show()` tears down the old shell if the cwd
changed.

## Terminal rendering & input (SwiftTerm fork)

The embedded terminal is our SwiftTerm fork (`Coiggahou2002/SwiftTerm`, branch
`leader-line-height`, revision-pinned in `Package.swift`). Two local patches live
there: `lineHeightMultiplier` (see the Package.swift TODO about upstream #585) and
Metal-renderer glyph centering for that multiplier. If you bump line-height behavior,
patch BOTH renderers (CG `drawTerminalContents` + `MetalTerminalRenderer`'s two
`yOffset` sites) or text sits low in the cell on one path.

- **Renderer**: Metal GPU path on by default (`term_metal` in
  `~/.config/leader/config.json`; toggle in Settings, falls back to CG if Metal init
  fails). Rationale: claude's TUI full-repaints every frame (we force it via
  `CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT=1` to dodge SwiftTerm's non-grapheme-aware
  CJK wrap drift), and the CG path re-rasterizes the whole grid on the CPU main
  thread per frame — typing lags. The full-bounds `setNeedsDisplay` promotion in
  `EmbeddedTerminalView` is CG-only; Metal routes through `requestMetalDisplay`.
- **Cursor**: `term_cursor_style` config key (default `steadyBar`), applied in
  `applyTermTheme` via `setCursorStyle`; DECSCUSR from apps still overrides.
- **Color env is pinned, not inherited.** `termCleanEnv()` strips `TERM`,
  `COLORTERM`, `NO_COLOR`, `NODE_DISABLE_COLORS` from the inherited env and
  always sets `TERM=xterm-256color` + `COLORTERM=truecolor`. Reason: launching
  Leader via `open` from a TUI shell **propagates that shell's env** — a kimi/
  claude CLI session exports `NO_COLOR=1` + `TERM=dumb`, and every embedded TUI
  then renders monochrome (Node honors `NO_COLOR`; everything honors
  `TERM=dumb`). Symptoms are renderer-independent (CG and Metal both "lose
  color"), so if colors ever look wrong, `ps eww -p <leader-pid>` the launch
  env FIRST before suspecting SwiftTerm — the parse/map/render pipeline was
  verified end-to-end (headless `Terminal.feed` + offscreen `LocalProcessTerminalView`
  rasterize truecolor correctly).
- **IME preedit**: SwiftTerm's `NSTextInputClient` marked-text methods are stubs
  (`setMarkedText` discards the string), so `EmbeddedTerminalView` overrides them
  and shows the composing pinyin in an overlay label pinned to the caret. Purely
  presentational — nothing reaches the PTY until the IME commits. SwiftTerm marks
  `resignFirstResponder` public-not-open, hence the `viewWillMove(toSuperview:)`
  hook for discarding compositions on session switch.

## Shipping releases (Sparkle auto-update + CI)

The app updates itself via **Sparkle**: it reads an appcast from GitHub Releases
(`SUFeedURL` = `.../releases/latest/download/appcast.xml`, baked into Info.plist by
`build.sh`) and installs new versions in place. Updates are trusted by an **EdDSA
signature**, so the app stays **ad-hoc signed** — no Apple Developer account.

**Versioning.** `build.sh` stamps the version from `$LEADER_VERSION` (set by CI from
the tag) → else `./VERSION` → else `1.0`. Sparkle compares `CFBundleVersion`, so every
release **must be a strictly higher version than the last** or existing installs won't
see it. Keep `./VERSION` in sync with the tag you cut.

**Cutting a release — CI (preferred).** Push a tag and GitHub Actions
(`.github/workflows/release.yml`) does the rest:
```
# bump ./VERSION to match, commit, then:
git tag v1.2 && git push origin v1.2
```
The workflow builds on a `macos-14` (arm64) runner, ad-hoc-signs, regenerates the
signed appcast, and publishes the Release via the built-in `GITHUB_TOKEN`. The tag
**is** the version (leading `v` stripped). You can also trigger it manually:
`gh workflow run release.yml -f version=1.2`.
- **Merging to `main` does NOT release.** Only a `v*` tag push (or manual dispatch)
  does — this is deliberate, so ordinary merges don't ship versions.

**Cutting a release — local fallback.** Bump `./VERSION`, then `./release.sh` (build →
zip → sign appcast → `gh release create`). Locally the signing key is read from the
login keychain; no env var needed.

**The signing key (EdDSA).** Local: generated once by Sparkle's `generate_keys`, lives
in the login keychain. CI: stored as the repo secret **`SPARKLE_ED_PRIVATE_KEY`** (the
base64 blob from `generate_keys -x`), fed to `generate_appcast --ed-key-file -` over
**stdin** so it never touches disk. Only tag-push / manual-dispatch runs get the secret
(fork PRs don't). **Back the key up — losing it bricks auto-update for every existing
install.** The matching public key is hardcoded as `PUBKEY` in `build.sh` (→
`SUPublicEDKey`); rotating the key means updating `PUBKEY`, and old installs will reject
updates signed by the new key.

**Do not break the bundle-signing order in `build.sh`.** It embeds the universal
`Sparkle.framework` into `Contents/Frameworks`, adds the `@executable_path/../Frameworks`
rpath, then signs the nested Sparkle helpers (XPCServices, Autoupdate, Updater.app)
inside-out **before** signing the framework and the app. Ad-hoc-signing the app with
`--deep` instead is unreliable for the XPC services.

**First-install caveat.** A freshly *downloaded* build is quarantined, so its first
launch needs a one-time Gatekeeper bypass (right-click → Open, or
`xattr -dr com.apple.quarantine Leader.app`). Sparkle strips quarantine on the updates
it installs, so every subsequent auto-update relaunches cleanly.

## Session restore across restarts

Quit dialog (`AppDelegate.applicationShouldTerminate`) offers a macOS-logout-style
"下次启动时恢复这些会话" checkbox (last choice remembered as `restore_on_quit` in
config.json). Checked → the running sessions' (termKey, cwd) + the active termKey
are written to `~/.config/leader/restore.json` (`RestoreState` in
EmbeddedTerminal.swift); `SessionsView.restoreSessions()` (onAppear) consumes the
file — **read-then-delete before spawning**, so a crash can't loop into
mass-spawning CLIs — batch-opens each via `TerminalManager.terminal(forStoredKey:cwd:)`
(the key recovers the provider, so a restored Codex/Kimi session gets ITS resume
command, not claude's), and embeds the previously active one through
`activeEmbed`'s isOpen fallback (works before the first scan lands).
Consequence: restore fires only after a clean quit with the box checked; a crash
restores nothing (deliberate).

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

### 6. Verify on the tab that has the bug, and confirm your clicks actually landed
The Kimi/Codex "empty column next to the rail" saga: the root cause was one line —
`KimiView`/`CodexView`'s HSplitView detail pane declared only `minWidth: 520` with
no `maxWidth: .infinity` (unlike `ContentView`), so HSplitView dumped the extra
width into the sidebar pane, whose `maxWidth: 430` content then **centered**
(`frame(minWidth:idealWidth:maxWidth:)` defaults `alignment: .center`), leaving a
~115 pt leading margin that looked like an outer-layout gap. But the hours were
lost to process failures, not the fix:
- The app launches on the **Claude** tab, which never had the bug — rounds of
  "fix → screenshot" verified a healthy page. Reproduce the broken state first,
  then iterate there.
- Coordinate clicks (`CGEvent`/`cliclick`-style) went to the **frontmost window
  (Chrome)**, not Leader, so the tab never switched and the "unchanged" screenshot
  was misread as layout data. Drive the app via AX instead:
  `System Events → process "Leader" → set frontmost → click (first button whose
  help is "Kimi")` (`entire contents of window 1`), then `screencapture -l <wid>`.
- When a layout gap resists reasoning, **own the pixels**: give each candidate
  view a translucent debug overlay (red/green/blue), screenshot, and see which
  view's frame covers the gap. One instrumented screenshot ended the guessing.
  Remove all debug overlays before shipping.
