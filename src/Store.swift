// Store.swift — the 6s scan loop and all optimistic session mutations.
// Split out of LeaderApp.swift; pure move, no logic changes.
import SwiftUI
import Observation

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
            Task { @MainActor [weak self] in self?.refresh() }
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
                // Fire stuck-at-error banners for sessions that newly died mid-turn.
                let errs = s.filter { $0.errored && !$0.archived }
                    .map { (sid: $0.full_sid, name: $0.name, text: $0.error_text) }
                Activity.shared.reconcileErrored(errs)
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
