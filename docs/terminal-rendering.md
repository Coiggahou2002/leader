# Terminal color & rendering in Leader — investigation & reference

How the embedded terminal (SwiftTerm) was tuned to look like a modern terminal
(Kaku), why each problem happened, and how each was fixed. Written as a
first-principles reference: read top-to-bottom once, then use the tables.

Leader embeds a live `claude` inside each session via **SwiftTerm**
(`LocalProcessTerminalView`). SwiftTerm is a full terminal *emulator* — it
rasterizes glyphs and owns the whole render pipeline, exactly like WezTerm or
iTerm2. That matters: almost everything below is fixable *because* SwiftTerm
draws the pixels itself; the defaults were just plain.

---

## 0. The one idea that explains most of it

**ANSI color codes are slot numbers, not colors.**

When a program wants green it emits `ESC[32m`. The `32` does **not** carry an
RGB value — it means *"use slot 2 of whatever palette this terminal has."* The
actual pixels are `terminal_theme[slot]`. So the *same bytes* look different in
every terminal.

There are three ways a program can specify color:

| Escape | Meaning | On-screen RGB decided by |
|---|---|---|
| `ESC[30–37m` / `90–97m` | 16-color, slot 0–15 | **the terminal's theme** |
| `ESC[38;5;Nm` | 256-color, slot N | theme for 0–15; a fixed cube for 16–255 |
| `ESC[38;2;R;G;Bm` | **truecolor**, literal RGB | **the code itself** (theme-independent) |

Only truecolor is theme-independent. Everything else is a lookup. This single
fact is the root of problems #1 and #3 below.

---

## 1. claude-hud progress bars looked harsh

**Symptom:** claude-hud's context/usage bars were garish in Leader but soft in
Kaku — the *same* plugin.

**Root cause:** claude-hud emits **indexed** colors, not truecolor. From its
source (`render/colors.ts`):

```
GREEN = \x1b[32m   YELLOW = \x1b[33m   RED = \x1b[31m       (16-color slots 2/3/1)
BRIGHT_BLUE = \x1b[94m   BRIGHT_MAGENTA = \x1b[95m           (slots 12/13)
```

So the bar color is whatever slot 1/2/3/12/13 maps to. SwiftTerm's default
palette is the classic saturated xterm palette (pure-ish reds/greens) → harsh.
Kaku ships a soft palette → gentle. Not a filter, not an optimization — just the
palette.

> **Secondary amplifier (why it's *extra* harsh on a MacBook):** SwiftTerm
> paints with `CGColorSpaceCreateDeviceRGB()` — **no sRGB color management**. On
> a wide-gamut (P3) display, a saturated DeviceRGB value is pushed to the
> display's *native* gamut, i.e. more saturated than the same value in sRGB. A
> color-managed terminal (Kaku) renders it calmer. So harshness = saturated
> palette × P3 over-saturation.

**Fix:** install a soft 16-color palette. SwiftTerm exposes
`terminalView.installColors([Color])` (exactly 16 entries). We copied **Kaku
Dark's** palette verbatim (see §2) and install it when "柔和配色" is on; otherwise
we install SwiftTerm's stock 16.

Two other color forms to know:
- **`38;5;208`** (claude-hud's orange) is a 256-cube index; the cube is standard,
  so it looks the same everywhere and needs no fix.
- **User hex overrides** in claude-hud become truecolor (`38;2;…`) — those would
  look identical in every terminal and bypass the palette entirely. (An
  alternative fix for *just* claude-hud: set hex colors in its `config.json`.)

---

## 2. Kaku's palette (what we copied)

Kaku (`github.com/tw93/kaku`) is a **WezTerm fork**. Its default "Kaku Dark"
scheme is a *softened "Aura"* theme (their comment: hues sit a third of the way
back from Aura's vivid toward Aura Soft). The 16 colors live in
`assets/macos/Kaku.app/Contents/Resources/kaku.lua`:

```
fg  #d5d4d6      bg  #15141b      cursor #8e6ad9
ansi    0 #c8c6cc  1 #d85d5d  2 #58d8ad  3 #daae76  4 #68afda  5 #8e6ad9  6 #58d8ad  7 #d5d4d6
brights 8 #6d6d6d  9 #d85d5d 10 #58d8ad 11 #daae76 12 #90c9e6 13 #8e6ad9 14 #58d8ad 15 #d5d4d6
```

> **Caveat — slot 0 (black):** Kaku sets ANSI black to a *light* `#c8c6cc` so
> black *foreground* text stays readable on the dark background. But SwiftTerm
> uses one color per slot for both fg and bg, so a program that paints an ANSI
> *black background* gets light grey. Kaku dodges this with a separate background
> override (`color_overrides`) that SwiftTerm can't express. We accept it — it's
> the price of matching Kaku's palette exactly, and ANSI-black backgrounds are
> rare.

For coherence we also set the terminal **background `#15141b`, foreground
`#d5d4d6`, cursor `#8e6ad9`** (via `setBackgroundColor/setForegroundColor/
setCursorColor`) and added **inner padding** around the terminal, painting the
gutter the same background so it reads as one inset surface rather than a border.

Applied in `applyTermTheme()`; live terminals re-theme via `reapplyTheme()` on
Settings save (no restart).

---

## 3. Line height — SwiftTerm had no knob

**Symptom:** wanted iTerm2/Kaku-style line spacing; SwiftTerm 1.13.0 has none.

**Why it wasn't possible out of the box:** line height is computed once and hard-
coded — `cellHeight = ceil(ascent + descent + leading)` — with no multiplier, and
the function (`computeFontDimensions`) is `internal`, so it can't be overridden
from another module. Not a fundamental limit (SwiftTerm draws its own glyphs, so
it *could* do it, same as WezTerm's `line_height`) — the author just hadn't
exposed it.

**The patch (3 parts, mirrors WezTerm):**
1. add `public var lineHeightMultiplier` (default 1.0, `didSet → resetFont()`);
2. `cellHeight = ceil((ascent+descent+leading) * lineHeightMultiplier)`;
3. **center** the glyph: with a taller cell, split the extra above/below in
   `drawTerminalContents` (`yOffset += extra/2`) so spacing is balanced, not
   piled on one side.

**Delivery — via fork** (`Coiggahou2002/SwiftTerm@leader-line-height`), pinned by
exact revision in `Package.swift`. Leader reads `Conf.line_height` (default 1.2×,
Settings slider 1.0–2.0) and sets `tv.lineHeightMultiplier`.

> **Plot twist found while forking:** upstream `main` (unreleased; latest tag is
> still v1.13.0) *already* added a public `lineSpacing` — but it does **not**
> center (extra space piles above the text, iTerm2-style). So we kept our fork
> (centered) and contributed the centering upstream as
> **migueldeicaza/SwiftTerm#585**. Exit path (see the TODO in `Package.swift`):
> once #585 merges and ships in a tag, drop the fork, point back at the upstream
> tag, and rename `tv.lineHeightMultiplier` → `tv.lineSpacing`.

**Verification (A/B, identical claude screen):** at 1.0× consecutive wrapped
lines sat ~32px apart; at 1.6× ~50px (ratio ≈ 1.56 ≈ the multiplier), text
centered, no clipping.

---

## 4. Diff colors were washed out

**Symptom:** claude's diff view (added-green / removed-red) was faint/greyish in
Leader, vivid in Kaku. The 16-color palette was byte-identical to Kaku, and
Kaku's `color_overrides` does **not** touch diff colors — so it wasn't the
palette.

**Root cause:** Claude Code emits **truecolor** diff backgrounds *only when it
believes the terminal supports it* — it checks the `COLORTERM=truecolor` env var.
Otherwise it falls back to muted 256-color approximations.

Leader is usually launched from **Raycast/Dock**, which gives the app **no shell
environment** (the same reason the proxy was missing early on — see the proxy
settings work). So `COLORTERM` was absent → claude used the muted fallback. Kaku,
being a terminal, always advertises truecolor.

**Fix (one line):** in `termCleanEnv()`, force `COLORTERM=truecolor` (SwiftTerm
does render truecolor), just like we already force `TERM=xterm-256color`.

```
if !out.contains(where: { $0.hasPrefix("COLORTERM=") }) { out.append("COLORTERM=truecolor") }
```

**Lesson:** truecolor programs are gated on `COLORTERM`, *not* on terminal
capability queries. A GUI-launched terminal must inject it, because it can't rely
on inheriting a login shell's environment.

---

## 5. Environment we inject into every embedded shell

`termCleanEnv()` (in `EmbeddedTerminal.swift`) — because Raycast/Dock launches
inherit almost nothing:

| Var | Value | Why |
|---|---|---|
| `TERM` | `xterm-256color` | baseline capability advertisement |
| `COLORTERM` | `truecolor` | unlock vivid 24-bit diff colors (§4) |
| `PATH` | `~/.local/bin:/opt/homebrew/bin:…` | find `claude`, tools |
| `http_proxy`/`https_proxy`/`all_proxy` | from Settings | reach Anthropic (no shell env) |
| `CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT` | `1` | avoid post-resize repaint drift |
| (POISON stripped) | — | `CLAUDECODE`, `CLAUDE_CODE_*`, `CODEX_COMPANION_*` removed so the child isn't treated as a nested session |

---

## 6. How this was verified without touching the main instance

The main Leader can't be killed (it hosts live sessions). So every check ran in
an **isolated copy** with a different bundle id, which bypasses the single-
instance guard:

```
cp -R dist/Leader.app "$SB/LeaderVerify.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.leader.app.verify" .../Info.plist
codesign --force --deep --sign - "$SB/LeaderVerify.app"
```

Then launch by PID, drive with `osascript` System Events, `screencapture -R`
the window rect, and kill by exact PID. A/B comparisons wrote the shared
`~/.config/leader/config.json` (backed up + restored) to flip one variable at a
time.

**Traps hit (documented so we don't repeat them):**
- A cluttered desktop **occludes** the window; scripted focus can raise the wrong
  app, so a screenshot may capture a different window. Verify what's actually in
  the shot before trusting it.
- Synthesized **double-tap Control** (quake terminal) via `osascript` is
  unreliable — modifier taps don't register cleanly.
- Synthesized keystrokes can **leak into the main instance** if the verify window
  isn't truly key. Re-check the target window is frontmost before typing; prefer
  non-keystroke verification when possible.

---

## 7. Map: problem → commit / artifact

| Area | Where |
|---|---|
| Soft 16-color palette (§1–2) | `EmbeddedTerminal.swift` `kakuAnsiPalette` / `applyTermTheme` |
| bg/fg/cursor + inner padding (§2) | `applyTermTheme`, `TerminalContainer` |
| Line-height fork (§3) | fork `Coiggahou2002/SwiftTerm@leader-line-height`; `Package.swift` pin |
| Line-height centering upstream PR (§3) | `migueldeicaza/SwiftTerm#585` |
| COLORTERM / diff colors (§4) | `EmbeddedTerminal.swift` `termCleanEnv()` |
| Settings (font, size, line height, soft colors) | `SettingsSheet` in `LeaderApp.swift` |

All shipped on branch `feat/proxy-and-quake-terminal` (PR #3).
