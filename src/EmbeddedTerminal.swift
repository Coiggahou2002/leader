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
    static var claudeBin: String { (dict["claude_bin"] as? String) ?? "" }
    static var newCwd: String { (dict["new_session_cwd"] as? String) ?? "~" }
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

// Proxy env entries (or []) shared by any plain shell we spawn (e.g. the quake
// terminal). claude terminals inject the same vars via proxyExport() in their
// launch command; this is the array-form for processes started without a shell
// snippet.
func proxyEnvEntries() -> [String] {
    let p = Conf.proxy
    guard !p.isEmpty else { return [] }
    return ["http_proxy=http://\(p)", "https_proxy=http://\(p)", "all_proxy=socks5://\(p)"]
}

// CRITICAL: a `claude` launched with CLAUDE_CODE_*/CODEX_COMPANION_* in its env
// runs as a NESTED child session and does NOT persist its transcript. Strip them.
let POISON: [String] = [
    "CLAUDECODE", "CLAUDE_PLUGIN_DATA", "CLAUDE_EFFORT",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_SESSION_ID", "CODEX_COMPANION_SESSION_ID",
]
func termCleanEnv() -> [String] {
    var out: [String] = []
    for (k, v) in ProcessInfo.processInfo.environment {
        if POISON.contains(k) || k.hasPrefix("CLAUDE_CODE") || k.hasPrefix("CODEX_COMPANION") { continue }
        out.append("\(k)=\(v)")
    }
    if !out.contains(where: { $0.hasPrefix("TERM=") }) { out.append("TERM=xterm-256color") }
    out.append("PATH=\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    return out
}
func proxyExport() -> String {
    let p = Conf.proxy
    guard !p.isEmpty else { return ":" }
    return "export http_proxy=http://\(p) https_proxy=http://\(p) all_proxy=socks5://\(p)"
}
// Force claude's full-screen TUI to FULL-REPAINT instead of its cursor-relative
// differential redraw. The diff renderer rewinds by logical-line count, but a
// non-grapheme-aware emulator (SwiftTerm) wraps CJK / ZWJ-emoji / exact-width
// lines into a different physical-row count, so the rewind drifts and the screen
// garbles on scroll (clean in kitty/ghostty, which wrap the way claude assumes).
// This claude env var sidesteps the whole class of drift. Must be exported in the
// shell command because termCleanEnv() strips all CLAUDE_CODE* from the inherited env.
let fullRepaintExport = "export CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT=1"

func resumeCommand(sid: String) -> String {
    let unset = "unset " + POISON.joined(separator: " ")
    let fallback = Conf.claudeBin.isEmpty ? "$HOME/.local/bin/claude" : Conf.claudeBin
    return "\(unset); \(proxyExport()); \(fullRepaintExport); CLAUDE=\"$(command -v claude || echo \(fallback))\"; "
         + "\"$CLAUDE\" --dangerously-skip-permissions --resume \(sid); exec /bin/zsh -i"
}
// New session with a caller-chosen session id, so the app knows the sid up front
// (no scan race). `claude --session-id <uuid>` starts a fresh conversation at that id.
func newSessionCommand(sid: String) -> String {
    let unset = "unset " + POISON.joined(separator: " ")
    let fallback = Conf.claudeBin.isEmpty ? "$HOME/.local/bin/claude" : Conf.claudeBin
    return "\(unset); \(proxyExport()); \(fullRepaintExport); CLAUDE=\"$(command -v claude || echo \(fallback))\"; "
         + "\"$CLAUDE\" --dangerously-skip-permissions --session-id \(sid); exec /bin/zsh -i"
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
    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        let alt = terminal?.isCurrentBufferAlternate ?? false
        if alt || Date() < fullRepaintUntil { super.setNeedsDisplay(bounds) }
        else { super.setNeedsDisplay(invalidRect) }
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)               // emulator reflows + SIGWINCH
        fullRepaintUntil = Date().addingTimeInterval(0.8)
        terminal?.updateFullScreen()
        needsDisplay = true
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

@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()
    private var views: [String: EmbeddedTerminalView] = [:]
    @Published var running: Set<String> = []
    @Published var exited: Set<String> = []
    private let delegate = TermDelegate()

    func terminal(forSid sid: String, cwd: String) -> EmbeddedTerminalView {
        if let v = views[sid] { return v }
        let tv = EmbeddedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        applyTermTheme(tv)
        delegate.owner = self
        delegate.sidByView[ObjectIdentifier(tv)] = sid
        tv.processDelegate = delegate
        tv.startProcess(executable: "/bin/zsh", args: ["-lc", resumeCommand(sid: sid)],
                        environment: termCleanEnv(), currentDirectory: expandTilde(cwd))
        views[sid] = tv
        running.insert(sid); exited.remove(sid)
        return tv
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
        running.insert(sid); exited.remove(sid)
        return tv
    }
    func isOpen(_ sid: String) -> Bool { views[sid] != nil }
    func close(_ sid: String) {
        // Clear badge state UNCONDITIONALLY first — even if the view is somehow
        // already gone, the sidebar badge (driven by running/exited) must clear.
        // Doing it before terminate() also means the async processTerminated ->
        // markExited (below) sees the view untracked and won't re-add `exited`.
        running.remove(sid); exited.remove(sid)
        if let v = views[sid] {
            views.removeValue(forKey: sid)
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
    @ObservedObject var mgr = TerminalManager.shared
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = terminalHostBGColor().cgColor
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        host.layer?.backgroundColor = terminalHostBGColor().cgColor   // keep gutter matching after a theme toggle
        let term = mgr.terminal(forSid: sid, cwd: cwd)
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
