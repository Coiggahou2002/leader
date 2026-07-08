// LeaderApp.swift — native macOS fleet panel.
// Data: scan.py --json.  Open: launch.py.  Archive: archive.py.
// Follows system Light/Dark, frosted-glass; normal window level (pin is opt-in).
import SwiftUI
import AppKit
import Observation

// MARK: - Shared design constants
enum DS {
    static let gap: CGFloat = 6
    static let rowPadV: CGFloat = 8
    static let rowPadH: CGFloat = 10
    static let corner: CGFloat = 9
    static let panelWidth: CGFloat = 320
    static let menuZone: CGFloat = 34      // trailing hit-zone: opens the ••• menu
}

// Flat, opaque sidebar fill (Codex-style). Solid so it reads uniform all the way
// to the top edge under the transparent titlebar — a VisualEffect material renders
// a darker band where the titlebar overlaps it.
let sidebarBGColor = NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.145, alpha: 1)   // ~#252525
        : NSColor(calibratedWhite: 0.96, alpha: 1)
}

// Neutral hover/press highlight for sidebar nav rows (no accent tint).
struct HoverRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: DS.corner)
                .fill(hover ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.clear)))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hover = $0 }
    }
}

// MARK: - Model
struct Session: Decodable, Identifiable {
    let full_sid: String
    let sid: String
    let title: String?
    let last_prompt: String?
    let cwd: String?
    let resume_cwd: String?   // dir `claude --resume` must run from (scan.py)
    let branch: String?
    let bucket: String
    let idle_h: Double
    let msgs: Int
    let out_tok: Int
    var alive: Bool         // var: optimistically cleared when its terminal is closed
    var archived: Bool      // var: allows optimistic local toggle
    var pinned: Bool
    // Position in pinned.json (= pin time). The 置顶 section sorts by this so
    // pinned rows never reshuffle with activity. nil (e.g. an optimistic pin
    // before the next scan) sorts last, matching pin.py's append-on-add.
    var pin_order: Int?
    var unread: Bool = false   // manually marked unread (red "1" badge); default keeps old data decodable
    var nickname: String?
    var id: String { full_sid }

    var name: String {
        if let n = nickname, !n.isEmpty { return n }
        return title ?? last_prompt ?? "(无标题)"
    }
    var repo: String {
        let home = NSHomeDirectory()
        return (cwd ?? "?").replacingOccurrences(of: home + "/dev/", with: "")
                           .replacingOccurrences(of: home + "/", with: "~/")
    }
    var ago: String { idle_h < 48 ? "\(Int(idle_h.rounded()))h" : "\(Int((idle_h/24).rounded()))d" }
    var isStale: Bool { idle_h >= 15 * 24 }     // 最后消息 ≥ 15 天
    static let order = ["a": 0, "b": 1, "c": 2]
}

// MARK: - Backend (python scripts)
enum Backend {
    // Python backend ships INSIDE the app bundle (Contents/Resources/backend),
    // so the app is self-contained. Falls back to a dev source path if missing.
    static let dir: String = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("backend").path,
           FileManager.default.fileExists(atPath: r) { return r }
        return NSString(string: "~/dev/leader/src").expandingTildeInPath
    }()
    static let py = "/usr/bin/python3"
    static func run(_ args: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return Data() }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return d
    }
    static func scan() -> [Session] {
        (try? JSONDecoder().decode([Session].self, from: run(["\(dir)/scan.py", "--json"]))) ?? []
    }
    @discardableResult
    static func open(_ s: Session) -> Bool {
        let d = run(["\(dir)/launch.py", s.full_sid, s.resume_cwd ?? s.cwd ?? ""])
        let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        return (o?["ok"] as? Bool) ?? false
    }
    static func setArchived(_ s: Session, _ on: Bool) {
        _ = run(["\(dir)/archive.py", on ? "add" : "remove", s.full_sid])
    }
    static func setPinned(_ s: Session, _ on: Bool) {
        _ = run(["\(dir)/pin.py", on ? "add" : "remove", s.full_sid])
    }
    static func setUnread(_ s: Session, _ on: Bool) {
        _ = run(["\(dir)/unread.py", on ? "add" : "remove", s.full_sid])
    }
    static func setNickname(_ s: Session, _ nick: String) {
        let trimmed = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = trimmed.isEmpty ? run(["\(dir)/name.py", "clear", s.full_sid])
                            : run(["\(dir)/name.py", "set", s.full_sid, trimmed])
    }
    static func newSession(_ cwd: String) {
        _ = run(["\(dir)/launch.py", "new", cwd])
    }
}

// MARK: - Leader data paths + hook install
enum LeaderPaths {
    static let dataDir = NSString(string: "~/.claude/leader").expandingTildeInPath
    // Per-session turn-lifecycle records written by leader-hook.py (Stop / etc.),
    // watched by Activity to pulse the sidebar. Kept separate from scan.py's
    // `registry` (live-pane mapping) so the two concerns don't collide.
    static let activityDir = dataDir + "/activity"
    static let hooksSettings = dataDir + "/leader-hooks.json"
    static var hookScript: String { Backend.dir + "/leader-hook.py" }
}

// Write the `--settings` JSON that registers leader-hook.py on the turn-lifecycle
// hooks, and return its path. Merged (not replacing) on top of the user's own
// settings, so OpenIsland's hooks keep firing. Rewritten each call so the script
// path stays correct even for an isolated verify build. Returns "" on failure so
// the caller can skip `--settings` rather than pass a broken path.
@discardableResult
func ensureLeaderHookSettings() -> String {
    let cmd = "/usr/bin/python3 '\(LeaderPaths.hookScript)' '\(LeaderPaths.activityDir)'"
    let entry: [[String: Any]] = [["hooks": [["type": "command", "command": cmd]]]]
    let json: [String: Any] = ["hooks": [
        "UserPromptSubmit": entry, "Stop": entry, "SessionEnd": entry,
    ]]
    let fm = FileManager.default
    try? fm.createDirectory(atPath: LeaderPaths.dataDir, withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(withJSONObject: json),
          (try? data.write(to: URL(fileURLWithPath: LeaderPaths.hooksSettings))) != nil
    else { return "" }
    return LeaderPaths.hooksSettings
}

// MARK: - Store
@MainActor @Observable
final class Store {
    var sessions: [Session] = []
    var loading = false
    var toast: String?
    @ObservationIgnored private var timer: Timer?
    // Bumped whenever a write lands. A scan captures the epoch when it *starts*;
    // if the epoch has advanced by the time it finishes, a mutation happened after
    // it began, so its snapshot is stale and must not clobber the optimistic state.
    // This is what kills the archive flicker: an in-flight periodic scan that
    // started pre-archive can no longer overwrite the just-archived row.
    @ObservationIgnored private var epoch = 0
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        let e = epoch
        loading = true
        Task.detached(priority: .userInitiated) {
            let s = Backend.scan()
            await MainActor.run {
                self.loading = false
                guard e == self.epoch else { return }   // a write landed after this scan started → stale
                self.sessions = s
            }
        }
    }
    func open(_ s: Session) {
        Task.detached(priority: .userInitiated) {
            let ok = Backend.open(s)
            await MainActor.run { self.flash(ok ? "已打开 / 切回窗口" : "打开失败") }
        }
    }
    func setArchived(_ s: Session, _ on: Bool) {
        // Archiving also unpins: "archived but still pinned" is a contradiction —
        // the pin survived invisibly and un-archiving teleported the session into
        // 置顶 instead of back to its folder, which reads as "unarchive did nothing".
        optimistic(s.id) { $0.archived = on; if on { $0.pinned = false } }   // UI 立即变
        flash(on ? "已归档" : "已取消归档")
        Task.detached(priority: .userInitiated) {
            Backend.setArchived(s, on)
            if on && s.pinned { Backend.setPinned(s, false) }
            await MainActor.run { self.epoch += 1; self.refresh() }   // 落盘后对账;并作废落盘前发起的扫描
        }
    }
    func setPinned(_ s: Session, _ on: Bool) {
        optimistic(s.id) { $0.pinned = on }
        flash(on ? "已置顶" : "已取消置顶")
        Task.detached(priority: .userInitiated) {
            Backend.setPinned(s, on)
            await MainActor.run { self.epoch += 1; self.refresh() }   // invalidate scans started before this write landed
        }
    }
    func setUnread(_ s: Session, _ on: Bool) {
        optimistic(s.id) { $0.unread = on }
        flash(on ? "已标为未读" : "已标为已读")
        Task.detached(priority: .userInitiated) {
            Backend.setUnread(s, on)
            await MainActor.run { self.epoch += 1; self.refresh() }   // invalidate scans started before this write landed
        }
    }
    func newSession(_ cwd: String) {
        flash("正在新建会话…")
        Task.detached(priority: .userInitiated) {
            Backend.newSession(cwd)
            await MainActor.run { self.epoch += 1; self.refresh() }   // invalidate scans started before this write landed
        }
    }
    func setNickname(_ s: Session, _ nick: String) {
        let trimmed = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        optimistic(s.id) { $0.nickname = trimmed.isEmpty ? nil : trimmed }
        flash(trimmed.isEmpty ? "已恢复原标题" : "已重命名")
        Task.detached(priority: .userInitiated) {
            Backend.setNickname(s, trimmed)
            await MainActor.run { self.epoch += 1; self.refresh() }   // invalidate scans started before this write landed
        }
    }
    // Cmd+W / header ✕ just killed a terminal. The 活跃 tab already dropped the
    // row synchronously (it keys off TerminalManager.running, which close()
    // clears). This only handles the SECONDARY signals that read scan-derived
    // `alive`: stop the title shimmer at once (a SIGTERM kill fires no Stop hook,
    // so activity.running can lag), and reconcile once the process tree is dead.
    func markTerminalClosed(_ fullSid: String) {
        optimistic(fullSid) { $0.alive = false }
        epoch += 1
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(800))
            await MainActor.run { self.refresh() }
        }
    }
    private func optimistic(_ id: String, _ change: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { change(&sessions[i]) }
    }
    func flash(_ m: String) {
        toast = m
        Task { try? await Task.sleep(for: .seconds(2)); if toast == m { toast = nil } }
    }
}

// MARK: - Activity (turn-completion breathing light)
// Watches the activity dir that leader-hook.py writes on every turn's Stop, and
// exposes `attention`: the set of sessions that FINISHED WHILE NOT FOCUSED. The
// scenario: you leave session A reasoning, switch to B; when A's claude finishes,
// A's sidebar row breathes until you look at it. FSEvents gives sub-second latency
// (the 6s scan would feel laggy); a 3s poll backstops any coalesced/missed event.
@MainActor
final class Activity: ObservableObject {
    static let shared = Activity()
    @Published private(set) var attention: Set<String> = []   // full_sids needing a pulse (done while unfocused)
    @Published private(set) var running: Set<String> = []      // full_sids reasoning NOW (UserPromptSubmit..Stop)
    var focusedSID: String?                                    // the embedded session

    private var appActive = true
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var seen: [String: Double] = [:]                   // full_sid -> last handled ts
    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(atPath: LeaderPaths.activityDir,
                                                 withIntermediateDirectories: true)
        ensureLeaderHookSettings()
        pruneOld()
        for (sid, ts, _) in readAll() { seen[sid] = ts }      // seed: don't pulse pre-existing files
        installWatcher()
        appActive = NSApp.isActive
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.appBecameActive() }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.appActive = false }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.process() }
        }
    }

    // User is now looking at this session -> it no longer needs attention.
    func markFocused(_ sid: String?) {
        focusedSID = sid
        if let sid, attention.contains(sid) { attention.remove(sid) }
    }

    private func appBecameActive() {
        appActive = true
        if let f = focusedSID, attention.contains(f) { attention.remove(f) }   // returned to a done session
    }

    private func installWatcher() {
        fd = open(LeaderPaths.activityDir, O_EVTONLY)
        guard fd >= 0 else { return }
        // Atomic os.replace() in the hook lands as a rename INTO the dir, which the
        // directory vnode reports as .write — so dir-level watching catches it.
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: [.write], queue: .main)
        s.setEventHandler { [weak self] in Task { @MainActor in self?.process() } }
        s.setCancelHandler { [fd] in close(fd) }
        s.resume()
        source = s
    }

    private func process() {
        for (sid, ts, event) in readAll() {
            guard ts > (seen[sid] ?? 0) else { continue }   // only newly-written records
            seen[sid] = ts
            switch event {
            case "Stop":
                running.remove(sid)                          // reasoning finished
                if sid == focusedSID && appActive { attention.remove(sid) }   // you're watching it
                else { attention.insert(sid) }
            case "UserPromptSubmit":
                running.insert(sid)                          // reasoning started -> spinner
                attention.remove(sid)                        // work resumed -> clear stale pulse
            case "SessionEnd":
                running.remove(sid); attention.remove(sid)   // session gone
            default: break
            }
        }
    }

    private func readAll() -> [(String, Double, String)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: LeaderPaths.activityDir) else { return [] }
        var out: [(String, Double, String)] = []
        for n in names where n.hasSuffix(".json") {
            guard let d = fm.contents(atPath: LeaderPaths.activityDir + "/" + n),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sid = o["sid"] as? String, let ts = o["ts"] as? Double else { continue }
            out.append((sid, ts, (o["event"] as? String) ?? ""))
        }
        return out
    }

    private func pruneOld() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: LeaderPaths.activityDir) else { return }
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for n in names where n.hasSuffix(".json") {
            let p = LeaderPaths.activityDir + "/" + n
            if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, m < cutoff {
                try? fm.removeItem(atPath: p)
            }
        }
    }
}

// ChatGPT "Working…"-style shimmer for a session that is reasoning right now
// (UserPromptSubmit..Stop): the title dims and a bright band sweeps left→right.
// Replaces the old spinner dot / green terminal icon as the "in progress" signal.
struct WorkingShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.6)          // still visibly "working", just no sweep
        } else {
            content
                .opacity(0.45)            // dimmed base; the band restores full brightness
                .overlay {
                    // Time-driven (not onAppear+repeatForever): a re-rendered row can
                    // fire onAppear with @State already at its end value, freezing the
                    // sweep; a TimelineView phase is stateless and always correct.
                    TimelineView(.animation) { tl in
                        GeometryReader { geo in
                            let t = tl.date.timeIntervalSinceReferenceDate
                            // 1.4s cycle, band sweeps -0.7W → 1.2W with a short
                            // fully-off pause between passes (ChatGPT-like).
                            let phase = CGFloat((t / 1.4).truncatingRemainder(dividingBy: 1)) * 1.9 - 0.7
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .primary, location: 0.5),
                                .init(color: .clear, location: 1),
                            ], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(geo.size.width * 0.55, 40))
                            .offset(x: phase * geo.size.width)
                        }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
        }
    }
}
extension View {
    // Structural if: identity changes when `active` flips, so the repeatForever
    // animation starts fresh on activation and is fully torn down on stop.
    @ViewBuilder func workingShimmer(_ active: Bool) -> some View {
        if active { modifier(WorkingShimmer()) } else { self }
    }
}

// Red "1" badge for a manually-marked-unread session (email-style unread count).
struct UnreadBadge: View {
    var body: some View {
        Text("1")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(.red))
            .help("未读(右键可标记已读;打开即自动已读)")
    }
}

// A soft pulsing dot ("呼吸灯") shown on a sidebar row whose session just finished.
struct BreathingDot: View {
    @State private var on = false
    private let color = Color(red: 0x8e / 255, green: 0x6a / 255, blue: 0xd9 / 255)  // Kaku accent purple
    var body: some View {
        Circle().fill(color)
            .frame(width: 7, height: 7)
            .opacity(on ? 1.0 : 0.28)
            .shadow(color: color.opacity(on ? 0.75 : 0), radius: on ? 3.5 : 0)
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .help("此会话已完成")
    }
}

// MARK: - 毛玻璃背景
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// Low-contrast overlay scrollbar knob (Codex-like). The system .light knob on a
// dark UI is glaringly bright; draw a subtle rounded knob and no track instead.
final class SubtleScroller: NSScroller {
    var isDark = true
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slot: NSRect, highlight: Bool) { /* no track */ }
    override func drawKnob() {
        let r = rect(for: .knob).insetBy(dx: 3, dy: 3)
        guard r.width > 1, r.height > 1 else { return }
        let a: CGFloat = isDark ? 0.22 : 0.24
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(a).setFill()
        let radius = min(r.width, r.height) / 2
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - 滚动条暗色适配:overlay 细滚动条 + 低对比 knob(参考 Codex)
struct ScrollerFix: NSViewRepresentable {
    var dark: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let dark = self.dark
        func apply(_ tries: Int) {
            guard let sv = v.enclosingScrollView else {
                if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { apply(tries - 1) } }
                return
            }
            let ap = NSAppearance(named: dark ? .darkAqua : .aqua)
            sv.appearance = ap
            sv.scrollerStyle = .overlay                 // 细的覆盖式,无突兀轨道
            if !(sv.verticalScroller is SubtleScroller) {
                let s = SubtleScroller()
                s.scrollerStyle = .overlay
                sv.verticalScroller = s
            }
            (sv.verticalScroller as? SubtleScroller)?.isDark = dark
            sv.verticalScroller?.appearance = ap
            sv.verticalScroller?.needsDisplay = true
            sv.drawsBackground = false
            sv.backgroundColor = .clear
        }
        DispatchQueue.main.async { apply(5) }
    }
}

// MARK: - 鼠标层:acceptsFirstMouse(未聚焦也单击生效)+ 右侧热区=归档 + hover
final class MouseNSView: NSView {
    var onClick: () -> Void = {}
    var onArchive: () -> Void = {}
    var onPin: () -> Void = {}
    var onRename: () -> Void = {}
    var onMarkUnread: () -> Void = {}
    var canPin = true              // gates the 置顶 context-menu item
    // context-menu state (right-click)
    var contextMenuEnabled = true
    var isPinned = false
    var isUnread = false
    var canUnread = true
    var archiveTitle = "归档"
    var archiveSymbol = "archivebox"
    var onHover: (Bool) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Left-click opens the session; a click in the trailing zone (under the •••
    // glyph) opens the same menu as a right-click. Folder headers pass
    // contextMenuEnabled=false, so their whole width just fires onClick (toggle) —
    // no dead strip on the right.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if contextMenuEnabled, p.x > bounds.width - DS.menuZone { showMenu(at: p) }
        else { onClick() }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard contextMenuEnabled else { return }
        showMenu(at: convert(event.locationInWindow, from: nil))
    }
    // The row's ••• / right-click menu. Labels/icons derive from the session's own
    // state so they're always correct (置顶↔取消置顶, 归档↔取消归档).
    private func showMenu(at point: NSPoint) {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ sel: Selector) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(it)
        }
        if canPin { add(isPinned ? "取消置顶" : "置顶", isPinned ? "star.slash" : "star", #selector(miPin)) }
        if canUnread { add(isUnread ? "标记已读" : "标记未读",
                           isUnread ? "envelope.open" : "envelope.badge", #selector(miUnread)) }
        add("重命名", "pencil", #selector(miRename))
        menu.addItem(.separator())
        add(archiveTitle, archiveSymbol, #selector(miArchive))
        menu.popUp(positioning: nil, at: point, in: self)
    }
    @objc private func miRename() { onRename() }
    @objc private func miPin() { onPin() }
    @objc private func miUnread() { onMarkUnread() }
    @objc private func miArchive() { onArchive() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        // Rows move UNDER a stationary pointer (scroll, pin/refresh reorder) with no
        // entered/exited events, leaving a stale hover highlight on the old row.
        // AppKit re-invokes this on geometry changes, so reconcile against the real
        // pointer position — the row no longer under the pointer clears itself.
        // Async: this can run mid-layout, and onHover mutates SwiftUI state.
        if let w = window {
            let inside = bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
            DispatchQueue.main.async { [weak self] in self?.onHover(inside) }
        }
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}
struct MouseLayer: NSViewRepresentable {
    var onClick: () -> Void
    var onArchive: () -> Void = {}
    var onPin: () -> Void = {}
    var onRename: () -> Void = {}
    var onMarkUnread: () -> Void = {}
    var canPin = false
    var contextMenuEnabled = true
    var isPinned = false
    var isUnread = false
    var canUnread = true
    var archiveTitle = "归档"
    var archiveSymbol = "archivebox"
    var onHover: (Bool) -> Void = { _ in }
    private func apply(_ v: MouseNSView) {
        v.onClick = onClick; v.onArchive = onArchive; v.onPin = onPin
        v.onRename = onRename; v.onMarkUnread = onMarkUnread
        v.canPin = canPin; v.contextMenuEnabled = contextMenuEnabled
        v.isPinned = isPinned; v.isUnread = isUnread; v.canUnread = canUnread
        v.archiveTitle = archiveTitle; v.archiveSymbol = archiveSymbol; v.onHover = onHover
    }
    func makeNSView(context: Context) -> MouseNSView { let v = MouseNSView(); apply(v); return v }
    func updateNSView(_ v: MouseNSView, context: Context) { apply(v) }
}

extension Notification.Name {
    static let leaderCloseActive = Notification.Name("leaderCloseActive")
    static let leaderTogglePalette = Notification.Name("leaderTogglePalette")
    static let leaderSelectTab = Notification.Name("leaderSelectTab")   // object: Int tab index
    static let leaderOpenSession = Notification.Name("leaderOpenSession")   // object: String full_sid
}

// MARK: - 窗口配置 + 置顶
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var pinned = false   // window stays normal level; opt-in via the pin toolbar button
    var window: NSWindow?

    // Single-instance guard. Finder double-click already de-dups a .app by bundle
    // id, but launching the raw binary (or two mismatched bundles) does not — so if
    // another Leader is already up, hand focus to it and bow out before the window
    // is built. Runs in willFinish (earliest hook) to avoid a second window flashing.
    func applicationWillFinishLaunching(_ n: Notification) {
        let me = NSRunningApplication.current
        let bid = Bundle.main.bundleIdentifier ?? "com.leader.app"
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .first { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        if let other {
            other.activate(options: [.activateAllWindows])
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        installScrollMonitor()                       // wheel -> embedded terminal
        QuakeTerminal.shared.installHotkey()          // double-tap Control -> scratch terminal
        installKeyMonitor()                           // Cmd+W -> close active session; Cmd+F -> focus search
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.configure() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyLevel() }
    }
    // Cmd+W must not close the window/quit the app; repurpose it to "close the
    // active session" (with confirm, handled in ContentView). Swallow the event
    // so the default File→Close never fires. Cmd+Q still quits (its own confirm).
    func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Only plain Cmd (no other modifiers), else let chords through.
            guard e.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command]
            else { return e }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "w":
                NotificationCenter.default.post(name: .leaderCloseActive, object: nil)
                return nil                            // swallow so File→Close never fires
            case "k", "f":
                // Command palette (session search + per-session actions). Claimed
                // globally so it opens even while an embedded terminal has key focus;
                // the terminal's own Cmd+K (clear scrollback) is sacrificed for it.
                // Cmd+F is an alias — "find" — now that the sidebar search box is gone.
                NotificationCenter.default.post(name: .leaderTogglePalette, object: nil)
                return nil
            case "1", "2", "3", "4":
                // Cmd+1..4 → switch the four sidebar tabs (会话/活跃/陈旧/已归档),
                // even from inside a terminal. Tab index carried on the notification.
                if let n = e.charactersIgnoringModifiers, let i = Int(n) {
                    NotificationCenter.default.post(name: .leaderSelectTab, object: i - 1)
                }
                return nil
            default:
                return e
            }
        }
    }
    func configure() {
        guard let w = NSApp.windows.first else { return }
        window = w
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.titlebarSeparatorStyle = .none          // kill the hairline strip under the titlebar
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.styleMask.insert(.fullSizeContentView)
        applyLevel()
        centerWindow()
    }
    func applyLevel() {
        guard let w = window ?? NSApp.windows.first else { return }
        window = w
        w.level = AppDelegate.pinned ? .floating : .normal
        w.collectionBehavior = AppDelegate.pinned
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary] : [.managed]
    }
    func centerWindow() {
        guard let w = window, let scr = NSScreen.main else { return }
        let vf = scr.visibleFrame
        // A comfortable centered size (not full-height, not left-snapped).
        let width = min(1200, vf.width * 0.82)
        let height = min(820, vf.height * 0.86)
        let x = vf.minX + (vf.width - width) / 2
        let y = vf.minY + (vf.height - height) / 2
        w.setFrame(NSRect(x: x, y: y, width: width, height: height),
                   display: true, animate: false)
    }
    // Quitting kills every embedded claude. Confirm if any session is live so a
    // stray Cmd+Q doesn't tear down running work.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let n = TerminalManager.shared.running.count
        guard n > 0 else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "退出 Leader?"
        a.informativeText = "还有 \(n) 个嵌入的会话在运行,退出会杀掉它们的进程(transcript 已持久化,可重新 resume)。"
        a.addButton(withTitle: "退出")
        a.addButton(withTitle: "取消")
        a.alertStyle = .warning
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

// MARK: - Row
struct Row: View {
    let s: Session
    let onOpen: () -> Void
    let onArchive: () -> Void
    var onPin: () -> Void = {}
    var onRename: () -> Void = {}
    var onMarkUnread: () -> Void = {}
    var selected: Bool = false
    @Binding var hoveredID: String?
    @ObservedObject var term = TerminalManager.shared   // embed state (running/exited)
    @ObservedObject var activity = Activity.shared       // turn-completion pulse
    // single shared hovered id -> at most one row highlights, even mid-scroll
    private var hover: Bool { hoveredID == s.id }
    // embedded-terminal badge: filled while the in-app claude process is alive,
    // hollow once it exits, nothing if never embedded. Quiet grey either way —
    // "actively working" is signalled by the title shimmer, not by color here.
    private var embedSymbol: String? {
        if term.running.contains(s.full_sid) { return "terminal.fill" }
        if term.exited.contains(s.full_sid) { return "terminal" }
        return nil
    }
    // Guard on s.alive so a crashed session (no Stop event) can't shimmer forever.
    private var isWorking: Bool { activity.running.contains(s.full_sid) && s.alive }
    // Archive affordances derive from the session's own state — never passed in
    // by the surrounding list, so a row can't show 取消归档 after it moved back
    // to the active tab (or vice versa). Pin/unread only make sense un-archived.
    private var archiveSymbol: String { s.archived ? "tray.and.arrow.up" : "archivebox" }
    private var archiveTitle: String { s.archived ? "取消归档" : "归档" }
    private var canPinOrUnread: Bool { !s.archived }

    var body: some View {
        HStack(spacing: 6) {
            Text(s.name).font(.system(size: 14)).lineLimit(1)
                .workingShimmer(isWorking)
            if s.unread { UnreadBadge() }
            if let sym = embedSymbol {
                Image(systemName: sym).font(.caption2).foregroundStyle(.secondary)
                    .help(sym == "terminal.fill" ? "已嵌入运行" : "已嵌入(进程已退出)")
            }
            if activity.attention.contains(s.full_sid) { BreathingDot() }
            Spacer(minLength: 4)
            // ••• more-actions, hidden until the row is hovered/selected. The actual
            // click is caught by MouseLayer's trailing zone (acceptsFirstMouse), which
            // pops the same menu as a right-click — this glyph is just its marker.
            Image(systemName: "ellipsis")
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 18)
                .opacity(hover || selected ? 1 : 0)
                .help("更多操作")
        }
        .padding(.vertical, DS.rowPadV).padding(.horizontal, DS.rowPadH)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: DS.corner)
            .fill(selected ? AnyShapeStyle(Color.primary.opacity(0.14))
                           : (hover ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.clear))))
        .contentShape(RoundedRectangle(cornerRadius: DS.corner))
        .overlay { MouseLayer(onClick: onOpen, onArchive: onArchive, onPin: onPin,
                              onRename: onRename, onMarkUnread: onMarkUnread,
                              canPin: canPinOrUnread, isPinned: s.pinned, isUnread: s.unread,
                              canUnread: canPinOrUnread, archiveTitle: archiveTitle,
                              archiveSymbol: archiveSymbol, onHover: { inside in
            if inside { hoveredID = s.id } else if hoveredID == s.id { hoveredID = nil }
        }) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(s.name)
        .accessibilityHint("打开或切回该会话窗口")
    }
}

// MARK: - Section header (plain)
struct SectionHeader: View {
    let title: String
    let n: Int
    var icon: String?
    var iconTint: Color?    // e.g. the single golden star on the 置顶 header
    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.caption2)
                    .foregroundStyle(iconTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
            }
            Text(title).lineLimit(1)
            Text("\(n)").foregroundStyle(.quaternary)
        }
        .font(.caption).bold().foregroundStyle(.tertiary)
        .padding(.top, 13).padding(.bottom, 2).padding(.horizontal, DS.rowPadH)
    }
}

// MARK: - Collapsible folder header (single-click via acceptsFirstMouse)
struct FolderHeader: View {
    let title: String
    let n: Int
    let collapsed: Bool
    var icon: String = "folder"
    let toggle: () -> Void
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.caption2).frame(width: 9)
            Image(systemName: icon).font(.caption2)
            Text(title).lineLimit(1)
            Text("\(n)").foregroundStyle(.quaternary)
            Spacer(minLength: 0)
        }
        .font(.caption).bold().foregroundStyle(.tertiary)
        .padding(.top, 13).padding(.bottom, 3).padding(.horizontal, DS.rowPadH)
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .overlay { MouseLayer(onClick: toggle, onArchive: toggle, contextMenuEnabled: false, onHover: { _ in }) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(title) 文件夹,\(n) 个会话")
    }
}

// MARK: - Command palette (Cmd+K)
// One action performable from the palette's drill-in level. `run` is invoked AFTER
// the palette closes, so a follow-up sheet (rename) presents over a clean UI.
struct PaletteAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let run: () -> Void
}

// MARK: - Main
struct ContentView: View {
    @State private var store = Store()
    @State private var pinned = false   // window-level always-on-top, opt-in
    @State private var mode: Mode = .live
    @State private var hoveredID: String?
    @State private var collapsed: Set<String> = []
    @State private var renameTarget: Session?
    @State private var renameText = ""
    @State private var staleExpanded = false
    @State private var selectedID: String?
    @State private var activeSID: String?            // session embedded in the main area
    @State private var showSettings = false
    @State private var showOpenPath = false          // Cmd+Shift+O quick-open
    @State private var pathInput = ""
    @State private var pathSel = 0
    @State private var confirmCloseActive = false    // Cmd+W confirm
    @State private var closeTarget: (sid: String, name: String)?   // what Cmd+W will close
    // Cmd+K command palette. Two levels: nil paletteActionsFor = session search;
    // non-nil = the drill-in action list for that one session. paletteSel indexes
    // whichever list is active; paletteQuery filters it.
    @State private var showPalette = false
    @State private var paletteQuery = ""
    @State private var paletteSel = 0
    @State private var paletteActionsFor: Session?
    // A just-created session: embedded immediately at a known sid, before the
    // scanner (every 6s) picks it up into store.sessions.
    @State private var pendingNew: (sid: String, cwd: String)?
    @FocusState private var focus: Focus?
    @AppStorage("leader.grouped") private var grouped = true
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var term = TerminalManager.shared   // 活跃 tab: embed liveness

    enum Focus { case list, openPath, palette }
    // "" -> launch.py uses config.new_session_cwd() (default ~). Configure in
    // ~/.config/leader/config.json -> "new_session_cwd".
    static let newCwd = ""

    // ordered sessions currently displayed -> drives ↑/↓ navigation
    private var navList: [Session] {
        switch mode {
        case .active:
            var arr = pinnedList
            if grouped {
                for f in folders where !collapsed.contains(f.name) { arr += f.items }
            } else { arr += flatList }
            return arr
        case .live:     return liveList
        case .stale:    return staleExpanded ? staleList.sorted { $0.idle_h < $1.idle_h } : []
        case .archived: return archivedList.sorted(by: Self.byPriority)
        }
    }
    private func moveSelection(_ d: Int) {
        let ids = navList.map(\.id)
        guard !ids.isEmpty else { return }
        if let cur = selectedID, let i = ids.firstIndex(of: cur) {
            selectedID = ids[min(max(i + d, 0), ids.count - 1)]
        } else {
            selectedID = d > 0 ? ids.first : ids.last
        }
    }
    private func openSelected() {
        if let id = selectedID, let s = navList.first(where: { $0.id == id }) { openEmbedded(s) }
    }
    // Click / Enter: embed the session in the main area (instead of a kitty window).
    private func openEmbedded(_ s: Session) {
        selectedID = s.id
        activeSID = s.id
        if s.unread { store.setUnread(s, false) }   // 打开即已读(邮件式)
    }
    // "+": start a fresh session embedded right here. We mint the sid so there's no
    // race to discover it; claude --session-id starts the conversation at that id.
    private func newEmbeddedSession() {
        newEmbeddedSession(in: Conf.newCwd.isEmpty ? "~" : Conf.newCwd)
    }
    private func newEmbeddedSession(in cwd: String) {
        let sid = UUID().uuidString.lowercased()
        _ = TerminalManager.shared.newSession(sid: sid, cwd: cwd)
        pendingNew = (sid, cwd)
        selectedID = sid
        activeSID = sid
        store.flash("已在 \(prettyPath(expandTilde(cwd))) 新建会话")
        // pull the new session into the list once its transcript lands
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { store.refresh() }
    }

    // MARK: Cmd+Shift+O quick-open — type a directory (with live completion),
    // Enter starts a new session there.
    private func promptOpenPath() {
        pathInput = "~/dev/"      // most sessions live here; user can clear it
        pathSel = 0
        showOpenPath = true
        DispatchQueue.main.async { focus = .openPath }
    }
    private func prettyPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
    // Directories under the typed path's parent whose name matches the last
    // component. Hidden dirs shown only when the user is typing a dot.
    private func pathCandidates(_ input: String) -> [String] {
        guard !input.isEmpty else { return [] }
        let ns = (input as NSString).expandingTildeInPath
        let fm = FileManager.default
        let dir: String, prefix: String
        if input.hasSuffix("/") { dir = ns; prefix = "" }
        else { dir = (ns as NSString).deletingLastPathComponent; prefix = (ns as NSString).lastPathComponent }
        let base = dir.isEmpty ? "/" : dir
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        let showHidden = prefix.hasPrefix(".")
        return entries.filter { e in
            (showHidden || !e.hasPrefix(".")) &&
            (prefix.isEmpty || e.lowercased().hasPrefix(prefix.lowercased()))
        }.filter { e in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: (base as NSString).appendingPathComponent(e), isDirectory: &isDir)
            return isDir.boolValue
        }.sorted().prefix(8).map { (base as NSString).appendingPathComponent($0) }
    }
    // Enter: open the typed dir if it exists, else the highlighted/first candidate.
    private func commitOpenPath() {
        let expanded = (pathInput as NSString).expandingTildeInPath
        let cands = pathCandidates(pathInput)
        var isDir: ObjCBool = false
        var target: String?
        if !pathInput.isEmpty,
           FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            target = expanded
        } else if pathSel < cands.count { target = cands[pathSel] }
        else { target = cands.first }
        guard let t = target else { store.flash("路径不存在"); return }
        showOpenPath = false
        focus = .list
        newEmbeddedSession(in: t)
    }
    private func beginRename(_ s: Session) {
        renameText = s.nickname ?? s.title ?? ""
        renameTarget = s
    }
    // Substring match over the fields a person would search by — drives the Cmd+K
    // palette. Includes full_sid so you can paste a raw session id to jump to it.
    static func sessionMatches(_ s: Session, _ raw: String) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return s.name.lowercased().contains(q)
            || (s.title ?? "").lowercased().contains(q)
            || (s.last_prompt ?? "").lowercased().contains(q)
            || s.repo.lowercased().contains(q)
            || (s.branch ?? "").lowercased().contains(q)
            || s.full_sid.lowercased().contains(q)
    }

    // MARK: Cmd+K palette — data
    // Level 1: sessions matching the query (all tabs, so you never have to switch
    // first). Empty query = most-recently-used, so the palette is useful on open.
    // Capped so ↑/↓ stays snappy on a huge history.
    private var paletteSessions: [Session] {
        let q = paletteQuery.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty
            ? store.sessions.filter { !$0.archived }.sorted { $0.idle_h < $1.idle_h }
            : store.sessions.filter { Self.sessionMatches($0, q) }.sorted(by: Self.byPriority)
        return Array(base.prefix(60))
    }
    // Level 2: the actions available on one session. Derived from that session's own
    // state (archived/pinned/unread) so labels are always correct, mirroring the
    // right-click menu. Filtered by the query while drilled in.
    private func paletteActions(_ s: Session) -> [PaletteAction] {
        var a: [PaletteAction] = [
            .init(id: "open", title: "打开(嵌入)", icon: "arrow.forward.circle") { openEmbedded(s) },
            .init(id: "archive", title: s.archived ? "取消归档" : "归档",
                  icon: s.archived ? "tray.and.arrow.up" : "archivebox") { store.setArchived(s, !s.archived) },
        ]
        if !s.archived {
            a.append(.init(id: "pin", title: s.pinned ? "取消置顶" : "置顶",
                           icon: s.pinned ? "pin.slash" : "pin") { store.setPinned(s, !s.pinned) })
            a.append(.init(id: "unread", title: s.unread ? "标记已读" : "标记未读",
                           icon: s.unread ? "envelope.open" : "envelope.badge") { store.setUnread(s, !s.unread) })
        }
        a.append(.init(id: "rename", title: "重命名", icon: "pencil") { beginRename(s) })
        a.append(.init(id: "kitty", title: "在 kitty 窗口打开", icon: "rectangle.on.rectangle") { store.open(s) })
        return a
    }
    private var paletteActionResults: [PaletteAction] {
        guard let s = paletteActionsFor else { return [] }
        let all = paletteActions(s)
        let q = paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) }
    }
    private func paletteEmbedGlyph(_ s: Session) -> String {
        if term.running.contains(s.full_sid) { return "terminal.fill" }
        if term.exited.contains(s.full_sid) { return "terminal" }
        return "circle.dotted"
    }

    // MARK: Cmd+K palette — control
    private func openPalette() {
        paletteQuery = ""; paletteSel = 0; paletteActionsFor = nil
        showPalette = true
        DispatchQueue.main.async { focus = .palette }
    }
    private func closePalette() {
        showPalette = false; paletteActionsFor = nil
        focus = .list
    }
    // Esc: back out of the action level first, only then dismiss the whole palette.
    private func paletteEscape() {
        if paletteActionsFor != nil { paletteActionsFor = nil; paletteQuery = ""; paletteSel = 0 }
        else { closePalette() }
    }
    private func paletteMove(_ d: Int) {
        let n = paletteActionsFor != nil ? paletteActionResults.count : paletteSessions.count
        guard n > 0 else { return }
        paletteSel = min(max(paletteSel + d, 0), n - 1)
    }
    // Tab: drill from the highlighted session into its action list.
    private func paletteDrill() {
        guard paletteActionsFor == nil else { return }
        let ss = paletteSessions
        guard paletteSel < ss.count else { return }
        paletteActionsFor = ss[paletteSel]; paletteQuery = ""; paletteSel = 0
    }
    // Enter: run the highlighted action, or open the highlighted session. Close the
    // palette BEFORE running so a follow-up sheet (rename) isn't hidden behind it.
    private func paletteCommit() {
        if paletteActionsFor != nil {
            let acts = paletteActionResults
            guard paletteSel < acts.count else { return }
            let act = acts[paletteSel]
            closePalette(); act.run()
        } else {
            let ss = paletteSessions
            guard paletteSel < ss.count else { return }
            let s = ss[paletteSel]
            closePalette(); openEmbedded(s)
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        // Order = left-to-right tab order = Cmd+1..4. 活跃 is first (the default).
        case live = "活跃", active = "会话", stale = "陈旧", archived = "已归档"
        var id: Self { self }
    }

    // INVARIANT — tab membership. `archived` is EXCLUSIVE: an archived session
    // appears ONLY in 已归档; every other list filters `!archived`. Breaking this
    // (as liveList once did) is the root of the "archived it but it won't leave"
    // class of bug. 会话 buckets pinned/stale/folder are mutually exclusive;
    // 活跃 is an ORTHOGONAL filter over the SINGLE synchronous source of truth
    // for "has a terminal open in Leader right now" — TerminalManager.running.
    // It deliberately does NOT read scan-derived `alive` (6s-laggy + racy on
    // close) nor external REPLs; open/close mutate `running` synchronously, so
    // the tab is correct by construction with no timing dependence.
    private var pinnedList: [Session] {
        // Fixed order = pin time (pin_order), NOT recency — a pinned row must
        // never drift when scans update idle times. sid tiebreak is deterministic.
        store.sessions.filter { $0.pinned && !$0.archived }.sorted {
            let (a, b) = ($0.pin_order ?? .max, $1.pin_order ?? .max)
            return a == b ? $0.full_sid < $1.full_sid : a < b
        }
    }
    private var staleList: [Session] { store.sessions.filter { !$0.archived && !$0.pinned && $0.isStale } }
    private var archivedList: [Session] { store.sessions.filter(\.archived) }
    private var liveList: [Session] {
        store.sessions.filter { !$0.archived && term.running.contains($0.full_sid) }
            .sorted { $0.idle_h < $1.idle_h }
    }
    private var folders: [(name: String, items: [Session])] {
        let rest = store.sessions.filter { !$0.archived && !$0.pinned && !$0.isStale }
        return Dictionary(grouping: rest, by: \.repo)
            .map { (name: $0.key, items: $0.value.sorted(by: Self.byPriority)) }
            .sorted { $0.name < $1.name }
    }
    private static func byPriority(_ l: Session, _ r: Session) -> Bool {
        let lo = Session.order[l.bucket] ?? 9, ro = Session.order[r.bucket] ?? 9
        return lo == ro ? l.idle_h < r.idle_h : lo < ro
    }
    // LRU: most-recently-used first (smallest idle first)
    private var flatList: [Session] {
        store.sessions.filter { !$0.archived && !$0.pinned && !$0.isStale }.sorted { $0.idle_h < $1.idle_h }
    }
    private func togglePin() {
        pinned.toggle(); AppDelegate.pinned = pinned
        (NSApp.delegate as? AppDelegate)?.applyLevel()
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 280, idealWidth: DS.panelWidth, maxWidth: 460,
                       maxHeight: .infinity)
            terminalArea
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                .background(TerminalAreaProbe())   // anchors the scratch terminal over this pane
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        }
        .ignoresSafeArea()                          // let both panes fill under the transparent titlebar
        .overlay { openPathPanel }
        .overlay { commandPalette }
        .frame(minWidth: 820, minHeight: 480)
        .onAppear {
            store.start(); Activity.shared.start(); focus = .list; updateQuakeCwd()
            // Give Activity a way to name a session for its completion banners.
            Activity.shared.displayName = { sid in
                store.sessions.first(where: { $0.full_sid == sid })?.name ?? "Claude 会话"
            }
        }
        .onChange(of: activeSID) { _, id in
            updateQuakeCwd(); Activity.shared.markFocused(id)
            hoveredID = nil   // switch kills any stale hover on the previous row
        }
        .sheet(item: $renameTarget) { s in
            RenameSheet(session: s, text: $renameText,
                        onSave: { store.setNickname(s, $0); renameTarget = nil },
                        onCancel: { renameTarget = nil })
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .leaderCloseActive)) { _ in
            // Target the embedded session in the main pane; else fall back to the
            // sidebar-SELECTED row if its terminal is open (e.g. selecting in 活跃
            // with ↑/↓ and hitting Cmd+W while the main pane is empty). A silent
            // no-op here read as "close is broken", so always give feedback.
            if let a = activeEmbed {
                closeTarget = (a.sid, a.name); confirmCloseActive = true
            } else if let id = selectedID, let s = store.sessions.first(where: { $0.id == id }),
                      TerminalManager.shared.isOpen(s.full_sid) {
                closeTarget = (s.full_sid, s.name); confirmCloseActive = true
            } else {
                store.flash("没有打开的会话终端")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .leaderSelectTab)) { note in
            if let i = note.object as? Int, Mode.allCases.indices.contains(i) {
                withAnimation(.easeInOut(duration: 0.12)) { mode = Mode.allCases[i] }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .leaderTogglePalette)) { _ in
            if showPalette { closePalette() } else { openPalette() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .leaderOpenSession)) { note in
            // A completion banner was clicked — embed that session in the main pane.
            if let sid = note.object as? String,
               let s = store.sessions.first(where: { $0.full_sid == sid }) { openEmbedded(s) }
        }
        .onChange(of: paletteQuery) { _, _ in paletteSel = 0 }
        .confirmationDialog("关闭会话终端?", isPresented: $confirmCloseActive, titleVisibility: .visible) {
            Button("关闭会话", role: .destructive) { if let t = closeTarget { closeSession(t.sid) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会杀掉「\(closeTarget?.name ?? "")」的嵌入进程(transcript 已保存,可重新打开)。Leader 不会退出。")
        }
    }

    // Close one session's embedded terminal (Cmd+W target or the header ✕).
    private func closeSession(_ sid: String) {
        // Unmount the terminal view FIRST (activeSID=nil → terminalArea shows the
        // empty state, TerminalContainer leaves the tree), so nothing can re-run
        // its updateNSView and re-spawn the terminal we're about to kill.
        if activeSID == sid { activeSID = nil }
        if pendingNew?.sid == sid { pendingNew = nil }
        TerminalManager.shared.close(sid)
        store.markTerminalClosed(sid)     // drop from 活跃 immediately, then reconcile
    }

    // The scratch (quake) terminal opens in the active session's working dir; keep
    // it pointed there. Uses the last-seen cwd (where the work is), not the resume
    // root, since a scratch shell is most useful next to the actual work.
    private func updateQuakeCwd() {
        if let id = activeSID, let s = store.sessions.first(where: { $0.id == id }) {
            QuakeTerminal.shared.currentCwd = s.cwd ?? s.resume_cwd ?? NSHomeDirectory()
        } else if let p = pendingNew {
            QuakeTerminal.shared.currentCwd = expandTilde(p.cwd)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            trafficInset                                 // 红绿灯落在这块留白里
            Picker("视图", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, DS.rowPadH).padding(.bottom, 6)
            Divider().opacity(0.4)
            list
            Divider().opacity(0.4)
            bottomBar
        }
        .background(VisualEffect().ignoresSafeArea())   // frosted translucent sidebar (Codex-like)
        .background {                                   // hidden keyboard shortcuts
            ZStack {                                     // Cmd+F is handled by the app-wide key monitor
                Button("") { promptOpenPath() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }.opacity(0)
        }
        .focusable()
        .focusEffectDisabled()                          // no blue focus ring around the sidebar
        .focused($focus, equals: .list)
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.return) { openSelected(); return .handled }
        .overlay(alignment: .bottom) { toast }
    }

    // Cmd+Shift+O overlay: a floating input with live directory completion.
    @ViewBuilder private var openPathPanel: some View {
        if showOpenPath {
            ZStack(alignment: .top) {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { showOpenPath = false; focus = .list }
                let cands = pathCandidates(pathInput)
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        TextField("输入目录路径,回车新建会话", text: $pathInput)
                            .textFieldStyle(.plain).font(.title3)
                            .focused($focus, equals: .openPath)
                            .onChange(of: pathInput) { _, _ in pathSel = 0 }
                            .onSubmit { commitOpenPath() }
                            .onKeyPress(.downArrow) {
                                if !cands.isEmpty { pathSel = min(pathSel + 1, cands.count - 1) }
                                return .handled
                            }
                            .onKeyPress(.upArrow) { pathSel = max(pathSel - 1, 0); return .handled }
                            .onKeyPress(.tab) {
                                if pathSel < cands.count { pathInput = cands[pathSel] + "/"; pathSel = 0 }
                                return .handled
                            }
                    }
                    .padding(14)
                    if !cands.isEmpty {
                        Divider()
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(cands.enumerated()), id: \.element) { i, c in
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder.fill").font(.caption).foregroundStyle(.tertiary)
                                        Text(prettyPath(c)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(i == pathSel ? Color.primary.opacity(0.12) : .clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { pathInput = c + "/"; pathSel = 0 }
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                }
                .frame(width: 540)
                .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
                .shadow(radius: 30, y: 12)
                .padding(.top, 96)
                // Esc to dismiss (hidden button so it works while the field is focused)
                .background {
                    Button("") { showOpenPath = false; focus = .list }
                        .keyboardShortcut(.cancelAction).opacity(0)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Cmd+K palette overlay — session search that drills into per-session
    // actions. Same floating-panel look as the Cmd+Shift+O quick-open above.
    @ViewBuilder private var commandPalette: some View {
        if showPalette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { closePalette() }
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        // Doubles as a back button once drilled into an action list.
                        Image(systemName: paletteActionsFor == nil ? "magnifyingglass" : "chevron.left")
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                            .onTapGesture { if paletteActionsFor != nil { paletteEscape() } }
                        TextField(paletteActionsFor == nil
                                    ? "搜索会话(名称 / 目录 / 分支 / session id)"
                                    : "在「\(paletteActionsFor?.name ?? "")」中执行…",
                                  text: $paletteQuery)
                            .textFieldStyle(.plain).font(.title3)
                            .focused($focus, equals: .palette)
                            .onSubmit { paletteCommit() }
                            .onKeyPress(.downArrow) { paletteMove(1); return .handled }
                            .onKeyPress(.upArrow) { paletteMove(-1); return .handled }
                            .onKeyPress(.tab) { paletteDrill(); return .handled }
                    }
                    .padding(14)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                if paletteActionsFor == nil { paletteSessionList }
                                else { paletteActionList }
                            }
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: paletteSel) { _, i in
                            withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
                        }
                    }
                }
                .frame(width: 560)
                .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
                .shadow(radius: 30, y: 12)
                .padding(.top, 96)
                // Esc: back out of the action list, else dismiss (hidden button so it
                // fires while the text field holds focus — same trick as quick-open).
                .background {
                    Button("") { paletteEscape() }.keyboardShortcut(.cancelAction).opacity(0)
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var paletteSessionList: some View {
        let sessions = paletteSessions
        if sessions.isEmpty {
            Text(paletteQuery.isEmpty ? "没有会话" : "无匹配会话")
                .foregroundStyle(.secondary).font(.callout)
                .frame(maxWidth: .infinity).padding(.vertical, 28)
        } else {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                let sel = i == paletteSel
                HStack(spacing: 10) {
                    Image(systemName: paletteEmbedGlyph(s)).font(.caption)
                        .foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).lineLimit(1)
                        Text("\(s.ago)前 · \(s.repo)").font(.caption)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if sel {   // keyboard hint: Tab drills into this session's actions
                        HStack(spacing: 3) {
                            Text("⇥").font(.callout); Text("操作").font(.caption2)
                        }.foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(sel ? Color.primary.opacity(0.12) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { closePalette(); openEmbedded(s) }
                .id(i)
            }
        }
    }

    @ViewBuilder private var paletteActionList: some View {
        let acts = paletteActionResults
        if acts.isEmpty {
            Text("无匹配操作")
                .foregroundStyle(.secondary).font(.callout)
                .frame(maxWidth: .infinity).padding(.vertical, 28)
        } else {
            ForEach(Array(acts.enumerated()), id: \.element.id) { i, act in
                let sel = i == paletteSel
                HStack(spacing: 10) {
                    Image(systemName: act.icon).font(.callout)
                        .foregroundStyle(.secondary).frame(width: 16)
                    Text(act.title).lineLimit(1)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(sel ? Color.primary.opacity(0.12) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { closePalette(); act.run() }
                .id(i)
            }
        }
    }

    // What to embed for the current activeSID: a scanned session if known, else
    // the just-created pending one (which has no Session yet).
    private struct ActiveEmbed { let sid: String; let cwd: String; let name: String; let session: Session? }
    private var activeEmbed: ActiveEmbed? {
        guard let id = activeSID else { return nil }
        if let s = store.sessions.first(where: { $0.id == id }) {
            // resume_cwd is the dir claude can actually --resume from; s.cwd is
            // the last-seen (possibly cd'd-into) dir, only good for display.
            return ActiveEmbed(sid: s.full_sid, cwd: s.resume_cwd ?? s.cwd ?? "~",
                               name: s.name, session: s)
        }
        if let p = pendingNew, p.sid == id {
            return ActiveEmbed(sid: p.sid, cwd: p.cwd, name: "新会话", session: nil)
        }
        return nil
    }

    @ViewBuilder private var terminalArea: some View {
        if let info = activeEmbed {
            VStack(spacing: 0) {
                terminalHeader(sid: info.sid, name: info.name, session: info.session)
                TerminalContainer(sid: info.sid, cwd: info.cwd)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("点击左侧会话,在此嵌入运行 claude").foregroundStyle(.secondary).font(.callout)
                Text("再次点击切换 · 关掉单个会话可释放资源").foregroundStyle(.tertiary).font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // Thin bar above the embedded terminal: which session is running + a close
    // button that kills the in-app process but leaves the list item in place.
    // `session` is nil for a just-created session not yet in the scanned list —
    // the kitty escape hatch needs a real Session, so it's hidden until then.
    private func terminalHeader(sid: String, name: String, session: Session?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(name).font(.callout).bold().lineLimit(1)
            Text(sid).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 8)
            if let s = session {
                Button("在 kitty 窗口打开", systemImage: "rectangle.on.rectangle") { store.open(s) }
                    .buttonStyle(.plain).labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .help("在独立 kitty 窗口打开(全屏 TUI 滚动用)")
            }
            Button("关闭会话终端", systemImage: "xmark.circle.fill") {
                closeSession(sid)         // same path as Cmd+W (kills tree + clears 活跃)
            }
            .buttonStyle(.plain).labelStyle(.iconOnly).foregroundStyle(.secondary)
            .help("杀掉嵌入的 claude 进程(列表项保留)")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }

    // Top strip: reserves room for the window's traffic lights (which sit at the
    // sidebar's top-left) and shows the Claude logo just to their right.
    private var trafficInset: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 26)        // room for the floating traffic lights
            if let logo = Self.claudeLogo {
                Image(nsImage: logo).resizable().interpolation(.high)
                    .scaledToFit().frame(height: 36)
                    .padding(.leading, DS.gap + DS.rowPadH - 2)   // align with list content
                    .padding(.bottom, 16)                          // breathing room above the search box
            }
        }
    }
    // Bundled brand mark (Contents/Resources/claude-logo.png), loaded once and
    // pre-downsampled with high-quality interpolation. The source is 1000px; the
    // starburst's fine spokes alias badly if SwiftUI does the whole ~14× shrink at
    // draw time, so we bake it down to ~display resolution (36pt @3× = 108px) once.
    static let claudeLogo: NSImage? = {
        guard let p = Bundle.main.resourcePath,
              let src = NSImage(contentsOfFile: p + "/claude-logo.png") else { return nil }
        let side: CGFloat = 108
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                 from: NSRect(origin: .zero, size: src.size),
                 operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }()

    // Utility strip pinned to the sidebar bottom (Codex puts the account row here).
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if store.loading { ProgressView().controlSize(.small) }
            Spacer(minLength: 4)
            iconButton("arrow.clockwise", "刷新", Color.secondary, action: store.refresh)
            iconButton(grouped ? "folder.fill" : "clock",
                       grouped ? "按文件夹分组(点切最近使用)" : "按最近使用(点切分组)",
                       grouped ? Color.accentColor : Color.secondary) { grouped.toggle() }
            iconButton("gearshape", "设置(代理等)", Color.secondary) { showSettings = true }
            iconButton(pinned ? "pin.fill" : "pin", "窗口置顶",
                       pinned ? Color.accentColor : Color.secondary, action: togglePin)
        }
        .padding(.horizontal, DS.rowPadH).padding(.vertical, 8)
    }
    private func iconButton(_ sym: String, _ help: String, _ color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: sym).font(.callout) }
            .buttonStyle(.plain).foregroundStyle(color).help(help)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.loading && store.sessions.isEmpty {   // initial load: spinner, not a blank pane
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    // VStack, NOT LazyVStack: rows carry parent-computed state
                    // (`selected` = selectedID == s.id, hover). A LazyVStack does
                    // not reliably re-render its children when that parent @State
                    // changes — because the read happens inside the lazy child, not
                    // the eager body — so clicking a row switched the terminal
                    // (activeSID, read eagerly) but left the sidebar highlight on the
                    // previous row. Eager VStack re-renders every row on any state
                    // change. The list is bounded (≈ session count) and each row is
                    // light, so eager layout is cheap and kills a whole class of
                    // "row visual doesn't update" bugs (highlight + stuck hover).
                    VStack(alignment: .leading, spacing: 2) {
                        switch mode {
                        case .active: activeContent
                        case .live: liveContent
                        case .stale: staleContent
                        case .archived: archivedContent
                        }
                    }
                    .padding(.horizontal, DS.gap).padding(.bottom, 20)
                    .background(ScrollerFix(dark: scheme == .dark))
                }
            }
            .onChange(of: selectedID) { _, id in
                if let id { withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
            }
            // Belt-and-suspenders for stuck hover: a row leaving under the pointer
            // (scroll, reorder) can miss its mouseExited; clear hoveredID when the
            // pointer leaves the whole list so at rest only the selected row glows.
            .onHover { inside in if !inside { hoveredID = nil } }
        }
    }

    @ViewBuilder private var activeContent: some View {
        if !pinnedList.isEmpty {
            // The one golden star lives here; rows stay clean (pin/unpin via 右键).
            SectionHeader(title: "置顶", n: pinnedList.count, icon: "star.fill", iconTint: .yellow)
            ForEach(pinnedList) { s in sessionRow(s) }
        }
        if grouped {
            ForEach(folders, id: \.name) { folder in
                let isCollapsed = collapsed.contains(folder.name)
                FolderHeader(title: folder.name, n: folder.items.count, collapsed: isCollapsed) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isCollapsed { collapsed.remove(folder.name) } else { collapsed.insert(folder.name) }
                    }
                }
                if !isCollapsed {
                    ForEach(folder.items) { s in sessionRow(s) }
                }
            }
        } else {
            SectionHeader(title: "最近使用", n: flatList.count, icon: "clock")
            ForEach(flatList) { s in sessionRow(s) }
        }
    }

    private func sessionRow(_ s: Session) -> some View {
        Row(s: s,
            onOpen: { openEmbedded(s) }, onArchive: { store.setArchived(s, !s.archived) },
            onPin: { store.setPinned(s, !s.pinned) }, onRename: { beginRename(s) },
            onMarkUnread: { store.setUnread(s, !s.unread) },
            selected: selectedID == s.id, hoveredID: $hoveredID)
    }

    @ViewBuilder private var liveContent: some View {
        let items = liveList
        if items.isEmpty {
            ContentUnavailableView("没有活跃会话",
                systemImage: "terminal",
                description: Text("开着终端的会话(App 内嵌入运行,或外部 kitty/终端里的 claude)会出现在这里"))
                .padding(.top, 40)
        } else {
            SectionHeader(title: "活跃", n: items.count, icon: "terminal")
            ForEach(items) { s in sessionRow(s) }
        }
    }

    @ViewBuilder private var staleContent: some View {
        let items = staleList.sorted { $0.idle_h < $1.idle_h }
        if items.isEmpty {
            ContentUnavailableView("没有陈旧会话",
                systemImage: "clock.badge.xmark",
                description: Text("最后消息满 15 天的会话会自动归到这里"))
                .padding(.top, 40)
        } else {
            FolderHeader(title: "陈旧会话(15天+)", n: items.count,
                         collapsed: !staleExpanded, icon: "clock.badge.xmark") {
                withAnimation(.easeInOut(duration: 0.15)) { staleExpanded.toggle() }
            }
            if staleExpanded {
                ForEach(items) { s in sessionRow(s) }
            }
        }
    }

    @ViewBuilder private var archivedContent: some View {
        let items = archivedList.sorted(by: Self.byPriority)
        if items.isEmpty {
            ContentUnavailableView("没有已归档的会话",
                systemImage: "archivebox",
                description: Text("在“会话”里点卡片右侧的归档图标即可归档"))
                .padding(.top, 40)
        } else {
            ForEach(items) { s in
                Row(s: s,
                    onOpen: { openEmbedded(s) }, onArchive: { store.setArchived(s, !s.archived) },
                    onRename: { beginRename(s) },
                    selected: selectedID == s.id, hoveredID: $hoveredID)
            }
        }
    }

    @ViewBuilder private var toast: some View {
        if let t = store.toast {
            Label(t, systemImage: t.contains("失败") ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.callout).bold()
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35)))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - 重命名面板(sheet:macOS 上比 alert+TextField 可靠得多)
struct RenameSheet: View {
    let session: Session
    @Binding var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名会话").font(.headline)
            Text("原标题:\(session.title ?? session.last_prompt ?? "(无)")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField("昵称(留空恢复原标题)", text: $text)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { onSave(text) }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") { onSave(text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 320)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - 设置面板(代理)
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var addr: String
    @State private var font: String
    @State private var fontSize: CGFloat
    @State private var lineHeight: CGFloat
    @State private var softColors: Bool
    init() {
        let p = Conf.proxy
        _enabled = State(initialValue: !p.isEmpty)
        _addr = State(initialValue: p.isEmpty ? Conf.detectedEnvProxy() : p)
        _font = State(initialValue: Conf.termFont)
        _fontSize = State(initialValue: Conf.termFontSize)
        _lineHeight = State(initialValue: Conf.lineHeight)
        _softColors = State(initialValue: Conf.softColors)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置").font(.headline)

            // MARK: terminal appearance
            VStack(alignment: .leading, spacing: 8) {
                Text("终端外观").font(.subheadline).bold()
                HStack {
                    Text("字体").frame(width: 44, alignment: .leading)
                    Picker("", selection: $font) {
                        // Keep a stale/custom value selectable so it isn't silently lost.
                        if !Conf.monoFontChoices.contains(font) { Text(font).tag(font) }
                        ForEach(Conf.monoFontChoices, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                HStack {
                    Text("字号").frame(width: 44, alignment: .leading)
                    Stepper(value: $fontSize, in: 8...32, step: 1) {
                        Text("\(Int(fontSize)) pt")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                HStack {
                    Text("行高").frame(width: 44, alignment: .leading)
                    Slider(value: $lineHeight, in: 1.0...2.0, step: 0.05)
                    Text(String(format: "%.2f×", lineHeight))
                        .font(.system(.body, design: .monospaced)).frame(width: 52, alignment: .trailing)
                }
                Text("预览 The quick brown fox · 0123 (){}[]")
                    .font(.custom(font, size: fontSize))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Text("行距无法调整:终端引擎(SwiftTerm)按字体自身度量决定行高,不提供行距设置。")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Toggle("柔和配色(Kaku Dark)", isOn: $softColors)
                Text("套用 Kaku Dark 主题:16 色 ANSI 调色板 + 深色背景/前景/光标,让 claude-hud 进度条等只发索引色的程序不再刺眼。关闭则回到默认自适应配色。")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // MARK: proxy
            VStack(alignment: .leading, spacing: 8) {
                Text("代理").font(.subheadline).bold()
                Toggle("启用代理", isOn: $enabled)
                HStack(spacing: 6) {
                    TextField("127.0.0.1:6789", text: $addr)
                        .textFieldStyle(.roundedBorder).disabled(!enabled)
                    Button("检测环境") {
                        let d = Conf.detectedEnvProxy()
                        if !d.isEmpty { addr = d; enabled = true }
                    }.help("从当前 shell 的 http_proxy / https_proxy 读取")
                }
                Text("填 host:port(不带 http://)。启用后,每个新终端启动时会注入 "
                     + "http_proxy / https_proxy / all_proxy。从 Raycast/Dock 启动 App "
                     + "时没有 shell 环境,必须在这里显式设置代理,否则 claude 连不上会让你登录。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("代理改动对已打开的终端不生效,重开该会话即可。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    let val = enabled ? addr.trimmingCharacters(in: .whitespaces) : ""
                    Conf.save(["proxy": val,
                               "term_font": font,
                               "term_font_size": Double(fontSize),
                               "line_height": Double(lineHeight),
                               "soft_colors": softColors])
                    TerminalManager.shared.reapplyTheme()   // live terminals update now
                    QuakeTerminal.shared.reapplyTheme()
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 400)
    }
}

@main
struct LeaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.hiddenTitleBar)              // traffic lights float over content; no titlebar band
            .windowResizability(.contentMinSize)
    }
}
