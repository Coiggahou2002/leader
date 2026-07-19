// SessionsView.swift — THE one sessions list. Used for the All-in-One view
// (filter == nil) and for each per-provider rail tab (filter == .claude/.codex/
// .kimi). One implementation, one set of shortcuts; provider differences live
// in AnySession's capability flags, not in forked views.
import SwiftUI
import AppKit
import Observation

// Sidebar sort for the 会话 tab, cycled from the bottom bar. Persisted.
//   folder    group by repo (collapsible folders)
//   activity  flat, attention-ranked (Claude rows use hook signals; others idle_h)
//   lru       flat, most-recently-opened-in-Leader first (never-opened fall back to idle_h)
enum SortMode: String, CaseIterable {
    case folder, activity, lru
    var next: SortMode { SortMode.allCases[(SortMode.allCases.firstIndex(of: self)! + 1) % SortMode.allCases.count] }
    var icon: String {
        switch self { case .folder: "folder.fill"; case .activity: "bolt.fill"; case .lru: "clock" }
    }
    var help: String {
        switch self {
        case .folder: "按文件夹分组(点击切换到活跃排序)"
        case .activity: "按活跃排序(点击切换到最近打开)"
        case .lru: "按最近打开排序(点击切换到文件夹分组)"
        }
    }
    var tint: Color { self == .folder ? .accentColor : .secondary }
}

func providerLabel(_ kind: TerminalKind) -> String {
    switch kind { case .claude: "Claude"; case .codex: "Codex"; case .kimi: "Kimi" }
}

struct SessionsView: View {
    /// nil = All-in-One (every provider in one list); non-nil = one provider only.
    let filter: TerminalKind?

    private let store = SessionStore.shared
    @State private var pinned = false   // window-level always-on-top, opt-in
    @State private var mode: Mode = .live
    @State private var hoveredID: String?
    @State private var collapsed: Set<String> = []
    @State private var renameTarget: AnySession?
    @State private var renameText = ""
    @State private var staleExpanded = false
    @State private var selectedID: String?             // AnySession.id
    @State private var activeSID: String?              // termKey of the session in the main area
    @State private var showSettings = false
    @State private var showHelp = false                // 快捷键帮助面板
    @State private var showOpenPath = false            // Cmd+Shift+O quick-open
    @State private var pathInput = ""
    @State private var pathSel = 0
    @State private var pathCands: [String] = []        // dir completions, scanned off-main per input change
    @State private var confirmCloseActive = false      // Cmd+W confirm
    @State private var closeTarget: (termKey: String, name: String)?   // what Cmd+W will close
    // Cmd+K command palette. Two levels: nil paletteActionsFor = session search;
    // non-nil = the drill-in action list for that one session.
    @State private var showPalette = false
    @State private var paletteQuery = ""
    @State private var paletteSel = 0
    @State private var paletteActionsFor: AnySession?
    // A just-created session: embedded immediately at a known (possibly synthetic)
    // sid, before the scanner picks it up into store.sessions.
    @State private var pendingNew: (sid: String, cwd: String, kind: TerminalKind)?
    // Kimi sids seen in earlier scans — the "is this session NEW?" signal used to
    // adopt a pendingNew kimi session once its real sid lands (see
    // reconcileAfterScan). Seeded on appear, unioned after every scan.
    @State private var knownKimiSids: Set<String> = []
    @FocusState private var focus: Focus?
    @AppStorage("leader.sortMode") private var sortMode: SortMode = .folder
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var term = TerminalManager.shared   // 活跃 tab: embed liveness
    // P1: observe the turn-lifecycle store so the sidebar RE-SORTS when a Claude
    // session starts/finishes (lists rank by sessionState, which reads this).
    @ObservedObject private var activity = Activity.shared

    enum Focus { case list, openPath, palette }

    // Sessions visible under the current rail filter.
    private var visible: [AnySession] {
        guard let filter else { return store.sessions }
        return store.sessions.filter { $0.kind == filter }
    }

    // ordered sessions currently displayed -> drives ↑/↓ navigation
    private var navList: [AnySession] {
        switch mode {
        case .active:
            var arr = pinnedList
            switch sortMode {
            case .folder:
                for f in folders where !collapsed.contains(f.name) { arr += f.items }
            case .activity: arr += flatList
            case .lru:      arr += lruList
            }
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
        if let id = selectedID, let s = visible.first(where: { $0.id == id }) { openEmbedded(s) }
    }
    // Click / Enter: embed the session in the main area.
    private func openEmbedded(_ s: AnySession) {
        selectedID = s.id
        activeSID = s.termKey
        store.markOpened(s)                            // LRU sort data
        if s.unread { store.setUnread(s, false) }      // 打开即已读(邮件式)
        // Embedding = active work again, so an archived session must come back out
        // of 已归档 — otherwise it runs a terminal but never shows in 活跃.
        if s.archived { store.setArchived(s, false) }
    }
    // Which provider a ⌘⇧O-created session belongs to: the rail filter if any,
    // else the selected session's provider, else Claude. Codex can't be created
    // in-app (no --session-id equivalent) — say so instead of faking it.
    private func createKind() -> TerminalKind? {
        let candidate = filter
            ?? store.sessions.first(where: { $0.id == selectedID })?.kind
            ?? .claude
        guard candidate.canCreate else {
            store.flash("Codex 会话暂不支持在 Leader 内新建")
            return nil
        }
        return candidate
    }
    private func newEmbeddedSession(in cwd: String) {
        guard let kind = createKind() else { return }
        switch kind {
        case .claude:
            // We mint the sid so there's no race to discover it; claude
            // --session-id starts the conversation at that id.
            let sid = UUID().uuidString.lowercased()
            _ = TerminalManager.shared.newSession(sid: sid, cwd: cwd)
            pendingNew = (sid, cwd, .claude)
            selectedID = "claude:\(sid)"   // matches AnySession.id once the scan lands
            activeSID = sid                // claude termKey = bare sid
        case .kimi:
            // Kimi has no --session-id: bare `kimi` under a synthetic sid until
            // the next scan picks the real session up into the index.
            let sid = TerminalManager.shared.newKimiSession(cwd: cwd)
            pendingNew = (sid, cwd, .kimi)
            selectedID = nil               // the synthetic sid never appears in scans
            activeSID = "kimi:\(sid)"
        case .codex:
            break                          // unreachable: createKind() filters it
        }
        store.flash("已在 \(prettyPath(expandTilde(cwd))) 新建 \(providerLabel(kind)) 会话")
        updateQuakeCwd()
        // pull the new session into the list once its transcript/index entry lands
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
    private func refreshPathCandidates() {
        let input = pathInput
        Task.detached(priority: .userInitiated) {
            let cands = Self.pathCandidates(input)
            await MainActor.run { if input == pathInput { pathCands = cands } }
        }
    }
    // Directories under the typed path's parent whose name matches the last
    // component. Hidden dirs shown only when the user is typing a dot.
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
    private func beginRename(_ s: AnySession) {
        renameText = s.nickname ?? s.title ?? ""
        renameTarget = s
    }
    // Substring match over the fields a person would search by — drives the Cmd+K
    // palette. Includes full_sid (paste a raw id) and the provider name.
    static func sessionMatches(_ s: AnySession, _ raw: String) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return s.name.lowercased().contains(q)
            || (s.title ?? "").lowercased().contains(q)
            || (s.last_prompt ?? "").lowercased().contains(q)
            || s.repo.lowercased().contains(q)
            || (s.branch ?? "").lowercased().contains(q)
            || s.full_sid.lowercased().contains(q)
            || s.kind.rawValue.lowercased().contains(q)
    }

    // MARK: Cmd+K palette — data
    // Level 1: sessions matching the query (all tabs, so you never have to switch
    // first). Empty query = most-recently-used, so the palette is useful on open.
    private var paletteSessions: [AnySession] {
        let q = paletteQuery.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty
            ? visible.filter { !$0.archived }.sorted { $0.idle_h < $1.idle_h }
            : visible.filter { Self.sessionMatches($0, q) }.sorted(by: byAttention)
        return Array(base.prefix(60))
    }
    // Level 2: actions on one session, derived from its own state + capabilities,
    // mirroring the right-click menu.
    private func paletteActions(_ s: AnySession) -> [PaletteAction] {
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
        if s.canOpenInKitty {
            a.append(.init(id: "kitty", title: "在 kitty 窗口打开", icon: "rectangle.on.rectangle") { store.openInKitty(s) })
        }
        return a
    }
    private var paletteActionResults: [PaletteAction] {
        guard let s = paletteActionsFor else { return [] }
        let all = paletteActions(s)
        let q = paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) }
    }
    private func paletteEmbedGlyph(_ s: AnySession) -> String {
        if term.running.contains(s.termKey) { return "terminal.fill" }
        if term.exited.contains(s.termKey) { return "terminal" }
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
    // appears ONLY in 已归档; every other list filters `!archived`. 活跃 is an
    // ORTHOGONAL filter over the SINGLE synchronous source of truth for "has a
    // terminal open in Leader right now" — TerminalManager.running (already
    // cross-provider via namespaced termKeys).
    private var pinnedList: [AnySession] {
        // Fixed order = pin time (pin_order), NOT recency — a pinned row must
        // never drift when scans update idle times.
        visible.filter { $0.pinned && !$0.archived }.sorted {
            let (a, b) = ($0.pin_order ?? .max, $1.pin_order ?? .max)
            return a == b ? $0.id < $1.id : a < b
        }
    }
    private var staleList: [AnySession] { visible.filter { !$0.archived && !$0.pinned && $0.isStale } }
    private var archivedList: [AnySession] { visible.filter(\.archived) }
    private var liveList: [AnySession] {
        visible.filter { !$0.archived && term.running.contains($0.termKey) }
            .sorted(by: byAttention)
    }
    private var folders: [(name: String, items: [AnySession])] {
        let rest = visible.filter { !$0.archived && !$0.pinned && !$0.isStale }
        return Dictionary(grouping: rest, by: \.repo)
            .map { (name: $0.key, items: $0.value.sorted(by: byAttention)) }
            .sorted { $0.name < $1.name }
    }
    // P0: the one place session state is derived. Only Claude rows carry hook
    // signals (Activity sets + alive/asks/errored); Codex/Kimi always land in
    // .closed and rank by idle_h — honest degradation, no fake state.
    private func sessionState(_ s: AnySession) -> SessionState {
        if activity.attention.contains(s.full_sid) { return .doneAway }
        if activity.running.contains(s.full_sid) && s.alive { return .working }
        if s.alive { return .waiting }
        return .closed
    }
    // P1: attention ranking. State first (needs-you above all), then asks
    // tiebreak, then recency. Meaningful for Claude; for Codex/Kimi it reduces
    // to idle_h, which is exactly their native ordering.
    private func byAttention(_ l: AnySession, _ r: AnySession) -> Bool {
        let ls = sessionState(l), rs = sessionState(r)
        if ls != rs { return ls < rs }
        if (ls == .doneAway || ls == .waiting) && l.asks != r.asks { return l.asks }
        return l.idle_h < r.idle_h
    }
    // 活跃排序: attention-ranked flat list.
    private var flatList: [AnySession] {
        visible.filter { !$0.archived && !$0.pinned && !$0.isStale }.sorted(by: byAttention)
    }
    // LRU: most-recently-opened-in-Leader first; never-opened (0) sink, ordered
    // by recency among themselves.
    private var lruList: [AnySession] {
        visible.filter { !$0.archived && !$0.pinned && !$0.isStale }.sorted {
            let (a, b) = (store.lastOpenedAt($0), store.lastOpenedAt($1))
            return a == b ? $0.idle_h < $1.idle_h : a > b
        }
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
            store.start(); focus = .list; updateQuakeCwd()
            reconcileAfterScan()   // seed knownKimiSids with whatever is already scanned
            restoreSessions()
        }
        .onChange(of: store.sessions) { _, _ in reconcileAfterScan() }
        .onChange(of: activeSID) { _, key in
            updateQuakeCwd()
            let (kind, sid) = kindAndSid(fromTermKey: key ?? "")
            if kind == .claude { Activity.shared.markFocused(key == nil ? nil : sid) }
            TerminalManager.shared.lastActiveSid = key   // for the quit dialog's restore file
            hoveredID = nil   // switch kills any stale hover on the previous row
        }
        .sheet(item: $renameTarget) { s in
            RenameSheet(originalTitle: s.title ?? s.last_prompt ?? "(无)", text: $renameText,
                        onSave: { store.setNickname(s, $0); renameTarget = nil },
                        onCancel: { renameTarget = nil })
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showHelp) { HelpSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .leaderCloseActive)) { _ in
            // Target the embedded session in the main pane; else fall back to the
            // sidebar-SELECTED row if its terminal is open. A silent no-op reads as
            // "close is broken", so always give feedback.
            if let a = activeEmbed {
                closeTarget = (a.termKey, a.name); confirmCloseActive = true
            } else if let id = selectedID, let s = store.sessions.first(where: { $0.id == id }),
                      TerminalManager.shared.isOpen(s.full_sid, kind: s.kind) {
                closeTarget = (s.termKey, s.name); confirmCloseActive = true
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
            // A completion banner was clicked — embed that (Claude) session.
            if let sid = note.object as? String,
               let s = store.sessions.first(where: { $0.kind == .claude && $0.full_sid == sid }) { openEmbedded(s) }
        }
        .onChange(of: paletteQuery) { _, _ in paletteSel = 0 }
        .confirmationDialog("关闭会话终端?", isPresented: $confirmCloseActive, titleVisibility: .visible) {
            Button("关闭会话", role: .destructive) { if let t = closeTarget { closeSession(t.termKey) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会杀掉「\(closeTarget?.name ?? "")」的嵌入进程(transcript 已保存,可重新打开)。Leader 不会退出。")
        }
    }

    // Runs after every scan merge. Two jobs:
    // 1. Claude: pendingNew mints the real sid up front, so once the scan lands it
    //    the stub is redundant — retire it (activeEmbed already prefers the row).
    // 2. Kimi: pendingNew is a SYNTHETIC sid (no --session-id exists). When the
    //    real session shows up in the scan, adopt it: re-key the live terminal to
    //    the real sid (same process, no respawn) and select the row. Candidates
    //    must be in the same cwd, fresh (updated < 3 min ago), and never seen in
    //    an earlier scan — and there must be exactly ONE, or we stay unselected
    //    rather than adopt the wrong session.
    private func reconcileAfterScan() {
        defer {
            knownKimiSids.formUnion(store.sessions.filter { $0.kind == .kimi }.map(\.full_sid))
        }
        guard let p = pendingNew else { return }
        if p.kind == .claude {
            if store.sessions.contains(where: { $0.kind == .claude && $0.full_sid == p.sid }) {
                pendingNew = nil
            }
            return
        }
        guard p.kind == .kimi else { return }
        let fresh = store.sessions.filter { s in
            s.kind == .kimi && !s.archived
                && !knownKimiSids.contains(s.full_sid)
                && s.idle_h < 3.0 / 60.0
                && (sameDir(s.resume_cwd, p.cwd) || sameDir(s.cwd, p.cwd))
        }
        guard fresh.count == 1, let s = fresh.first else { return }
        let syntheticKey = "kimi:\(p.sid)"
        TerminalManager.shared.rekey(from: syntheticKey, to: s.termKey)
        if activeSID == syntheticKey { activeSID = s.termKey }
        pendingNew = nil
        selectedID = s.id
        store.markOpened(s)
    }
    private func sameDir(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        var x = expandTilde(a), y = expandTilde(b)
        if x.hasSuffix("/") { x = String(x.dropLast()) }
        if y.hasSuffix("/") { y = String(y.dropLast()) }
        return x == y
    }

    // Reopen the sessions saved by the quit dialog (macOS-style "恢复会话").
    // consume() is one-shot — the file is deleted before any spawn, so a crash
    // here can't loop into mass-spawning CLIs on every launch.
    private func restoreSessions() {
        guard let r = RestoreState.consume() else { return }
        for e in r.sessions { _ = TerminalManager.shared.terminal(forStoredKey: e.sid, cwd: e.cwd) }
        let front = r.active.flatMap { a in r.sessions.first { $0.sid == a }?.sid }
            ?? r.sessions.first?.sid
        if let front {
            activeSID = front
            let (kind, sid) = kindAndSid(fromTermKey: front)
            selectedID = "\(kind.rawValue):\(sid)"   // matches AnySession.id once scanned
        }
        store.flash("已恢复 \(r.sessions.count) 个会话")
    }

    // Close one session's embedded terminal (Cmd+W target or the header ✕).
    // Unmount the terminal view FIRST, with animations DISABLED, so nothing can
    // re-run updateNSView and re-spawn the terminal we're about to kill.
    private func closeSession(_ key: String) {
        let (kind, sid) = kindAndSid(fromTermKey: key)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if activeSID == key { activeSID = nil }
            if let p = pendingNew, p.kind == kind, p.sid == sid { pendingNew = nil }
        }
        TerminalManager.shared.close(sid, kind: kind)
        store.markTerminalClosed(key)     // drop from 活跃 immediately, then reconcile
    }

    // The scratch (quake) terminal opens in the active session's working dir;
    // keep it pointed there, for ANY provider.
    private func updateQuakeCwd() {
        if let key = activeSID {
            let (kind, sid) = kindAndSid(fromTermKey: key)
            if let s = store.sessions.first(where: { $0.kind == kind && $0.full_sid == sid }) {
                QuakeTerminal.shared.currentCwd = s.cwd ?? s.resume_cwd ?? NSHomeDirectory()
                return
            }
            if let p = pendingNew, p.kind == kind, p.sid == sid {
                QuakeTerminal.shared.currentCwd = expandTilde(p.cwd)
            }
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
        .background(VisualEffect().ignoresSafeArea())   // frosted translucent sidebar
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
                                    ? "搜索会话(名称 / 目录 / 分支 / provider / session id)"
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
                    if let logo = ProviderLogos.image(for: s.kind) {
                        Image(nsImage: logo).interpolation(.high).resizable().scaledToFit()
                            .frame(width: 15, height: 15)
                    } else {
                        Image(systemName: paletteEmbedGlyph(s)).font(.caption)
                            .foregroundStyle(.secondary).frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).lineLimit(1)
                        Text("\(providerLabel(s.kind)) · \(s.ago)前 · \(s.repo)").font(.caption)
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
    // the just-created pending one (which has no AnySession yet). activeSID is a
    // termKey (claude bare, others namespaced) so restore.json round-trips it.
    private struct ActiveEmbed {
        let termKey: String; let sid: String; let kind: TerminalKind
        let cwd: String; let name: String; let session: AnySession?
    }
    private var activeEmbed: ActiveEmbed? {
        guard let key = activeSID else { return nil }
        let (kind, sid) = kindAndSid(fromTermKey: key)
        if let s = store.sessions.first(where: { $0.kind == kind && $0.full_sid == sid }) {
            // resume_cwd is the dir the CLI can actually resume from; s.cwd is
            // the last-seen (possibly cd'd-into) dir, only good for display.
            return ActiveEmbed(termKey: key, sid: sid, kind: kind,
                               cwd: s.resume_cwd ?? s.cwd ?? "~", name: s.name, session: s)
        }
        if let p = pendingNew, p.kind == kind, p.sid == sid {
            return ActiveEmbed(termKey: key, sid: sid, kind: kind, cwd: p.cwd, name: "新会话", session: nil)
        }
        // Restored-at-launch session the first scan hasn't caught up with yet:
        // its terminal is already open in TerminalManager, embed it right away.
        if TerminalManager.shared.isOpen(sid, kind: kind),
           let cwd = TerminalManager.shared.cwd(forSid: key) {
            return ActiveEmbed(termKey: key, sid: sid, kind: kind, cwd: cwd,
                               name: "会话 \(sid.prefix(8))", session: nil)
        }
        return nil
    }

    @ViewBuilder private var terminalArea: some View {
        if let info = activeEmbed {
            VStack(spacing: 0) {
                terminalHeader(embed: info)
                TerminalContainer(sid: info.sid, cwd: info.cwd, kind: info.kind)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(filter.map { "点击左侧会话,在此嵌入运行 \(providerLabel($0))" }
                        ?? "点击左侧会话,在此嵌入运行(支持 Claude / Codex / Kimi)")
                    .foregroundStyle(.secondary).font(.callout)
                Text("再次点击切换 · 关掉单个会话可释放资源").foregroundStyle(.tertiary).font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // Thin bar above the embedded terminal: which session is running + a close
    // button that kills the in-app process but leaves the list item in place.
    private func terminalHeader(embed: ActiveEmbed) -> some View {
        HStack(spacing: 8) {
            if let logo = ProviderLogos.image(for: embed.kind) {
                Image(nsImage: logo).interpolation(.high).resizable().scaledToFit()
                    .frame(width: 15, height: 15)
            } else {
                Image(systemName: "terminal").foregroundStyle(.secondary)
            }
            Text(embed.name).font(.callout).bold().lineLimit(1)
            Text(embed.sid).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 8)
            if let s = embed.session, s.canOpenInKitty {
                Button("在 kitty 窗口打开", systemImage: "rectangle.on.rectangle") { store.openInKitty(s) }
                    .buttonStyle(.plain).labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .help("在独立 kitty 窗口打开(全屏 TUI 滚动用)")
            }
            Button("关闭会话终端", systemImage: "xmark.circle.fill") {
                closeSession(embed.termKey)   // same path as Cmd+W (kills tree + clears 活跃)
            }
            .buttonStyle(.plain).labelStyle(.iconOnly).foregroundStyle(.secondary)
            .help("杀掉嵌入的进程(列表项保留)")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }

    // Top strip: reserves room for the window's traffic lights and shows the
    // current scope's brand mark — the provider logo, or the app icon for All.
    private var trafficInset: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 26)        // room for the floating traffic lights
            Group {
                if let f = filter {
                    if let logo = ProviderLogos.image(for: f) {
                        Image(nsImage: logo).resizable().interpolation(.high)
                            .scaledToFit().frame(height: 32)
                    } else {
                        Text(providerLabel(f)).font(.title3).bold()
                    }
                } else {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                        .scaledToFit().frame(height: 32)
                }
            }
            .padding(.leading, DS.gap + DS.rowPadH - 2)   // align with list content
            .padding(.bottom, 16)
        }
    }

    // Utility strip pinned to the sidebar bottom.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if store.loading { ProgressView().controlSize(.small) }
            Spacer(minLength: 4)
            iconButton("arrow.clockwise", "刷新", Color.secondary, action: store.refresh)
            iconButton(sortMode.icon, sortMode.help, sortMode.tint) { sortMode = sortMode.next }
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
                    // (`selected`, hover). A LazyVStack does not reliably re-render
                    // its children when that parent @State changes — clicking a row
                    // switched the terminal but left the highlight on the previous
                    // row. Eager VStack re-renders every row on any state change.
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
            // Belt-and-suspenders for stuck hover: clear hoveredID when the pointer
            // leaves the whole list so at rest only the selected row glows.
            .onHover { inside in if !inside { hoveredID = nil } }
        }
    }

    @ViewBuilder private var activeContent: some View {
        if !pinnedList.isEmpty {
            // The one golden star lives here; rows stay clean (pin/unpin via 右键).
            SectionHeader(title: "置顶", n: pinnedList.count, icon: "star.fill", iconTint: .yellow)
            ForEach(pinnedList) { s in sessionRow(s) }
        }
        switch sortMode {
        case .folder:
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
        case .activity:
            SectionHeader(title: "按活跃", n: flatList.count, icon: "bolt.fill")
            ForEach(flatList) { s in sessionRow(s) }
        case .lru:
            SectionHeader(title: "最近打开", n: lruList.count, icon: "clock")
            ForEach(lruList) { s in sessionRow(s) }
        }
    }

    private func sessionRow(_ s: AnySession, showEmbedBadge: Bool = true) -> some View {
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
                description: Text("开着终端的会话(App 内嵌入运行)会出现在这里"))
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
