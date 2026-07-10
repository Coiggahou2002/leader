// Activity.swift — turn-lifecycle signals from leader-hook.py (FSEvents)
// and the notification banners (turn done / stuck on API error).
// Split out of LeaderApp.swift; pure move, no logic changes.
import AppKit
import UserNotifications

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
    var displayName: (String) -> String = { _ in "Claude 会话" } // full_sid -> name (set by the UI)

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
            [weak self] _ in Task { @MainActor [weak self] in self?.appBecameActive() }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor [weak self] in self?.appActive = false }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.process() }
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
        s.setEventHandler { [weak self] in Task { @MainActor [weak self] in self?.process() } }
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
                else { attention.insert(sid); postDoneNotification(sid) }     // done while away -> pulse + banner
            case "UserPromptSubmit":
                running.insert(sid)                          // reasoning started -> spinner
                attention.remove(sid)                        // work resumed -> clear stale pulse
            case "SessionEnd":
                running.remove(sid); attention.remove(sid)   // session gone
            default: break
            }
        }
    }

    // macOS banner for a turn that finished while you weren't watching it. Stable
    // per-session identifier so a chatty session replaces its banner, not stacks.
    // Guarded by Conf.notify; add() is a no-op if the user denied authorization.
    private func postDoneNotification(_ sid: String) {
        guard Conf.notify else { return }
        let content = UNMutableNotificationContent()
        content.title = displayName(sid)
        content.body = "已完成本轮回答"
        content.sound = .default
        content.userInfo = ["sid": sid]
        let req = UNNotificationRequest(identifier: "leader.done." + sid, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // ---- Stuck-at-error banners (driven by scan.py's poll, NOT the hook) --------
    // scan.py flags a session `errored` when its last turn died on an API error /
    // dropped connection and never resumed. Store hands us that set after each scan;
    // we fire a one-time banner when a session NEWLY enters that state (unless you're
    // already looking at it). Seed silently on the first scan so sessions already
    // stuck from before launch don't all banner at once. A recover-then-reerror
    // re-notifies (the sid leaves knownErrored on the clean scan, so it's "new" again).
    private var knownErrored: Set<String> = []
    private var erroredSeeded = false
    func reconcileErrored(_ now: [(sid: String, name: String, text: String?)]) {
        let nowSet = Set(now.map(\.sid))
        defer { knownErrored = nowSet }
        guard erroredSeeded else { erroredSeeded = true; return }
        for e in now where !knownErrored.contains(e.sid) {
            if e.sid == focusedSID && appActive { continue }   // you're watching it die
            postErrorNotification(e.sid, name: e.name, text: e.text)
        }
    }
    private func postErrorNotification(_ sid: String, name: String, text: String?) {
        guard Conf.notify else { return }
        let content = UNMutableNotificationContent()
        content.title = "⚠️ " + name + " 卡住了"
        content.body = text ?? "因 API 错误 / 连接中断中途停住,需要你重新发一条消息"
        content.sound = .default
        content.userInfo = ["sid": sid]   // reuses the tap→open plumbing (AppDelegate)
        // stable per-session id → a re-error replaces its banner, doesn't stack
        let req = UNNotificationRequest(identifier: "leader.error." + sid, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
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
