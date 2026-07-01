// QuakeTerminal.swift — a Quake-style drop-down scratch terminal.
//
// Double-tap Control anywhere in the app to drop a floating, rounded, shadowed
// panel from the top of the screen holding a plain `/bin/zsh`, opened in the
// currently-active session's working directory. It's for the quick "let me run
// a command real quick" need that iTerm's Cmd+D split used to cover.
//
// Two ways to dismiss, with different semantics (as requested):
//   - double-tap Control again  -> collapse (slide up, KEEP the shell + scrollback)
//   - the ✕ button              -> close for real (terminate; next open is fresh,
//                                   in whatever session is active then)
import AppKit
import SwiftUI
import SwiftTerm

// Invisible probe placed over the right-hand terminal area; QuakeTerminal reads
// its on-screen rect to drop the scratch panel centered over the terminal (not
// the whole screen).
struct TerminalAreaProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { QuakeTerminal.shared.anchorView = v }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { QuakeTerminal.shared.anchorView = v }
}

// A borderless panel must opt in to key/main or it can't receive keystrokes.
final class QuakePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class QuakeTerminal: NSObject {
    static let shared = QuakeTerminal()

    private var panel: QuakePanel?
    private var term: EmbeddedTerminalView?
    private var visible = false
    private var lastCtrlPress: TimeInterval = 0
    private static let doubleTapWindow: TimeInterval = 0.4   // seconds

    // The right-hand terminal area, set by TerminalAreaProbe. The panel drops
    // centered over this, never wider than it.
    weak var anchorView: NSView?

    // ContentView keeps this pointed at the active session's cwd; captured when the
    // shell is (re)created, so a collapsed-and-reopened terminal keeps its dir but a
    // ✕-closed one reopens wherever you are now.
    var currentCwd: String = NSHomeDirectory()

    // MARK: hotkey (double-tap Control)
    // Local monitor: fires only while Leader is the active app, which is exactly
    // when this is wanted (no Accessibility permission, unlike a global key tap).
    func installHotkey() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
            return e
        }
    }
    private func handleFlags(_ e: NSEvent) {
        // Count Control *presses* only: keyCode 59 (left) / 62 (right), and the
        // control flag now on means this transition was a press, not a release.
        guard e.keyCode == 59 || e.keyCode == 62 else { return }
        guard e.modifierFlags.contains(.control) else { return }
        // Ignore chords like Ctrl+Cmd — only a clean Control tap counts.
        guard e.modifierFlags.isDisjoint(with: [.command, .option, .shift]) else { return }
        let now = e.timestamp
        if now - lastCtrlPress <= Self.doubleTapWindow {
            lastCtrlPress = 0
            toggle()
        } else {
            lastCtrlPress = now
        }
    }

    // Re-apply font/size to the scratch terminal if it's alive (Settings save).
    func reapplyTheme() { if let t = term { applyTermTheme(t) } }

    // MARK: show / collapse / close
    func toggle() { visible ? collapse() : show() }

    func show() {
        let p = ensurePanel()
        let g = geometry()
        p.setFrame(g.hidden, display: false)
        p.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        if let t = term { p.makeFirstResponder(t) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(g.shown, display: true)
            p.animator().alphaValue = 1
        }
        p.invalidateShadow()
        visible = true
    }

    // Slide up but keep the process alive (double-Control dismiss).
    func collapse() {
        guard let p = panel else { visible = false; return }
        let g = geometry()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(g.hidden, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
        visible = false
    }

    // On-screen rect of the terminal area (or nil if not laid out yet).
    private func anchorScreenRect() -> NSRect? {
        guard let v = anchorView, let win = v.window, v.bounds.width > 1 else { return nil }
        return win.convertToScreen(v.convert(v.bounds, to: nil))
    }

    // Shown/hidden frames: centered over the terminal area, dropping from its top,
    // never wider than it. Falls back to the screen if the area isn't available.
    private func geometry() -> (shown: NSRect, hidden: NSRect) {
        let m: CGFloat = 8
        if let a = anchorScreenRect() {
            let w = max(300, a.width - m * 2)
            let h = min(a.height - m * 2, max(240, a.height * 0.62))
            let x = a.minX + (a.width - w) / 2
            return (NSRect(x: x, y: a.maxY - h - m, width: w, height: h),   // just below top edge
                    NSRect(x: x, y: a.maxY + 4, width: w, height: h))        // just above top edge
        }
        let vf = (NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let w = min(1000, vf.width * 0.72), h = min(560, vf.height * 0.5)
        let x = vf.minX + (vf.width - w) / 2
        return (NSRect(x: x, y: vf.maxY - h - m, width: w, height: h),
                NSRect(x: x, y: vf.maxY + 4, width: w, height: h))
    }

    // Terminate and tear down (✕ button): the next show() spawns a fresh shell in
    // the then-current directory.
    @objc func closeForReal() {
        term?.terminate()
        term = nil
        panel?.orderOut(nil)
        panel = nil
        visible = false
    }

    // MARK: panel construction
    private func ensurePanel() -> QuakePanel {
        if let p = panel { return p }
        let p = QuakePanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true          // drag the top bar to move it
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        let bar = makeBar()
        let tv = EmbeddedTerminalView(frame: .zero)
        applyTermTheme(tv)
        tv.startProcess(executable: "/bin/zsh", args: ["-il"],
                        environment: quakeShellEnv(),
                        currentDirectory: expandTilde(currentCwd))
        self.term = tv

        bar.translatesAutoresizingMaskIntoConstraints = false
        tv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            tv.topAnchor.constraint(equalTo: bar.bottomAnchor),
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        p.contentView = container
        panel = p
        return p
    }

    // If a proxy is configured, it wins: drop any inherited proxy vars and inject
    // ours. If none is configured, keep whatever the app inherited (shell launch).
    private func quakeShellEnv() -> [String] {
        var env = termCleanEnv()
        let extra = proxyEnvEntries()
        guard !extra.isEmpty else { return env }
        let keys = ["http_proxy=", "https_proxy=", "all_proxy=",
                    "HTTP_PROXY=", "HTTPS_PROXY=", "ALL_PROXY="]
        env.removeAll { e in keys.contains { e.hasPrefix($0) } }
        return env + extra
    }

    private func makeBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor

        let label = NSTextField(labelWithString: "临时终端 · ⌃⌃ 收起")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "", target: self, action: #selector(closeForReal))
        close.bezelStyle = .circular
        close.image = NSImage(systemSymbolName: "xmark.circle.fill",
                              accessibilityDescription: "关闭临时终端")
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "关闭(销毁,下次在当前会话目录重开)"
        close.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(label)
        bar.addSubview(close)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
            close.heightAnchor.constraint(equalToConstant: 18),
        ])
        return bar
    }
}
