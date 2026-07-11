// LeaderApp.swift — native macOS fleet panel.
// Data: scan.py --json.  Open: launch.py.  Archive: archive.py.
// Follows system Light/Dark, frosted-glass; normal window level (pin is opt-in).
import SwiftUI
import AppKit
import Observation
import UserNotifications
import Sparkle


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
    @State private var showHelp = false               // 快捷键帮助面板
    @State private var showOpenPath = false          // Cmd+Shift+O quick-open
    @State private var pathInput = ""
    @State private var pathSel = 0
    @State private var pathCands: [String] = []      // dir completions, scanned off-main per input change
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
    // P1: observe the turn-lifecycle store so the sidebar RE-SORTS when a session
    // starts/finishes (folders/liveList rank by sessionState, which reads this).
    // Without observing it here, only individual Rows re-render (dot/shimmer) and
    // the order would stay stale until the next 6s scan re-ran body.
    @ObservedObject private var activity = Activity.shared

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
        case .stale:    return staleExpanded ? staleList.sorted(by: byAttention) : []
        case .archived: return archivedList.sorted(by: byAttention)
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
        if s.unread { store.setUnread(s, false) }        // 打开即已读(邮件式)
        // Embedding = active work again, so an archived session must come back out of
        // 已归档 — otherwise it runs a terminal but never shows in 活跃 (which, like every
        // non-archive list, filters !archived). Covers Cmd+K, the 已归档 row, and
        // notification-triggered opens, since all of them route through here.
        if s.archived { store.setArchived(s, false) }
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
        pathCands = []
        showOpenPath = true
        refreshPathCandidates()   // seed completions (onChange won't fire if input is unchanged)
        DispatchQueue.main.async { focus = .openPath }
    }
    private func prettyPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
    // Rescan directory completions for the current input, OFF the main thread.
    // The scan is filesystem I/O (contentsOfDirectory + a stat per entry) and used
    // to run synchronously inside the overlay's view body — so it re-fired on every
    // body invalidation (each keystroke, every hover flip, the 6 s scan.py refresh),
    // blocking the field. Now it runs only when the typed path changes, results are
    // cached in `pathCands`, and a staleness guard drops out-of-order responses.
    private func refreshPathCandidates() {
        let input = pathInput
        Task.detached(priority: .userInitiated) {
            let cands = Self.pathCandidates(input)
            await MainActor.run { if input == pathInput { pathCands = cands } }
        }
    }
    // Directories under the typed path's parent whose name matches the last
    // component. Hidden dirs shown only when the user is typing a dot. Pure +
    // static so refreshPathCandidates can call it off-main without capturing self;
    // uses a private FileManager and reads .isDirectoryKey from the enumeration
    // (one pass) instead of a second fileExists() stat per entry.
    private nonisolated static func pathCandidates(_ input: String) -> [String] {
        guard !input.isEmpty else { return [] }
        let ns = (input as NSString).expandingTildeInPath
        let dir: String, prefix: String
        if input.hasSuffix("/") { dir = ns; prefix = "" }
        else { dir = (ns as NSString).deletingLastPathComponent; prefix = (ns as NSString).lastPathComponent }
        let base = dir.isEmpty ? "/" : dir
        let fm = FileManager()
        guard let urls = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: base, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        let showHidden = prefix.hasPrefix(".")
        let lower = prefix.lowercased()
        return urls.filter { url in
            let name = url.lastPathComponent
            guard showHidden || !name.hasPrefix(".") else { return false }
            guard prefix.isEmpty || name.lowercased().hasPrefix(lower) else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.map(\.path).sorted().prefix(8).map { $0 }
    }
    // Enter: open the typed dir if it exists, else the highlighted/first candidate.
    private func commitOpenPath() {
        let expanded = (pathInput as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        var target: String?
        if !pathInput.isEmpty,
           FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            target = expanded
        } else if pathSel < pathCands.count { target = pathCands[pathSel] }
        else { target = pathCands.first }
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
            : store.sessions.filter { Self.sessionMatches($0, q) }.sorted(by: byAttention)
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
            .sorted(by: byAttention)
    }
    private var folders: [(name: String, items: [Session])] {
        let rest = store.sessions.filter { !$0.archived && !$0.pinned && !$0.isStale }
        return Dictionary(grouping: rest, by: \.repo)
            .map { (name: $0.key, items: $0.value.sorted(by: byAttention)) }
            .sorted { $0.name < $1.name }
    }
    // P0: the one place session state is derived. Order of checks = priority;
    // Activity's sets are mutually exclusive by construction (see Activity.process),
    // so at most one live state applies. `alive` gates .working exactly like the
    // title shimmer, so a crashed session (no Stop) can't read as "working" forever.
    private func sessionState(_ s: Session) -> SessionState {
        if activity.attention.contains(s.full_sid) { return .doneAway }
        if activity.running.contains(s.full_sid) && s.alive { return .working }
        if s.alive { return .waiting }
        return .closed
    }
    // P1: cμ-flavoured attention ranking. Primary key = state (needs-you first).
    // Within the SAME state, the one you're more directly blocking (it asked you a
    // question) and can clear fastest (most recent = cheapest context switch) comes
    // first. `asks` only orders sessions ALREADY in a needs-you state — it never
    // moves a session between states (that's the noise trap scan.py warns about).
    private func byAttention(_ l: Session, _ r: Session) -> Bool {
        let ls = sessionState(l), rs = sessionState(r)
        if ls != rs { return ls < rs }
        if (ls == .doneAway || ls == .waiting) && l.asks != r.asks { return l.asks }
        return l.idle_h < r.idle_h
    }
    // LRU: most-recently-used first (smallest idle first)
    private var flatList: [Session] {
        store.sessions.filter { !$0.archived && !$0.pinned && !$0.isStale }.sorted(by: byAttention)
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
            restoreSessions()
        }
        .onChange(of: activeSID) { _, id in
            updateQuakeCwd(); Activity.shared.markFocused(id)
            TerminalManager.shared.lastActiveSid = id   // for the quit dialog's restore file
            hoveredID = nil   // switch kills any stale hover on the previous row
        }
        .sheet(item: $renameTarget) { s in
            RenameSheet(session: s, text: $renameText,
                        onSave: { store.setNickname(s, $0); renameTarget = nil },
                        onCancel: { renameTarget = nil })
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showHelp) { HelpSheet() }
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

    // Reopen the sessions saved by the quit dialog (macOS-style "恢复会话").
    // consume() is one-shot — the file is deleted before any spawn, so a crash
    // here can't loop into mass-spawning claudes on every launch. Runs before
    // the first scan lands: terminal(forSid:) is self-contained (sid + cwd),
    // and activeEmbed's isOpen fallback shows the front session immediately.
    private func restoreSessions() {
        guard let r = RestoreState.consume() else { return }
        for e in r.sessions { _ = TerminalManager.shared.terminal(forSid: e.sid, cwd: e.cwd) }
        let front = r.active.flatMap { a in r.sessions.first { $0.sid == a }?.sid }
            ?? r.sessions.first?.sid
        if let front { selectedID = front; activeSID = front }
        store.flash("已恢复 \(r.sessions.count) 个会话")
    }

    // Close one session's embedded terminal (Cmd+W target or the header ✕).
    private func closeSession(_ sid: String) {
        // Unmount the terminal view FIRST (activeSID=nil → terminalArea shows the
        // empty state, TerminalContainer leaves the tree), so nothing can re-run
        // its updateNSView and re-spawn the terminal we're about to kill.
        //
        // Do the swap with animations DISABLED: Cmd+W runs this from inside the
        // confirmationDialog's "关闭会话" button, so the mutation would otherwise
        // inherit the dialog's dismissal transaction and SwiftUI would animate the
        // activeEmbed→nil branch swap — the terminal fades to transparent while the
        // empty-state placeholder scales up. We want an instant cut to the empty state.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if activeSID == sid { activeSID = nil }
            if pendingNew?.sid == sid { pendingNew = nil }
        }
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
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        TextField("输入目录路径,回车新建会话", text: $pathInput)
                            .textFieldStyle(.plain).font(.title3)
                            .focused($focus, equals: .openPath)
                            .onChange(of: pathInput) { _, _ in pathSel = 0; refreshPathCandidates() }
                            .onSubmit { commitOpenPath() }
                            .onKeyPress(.downArrow) {
                                if !pathCands.isEmpty { pathSel = min(pathSel + 1, pathCands.count - 1) }
                                return .handled
                            }
                            .onKeyPress(.upArrow) { pathSel = max(pathSel - 1, 0); return .handled }
                            .onKeyPress(.tab) {
                                if pathSel < pathCands.count { pathInput = pathCands[pathSel] + "/"; pathSel = 0 }
                                return .handled
                            }
                    }
                    .padding(14)
                    if !pathCands.isEmpty {
                        Divider()
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(pathCands.enumerated()), id: \.element) { i, c in
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
        // Restored-at-launch session the first scan hasn't caught up with yet:
        // its terminal is already open in TerminalManager, embed it right away
        // (the scanned row replaces this stub name within a refresh cycle).
        if TerminalManager.shared.isOpen(id), let cwd = TerminalManager.shared.cwd(forSid: id) {
            return ActiveEmbed(sid: id, cwd: cwd, name: "会话 \(id.prefix(8))", session: nil)
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
            iconButton("questionmark.circle", "快捷键帮助", Color.secondary) { showHelp = true }
            iconButton("arrow.down.circle", "检查更新", Color.secondary) {
                NotificationCenter.default.post(name: .leaderCheckUpdates, object: nil)
            }
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

    private func sessionRow(_ s: Session, showEmbedBadge: Bool = true) -> some View {
        Row(s: s,
            onOpen: { openEmbedded(s) }, onArchive: { store.setArchived(s, !s.archived) },
            onPin: { store.setPinned(s, !s.pinned) }, onRename: { beginRename(s) },
            onMarkUnread: { store.setUnread(s, !s.unread) },
            selected: selectedID == s.id, showEmbedBadge: showEmbedBadge, hoveredID: $hoveredID)
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
            ForEach(items) { s in sessionRow(s, showEmbedBadge: false) }
        }
    }

    @ViewBuilder private var staleContent: some View {
        let items = staleList.sorted(by: byAttention)
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
        let items = archivedList.sorted(by: byAttention)
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

@main
struct LeaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.hiddenTitleBar)              // traffic lights float over content; no titlebar band
            .defaultSize(width: 1200, height: 800)     // first launch only; SwiftUI persists later resizes
            .windowResizability(.contentMinSize)
    }
}
