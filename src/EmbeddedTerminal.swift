// EmbeddedTerminal.swift — hosts a live `claude --resume` inside the app via
// SwiftTerm, instead of a separate kitty window. Kept in its own file so that
// `import SwiftTerm` (which declares its own `Color`) doesn't collide with
// SwiftUI.Color used throughout LeaderApp.swift.
import Foundation
import AppKit
import SwiftUI
import SwiftTerm

// Machine-specific settings, mirroring config.py defaults. Read once at launch
// from ~/.config/leader/config.json (the proxy/claude_bin the python backend uses).
enum Conf {
    static let dict: [String: Any] = {
        let p = NSString(string: "~/.config/leader/config.json").expandingTildeInPath
        if let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
        return [:]
    }()
    static var proxy: String { (dict["proxy"] as? String) ?? "" }
    static var claudeBin: String { (dict["claude_bin"] as? String) ?? "" }
    static var newCwd: String { (dict["new_session_cwd"] as? String) ?? "~" }
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
func resumeCommand(sid: String) -> String {
    let unset = "unset " + POISON.joined(separator: " ")
    let fallback = Conf.claudeBin.isEmpty ? "$HOME/.local/bin/claude" : Conf.claudeBin
    return "\(unset); \(proxyExport()); CLAUDE=\"$(command -v claude || echo \(fallback))\"; "
         + "\"$CLAUDE\" --dangerously-skip-permissions --resume \(sid); exec /bin/zsh -i"
}
func newSessionCommand() -> String {
    let unset = "unset " + POISON.joined(separator: " ")
    let fallback = Conf.claudeBin.isEmpty ? "$HOME/.local/bin/claude" : Conf.claudeBin
    return "\(unset); \(proxyExport()); CLAUDE=\"$(command -v claude || echo \(fallback))\"; "
         + "\"$CLAUDE\" --dangerously-skip-permissions; exec /bin/zsh -i"
}
func expandTilde(_ p: String) -> String { (p as NSString).expandingTildeInPath }

func applyTermTheme(_ tv: LocalProcessTerminalView) {
    for name in ["JetBrains Mono", "JetBrainsMono-Regular", "Menlo"] {
        if let f = NSFont(name: name, size: 13) { tv.font = f; break }
    }
    tv.configureNativeColors()
}

final class EmbeddedTerminalView: LocalProcessTerminalView {
    private var scrollAccum: CGFloat = 0
    // Promote any invalidation to a full repaint while the app owns an alt-screen
    // (claude /tui fullscreen) — SwiftTerm's partial repaint leaves stale cells.
    // Normal buffer keeps the efficient incremental path. (Known limitation: even a
    // full repaint doesn't fully fix fullscreen scroll; /tui default scrolls fine.)
    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        if let t = terminal, t.isCurrentBufferAlternate { super.setNeedsDisplay(bounds) }
        else { super.setNeedsDisplay(invalidRect) }
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
    func isOpen(_ sid: String) -> Bool { views[sid] != nil }
    func close(_ sid: String) {
        guard let v = views[sid] else { return }
        v.terminate()
        v.removeFromSuperview()
        views.removeValue(forKey: sid)
        running.remove(sid); exited.remove(sid)
    }
    func markExited(_ sid: String) { running.remove(sid); exited.insert(sid) }
    var anyOpen: Bool { !views.isEmpty }
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
struct TerminalContainer: NSViewRepresentable {
    let sid: String
    let cwd: String
    @ObservedObject var mgr = TerminalManager.shared
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        let term = mgr.terminal(forSid: sid, cwd: cwd)
        for sub in host.subviews where sub !== term { sub.removeFromSuperview() }
        if term.superview !== host {
            term.removeFromSuperview()
            term.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(term)
            NSLayoutConstraint.activate([
                term.topAnchor.constraint(equalTo: host.topAnchor),
                term.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                term.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                term.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        }
        DispatchQueue.main.async { host.window?.makeFirstResponder(term) }
    }
}
