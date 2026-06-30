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
    static let archiveZone: CGFloat = 30   // trailing hit-zone: archive
    static let pinZone: CGFloat = 30       // next hit-zone: pin/unpin
}

// MARK: - Model
struct Session: Decodable, Identifiable {
    let full_sid: String
    let sid: String
    let title: String?
    let last_prompt: String?
    let cwd: String?
    let branch: String?
    let bucket: String
    let why: [String]
    let idle_h: Double
    let msgs: Int
    let out_tok: Int
    let alive: Bool
    var archived: Bool      // var: allows optimistic local toggle
    var pinned: Bool
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
    var tok: String { out_tok >= 1000 ? "\(out_tok/1000)k" : "\(out_tok)" }
    var needsAttention: Bool { bucket == "a" }
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
        let d = run(["\(dir)/launch.py", s.full_sid, s.cwd ?? ""])
        let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        return (o?["ok"] as? Bool) ?? false
    }
    static func setArchived(_ s: Session, _ on: Bool) {
        _ = run(["\(dir)/archive.py", on ? "add" : "remove", s.full_sid])
    }
    static func setPinned(_ s: Session, _ on: Bool) {
        _ = run(["\(dir)/pin.py", on ? "add" : "remove", s.full_sid])
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

// MARK: - Store
@MainActor @Observable
final class Store {
    var sessions: [Session] = []
    var loading = false
    var toast: String?
    @ObservationIgnored private var timer: Timer?
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let s = Backend.scan()
            await MainActor.run { self.sessions = s; self.loading = false }
        }
    }
    func open(_ s: Session) {
        Task.detached(priority: .userInitiated) {
            let ok = Backend.open(s)
            await MainActor.run { self.flash(ok ? "已打开 / 切回窗口" : "打开失败") }
        }
    }
    func setArchived(_ s: Session, _ on: Bool) {
        optimistic(s.id) { $0.archived = on }            // UI 立即变
        flash(on ? "已归档" : "已取消归档")
        Task.detached(priority: .userInitiated) {
            Backend.setArchived(s, on)
            await MainActor.run { self.refresh() }       // 后台落盘后对账
        }
    }
    func setPinned(_ s: Session, _ on: Bool) {
        optimistic(s.id) { $0.pinned = on }
        flash(on ? "已置顶" : "已取消置顶")
        Task.detached(priority: .userInitiated) {
            Backend.setPinned(s, on)
            await MainActor.run { self.refresh() }
        }
    }
    func newSession(_ cwd: String) {
        flash("正在新建会话…")
        Task.detached(priority: .userInitiated) {
            Backend.newSession(cwd)
            await MainActor.run { self.refresh() }
        }
    }
    func setNickname(_ s: Session, _ nick: String) {
        let trimmed = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        optimistic(s.id) { $0.nickname = trimmed.isEmpty ? nil : trimmed }
        flash(trimmed.isEmpty ? "已恢复原标题" : "已重命名")
        Task.detached(priority: .userInitiated) {
            Backend.setNickname(s, trimmed)
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

// MARK: - 滚动条暗色适配:强制 overlay 细滚动条 + 跟随明暗
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
            sv.scrollerKnobStyle = dark ? .light : .dark
            sv.verticalScroller?.appearance = ap
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
    var hasPinZone = true
    var onHover: (Bool) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if x > bounds.width - DS.archiveZone { onArchive() }
        else if hasPinZone, x > bounds.width - DS.archiveZone - DS.pinZone { onPin() }
        else { onClick() }
    }
    override func rightMouseDown(with event: NSEvent) { onRename() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}
struct MouseLayer: NSViewRepresentable {
    var onClick: () -> Void
    var onArchive: () -> Void = {}
    var onPin: () -> Void = {}
    var onRename: () -> Void = {}
    var hasPinZone = false
    var onHover: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> MouseNSView {
        let v = MouseNSView()
        v.onClick = onClick; v.onArchive = onArchive; v.onPin = onPin
        v.onRename = onRename; v.hasPinZone = hasPinZone; v.onHover = onHover
        return v
    }
    func updateNSView(_ v: MouseNSView, context: Context) {
        v.onClick = onClick; v.onArchive = onArchive; v.onPin = onPin
        v.onRename = onRename; v.hasPinZone = hasPinZone; v.onHover = onHover
    }
}

// MARK: - 窗口配置 + 置顶
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pinned = false   // window stays normal level; opt-in via the pin toolbar button
    var window: NSWindow?
    func applicationDidFinishLaunching(_ n: Notification) {
        installScrollMonitor()                       // wheel -> embedded terminal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.configure() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyLevel() }
    }
    func configure() {
        guard let w = NSApp.windows.first else { return }
        window = w
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.styleMask.insert(.fullSizeContentView)
        applyLevel()
        snapLeft()
    }
    func applyLevel() {
        guard let w = window ?? NSApp.windows.first else { return }
        window = w
        w.level = AppDelegate.pinned ? .floating : .normal
        w.collectionBehavior = AppDelegate.pinned
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary] : [.managed]
    }
    func snapLeft() {
        guard let w = window, let scr = NSScreen.main else { return }
        let vf = scr.visibleFrame
        // sidebar + embedded terminal -> a wide window, left-snapped, full height.
        let width = min(1180, vf.width)
        w.setFrame(NSRect(x: vf.minX, y: vf.minY, width: width, height: vf.height),
                   display: true, animate: false)
    }
}

// MARK: - Row
struct Row: View {
    let s: Session
    let archiveSymbol: String
    let onOpen: () -> Void
    let onArchive: () -> Void
    var onPin: () -> Void = {}
    var onRename: () -> Void = {}
    var showPin: Bool = true
    var selected: Bool = false
    @Binding var hoveredID: String?
    @ObservedObject var term = TerminalManager.shared   // embed state (running/exited)
    // single shared hovered id -> at most one row highlights, even mid-scroll
    private var hover: Bool { hoveredID == s.id }
    private var dotColor: Color { s.needsAttention ? .red : (s.alive ? .green : .secondary) }
    // embedded-terminal badge: filled+green while the in-app claude runs, hollow
    // grey once it exits, nothing if the session was never embedded.
    private var embedSymbol: String? {
        if term.running.contains(s.full_sid) { return "terminal.fill" }
        if term.exited.contains(s.full_sid) { return "terminal" }
        return nil
    }
    private var embedColor: Color { term.running.contains(s.full_sid) ? .green : .secondary }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.gap + 3) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(s.name).font(.callout).bold().lineLimit(1)
                    if let sym = embedSymbol {
                        Image(systemName: sym).font(.caption2).foregroundStyle(embedColor)
                            .help(sym == "terminal.fill" ? "已嵌入运行" : "已嵌入(进程已退出)")
                    }
                }
                Text("\(s.repo)@\(s.branch ?? "?") · \(s.ago)前 · \(s.msgs)条/\(s.tok)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if s.needsAttention, !s.why.isEmpty {
                    Text(s.why.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if showPin {
                    Image(systemName: s.pinned ? "star.fill" : "star")
                        .foregroundStyle(s.pinned ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                        .opacity(s.pinned ? 1 : (hover ? 1 : 0.3))
                        .help(s.pinned ? "取消置顶" : "置顶")
                }
                Image(systemName: archiveSymbol).foregroundStyle(.secondary)
                    .frame(width: 18)
                    .opacity(hover ? 1 : 0.32)
                    .help(archiveSymbol == "archivebox" ? "归档" : "取消归档")
            }
            .font(.caption)
        }
        .padding(.vertical, DS.rowPadV).padding(.horizontal, DS.rowPadH)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: DS.corner)
            .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                           : (hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))))
        .overlay(RoundedRectangle(cornerRadius: DS.corner)
            .strokeBorder(Color.accentColor.opacity(selected ? 0.7 : 0), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: DS.corner))
        .overlay { MouseLayer(onClick: onOpen, onArchive: onArchive, onPin: onPin,
                              onRename: onRename, hasPinZone: showPin, onHover: { inside in
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
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2) }
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
        .overlay { MouseLayer(onClick: toggle, onArchive: toggle, onHover: { _ in }) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(title) 文件夹,\(n) 个会话")
    }
}

// MARK: - Main
struct ContentView: View {
    @State private var store = Store()
    @State private var pinned = false   // window-level always-on-top, opt-in
    @State private var mode: Mode = .active
    @State private var hoveredID: String?
    @State private var collapsed: Set<String> = []
    @State private var renameTarget: Session?
    @State private var renameText = ""
    @State private var query = ""
    @State private var staleExpanded = false
    @State private var selectedID: String?
    @State private var activeSID: String?            // session embedded in the main area
    // A just-created session: embedded immediately at a known sid, before the
    // scanner (every 6s) picks it up into store.sessions.
    @State private var pendingNew: (sid: String, cwd: String)?
    @FocusState private var focus: Focus?
    @AppStorage("leader.grouped") private var grouped = true
    @Environment(\.colorScheme) private var scheme

    enum Focus { case list, search }
    // "" -> launch.py uses config.new_session_cwd() (default ~). Configure in
    // ~/.config/leader/config.json -> "new_session_cwd".
    static let newCwd = ""

    // ordered sessions currently displayed -> drives ↑/↓ navigation
    private var navList: [Session] {
        if !query.isEmpty {
            switch mode {
            case .active:   return store.sessions.filter { !$0.archived && matches($0) }.sorted(by: Self.byPriority)
            case .stale:    return staleList.filter(matches).sorted { $0.idle_h < $1.idle_h }
            case .archived: return archivedList.filter(matches).sorted(by: Self.byPriority)
            }
        }
        switch mode {
        case .active:
            var arr = pinnedList
            if grouped {
                arr += attention
                for f in folders where !collapsed.contains(f.name) { arr += f.items }
            } else { arr += flatList }
            return arr
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
    }
    // "+": start a fresh session embedded right here. We mint the sid so there's no
    // race to discover it; claude --session-id starts the conversation at that id.
    private func newEmbeddedSession() {
        let sid = UUID().uuidString.lowercased()
        let cwd = Conf.newCwd.isEmpty ? "~" : Conf.newCwd
        _ = TerminalManager.shared.newSession(sid: sid, cwd: cwd)
        pendingNew = (sid, cwd)
        selectedID = sid
        activeSID = sid
        store.flash("已新建会话")
        // pull the new session into the list once its transcript lands
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { store.refresh() }
    }
    private func beginRename(_ s: Session) {
        renameText = s.nickname ?? s.title ?? ""
        renameTarget = s
    }
    private func matches(_ s: Session) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return s.name.lowercased().contains(q)
            || (s.title ?? "").lowercased().contains(q)
            || (s.last_prompt ?? "").lowercased().contains(q)
            || s.repo.lowercased().contains(q)
            || (s.branch ?? "").lowercased().contains(q)
            || s.full_sid.lowercased().contains(q)        // 可直接粘 session id 定位
    }

    enum Mode: String, CaseIterable, Identifiable {
        case active = "会话", stale = "陈旧", archived = "已归档"
        var id: Self { self }
    }

    // pinned overrides stale (user explicitly wants it handy)
    private var pinnedList: [Session] {
        store.sessions.filter { $0.pinned && !$0.archived }.sorted(by: Self.byPriority)
    }
    private var attention: [Session] { store.sessions.filter { !$0.archived && !$0.pinned && !$0.isStale && $0.bucket == "a" } }
    private var staleList: [Session] { store.sessions.filter { !$0.archived && !$0.pinned && $0.isStale } }
    private var archivedList: [Session] { store.sessions.filter(\.archived) }
    private var folders: [(name: String, items: [Session])] {
        let rest = store.sessions.filter { !$0.archived && !$0.pinned && !$0.isStale && $0.bucket != "a" }
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
        }
        .frame(minWidth: 820, minHeight: 480)
        .onAppear { store.start(); focus = .list }
        // Headless E2E hook: LEADER_AUTOSELECT=1 auto-embeds the first session once
        // sessions load, so the embed path can be verified without clicking (no focus steal).
        .onChange(of: store.sessions.count) {
            guard activeSID == nil,
                  ProcessInfo.processInfo.environment["LEADER_AUTOSELECT"] == "1",
                  let first = navList.first else { return }
            openEmbedded(first)
        }
        .sheet(item: $renameTarget) { s in
            RenameSheet(session: s, text: $renameText,
                        onSave: { store.setNickname(s, $0); renameTarget = nil },
                        onCancel: { renameTarget = nil })
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            header
            Picker("视图", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, DS.rowPadH).padding(.bottom, 6)
            searchBar
            Divider().opacity(0.5)
            list
        }
        .background(VisualEffect().ignoresSafeArea())
        .background {                                   // Cmd+F -> focus search
            Button("") { focus = .search }
                .keyboardShortcut("f", modifiers: .command).opacity(0)
        }
        .focusable()
        .focused($focus, equals: .list)
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.return) { openSelected(); return .handled }
        .overlay(alignment: .bottom) { toast }
    }

    // What to embed for the current activeSID: a scanned session if known, else
    // the just-created pending one (which has no Session yet).
    private struct ActiveEmbed { let sid: String; let cwd: String; let name: String; let session: Session? }
    private var activeEmbed: ActiveEmbed? {
        guard let id = activeSID else { return nil }
        if let s = store.sessions.first(where: { $0.id == id }) {
            return ActiveEmbed(sid: s.full_sid, cwd: s.cwd ?? "~", name: s.name, session: s)
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
                TerminalManager.shared.close(sid)
                if pendingNew?.sid == sid { pendingNew = nil }
                activeSID = nil
            }
            .buttonStyle(.plain).labelStyle(.iconOnly).foregroundStyle(.secondary)
            .help("杀掉嵌入的 claude 进程(列表项保留)")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                HStack(spacing: 5) { Text("👨🏻‍💼"); Text("Leader").bold() }.font(.headline)
                if store.loading { ProgressView().controlSize(.small).padding(.leading, 2) }
                Spacer()
                Button("新建会话", systemImage: "plus", action: newEmbeddedSession)
                    .buttonStyle(.plain).labelStyle(.iconOnly)
                    .foregroundStyle(.secondary).help("在 impl 新建一个会话")
                Button(grouped ? "按文件夹分组" : "按最近使用",
                       systemImage: grouped ? "folder.fill" : "clock",
                       action: { grouped.toggle() })
                    .buttonStyle(.plain).labelStyle(.iconOnly)
                    .foregroundStyle(grouped ? Color.accentColor : .secondary)
                    .help(grouped ? "当前:按文件夹分组(点切换为最近使用)"
                                  : "当前:按最近使用 LRU(点切换为分组)")
                Button("置顶", systemImage: pinned ? "pin.fill" : "pin", action: togglePin)
                    .buttonStyle(.plain).labelStyle(.iconOnly)
                    .foregroundStyle(pinned ? Color.accentColor : .secondary).help("窗口置顶")
                Button("刷新", systemImage: "arrow.clockwise", action: store.refresh)
                    .buttonStyle(.plain).labelStyle(.iconOnly)
                    .foregroundStyle(.secondary).help("刷新")
            }
            Text("\(attention.count) 需处理 · \(staleList.count) 陈旧 · \(archivedList.count) 已归档")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.rowPadH).padding(.top, 12).padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("搜索 标题 / 文件夹 / session id", text: $query)
                .textFieldStyle(.plain).font(.callout)
                .focused($focus, equals: .search)
                .onSubmit { selectedID = navList.first?.id; openSelected(); focus = .list }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
        .padding(.horizontal, DS.rowPadH).padding(.bottom, 7)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    switch mode {
                    case .active: activeContent
                    case .stale: staleContent
                    case .archived: archivedContent
                    }
                }
                .padding(.horizontal, DS.gap).padding(.bottom, 20)
                .background(ScrollerFix(dark: scheme == .dark))
            }
            .onChange(of: selectedID) { _, id in
                if let id { withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder private var activeContent: some View {
        if !query.isEmpty {                                   // 搜索:跨分区扁平结果
            let results = store.sessions.filter { !$0.archived && matches($0) }
                .sorted(by: Self.byPriority)
            if results.isEmpty {
                ContentUnavailableView("无匹配会话", systemImage: "magnifyingglass").padding(.top, 40)
            } else {
                SectionHeader(title: "搜索结果", n: results.count, icon: "magnifyingglass")
                ForEach(results) { s in sessionRow(s) }
            }
        } else {
            if !pinnedList.isEmpty {
                SectionHeader(title: "置顶", n: pinnedList.count, icon: "star.fill")
                ForEach(pinnedList) { s in sessionRow(s) }
            }
            if grouped {
                if !attention.isEmpty {
                    SectionHeader(title: "需处理", n: attention.count)
                    ForEach(attention) { s in sessionRow(s) }
                }
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
    }

    private func sessionRow(_ s: Session) -> some View {
        Row(s: s, archiveSymbol: "archivebox",
            onOpen: { openEmbedded(s) }, onArchive: { store.setArchived(s, true) },
            onPin: { store.setPinned(s, !s.pinned) }, onRename: { beginRename(s) },
            selected: selectedID == s.id, hoveredID: $hoveredID)
    }

    @ViewBuilder private var staleContent: some View {
        let items = staleList.filter(matches).sorted { $0.idle_h < $1.idle_h }
        if items.isEmpty {
            ContentUnavailableView(query.isEmpty ? "没有陈旧会话" : "无匹配会话",
                systemImage: "clock.badge.xmark",
                description: Text(query.isEmpty ? "最后消息满 15 天的会话会自动归到这里" : ""))
                .padding(.top, 40)
        } else if !query.isEmpty {
            SectionHeader(title: "搜索结果", n: items.count, icon: "magnifyingglass")
            ForEach(items) { s in sessionRow(s) }
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
        let items = archivedList.filter(matches).sorted(by: Self.byPriority)
        if items.isEmpty {
            ContentUnavailableView(query.isEmpty ? "没有已归档的会话" : "无匹配会话",
                systemImage: "archivebox",
                description: Text(query.isEmpty ? "在“会话”里点卡片右侧的归档图标即可归档" : ""))
                .padding(.top, 40)
        } else {
            ForEach(items) { s in
                Row(s: s, archiveSymbol: "tray.and.arrow.up",
                    onOpen: { openEmbedded(s) }, onArchive: { store.setArchived(s, false) },
                    onRename: { beginRename(s) }, showPin: false,
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

@main
struct LeaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
