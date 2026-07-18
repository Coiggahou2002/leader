// RowViews.swift — sidebar row visuals (shimmer, badges, Row, headers)
// and the AppKit mouse layer they sit on.
// Split out of LeaderApp.swift; pure move, no logic changes.
import SwiftUI
import AppKit

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

// A pulsing yellow warning for a session whose last turn died mid-response on an API
// error / dropped connection and never resumed (scan.py: errored). It still looks
// alive (the claude REPL is idling at its prompt), but is stuck until you re-send —
// this surfaces that at a glance. Distinct color+shape from the purple 呼吸灯 (done).
struct ErrorPulse: View {
    @State private var on = false
    var help: String
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.yellow)
            .opacity(on ? 1.0 : 0.3)
            .shadow(color: .yellow.opacity(on ? 0.6 : 0), radius: on ? 3 : 0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .help(help)
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

// MARK: - Row
// Renders any provider's session (AnySession). The left edge carries the
// provider's brand logo so the All-in-One list shows where each session lives.
// Claude-only decorations (shimmer / breathing dot / ErrorPulse) are inert for
// other providers: their `alive`/`errored` are always false and the Activity
// sets only ever contain Claude sids.
struct Row: View {
    let s: AnySession
    let onOpen: () -> Void
    let onArchive: () -> Void
    var onPin: () -> Void = {}
    var onRename: () -> Void = {}
    var onMarkUnread: () -> Void = {}
    var selected: Bool = false
    // The embedded-terminal badge is redundant in the 活跃 tab (every row there is,
    // by definition, term.running) — that list passes false to hide it.
    var showEmbedBadge: Bool = true
    @Binding var hoveredID: String?
    @ObservedObject var term = TerminalManager.shared   // embed state (running/exited)
    @ObservedObject var activity = Activity.shared       // turn-completion pulse
    // single shared hovered id -> at most one row highlights, even mid-scroll
    private var hover: Bool { hoveredID == s.id }
    // embedded-terminal badge: filled while the in-app CLI process is alive,
    // hollow once it exits, nothing if never embedded. Quiet grey either way —
    // "actively working" is signalled by the title shimmer, not by color here.
    private var embedSymbol: String? {
        if term.running.contains(s.termKey) { return "terminal.fill" }
        if term.exited.contains(s.termKey) { return "terminal" }
        return nil
    }
    // Guard on s.alive so a crashed session (no Stop event) can't shimmer forever.
    // Also suppress when errored: a turn that died on an API error looks "running"
    // (no Stop fired) but is stuck — it must read as a warning, not as in-progress.
    private var isWorking: Bool { activity.running.contains(s.full_sid) && s.alive && !s.errored }
    // Archive affordances derive from the session's own state — never passed in
    // by the surrounding list, so a row can't show 取消归档 after it moved back
    // to the active tab (or vice versa). Pin/unread only make sense un-archived.
    private var archiveSymbol: String { s.archived ? "tray.and.arrow.up" : "archivebox" }
    private var archiveTitle: String { s.archived ? "取消归档" : "归档" }
    private var canPinOrUnread: Bool { !s.archived }

    var body: some View {
        HStack(spacing: 6) {
            // Provider brand mark (All-in-One: shows where this session lives).
            if let logo = ProviderLogos.image(for: s.kind) {
                Image(nsImage: logo).interpolation(.high).resizable().scaledToFit()
                    .frame(width: 15, height: 15)
                    .help(providerLabel(s.kind))
            }
            Text(s.name).font(.system(size: 14)).lineLimit(1)
                .workingShimmer(isWorking)
            if s.unread { UnreadBadge() }
            if showEmbedBadge, let sym = embedSymbol {
                Image(systemName: sym).font(.caption2).foregroundStyle(.secondary)
                    .help(sym == "terminal.fill" ? "已嵌入运行" : "已嵌入(进程已退出)")
            }
            if s.errored {
                ErrorPulse(help: s.error_text ?? "上一轮因 API 错误 / 连接中断卡住了,需要你重新发一条消息")
            } else if activity.attention.contains(s.full_sid) {
                BreathingDot()
            }
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
