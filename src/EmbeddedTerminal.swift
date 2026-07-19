// EmbeddedTerminal.swift — hosts a live `claude --resume` inside the app via
// SwiftTerm, instead of a separate kitty window. Kept in its own file so that
// `import SwiftTerm` (which declares its own `Color`) doesn't collide with
// SwiftUI.Color used throughout LeaderApp.swift.
import Foundation
import AppKit
import SwiftUI
import SwiftTerm

// Machine-specific settings, mirroring config.py defaults, in the SAME file the
// python backend reads (~/.config/leader/config.json). Read FRESH on each access
// so the Settings panel's writes take effect for the next terminal launch without
// an app restart (the file is tiny; this is not a hot path).
enum Conf {
    static let path = NSString(string: "~/.config/leader/config.json").expandingTildeInPath
    static var dict: [String: Any] {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
        return [:]
    }
    static var proxy: String { (dict["proxy"] as? String) ?? "" }
    // Per-provider proxy override, stored as proxy_<kind>: "inherit" (default →
    // use the global proxy), "off" (genuinely none — inherited env is stripped),
    // or "host:port" (custom). e.g. Kimi talks to a domestic endpoint and wants
    // "off" while Claude/Codex inherit the global proxy.
    static func proxySetting(for kind: TerminalKind) -> ProxySetting {
        switch ((dict["proxy_\(kind.rawValue)"] as? String) ?? "inherit").trimmingCharacters(in: .whitespaces) {
        case "off": return .off
        case "", "inherit": return .inherit
        case let v: return .custom(v)
        }
    }
    enum ProxySetting: Equatable { case off, inherit, custom(String) }
    static var claudeBin: String { (dict["claude_bin"] as? String) ?? "" }
    // Kept separate from claude_bin: users often install the different CLIs through
    // different channels, and an empty value still lets `command -v <cli>` win.
    static var codexBin: String { (dict["codex_bin"] as? String) ?? "" }
    static var kimiBin: String { (dict["kimi_bin"] as? String) ?? "" }
    static var newCwd: String { (dict["new_session_cwd"] as? String) ?? "~" }
    // Post a macOS system notification when a session finishes a turn while you
    // weren't watching it. On by default.
    static var notify: Bool { (dict["notify"] as? Bool) ?? true }
    // Terminal appearance. Defaults match the old hard-coded values.
    static var termFont: String { (dict["term_font"] as? String) ?? "JetBrains Mono" }
    static var termFontSize: CGFloat {
        (dict["term_font_size"] as? Double).map { CGFloat($0) } ?? 13
    }
    // Soft ANSI palette on by default: 16-color TUIs (claude-hud bars, ls, etc.)
    // otherwise render with SwiftTerm's harsh default xterm palette.
    static var softColors: Bool { (dict["soft_colors"] as? Bool) ?? true }
    // Line-height multiplier (needs the patched SwiftTerm). 1.0 = tight/upstream.
    static var lineHeight: CGFloat {
        let v = (dict["line_height"] as? Double).map { CGFloat($0) } ?? 1.2
        return min(2.0, max(1.0, v))
    }
    // Cursor style, wezterm-style thin bar by default. Any SwiftTerm CursorStyle
    // name is accepted: steadyBar/blinkBar/steadyBlock/blinkBlock/steadyUnderline/
    // blinkUnderline. Programs inside the terminal can still override via DECSCUSR.
    static var termCursorStyle: String { (dict["term_cursor_style"] as? String) ?? "steadyBar" }
    // GPU (Metal) renderer. claude's TUI full-repaints every frame (see
    // fullRepaintExport below), and SwiftTerm's default CoreGraphics path
    // re-rasterizes the whole grid on the CPU main thread per frame — key events
    // queue behind drawing and typing feels laggy. On by default; turn off to
    // fall back to the CG renderer if the (experimental) GPU path misbehaves.
    static var termMetal: Bool { (dict["term_metal"] as? Bool) ?? true }
    // Last state of the quit dialog's "restore sessions on next launch" checkbox
    // (macOS logout-style: the dialog remembers your previous choice).
    static var restoreOnQuit: Bool { (dict["restore_on_quit"] as? Bool) ?? true }
    // Common monospaced families, filtered to those actually installed so the
    // Settings picker never offers a font that won't resolve.
    static let monoFontChoices: [String] = {
        let candidates = ["JetBrains Mono", "SF Mono", "SFMono-Regular", "Menlo",
                          "Monaco", "Fira Code", "Hack", "Source Code Pro",
                          "IBM Plex Mono", "Cascadia Code", "Cascadia Mono",
                          "Roboto Mono", "Courier New"]
        var seen = Set<String>()
        return candidates.filter { NSFont(name: $0, size: 12) != nil && seen.insert($0).inserted }
    }()

    // Merge updates into the existing config and write it back (pretty-printed so
    // it stays hand-editable). Preserves keys the python backend owns.
    static func save(_ updates: [String: Any]) {
        var m = dict
        for (k, v) in updates { m[k] = v }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(
            withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
    // Best-effort "host:port" from the current shell's proxy env, so the Settings
    // panel can prefill instead of making the user retype it.
    static func detectedEnvProxy() -> String {
        let env = ProcessInfo.processInfo.environment
        for k in ["https_proxy", "http_proxy", "HTTPS_PROXY", "HTTP_PROXY",
                  "all_proxy", "ALL_PROXY"] {
            guard var v = env[k], !v.isEmpty else { continue }
            for pre in ["http://", "https://", "socks5://", "socks5h://"] where v.hasPrefix(pre) {
                v = String(v.dropFirst(pre.count))
            }
            return v.hasSuffix("/") ? String(v.dropLast()) : v
        }
        return ""
    }
}

// Proxy env entries (or []) for plain shells we spawn (e.g. the quake terminal).
// `setting` nil = the global proxy, preserving inherited env when unset.
func proxyEnvEntries(_ setting: Conf.ProxySetting?) -> [String] {
    let s = setting ?? .inherit
    switch s {
    case .off: return []          // caller strips inherited vars too
    case .custom(let p): return ["http_proxy=http://\(p)", "https_proxy=http://\(p)", "all_proxy=socks5://\(p)"]
    case .inherit:
        let p = Conf.proxy
        guard !p.isEmpty else { return [] }
        return ["http_proxy=http://\(p)", "https_proxy=http://\(p)", "all_proxy=socks5://\(p)"]
    }
}
// Shell-snippet form for the resume/new-session command strings. "off" actively
// UNSETS inherited proxy vars so the CLI genuinely goes direct; "inherit" with
// no global proxy is a no-op (inherited env passes through, same as before).
func proxyExport(for kind: TerminalKind) -> String {
    switch Conf.proxySetting(for: kind) {
    case .off:
        return "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    case .custom(let p):
        return "export http_proxy=http://\(p) https_proxy=http://\(p) all_proxy=socks5://\(p)"
    case .inherit:
        let p = Conf.proxy
        guard !p.isEmpty else { return ":" }
        return "export http_proxy=http://\(p) https_proxy=http://\(p) all_proxy=socks5://\(p)"
    }
}

// CRITICAL: a `claude` launched with CLAUDE_CODE_*/CODEX_COMPANION_*/KIMI_CODE_*
// in its env runs as a NESTED child session and does NOT persist its transcript.
// Strip them. Kimi has not been observed to use these markers yet, but filtering
// the prefix is harmless and keeps the policy consistent across providers.
let POISON: [String] = [
    "CLAUDECODE", "CLAUDE_PLUGIN_DATA", "CLAUDE_EFFORT",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_SESSION_ID", "CODEX_COMPANION_SESSION_ID",
]
func termCleanEnv() -> [String] {
    var out: [String] = []
    for (k, v) in ProcessInfo.processInfo.environment {
        if POISON.contains(k) || k.hasPrefix("CLAUDE_CODE") || k.hasPrefix("CODEX_COMPANION") || k.hasPrefix("KIMI_CODE") { continue }
        // Color env is REPLACED, never inherited (see below).
        if k == "TERM" || k == "COLORTERM" || k == "NO_COLOR" || k == "NODE_DISABLE_COLORS" { continue }
        out.append("\(k)=\(v)")
    }
    // Leader is often launched from inside a TUI shell (`open` from a kimi/claude
    // session), and `open` DOES propagate the caller's env — e.g. this repo's own
    // debugging session exports NO_COLOR=1 + TERM=dumb, which made every embedded
    // TUI render monochrome (Node CLIs honor NO_COLOR; anything honors TERM=dumb).
    // Embedded terminals are Leader-owned ptys that DO render 24-bit color, so
    // pin the canonical values instead of trusting the launch env.
    out.append("TERM=xterm-256color")
    out.append("COLORTERM=truecolor")   // SwiftTerm renders 24-bit; advertise it
    out.append("PATH=\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    return out
}
// Force claude's full-screen TUI to FULL-REPAINT instead of its cursor-relative
// differential redraw. The diff renderer rewinds by logical-line count, but a
// non-grapheme-aware emulator (SwiftTerm) wraps CJK / ZWJ-emoji / exact-width
// lines into a different physical-row count, so the rewind drifts and the screen
// garbles on scroll (clean in kitty/ghostty, which wrap the way claude assumes).
// This claude env var sidesteps the whole class of drift. Must be exported in the
// shell command because termCleanEnv() strips all CLAUDE_CODE* from the inherited env.
let fullRepaintExport = "export CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT=1"

// `--settings <file>` registers leader-hook.py on the turn-lifecycle hooks so the
// sidebar can breathe when this session finishes. It MERGES on top of the user's
// settings (OpenIsland's hooks keep firing). Empty path -> skip the flag.
func hookSettingsArg() -> String {
    let p = ensureLeaderHookSettings()
    return p.isEmpty ? "" : " --settings '\(p)'"
}
func resumeCommand(sid: String) -> String {
    let unset = "unset " + POISON.joined(separator: " ")
    let fallback = Conf.claudeBin.isEmpty ? "$HOME/.local/bin/claude" : Conf.claudeBin
    return "\(unset); \(proxyExport(for: .claude)); \(fullRepaintExport); CLAUDE=\"$(command -v claude || echo \(fallback))\"; "
         + "\"$CLAUDE\" --dangerously-skip-permissions\(hookSettingsArg()) --resume \(sid); exec /bin/zsh -i"
}

// Codex is deliberately launched with its normal approval and sandbox defaults.
// Leader is a terminal host here, not a policy override: unlike the legacy Claude
// path, it must not silently opt a Codex session into danger-full-access behavior.
func codexResumeCommand(sid: String) -> String {
    let fallback = Conf.codexBin.isEmpty ? "$HOME/.local/bin/codex" : Conf.codexBin
    return "\(proxyExport(for: .codex)); CODEX=\"$(command -v codex || echo \(fallback))\"; "
         + "\"$CODEX\" resume \(sid); exec /bin/zsh -i"
}
// Kimi is launched with its normal approval and sandbox defaults, just like Codex.
// Kimi uses `-S <id>` (or `--session <id>`) to resume a saved session.
func kimiResumeCommand(sid: String) -> String {
    let fallback = Conf.kimiBin.isEmpty ? "$HOME/.kimi-code/bin/kimi" : Conf.kimiBin
    return "\(proxyExport(for: .kimi)); KIMI=\"$(command -v kimi || echo \(fallback))\"; "
         + "\"$KIMI\" -S \(sid); exec /bin/zsh -i"
}
// New Kimi session: bare `kimi`. Unlike claude's --session-id, Kimi mints its own
// session id, so Leader tracks the embed under a synthetic sid (newKimiSession)
// until the next scan picks the real session up into the index.
func kimiNewCommand() -> String {
    let fallback = Conf.kimiBin.isEmpty ? "$HOME/.kimi-code/bin/kimi" : Conf.kimiBin
    return "\(proxyExport(for: .kimi)); KIMI=\"$(command -v kimi || echo \(fallback))\"; "
         + "\"$KIMI\"; exec /bin/zsh -i"
}
// New session with a caller-chosen session id, so the app knows the sid up front
// (no scan race). `claude --session-id <uuid>` starts a fresh conversation at that id.
func newSessionCommand(sid: String) -> String {
    let unset = "unset " + POISON.joined(separator: " ")
    let fallback = Conf.claudeBin.isEmpty ? "$HOME/.local/bin/claude" : Conf.claudeBin
    return "\(unset); \(proxyExport(for: .claude)); \(fullRepaintExport); CLAUDE=\"$(command -v claude || echo \(fallback))\"; "
         + "\"$CLAUDE\" --dangerously-skip-permissions\(hookSettingsArg()) --session-id \(sid); exec /bin/zsh -i"
}
func expandTilde(_ p: String) -> String { (p as NSString).expandingTildeInPath }

// 8-bit hex (0xRRGGBB) -> SwiftTerm.Color (its components are 16-bit, so ×257).
private func hexColor(_ hex: Int) -> SwiftTerm.Color {
    SwiftTerm.Color(red: UInt16((hex >> 16) & 0xff) * 257,
                    green: UInt16((hex >> 8) & 0xff) * 257,
                    blue: UInt16(hex & 0xff) * 257)
}

// The 16 ANSI colors of "Kaku Dark", copied verbatim from tw93/kaku
// (assets/.../kaku.lua, a softened "Aura" theme). The ANSI color CODES that
// programs emit (e.g. claude-hud's `ESC[32m` green) index INTO this table, so
// installing it makes those programs render with Kaku's muted hues instead of
// the default saturated xterm palette. Order: 0-7 normal, 8-15 bright.
//
// Caveat: slot 0 (black) is Kaku's light #c8c6cc so black *foreground* stays
// readable on a dark background — but SwiftTerm uses one color per slot for both
// fg and bg, so a program that paints an ANSI-black *background* will get light
// grey. Kaku dodges this with a separate bg override we can't express here; it's
// a rare case and the price of matching Kaku's palette exactly.
let kakuAnsiPalette: [SwiftTerm.Color] = [
    hexColor(0xc8c6cc), hexColor(0xd85d5d), hexColor(0x58d8ad), hexColor(0xdaae76),
    hexColor(0x68afda), hexColor(0x8e6ad9), hexColor(0x58d8ad), hexColor(0xd5d4d6),
    hexColor(0x6d6d6d), hexColor(0xd85d5d), hexColor(0x58d8ad), hexColor(0xdaae76),
    hexColor(0x90c9e6), hexColor(0x8e6ad9), hexColor(0x58d8ad), hexColor(0xd5d4d6),
]

// SwiftTerm's own default 16 (its `defaultInstalledColors` is internal, so we
// copy the exact values here) — used when the soft palette is toggled off.
let defaultAnsiPalette: [SwiftTerm.Color] = [
    hexColor(0x000000), hexColor(0x990001), hexColor(0x00a603), hexColor(0x999900),
    hexColor(0x0300b2), hexColor(0xb200b2), hexColor(0x00a5b2), hexColor(0xbfbfbf),
    hexColor(0x8a898a), hexColor(0xe50001), hexColor(0x00d800), hexColor(0xe5e500),
    hexColor(0x0700fe), hexColor(0xe500e5), hexColor(0x00e5e5), hexColor(0xe5e5e5),
]

func applyTermTheme(_ tv: LocalProcessTerminalView) {
    let size = Conf.termFontSize
    // Try the configured font first, then sensible fallbacks, then the system
    // monospace font so we always end up with *something* monospaced.
    for name in [Conf.termFont, "JetBrains Mono", "JetBrainsMono-Regular", "Menlo"] {
        if let f = NSFont(name: name, size: size) { tv.font = f; break }
    }
    if tv.font.pointSize != size { tv.font = .monospacedSystemFont(ofSize: size, weight: .regular) }
    tv.lineHeightMultiplier = Conf.lineHeight   // patched SwiftTerm: extra line spacing
    tv.configureNativeColors()   // adaptive default (used when soft colors are off)
    // Soft (Kaku Dark) theme: the muted ANSI palette was tuned for Kaku's #15141b
    // background, so on SwiftTerm's default background it looks off. Apply the
    // whole thing together — 16-color palette + bg/fg/cursor. installColors needs
    // exactly 16 or it no-ops.
    if Conf.softColors {
        tv.installColors(kakuAnsiPalette)
        let t = tv.getTerminal()
        tv.setBackgroundColor(source: t, color: hexColor(0x15141b))                       // Kaku Dark bg
        tv.setForegroundColor(source: t, color: hexColor(0xd5d4d6))                       // Kaku Dark fg
        tv.setCursorColor(source: t, color: hexColor(0x8e6ad9), textColor: hexColor(0x15141b))  // purple caret
    } else {
        tv.installColors(defaultAnsiPalette)
    }
    // setCursorStyle no-ops when unchanged, so reapplyTheme() is idempotent; the
    // change reaches both renderers (CG CaretView + Metal buildCursorDrawData).
    tv.getTerminal().setCursorStyle(CursorStyle.from(string: Conf.termCursorStyle) ?? .steadyBar)
    // perFrameAggregated: rebuild GPU buffers for the whole frame instead of
    // caching per-row — the right mode for our forced full-repaint workload.
    tv.metalBufferingMode = .perFrameAggregated
    do { try tv.setUseMetal(Conf.termMetal) }   // idempotent; safe from reapplyTheme()
    catch {
        // No Metal device (VM, old GPU): stay on the CG renderer, just note it.
        NSLog("Leader: Metal renderer unavailable, falling back to CoreGraphics: \(error)")
    }
}

final class EmbeddedTerminalView: LocalProcessTerminalView {
    private var scrollAccum: CGFloat = 0
    // The window is movable-by-background (titlebar is hidden), but the terminal
    // must NOT be a drag region or left-drag moves the window instead of selecting
    // text. Default is true for non-opaque views, so force it off here.
    override var mouseDownCanMoveWindow: Bool { false }
    // While this is non-past, promote every invalidation to a full repaint. Set
    // after a resize: claude reflows and streams its redraw over the PTY, and
    // SwiftTerm's partial repaint would otherwise leave the old layout's pixels
    // under the new frame.
    private var fullRepaintUntil: Date = .distantPast
    // Promote any invalidation to a full repaint while the app owns an alt-screen
    // (claude /tui fullscreen) — SwiftTerm's partial repaint leaves stale cells —
    // or during the post-resize window. Normal buffer otherwise keeps the efficient
    // incremental path. (Known limitation: even a full repaint doesn't fully fix
    // fullscreen *scroll*; /tui default scrolls fine.)
    // With the Metal renderer the terminal content is drawn by an MTKView on top
    // of this view (updateDisplay routes to requestMetalDisplay, not here), so the
    // promotion would only burn CPU re-rasterizing pixels nobody sees — skip it.
    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        if !isUsingMetalRenderer {
            let alt = terminal?.isCurrentBufferAlternate ?? false
            if alt || Date() < fullRepaintUntil { super.setNeedsDisplay(bounds); return }
        }
        super.setNeedsDisplay(invalidRect)
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)               // emulator reflows + SIGWINCH
        fullRepaintUntil = Date().addingTimeInterval(0.8)
        terminal?.updateFullScreen()
        needsDisplay = true
    }
    // ── IME preedit (marked text) ────────────────────────────────────────────
    // SwiftTerm's NSTextInputClient marked-text methods are stubs: setMarkedText
    // discards the string and hasMarkedText always answers false, so composing
    // pinyin was invisible — you typed blind until committing a candidate. The
    // composition itself already works (the IME owns the keystrokes; nothing
    // reaches the PTY until commit), so this is purely presentational: keep the
    // preedit string and show it in an overlay label pinned to the caret.
    private var preedit = ""
    private let preeditLabel = NSTextField(labelWithString: "")

    private func clearPreedit() {
        preedit = ""
        preeditLabel.removeFromSuperview()
    }
    private func showPreedit(selectedRange: NSRange) {
        // Rebuild style on every update: font/colors can change via Settings.
        let attr = NSMutableAttributedString(string: preedit, attributes: [
            .font: font,
            .foregroundColor: nativeForegroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let ns = preedit as NSString
        if selectedRange.location != NSNotFound, selectedRange.length > 0,
           selectedRange.location + selectedRange.length <= ns.length {
            // The clause the IME is currently converting: thicker underline.
            attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue,
                              range: selectedRange)
        }
        preeditLabel.attributedStringValue = attr
        preeditLabel.drawsBackground = true
        preeditLabel.backgroundColor = nativeBackgroundColor   // occlude the cells beneath
        preeditLabel.sizeToFit()
        // Pin to the caret cell. firstRect() is the caret frame in screen coords;
        // it stays current under the Metal renderer too (updateCursorPosition keeps
        // moving the hidden caret view). Clamp so long preedits never overflow.
        var origin = CGPoint.zero
        let screen = firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        if screen != .zero, let window {
            let caret = convert(window.convertFromScreen(screen), from: nil)
            origin = CGPoint(x: caret.minX, y: caret.minY + (caret.height - preeditLabel.frame.height) / 2)
        }
        origin.x = max(0, min(origin.x, bounds.width - preeditLabel.frame.width))
        origin.y = max(0, min(origin.y, bounds.height - preeditLabel.frame.height))
        preeditLabel.setFrameOrigin(origin)
        if preeditLabel.superview !== self { addSubview(preeditLabel) }  // topmost: above MTKView
    }

    // NSTextInputClient — super only tracks kitty-protocol composing state; layer
    // the real marked-text bookkeeping on top of it.
    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        preedit = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        if preedit.isEmpty { clearPreedit() } else { showPreedit(selectedRange: selectedRange) }
    }
    public override func unmarkText() {
        super.unmarkText()
        clearPreedit()
    }
    public override func hasMarkedText() -> Bool { !preedit.isEmpty }
    public override func markedRange() -> NSRange {
        preedit.isEmpty ? NSRange(location: NSNotFound, length: 0)
                        : NSRange(location: 0, length: (preedit as NSString).length)
    }
    public override func attributedSubstring(forProposedRange range: NSRange,
                                             actualRange: NSRangePointer?) -> NSAttributedString? {
        let ns = preedit as NSString
        guard range.location != NSNotFound, range.location < ns.length else { return nil }
        let clamped = NSRange(location: range.location,
                              length: min(range.length, ns.length - range.location))
        actualRange?.pointee = clamped
        return NSAttributedString(string: ns.substring(with: clamped))
    }
    public override func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .markedClauseSegment]
    }
    public override func insertText(_ string: Any, replacementRange: NSRange) {
        clearPreedit()   // commit: the terminal's own cells take over from here
        super.insertText(string, replacementRange: replacementRange)
    }
    // Switching sessions reparents this view mid-composition (SwiftTerm marks
    // resignFirstResponder public-not-open, so hook the reparent itself); drop
    // the composition instead of leaving a stale overlay behind.
    public override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if !preedit.isEmpty {
            inputContext?.discardMarkedText()
            clearPreedit()
        }
    }

    func handleScroll(_ event: NSEvent) -> Bool {
        guard let term = terminal else { return false }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 12
        if dy == 0 { return true }
        if term.isCurrentBufferAlternate && allowMouseReporting && term.mouseMode != .off {
            scrollAccum += dy
            let perTick: CGFloat = 12
            var ticks = 0
            while abs(scrollAccum) >= perTick && ticks < 8 {
                let up = scrollAccum > 0
                scrollAccum += up ? -perTick : perTick
                ticks += 1
                let flags = term.encodeButton(button: up ? 4 : 5, release: false,
                    shift: event.modifierFlags.contains(.shift),
                    meta: event.modifierFlags.contains(.option),
                    control: event.modifierFlags.contains(.control))
                let p = convert(event.locationInWindow, from: nil)
                let col = min(term.cols, max(1, Int(p.x / (bounds.width / CGFloat(max(1, term.cols)))) + 1))
                let row = min(term.rows, max(1, term.rows - Int(p.y / (bounds.height / CGFloat(max(1, term.rows))))))
                term.sendEvent(buttonFlags: flags, x: col, y: row)
            }
            return true
        }
        if term.isCurrentBufferAlternate {
            // Alt-screen has no scrollback, so scrollUp/Down is a no-op. Translate the
            // wheel into arrow keys for the app (vim/less/claude TUI), like kitty/wezterm
            // do when the app hasn't enabled mouse reporting. Encoding respects DECCKM.
            let app = term.applicationCursor
            let up: [UInt8]   = app ? [0x1b, 0x4f, 0x41] : [0x1b, 0x5b, 0x41]   // ESC O A / ESC [ A
            let down: [UInt8] = app ? [0x1b, 0x4f, 0x42] : [0x1b, 0x5b, 0x42]   // ESC O B / ESC [ B
            scrollAccum += dy
            let perTick: CGFloat = 12
            var ticks = 0
            while abs(scrollAccum) >= perTick && ticks < 8 {
                let goUp = scrollAccum > 0
                scrollAccum += goUp ? -perTick : perTick
                ticks += 1
                send(goUp ? up : down)
            }
            return true
        }
        let v = max(1, Int(abs(dy) / 12))
        if dy > 0 { scrollUp(lines: v) } else { scrollDown(lines: v) }
        return true
    }
}

func installScrollMonitor() {
    NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        guard let content = event.window?.contentView else { return event }
        var v: NSView? = content.hitTest(event.locationInWindow)
        while let cur = v, !(cur is EmbeddedTerminalView) { v = cur.superview }
        guard let term = v as? EmbeddedTerminalView else { return event }
        return term.handleScroll(event) ? nil : event
    }
}

// Sessions to reopen on the next launch, written by the quit dialog when its
// "恢复会话" checkbox is on (macOS logout-style). One-shot by design: consume()
// deletes the file before spawning anything, so a crash during restore can't
// loop into repeatedly mass-spawning claude processes.
struct RestoreEntry: Codable {
    let sid: String
    let cwd: String
}
struct RestoreFile: Codable {
    let sessions: [RestoreEntry]
    let active: String?   // the session the main pane showed at quit
}
enum RestoreState {
    static let path = NSString(string: "~/.config/leader/restore.json").expandingTildeInPath
    static func save(_ file: RestoreFile) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(file) { try? d.write(to: url) }
    }
    static func clear() { try? FileManager.default.removeItem(atPath: path) }
    static func consume() -> RestoreFile? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        clear()
        guard let f = try? JSONDecoder().decode(RestoreFile.self, from: d),
              !f.sessions.isEmpty else { return nil }
        return f
    }
}

@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()
    private var views: [String: EmbeddedTerminalView] = [:]
    // cwd each open session was spawned in — self-contained restore data, so
    // reopening after a relaunch never depends on scan.py having run yet.
    private var cwds: [String: String] = [:]
    // Mirrors ContentView's activeSID (set in its .onChange) so the quit dialog
    // in AppDelegate can persist which session the main pane was showing.
    var lastActiveSid: String?
    @Published var running: Set<String> = []
    @Published var exited: Set<String> = []
    private let delegate = TermDelegate()

    // What the quit dialog offers to restore: every running embedded session
    // with the cwd it was spawned in. Sorted for a deterministic file.
    var restoreSnapshot: [RestoreEntry] {
        running.sorted().compactMap { sid in cwds[sid].map { RestoreEntry(sid: sid, cwd: $0) } }
    }
    func cwd(forSid sid: String) -> String? { cwds[sid] }

    // Claude predates provider namespacing and persists bare ids in restore.json.
    // Keep that compatibility contract; newer providers are namespaced so sids
    // from different CLIs never collide in the same TerminalManager maps.
    private func key(_ sid: String, _ kind: TerminalKind) -> String {
        switch kind {
        case .claude: return sid
        case .codex: return "codex:\(sid)"
        case .kimi: return "kimi:\(sid)"
        }
    }
    private func resumeCommandString(for kind: TerminalKind, sid: String) -> String {
        switch kind {
        case .claude: return resumeCommand(sid: sid)
        case .codex: return codexResumeCommand(sid: sid)
        case .kimi: return kimiResumeCommand(sid: sid)
        }
    }
    func terminal(forSid sid: String, cwd: String, kind: TerminalKind = .claude) -> EmbeddedTerminalView {
        let k = key(sid, kind)
        if let v = views[k] { return v }
        let tv = EmbeddedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        applyTermTheme(tv)
        delegate.owner = self
        delegate.sidByView[ObjectIdentifier(tv)] = k
        tv.processDelegate = delegate
        let command = resumeCommandString(for: kind, sid: sid)
        tv.startProcess(executable: "/bin/zsh", args: ["-lc", command],
                        environment: termCleanEnv(), currentDirectory: expandTilde(cwd))
        views[k] = tv
        cwds[k] = cwd
        markRunningDeferred(k)
        return tv
    }
    // Restore entry points: restore.json persists termKeys (claude bare, others
    // namespaced), so the kind must be recovered from the key — otherwise a
    // restored Codex/Kimi session would be spawned with the claude --resume
    // command. Splits the key and forwards to terminal(forSid:cwd:kind:).
    func terminal(forStoredKey storedKey: String, cwd: String) -> EmbeddedTerminalView {
        let (kind, sid) = kindAndSid(fromTermKey: storedKey)
        return terminal(forSid: sid, cwd: cwd, kind: kind)
    }
    // Start a brand-new session at a caller-chosen sid (no --resume). If a view for
    // that sid already exists it's returned as-is, so a later TerminalContainer
    // lookup reuses it instead of re-spawning with --resume.
    func newSession(sid: String, cwd: String) -> EmbeddedTerminalView {
        if let v = views[sid] { return v }
        let tv = EmbeddedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        applyTermTheme(tv)
        delegate.owner = self
        delegate.sidByView[ObjectIdentifier(tv)] = sid
        tv.processDelegate = delegate
        tv.startProcess(executable: "/bin/zsh", args: ["-lc", newSessionCommand(sid: sid)],
                        environment: termCleanEnv(), currentDirectory: expandTilde(cwd))
        views[sid] = tv
        cwds[sid] = cwd
        markRunningDeferred(sid)
        return tv
    }
    // New Kimi session (bare `kimi` in cwd). Kimi has no --session-id equivalent,
    // so the embed is keyed under a synthetic "new-<hex>" sid until the session
    // lands in ~/.kimi-code/session_index.jsonl. Returns the synthetic sid.
    @discardableResult
    func newKimiSession(cwd: String) -> String {
        let sid = "new-" + String(UUID().uuidString.lowercased().prefix(8))
        let k = key(sid, .kimi)
        if views[k] != nil { return sid }
        let tv = EmbeddedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        applyTermTheme(tv)
        delegate.owner = self
        delegate.sidByView[ObjectIdentifier(tv)] = k
        tv.processDelegate = delegate
        tv.startProcess(executable: "/bin/zsh", args: ["-lc", kimiNewCommand()],
                        environment: termCleanEnv(), currentDirectory: expandTilde(cwd))
        views[k] = tv
        cwds[k] = cwd
        markRunningDeferred(k)
        return sid
    }
    // terminal(forSid:)/newSession are called from TerminalContainer.updateNSView —
    // i.e. MID view update. Mutating @Published there is SwiftUI undefined behavior
    // ("Publishing changes from within view updates"): the transaction's other
    // invalidations get dropped — concretely, clicking a not-yet-open session
    // switched the terminal pane but the sidebar row highlight never moved.
    // Defer the publish to the next runloop tick, outside the render pass.
    private func markRunningDeferred(_ sid: String) {
        DispatchQueue.main.async {
            guard self.views[sid] != nil else { return }   // closed before the tick landed
            self.running.insert(sid); self.exited.remove(sid)
        }
    }
    func isOpen(_ sid: String, kind: TerminalKind = .claude) -> Bool { views[key(sid, kind)] != nil }
    // Move a live terminal to a new key WITHOUT touching its process. Used when a
    // synthetic key (kimi "new-<hex>") is adopted by the real session id the
    // scanner just picked up — the alternative (look the session up under its real
    // sid later) would spawn a SECOND CLI process on the same session.
    func rekey(from oldKey: String, to newKey: String) {
        guard let v = views[oldKey] else { return }
        views.removeValue(forKey: oldKey)
        views[newKey] = v
        if let c = cwds.removeValue(forKey: oldKey) { cwds[newKey] = c }
        if running.remove(oldKey) != nil { running.insert(newKey) }
        if exited.remove(oldKey) != nil { exited.insert(newKey) }
        delegate.sidByView[ObjectIdentifier(v)] = newKey
        if lastActiveSid == oldKey { lastActiveSid = newKey }
    }
    func close(_ sid: String, kind: TerminalKind = .claude) {
        let sid = key(sid, kind)
        // Clear badge state UNCONDITIONALLY first — even if the view is somehow
        // already gone, the sidebar badge (driven by running/exited) must clear.
        // Doing it before terminate() also means the async processTerminated ->
        // markExited (below) sees the view untracked and won't re-add `exited`.
        running.remove(sid); exited.remove(sid)
        cwds.removeValue(forKey: sid)
        if let v = views[sid] {
            views.removeValue(forKey: sid)
            // Kill the whole process GROUP: the child is `zsh -lc "claude …"`, and
            // terminate() only signals the shell — the orphaned claude can linger
            // long enough for the next scan's ps to still count it "alive" (活跃).
            // forkpty setsid's the child, so pgid == shellPid and -pid is the group.
            if let pid = v.process?.shellPid, pid > 0 { kill(-pid, SIGTERM) }
            v.terminate()
            v.removeFromSuperview()
        }
    }
    // Process exited on its own (claude quit) -> show the "exited" badge. Ignore
    // terminations from an explicit close() (the view is already untracked).
    func markExited(_ sid: String) {
        guard views[sid] != nil else { return }
        running.remove(sid); exited.insert(sid)
    }
    var anyOpen: Bool { !views.isEmpty }
    // Re-apply font/size to every open terminal (called after Settings saves).
    // SwiftTerm's font setter recomputes cell size and repaints from its own
    // buffer, so this takes effect without reopening the session.
    func reapplyTheme() { for v in views.values { applyTermTheme(v) } }
}

final class TermDelegate: LocalProcessTerminalViewDelegate {
    weak var owner: TerminalManager?
    var sidByView: [ObjectIdentifier: String] = [:]
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let tv = source as? LocalProcessTerminalView,
              let sid = sidByView[ObjectIdentifier(tv)] else { return }
        DispatchQueue.main.async { self.owner?.markExited(sid) }
    }
}

// Hosts the selected session's terminal; reparents the one visible terminal so
// all opened sessions stay alive in the background for instant switching.
// Inner padding around the embedded terminal (Kaku-style breathing room; the
// gutter is painted the same color as the terminal background so it reads as one
// surface, not a border).
let terminalInnerPadding: CGFloat = 10

// The color the host gutter is painted so it matches the terminal background:
// Kaku Dark's #15141b when soft colors are on, otherwise the adaptive default.
func terminalHostBGColor() -> NSColor {
    Conf.softColors ? NSColor(srgbRed: 0x15/255, green: 0x14/255, blue: 0x1b/255, alpha: 1)
                    : .textBackgroundColor
}

struct TerminalContainer: NSViewRepresentable {
    let sid: String
    let cwd: String
    var kind: TerminalKind = .claude
    // NOT @ObservedObject: this container hosts exactly one session's terminal and
    // reparents on sid change. Observing TerminalManager made every running/exited
    // publish re-run updateNSView, and updateNSView calls the *mutating* factory
    // terminal(forSid:). So close()'s `running.remove` re-triggered updateNSView on
    // the still-mounted container, which re-created the just-killed terminal (new
    // claude process!) and re-inserted `running` — the row popped back into 活跃.
    // Lifecycle is driven solely by the parent passing sid via activeEmbed.
    private let mgr = TerminalManager.shared
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = terminalHostBGColor().cgColor
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        host.layer?.backgroundColor = terminalHostBGColor().cgColor   // keep gutter matching after a theme toggle
        let term = mgr.terminal(forSid: sid, cwd: cwd, kind: kind)
        for sub in host.subviews where sub !== term { sub.removeFromSuperview() }
        if term.superview !== host {
            term.removeFromSuperview()
            term.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(term)
            let p = terminalInnerPadding
            NSLayoutConstraint.activate([
                term.topAnchor.constraint(equalTo: host.topAnchor, constant: p),
                term.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -p),
                term.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: p),
                term.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -p),
            ])
        }
        DispatchQueue.main.async { host.window?.makeFirstResponder(term) }
    }
}
