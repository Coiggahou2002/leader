// Model.swift — Session/SessionState, the python Backend bridge, and
// Leader's data paths + hook-settings install.
// Split out of LeaderApp.swift; pure move, no logic changes.
import Foundation

enum TerminalKind: String, CaseIterable, Identifiable {
    case claude, codex, kimi
    var id: Self { self }
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
    // scan.py: does the last assistant turn actually ask the user something? Used
    // ONLY to order sessions already known to need you (cμ tiebreak) — never to
    // promote a session INTO the needs-you set. Default keeps old data decodable.
    var asks: Bool = false
    // scan.py: the last turn died mid-response on an API error / dropped connection
    // and never resumed — the session looks "still running" but is stuck until you
    // re-send. error_text is the specific message (row tooltip). Defaults decode-safe.
    var errored: Bool = false
    var error_text: String? = nil
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

// MARK: - Codex/Kimi scan wire contracts
// These structs are only the decode targets for codex-scan.py / kimi-scan.py
// output — the UI never touches them directly (it sees AnySession, which these
// are adapted into). Leader-side flags (archived/pinned/…) are NOT decoded here;
// they're replayed from JsonOverrideStore after each scan.
struct CodexSession: Decodable, Identifiable {
    let full_sid: String
    let sid: String
    let title: String?
    let cwd: String?
    let resume_cwd: String?
    let idle_h: Double
    let file: String?
    var id: String { full_sid }
}

struct KimiSession: Decodable, Identifiable {
    let full_sid: String
    let sid: String
    let title: String?
    let cwd: String?
    let resume_cwd: String?
    let idle_h: Double
    let file: String?
    var id: String { full_sid }
}

// P0 — the single, mutually-exclusive session state the sidebar ranks and groups
// on. Derived ONLY from reliable live signals: the leader-hook turn lifecycle
// (Activity.running / .attention) + scan-derived `alive`. Deliberately NOT from
// transcript heuristics like `asks` — those fired far too often to drive
// attention (see scan.py's removed "needs you" tier). Raw value = attention
// priority, lowest = "most needs you", so a plain rawValue compare sorts the list.
//   doneAway  finished a turn while you weren't looking — unacknowledged, needs you
//   waiting   alive & idle (turn done, acknowledged) — open, awaiting your input
//   working   reasoning right now — busy, does NOT need you
//   closed    no live REPL — historical
enum SessionState: Int, Comparable {
    case doneAway = 0, waiting = 1, working = 2, closed = 3
    static func < (a: SessionState, b: SessionState) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Backend (python scripts)
enum Backend {
    // Python backend ships INSIDE the app bundle (Contents/Resources/backend),
    // so the app is self-contained. Falls back to a dev source path if missing.
    static let dir: String = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("backend").path,
           FileManager.default.fileExists(atPath: r) { return r }
        return NSString(string: "~/dev/leader.wt/embedded-app/src").expandingTildeInPath
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
    static func scanCodex() -> [CodexSession] {
        (try? JSONDecoder().decode([CodexSession].self, from: run(["\(dir)/codex-scan.py", "--json"]))) ?? []
    }
    static func scanKimi() -> [KimiSession] {
        (try? JSONDecoder().decode([KimiSession].self, from: run(["\(dir)/kimi-scan.py", "--json"]))) ?? []
    }
    // Claude-only write scripts (they write ~/.claude/leader/*.json). Codex/Kimi
    // overrides live in JsonOverrideStore instead — see UnifiedSession.swift.
    @discardableResult
    static func open(sid: String, cwd: String) -> Bool {
        let d = run(["\(dir)/launch.py", sid, cwd])
        let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        return (o?["ok"] as? Bool) ?? false
    }
    static func setArchived(sid: String, on: Bool) {
        _ = run(["\(dir)/archive.py", on ? "add" : "remove", sid])
    }
    static func setPinned(sid: String, on: Bool) {
        _ = run(["\(dir)/pin.py", on ? "add" : "remove", sid])
    }
    static func setUnread(sid: String, on: Bool) {
        _ = run(["\(dir)/unread.py", on ? "add" : "remove", sid])
    }
    static func setNickname(sid: String, nick: String) {
        let trimmed = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = trimmed.isEmpty ? run(["\(dir)/name.py", "clear", sid])
                            : run(["\(dir)/name.py", "set", sid, trimmed])
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
    var json: [String: Any] = ["hooks": [
        "UserPromptSubmit": entry, "Stop": entry, "SessionEnd": entry,
    ]]
    // Theme for Leader-spawned claude sessions. Merged over the user's own settings
    // (via --settings), so it affects only sessions we launch and never touches
    // ~/.claude/settings.json. (kimi needs no injection: its tui.toml theme="auto"
    // speaks the same DEC 2031 protocol, see viewDidChangeEffectiveAppearance.)
    //   follow ON  → "auto": claude detects light/dark from the terminal (OSC 11) at
    //                startup AND follows live — it subscribes to DEC mode 2031 at
    //                launch, and EmbeddedTerminalView pushes it a CSI ?997 notification
    //                whenever the appearance flips, so it re-themes without a restart.
    //   follow OFF → "dark": the terminal is pinned to Kaku Dark, so match it.
    json["theme"] = Conf.followAppearance ? "auto" : "dark"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: LeaderPaths.dataDir, withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(withJSONObject: json),
          (try? data.write(to: URL(fileURLWithPath: LeaderPaths.hooksSettings))) != nil
    else { return "" }
    return LeaderPaths.hooksSettings
}
