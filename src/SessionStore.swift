// SessionStore.swift — the single store behind the one unified sessions view.
// Three provider scan loops merge into one [AnySession] collection; all
// override mutations (archive/pin/unread/rename) go through SessionOverrides,
// with optimistic UI updates and (for Claude) the epoch guard against stale
// in-flight scans. Also owns the cross-provider last-opened LRU timestamps.
import SwiftUI
import Observation

@MainActor @Observable
final class SessionStore {
    static let shared = SessionStore()

    var sessions: [AnySession] = []
    var loading = false
    var toast: String?
    // LRU sort data: AnySession.id -> last time it was opened in Leader.
    // Persisted to ~/.config/leader/last-opened.json (app UI state, NOT provider
    // data — deliberately outside every provider's storage contract).
    private(set) var lastOpened: [String: TimeInterval] = [:]

    @ObservationIgnored private var started = false
    @ObservationIgnored private var timers: [Timer] = []
    // Bumped whenever a Claude write lands. A Claude scan captures the epoch when
    // it *starts*; if the epoch advanced by the time it finishes, its snapshot is
    // stale and must not clobber the optimistic state (kills the archive flicker).
    // Codex/Kimi don't need this: their overrides replay from a synchronously
    // written JSON, so a late scan still reconstructs the post-write state.
    @ObservationIgnored private var epoch = 0

    func start() {
        guard !started else { return }
        started = true
        loadLastOpened()
        refreshAll()
        // Claude scans are heavier (full transcript parse) but digest-cached → 6s,
        // same cadence as the old Store. Codex/Kimi keep their old 10s.
        timers = [
            Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshClaude() }
            },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshKimi() }
            },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshCodex() }
            },
        ]
        Activity.shared.start()
        // Give Activity a way to name a session for its completion banners.
        Activity.shared.displayName = { [weak self] sid in
            self?.sessions.first { $0.kind == .claude && $0.full_sid == sid }?.name ?? "Claude 会话"
        }
    }

    // Bottom-bar refresh button: all three providers at once.
    func refresh() { refreshAll() }
    private func refreshAll() { refreshClaude(); refreshKimi(); refreshCodex() }

    private func refreshClaude() {
        let e = epoch
        loading = true
        Task.detached(priority: .userInitiated) {
            let scanned = Backend.scan().map { AnySession($0) }
            await MainActor.run {
                self.loading = false
                guard e == self.epoch else { return }   // a write landed mid-scan → stale
                self.merge(.claude, scanned)
                // Fire stuck-at-error banners for sessions that newly died mid-turn.
                let errs = scanned.filter { $0.errored && !$0.archived }
                    .map { (sid: $0.full_sid, name: $0.name, text: $0.error_text) }
                Activity.shared.reconcileErrored(errs)
            }
        }
    }
    private func refreshKimi() {
        Task.detached(priority: .userInitiated) {
            let scanned = Backend.scanKimi().map { AnySession($0) }
            await MainActor.run {
                var s = scanned
                for i in s.indices { SessionOverrides.kimi.replay(&s[i]) }
                self.merge(.kimi, s)
            }
        }
    }
    private func refreshCodex() {
        Task.detached(priority: .userInitiated) {
            let scanned = Backend.scanCodex().map { AnySession($0) }
            await MainActor.run {
                var s = scanned
                for i in s.indices { SessionOverrides.codex.replay(&s[i]) }
                self.merge(.codex, s)
            }
        }
    }
    private func merge(_ kind: TerminalKind, _ scanned: [AnySession]) {
        sessions.removeAll { $0.kind == kind }
        sessions.append(contentsOf: scanned)
    }

    // MARK: - mutations. Every one: optimistic local change → persist → for
    // Claude, epoch+1 + rescan to reconcile (and invalidate pre-write scans).

    func setArchived(_ s: AnySession, _ on: Bool) {
        // Archiving also unpins, uniformly across providers: "archived but still
        // pinned" is a contradiction — the pin survived invisibly and un-archiving
        // teleported the session into 置顶 instead of back to its folder.
        optimistic(s.id) { $0.archived = on; if on { $0.pinned = false; $0.pin_order = nil } }
        flash(on ? "已归档" : "已取消归档")
        let ov = SessionOverrides.store(for: s.kind)
        if s.kind == .claude {
            Task.detached(priority: .userInitiated) {
                ov.setArchived(s, on)
                if on && s.pinned { ov.setPinned(s, false, order: nil) }
                await MainActor.run { self.epoch += 1; self.refreshClaude() }
            }
        } else {
            ov.setArchived(s, on)
            if on && s.pinned { ov.setPinned(s, false, order: nil) }
        }
    }
    func setPinned(_ s: AnySession, _ on: Bool) {
        let nextOrder = (sessions.filter { $0.kind == s.kind }.compactMap(\.pin_order).max() ?? -1) + 1
        optimistic(s.id) { $0.pinned = on; $0.pin_order = on ? nextOrder : nil }
        flash(on ? "已置顶" : "已取消置顶")
        let ov = SessionOverrides.store(for: s.kind)
        if s.kind == .claude {
            Task.detached(priority: .userInitiated) {
                ov.setPinned(s, on, order: on ? nextOrder : nil)
                await MainActor.run { self.epoch += 1; self.refreshClaude() }
            }
        } else {
            ov.setPinned(s, on, order: on ? nextOrder : nil)
        }
    }
    func setUnread(_ s: AnySession, _ on: Bool) {
        optimistic(s.id) { $0.unread = on }
        flash(on ? "已标为未读" : "已标为已读")
        let ov = SessionOverrides.store(for: s.kind)
        if s.kind == .claude {
            Task.detached(priority: .userInitiated) {
                ov.setUnread(s, on)
                await MainActor.run { self.epoch += 1; self.refreshClaude() }
            }
        } else {
            ov.setUnread(s, on)
        }
    }
    func setNickname(_ s: AnySession, _ nick: String) {
        let trimmed = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        optimistic(s.id) { $0.nickname = trimmed.isEmpty ? nil : trimmed }
        flash(trimmed.isEmpty ? "已恢复原标题" : "已重命名")
        let ov = SessionOverrides.store(for: s.kind)
        if s.kind == .claude {
            Task.detached(priority: .userInitiated) {
                ov.setNickname(s, trimmed.isEmpty ? nil : trimmed)
                await MainActor.run { self.epoch += 1; self.refreshClaude() }
            }
        } else {
            ov.setNickname(s, trimmed.isEmpty ? nil : trimmed)
        }
    }
    // "在 kitty 窗口打开" escape hatch — Claude only (launch.py).
    func openInKitty(_ s: AnySession) {
        guard s.canOpenInKitty else { return }
        Task.detached(priority: .userInitiated) {
            let ok = Backend.open(sid: s.full_sid, cwd: s.resume_cwd ?? s.cwd ?? "")
            await MainActor.run { self.flash(ok ? "已打开 / 切回窗口" : "打开失败") }
        }
    }
    // Cmd+W / header ✕ just killed a terminal. The 活跃 tab already dropped the
    // row synchronously (it keys off TerminalManager.running). This clears the
    // secondary Claude-only signals (alive → title shimmer) and reconciles once
    // the process tree is dead. Other providers carry no such signals.
    func markTerminalClosed(_ key: String) {
        let (kind, sid) = kindAndSid(fromTermKey: key)
        guard kind == .claude else { return }
        optimistic("claude:\(sid)") { $0.alive = false }
        epoch += 1
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(800))
            await MainActor.run { self.refreshClaude() }
        }
    }

    // MARK: - LRU (last-opened) timestamps
    func markOpened(_ s: AnySession) {
        lastOpened[s.id] = Date().timeIntervalSince1970
        saveLastOpened()
    }
    func lastOpenedAt(_ s: AnySession) -> TimeInterval { lastOpened[s.id] ?? 0 }
    private static let lastOpenedPath =
        NSString(string: "~/.config/leader/last-opened.json").expandingTildeInPath
    private func loadLastOpened() {
        lastOpened = (try? Data(contentsOf: URL(fileURLWithPath: Self.lastOpenedPath)))
            .flatMap { try? JSONDecoder().decode([String: TimeInterval].self, from: $0) } ?? [:]
    }
    private func saveLastOpened() {
        let url = URL(fileURLWithPath: Self.lastOpenedPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(lastOpened) { try? d.write(to: url, options: .atomic) }
    }

    private func optimistic(_ id: String, _ change: (inout AnySession) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { change(&sessions[i]) }
    }
    func flash(_ m: String) {
        toast = m
        Task { try? await Task.sleep(for: .seconds(2)); if toast == m { toast = nil } }
    }
}
