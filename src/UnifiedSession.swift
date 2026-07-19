// UnifiedSession.swift — the cross-provider session model (AnySession), the
// per-provider override stores (archive/pin/unread/nickname), and the shared
// brand-logo loader. This is the layer that lets ONE list view render Claude,
// Codex and Kimi sessions together.
import Foundation
import AppKit

// MARK: - AnySession: the union of all three providers' scan output.
//
// The three scan scripts share only 7 fields (full_sid/sid/title/cwd/resume_cwd/
// idle_h/file). Anything richer (branch, alive, asks, errored, …) is Claude-only
// and stays Optional/defaulted — UI that depends on it degrades per-capability
// (see hasActivitySignals) instead of faking state for Codex/Kimi.
struct AnySession: Identifiable, Equatable {
    let kind: TerminalKind
    let full_sid: String
    let sid: String
    var title: String?
    var cwd: String?
    var resume_cwd: String?
    var idle_h: Double

    // Leader-side overrides. Claude's arrive pre-merged by scan.py; Codex/Kimi's
    // are replayed from their JsonOverrideStore after each scan.
    var archived = false
    var pinned = false
    // Position in the pin list (= pin time). nil sorts last, matching the
    // append-on-add behavior of both pin.py and JsonOverrideStore.
    var pin_order: Int? = nil
    var unread = false
    var nickname: String? = nil

    // Claude-only enrichment (nil/false for Codex/Kimi).
    var last_prompt: String? = nil
    var branch: String? = nil
    var alive = false
    var asks = false
    var errored = false
    var error_text: String? = nil

    /// Identity key, unique across providers: "claude:<sid>" / "codex:<sid>" /
    /// "kimi:<sid>". Used for list selection, hover, and the last-opened store.
    var id: String { "\(kind.rawValue):\(full_sid)" }
    /// TerminalManager key. Claude stays BARE (legacy contract: restore.json and
    /// the running/exited sets predate namespacing); codex/kimi equal `id`.
    var termKey: String { kind == .claude ? full_sid : id }

    var name: String {
        if let n = nickname, !n.isEmpty { return n }
        if let t = title, !t.isEmpty { return t }
        return last_prompt ?? "(无标题)"
    }
    var repo: String {
        let home = NSHomeDirectory()
        return (cwd ?? "?").replacingOccurrences(of: home + "/dev/", with: "")
                           .replacingOccurrences(of: home + "/", with: "~/")
    }
    var ago: String { idle_h < 48 ? "\(Int(idle_h.rounded()))h" : "\(Int((idle_h / 24).rounded()))d" }
    var isStale: Bool { idle_h >= 15 * 24 }     // 最后消息 ≥ 15 天

    // MARK: capability flags — menu items and row decorations key off these.
    /// Hook pipeline (Activity running/attention, errored, asks): Claude only.
    var hasActivitySignals: Bool { kind == .claude }
    /// "在 kitty 窗口打开" escape hatch (launch.py): Claude only.
    var canOpenInKitty: Bool { kind == .claude }
    /// In-app new session: claude via --session-id, kimi via bare `kimi` +
    /// synthetic sid. Codex has no --session-id equivalent, so no quick-create.
    var canCreate: Bool { kind != .codex }
}

// MARK: - Adapters from the three scan outputs (their decode structs stay the
// wire contract with the python backend; UI only ever sees AnySession).
extension AnySession {
    init(_ s: Session) {            // Claude: flags arrive pre-merged by scan.py
        kind = .claude
        full_sid = s.full_sid; sid = s.sid
        title = s.title; cwd = s.cwd; resume_cwd = s.resume_cwd; idle_h = s.idle_h
        archived = s.archived; pinned = s.pinned; pin_order = s.pin_order
        unread = s.unread; nickname = s.nickname
        last_prompt = s.last_prompt; branch = s.branch
        alive = s.alive; asks = s.asks; errored = s.errored; error_text = s.error_text
    }
    init(_ s: KimiSession) {        // overrides replayed by SessionStore
        kind = .kimi
        full_sid = s.full_sid; sid = s.sid
        title = s.title; cwd = s.cwd; resume_cwd = s.resume_cwd; idle_h = s.idle_h
    }
    init(_ s: CodexSession) {       // overrides replayed by SessionStore
        kind = .codex
        full_sid = s.full_sid; sid = s.sid
        title = s.title; cwd = s.cwd; resume_cwd = s.resume_cwd; idle_h = s.idle_h
    }
}

// MARK: - termKey parsing
// TerminalManager keys: claude bare, others "kind:<sid>". Splits such a key back
// into (kind, raw sid). Used by close/restore/embed-fallback paths.
func kindAndSid(fromTermKey key: String) -> (TerminalKind, String) {
    for k in [TerminalKind.kimi, .codex] {
        let prefix = k.rawValue + ":"
        if key.hasPrefix(prefix) { return (k, String(key.dropFirst(prefix.count))) }
    }
    return (.claude, key)
}

extension TerminalKind {
    /// In-app new session possible: claude via --session-id, kimi via bare `kimi`
    /// + synthetic sid. Codex has no --session-id equivalent.
    var canCreate: Bool { self != .codex }
}

// MARK: - Override stores (归档/置顶/未读/重命名)
// One protocol, two backends. Storage contracts are deliberately UNCHANGED:
// Claude keeps its python scripts + ~/.claude/leader/*.json (external tools read
// them, and scan.py merges the flags into its output); Codex/Kimi keep the
// Kimi-style single JSON per provider under ~/.config/leader/.
protocol SessionOverrideStore {
    /// Apply stored flags onto a freshly scanned session (no-op for Claude —
    /// scan.py already merged them).
    func replay(_ s: inout AnySession)
    func setArchived(_ s: AnySession, _ on: Bool)
    func setPinned(_ s: AnySession, _ on: Bool, order: Int?)
    func setUnread(_ s: AnySession, _ on: Bool)
    func setNickname(_ s: AnySession, _ nick: String?)
}

// Claude: flags live in ~/.claude/leader/{archived,pinned,unread,names}.json,
// written by the python scripts (Backend). scan.py merges them, so replay is a
// no-op and the write side must round-trip through a rescan (Store's epoch
// guards the optimistic state in the meantime).
struct ClaudeOverrideStore: SessionOverrideStore {
    func replay(_ s: inout AnySession) {}
    func setArchived(_ s: AnySession, _ on: Bool) { Backend.setArchived(sid: s.full_sid, on: on) }
    func setPinned(_ s: AnySession, _ on: Bool, order: Int?) { Backend.setPinned(sid: s.full_sid, on: on) }
    func setUnread(_ s: AnySession, _ on: Bool) { Backend.setUnread(sid: s.full_sid, on: on) }
    func setNickname(_ s: AnySession, _ nick: String?) { Backend.setNickname(sid: s.full_sid, nick: nick ?? "") }
}

// Codex/Kimi: one Leader-owned JSON per provider ({sid: override}), written
// atomically. kimi-scan.py / codex-scan.py stay read-only by contract, so flags
// never round-trip through the scanner — they're replayed after each scan.
// Writes are synchronous, so a replay always sees the latest state.
final class JsonOverrideStore: SessionOverrideStore {
    struct Entry: Codable {
        var nickname: String?
        var archived: Bool?
        var pinned: Bool?
        var pin_order: Int?
        var unread: Bool?
        var isEmpty: Bool {
            nickname == nil && archived == nil && pinned == nil && pin_order == nil && unread == nil
        }
    }
    private let path: String
    private var cache: [String: Entry]?
    init(path: String) { self.path = NSString(string: path).expandingTildeInPath }

    private func all() -> [String: Entry] {
        if let cache { return cache }
        let d = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
            try? JSONDecoder().decode([String: Entry].self, from: $0)
        } ?? [:]
        cache = d
        return d
    }
    private func update(_ sid: String, _ f: (inout Entry) -> Void) {
        var m = all()
        var e = m[sid] ?? Entry()
        f(&e)
        if e.isEmpty { m.removeValue(forKey: sid) } else { m[sid] = e }
        cache = m
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: url, options: .atomic)   // atomic: tmp + rename, no half files
        }
    }

    func replay(_ s: inout AnySession) {
        let o = all()[s.full_sid] ?? Entry()
        s.archived = o.archived ?? false
        s.pinned = o.pinned ?? false
        s.pin_order = o.pin_order
        s.unread = o.unread ?? false
        s.nickname = o.nickname
    }
    func setArchived(_ s: AnySession, _ on: Bool) { update(s.full_sid) { $0.archived = on ? true : nil } }
    func setPinned(_ s: AnySession, _ on: Bool, order: Int?) {
        update(s.full_sid) { $0.pinned = on ? true : nil; $0.pin_order = on ? order : nil }
    }
    func setUnread(_ s: AnySession, _ on: Bool) { update(s.full_sid) { $0.unread = on ? true : nil } }
    func setNickname(_ s: AnySession, _ nick: String?) {
        let t = (nick ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        update(s.full_sid) { $0.nickname = t.isEmpty ? nil : t }
    }
}

enum SessionOverrides {
    static let claude = ClaudeOverrideStore()
    // Path kept from the old KimiOverrides: existing user data loads unchanged.
    static let kimi = JsonOverrideStore(path: "~/.config/leader/kimi-overrides.json")
    static let codex = JsonOverrideStore(path: "~/.config/leader/codex-overrides.json")
    static func store(for kind: TerminalKind) -> SessionOverrideStore {
        switch kind {
        case .claude: return claude
        case .kimi: return kimi
        case .codex: return codex
        }
    }
}

// MARK: - Brand logos, loaded once and pre-downsampled with high-quality
// interpolation. The sources are up to 1000px; shrinking ~7× at draw time
// aliases (the Claude starburst's fine spokes), so we bake them to ~108px once.
// 108px covers every consumer: rail button (28pt) and row logo (15pt) @3x.
enum ProviderLogos {
    static let claude = named("claude-logo")
    static let codex = named("openai-logo")
    static let kimi = named("kimi-logo")
    static func image(for kind: TerminalKind) -> NSImage? {
        switch kind {
        case .claude: return claude
        case .codex: return codex
        case .kimi: return kimi
        }
    }
    static func named(_ name: String) -> NSImage? {
        guard let p = Bundle.main.resourcePath,
              let src = NSImage(contentsOfFile: p + "/\(name).png") else { return nil }
        let side: CGFloat = 108
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                 from: NSRect(origin: .zero, size: src.size),
                 operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}
