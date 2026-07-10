// DesignSystem.swift — shared visual constants and low-level chrome
// (colors, hover style, frosted background, overlay-scroller styling).
// Split out of LeaderApp.swift; pure move, no logic changes.
import SwiftUI
import AppKit

// MARK: - Shared design constants
enum DS {
    static let gap: CGFloat = 6
    static let rowPadV: CGFloat = 8
    static let rowPadH: CGFloat = 10
    static let corner: CGFloat = 9
    static let panelWidth: CGFloat = 320
    static let menuZone: CGFloat = 34      // trailing hit-zone: opens the ••• menu
}

// Flat, opaque sidebar fill (Codex-style). Solid so it reads uniform all the way
// to the top edge under the transparent titlebar — a VisualEffect material renders
// a darker band where the titlebar overlaps it.
let sidebarBGColor = NSColor(name: nil) { app in
    app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.145, alpha: 1)   // ~#252525
        : NSColor(calibratedWhite: 0.96, alpha: 1)
}

// Neutral hover/press highlight for sidebar nav rows (no accent tint).
struct HoverRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: DS.corner)
                .fill(hover ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.clear)))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hover = $0 }
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

// Low-contrast overlay scrollbar knob (Codex-like). The system .light knob on a
// dark UI is glaringly bright; draw a subtle rounded knob and no track instead.
final class SubtleScroller: NSScroller {
    var isDark = true
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slot: NSRect, highlight: Bool) { /* no track */ }
    override func drawKnob() {
        let r = rect(for: .knob).insetBy(dx: 3, dy: 3)
        guard r.width > 1, r.height > 1 else { return }
        let a: CGFloat = isDark ? 0.22 : 0.24
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(a).setFill()
        let radius = min(r.width, r.height) / 2
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - 滚动条暗色适配:overlay 细滚动条 + 低对比 knob(参考 Codex)
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
            if !(sv.verticalScroller is SubtleScroller) {
                let s = SubtleScroller()
                s.scrollerStyle = .overlay
                sv.verticalScroller = s
            }
            (sv.verticalScroller as? SubtleScroller)?.isDark = dark
            sv.verticalScroller?.appearance = ap
            sv.verticalScroller?.needsDisplay = true
            sv.drawsBackground = false
            sv.backgroundColor = .clear
        }
        DispatchQueue.main.async { apply(5) }
    }
}
