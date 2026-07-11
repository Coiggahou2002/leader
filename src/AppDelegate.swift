// AppDelegate.swift — window chrome, single-instance guard, global key
// monitor, Sparkle updater, notification delegate + app notifications.
// Split out of LeaderApp.swift; pure move, no logic changes.
import AppKit
import SwiftUI
import UserNotifications
import Sparkle

extension Notification.Name {
    static let leaderCloseActive = Notification.Name("leaderCloseActive")
    static let leaderTogglePalette = Notification.Name("leaderTogglePalette")
    static let leaderSelectTab = Notification.Name("leaderSelectTab")   // object: Int tab index
    static let leaderOpenSession = Notification.Name("leaderOpenSession")   // object: String full_sid
    static let leaderCheckUpdates = Notification.Name("leaderCheckUpdates")   // manual "检查更新" from the UI
}

// MARK: - 窗口配置 + 置顶
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var pinned = false   // window stays normal level; opt-in via the pin toolbar button
    var window: NSWindow?

    // Sparkle in-app auto-update. startingUpdater:true kicks off the scheduled
    // background check (interval + feed URL come from Info.plist: SUFeedURL,
    // SUEnableAutomaticChecks, SUPublicEDKey). The "检查更新…" button posts
    // .leaderCheckUpdates, which we forward to checkForUpdates(_:).
    private lazy var updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
        installKeyMonitor()                           // Cmd+W close · Cmd+K/F palette · Cmd+1..4 tabs
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // configure() only styles the titlebar (transparent + full-size content). It
        // must NOT touch the window frame — SwiftUI's WindowGroup persists and restores
        // size/position across launches on its own; resetting it here caused the
        // "restored correctly, then snapped back to centered" flicker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.configure() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyLevel() }
        _ = updater                                   // touch the lazy prop to start the updater now
        NotificationCenter.default.addObserver(
            forName: .leaderCheckUpdates, object: nil, queue: .main
        ) { [weak self] _ in self?.updater.checkForUpdates(nil) }
    }
    // Cmd+W must not close the window/quit the app; repurpose it to "close the
    // active session" (with confirm, handled in ContentView). Swallow the event
    // so the default File→Close never fires. Cmd+Q still quits (its own confirm).
    func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = e.charactersIgnoringModifiers?.lowercased()

            // Cmd+W is ALWAYS repurposed to "close the active session" and swallowed,
            // so it can never close the window / quit the app — scratch terminal or
            // not. (Handled in ContentView with a confirm.) Cmd+Q still quits.
            if mods == [.command], key == "w" {
                NotificationCenter.default.post(name: .leaderCloseActive, object: nil)
                return nil
            }

            // While the double-tap-Ctrl scratch terminal is up it OWNS the keyboard:
            // Leader's global chords must not steer the main window hidden behind it.
            // Let Cmd+K/Cmd+F reach the terminal (its clear-scrollback) instead of
            // opening the palette, and disable tab-switch (Cmd+1..4) and quick-open
            // (Cmd+Shift+O) entirely until it's dismissed (⌃⌃ again or ✕).
            let quakeUp = MainActor.assumeIsolated { QuakeTerminal.shared.isVisible }
            if quakeUp {
                if mods == [.command], let k = key, ["1", "2", "3", "4"].contains(k) { return nil }
                if mods == [.command, .shift], key == "o" { return nil }
                return e
            }

            // Only plain Cmd (no other modifiers), else let chords through.
            guard mods == [.command] else { return e }
            switch key {
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
        // Deliberately NO frame code here — see applicationDidFinishLaunching. SwiftUI
        // owns the window frame and restores it; first-launch size is .defaultSize.
    }
    func applyLevel() {
        guard let w = window ?? NSApp.windows.first else { return }
        window = w
        w.level = AppDelegate.pinned ? .floating : .normal
        w.collectionBehavior = AppDelegate.pinned
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary] : [.managed]
    }
    // Quitting kills every embedded claude. Confirm if any session is live so a
    // stray Cmd+Q doesn't tear down running work, and offer a macOS-logout-style
    // "restore on next launch" checkbox: when checked, the running sessions are
    // written to RestoreState and ContentView.onAppear respawns them next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let snapshot = TerminalManager.shared.restoreSnapshot
        guard !snapshot.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "退出 Leader?"
        a.informativeText = "还有 \(snapshot.count) 个嵌入的会话在运行,退出会杀掉它们的进程(transcript 已持久化,可重新 resume)。"
        let box = NSButton(checkboxWithTitle: "下次启动时恢复这些会话", target: nil, action: nil)
        box.state = Conf.restoreOnQuit ? .on : .off   // dialog remembers the last choice
        box.sizeToFit()
        a.accessoryView = box
        a.addButton(withTitle: "退出")
        a.addButton(withTitle: "取消")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        let restore = box.state == .on
        Conf.save(["restore_on_quit": restore])
        if restore {
            RestoreState.save(RestoreFile(sessions: snapshot,
                                          active: TerminalManager.shared.lastActiveSid))
        } else {
            RestoreState.clear()   // stale file from an earlier quit must not resurrect
        }
        return .terminateNow
    }

    // Show banners even when Leader is frontmost — you may be watching one session's
    // terminal while another finishes.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    // Click a banner -> focus Leader and open that session.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sid = response.notification.request.content.userInfo["sid"] as? String {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .leaderOpenSession, object: sid)
        }
        completionHandler()
    }
}
