import AppKit
import SwiftUI
import SwiftTerm

// ============================================================================
// Leader — embedded-terminal SPIKE
// Goal: prove we can host live `claude` sessions INSIDE one window (sidebar +
// embedded terminal), instead of spraying kitty windows across the desktop.
// Also a headless `--bench` to measure SwiftTerm's VT-parse/render throughput.
// ============================================================================

// ---- env hygiene (must match launch.py, or resumed sessions don't persist) --
let POISON: [String] = [
    "CLAUDECODE", "CLAUDE_PLUGIN_DATA", "CLAUDE_EFFORT",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_SESSION_ID", "CODEX_COMPANION_SESSION_ID",
]
func cleanEnv() -> [String] {
    var out: [String] = []
    for (k, v) in ProcessInfo.processInfo.environment {
        if POISON.contains(k) || k.hasPrefix("CLAUDE_CODE") || k.hasPrefix("CODEX_COMPANION") { continue }
        out.append("\(k)=\(v)")
    }
    if !out.contains(where: { $0.hasPrefix("TERM=") }) { out.append("TERM=xterm-256color") }
    return out
}
func resumeCommand(sid: String) -> String {
    let unset = "unset " + POISON.joined(separator: " ")
    // command -v claude in a non-interactive login shell resolves the real binary
    // (the yolo alias lives in .zshrc, interactive-only). Fallback to ~/.local/bin.
    return "\(unset); CLAUDE=\"$(command -v claude || echo $HOME/.local/bin/claude)\"; "
         + "\"$CLAUDE\" --dangerously-skip-permissions --resume \(sid); exec /bin/zsh -i"
}
func expandTilde(_ p: String) -> String { (p as NSString).expandingTildeInPath }

// ---- session model (subset of scan.py --json) ------------------------------
struct Session: Decodable, Identifiable, Hashable {
    let full_sid: String
    let sid: String?
    let cwd: String?
    let title: String?
    let nickname: String?
    let bucket: String?
    var id: String { full_sid }
    var display: String {
        if let n = nickname, !n.isEmpty { return n }
        if let t = title, !t.isEmpty { return t }
        return String(full_sid.prefix(8))
    }
    var folder: String { ((cwd ?? "~") as NSString).lastPathComponent }
    static func == (a: Session, b: Session) -> Bool { a.full_sid == b.full_sid }
    func hash(into h: inout Hasher) { h.combine(full_sid) }
}

func backendDir() -> String {
    // run from the spike's sibling src/ (scan.py lives there)
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    var dir = here
    for _ in 0..<8 {
        let candidate = dir.appendingPathComponent("src/scan.py")
        if FileManager.default.fileExists(atPath: candidate.path) { return dir.appendingPathComponent("src").path }
        dir = dir.deletingLastPathComponent()
    }
    return expandTilde("~/dev/leader.wt/embedded-terminal/src")
}

func loadSessions() -> [Session] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [backendDir() + "/scan.py", "--json"]
    p.currentDirectoryURL = URL(fileURLWithPath: backendDir())
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (try? JSONDecoder().decode([Session].self, from: data)) ?? []
}

// ---- terminal manager: one live terminal per sid, kept alive across switches -
@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()
    private var views: [String: LocalProcessTerminalView] = [:]
    @Published var running: Set<String> = []     // has a live (non-exited) process
    @Published var exited: Set<String> = []       // process terminated
    private let delegate = TermDelegate()

    func terminal(for s: Session) -> LocalProcessTerminalView {
        if let v = views[s.full_sid] { return v }
        let tv = EmbeddedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        applyTheme(tv)
        delegate.owner = self
        delegate.sidByView[ObjectIdentifier(tv)] = s.full_sid
        tv.processDelegate = delegate
        tv.startProcess(executable: "/bin/zsh",
                        args: ["-lc", resumeCommand(sid: s.full_sid)],
                        environment: cleanEnv(),
                        currentDirectory: expandTilde(s.cwd ?? "~"))
        views[s.full_sid] = tv
        running.insert(s.full_sid); exited.remove(s.full_sid)
        return tv
    }
    func isOpen(_ sid: String) -> Bool { views[sid] != nil }
    func close(_ sid: String) {
        guard let v = views[sid] else { return }
        v.terminate()                 // kill the child process -> free resources
        v.removeFromSuperview()
        views.removeValue(forKey: sid)
        running.remove(sid); exited.remove(sid)
    }
    func markExited(_ sid: String) { running.remove(sid); exited.insert(sid) }
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

// SwiftTerm's stock scrollWheel always scrolls its own scrollback and never
// forwards the wheel to the child. claude runs a full-screen TUI (alternate
// buffer + mouse reporting), so its scrollback is empty -> the wheel does
// nothing. Forward the wheel to the app in that mode; otherwise scroll locally
// (and handle trackpad precise deltas, which the stock deltaY==0 guard drops).
final class EmbeddedTerminalView: LocalProcessTerminalView {
    // Handle a scroll event. Returns true if consumed (caller swallows it).
    // SwiftTerm's own scrollWheel is `public override` (not `open`), so a local
    // event monitor calls this before dispatch instead.
    //
    // We deliberately scroll SwiftTerm's OWN buffer (the same path drag-select
    // auto-scroll uses, which renders cleanly) rather than forwarding wheel
    // events to claude: claude's mouse-reporting mode turns forwarded wheel
    // events into on-screen garbage. The original "can't scroll" bug was only
    // that trackpad precise deltas have deltaY==0, which SwiftTerm drops.
    func handleScroll(_ event: NSEvent) -> Bool {
        guard terminal != nil else { return false }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        if dy == 0 { return true }
        let v = max(1, Int(abs(dy) / (event.hasPreciseScrollingDeltas ? 3 : 1)))
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

func applyTheme(_ tv: LocalProcessTerminalView) {
    let candidates = ["JetBrains Mono", "JetBrainsMono-Regular", "Menlo"]
    for name in candidates {
        if let f = NSFont(name: name, size: 13) { tv.font = f; break }
    }
    tv.configureNativeColors()
}

// ---- terminal container: swap which cached terminal is visible -------------
struct TerminalContainer: NSViewRepresentable {
    let session: Session?
    @ObservedObject var mgr = TerminalManager.shared

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        let want = session.map { mgr.terminal(for: $0) }
        for sub in host.subviews where sub !== want { sub.removeFromSuperview() }
        guard let term = want else { return }
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

// ---- sidebar + content -----------------------------------------------------
struct ContentView: View {
    @State private var sessions: [Session] = []
    @State private var selected: Session?
    @State private var query: String = ""
    @StateObject private var mgr = TerminalManager.shared

    var filtered: [Session] {
        guard !query.isEmpty else { return sessions }
        let q = query.lowercased()
        return sessions.filter { $0.display.lowercased().contains(q) || $0.folder.lowercased().contains(q) }
    }
    func dot(_ s: Session) -> SwiftUI.Color {
        if mgr.exited.contains(s.full_sid) { return .red }
        if mgr.running.contains(s.full_sid) { return .green }
        return SwiftUI.Color.secondary.opacity(0.35)
    }
    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selected) { s in
                HStack(spacing: 8) {
                    Circle().fill(dot(s)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.display).lineLimit(1).font(.system(size: 12, weight: .medium))
                        Text(s.folder).lineLimit(1).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if mgr.isOpen(s.full_sid) {
                        Button { mgr.close(s.full_sid); if selected == s { selected = nil } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help("关闭会话终端（保留列表项）")
                    }
                }.tag(s)
            }
            .searchable(text: $query, placement: .sidebar)
            .frame(minWidth: 240)
            .navigationTitle("Leader · 嵌入式")
        } detail: {
            if let s = selected {
                TerminalContainer(session: s)
                    .navigationTitle(s.display)
                    .navigationSubtitle(s.cwd ?? "")
            } else {
                ContentUnavailableView("选择一个会话", systemImage: "terminal",
                    description: Text("点击左侧会话即可在此嵌入运行 claude --resume"))
            }
        }
        .onAppear {
            sessions = loadSessions()
            if let want = autoOpenSID, let s = sessions.first(where: { $0.full_sid == want }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selected = s }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installScrollMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

struct LeaderEmbedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            ContentView().frame(minWidth: 1000, minHeight: 640)
        }
    }
}

// ============================================================================
// Headless benchmark: measure SwiftTerm VT-parse/render throughput.
// `--bench <path-to-bigfile>`: cat the file into an embedded terminal, time it.
// ============================================================================
final class BenchDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let bytes: Int; let start: Date; let onDone: (Double, Double) -> Void
    init(bytes: Int, start: Date, onDone: @escaping (Double, Double) -> Void) {
        self.bytes = bytes; self.start = start; self.onDone = onDone
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let elapsed = Date().timeIntervalSince(start)
        let mbps = Double(bytes) / 1_048_576.0 / elapsed
        onDone(elapsed, mbps)
    }
}

func runBenchmark(file: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let bytes = ((try? FileManager.default.attributesOfItem(atPath: file)[.size]) as? Int) ?? 0
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                       styleMask: [.titled], backing: .buffered, defer: false)
    let tv = LocalProcessTerminalView(frame: win.contentView!.bounds)
    tv.autoresizingMask = [.width, .height]
    applyTheme(tv)
    win.contentView!.addSubview(tv)
    win.makeKeyAndOrderFront(nil)
    let start = Date()
    let delegate = BenchDelegate(bytes: bytes, start: start) { elapsed, mbps in
        print(String(format: "BENCH_RESULT bytes=%d elapsed=%.3fs throughput=%.1f MB/s",
                     bytes, elapsed, mbps))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }
    objc_setAssociatedObject(tv, "d", delegate, .OBJC_ASSOCIATION_RETAIN)
    tv.processDelegate = delegate
    tv.startProcess(executable: "/bin/zsh", args: ["-lc", "cat \(file)"], environment: cleanEnv())
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("BENCH_RESULT TIMEOUT"); exit(2)
    }
    app.run()
}

// ---- entry -----------------------------------------------------------------
let args = CommandLine.arguments
var autoOpenSID: String? = {
    if let i = args.firstIndex(of: "--open"), i + 1 < args.count { return args[i + 1] }
    return nil
}()
if let i = args.firstIndex(of: "--bench"), i + 1 < args.count {
    runBenchmark(file: args[i + 1])
} else {
    LeaderEmbedApp.main()
}
