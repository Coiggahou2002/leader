// LeaderApp.swift — app entry, window scene, and the left provider rail
// (All / Claude / Codex / Kimi). All session-list UI lives in SessionsView.swift;
// the rail just picks the filter. Follows system Light/Dark; normal window level
// (pin is opt-in).
import SwiftUI
import AppKit

@main
struct LeaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ProviderRootView() }
            .windowStyle(.hiddenTitleBar)              // traffic lights float over content; no titlebar band
            .defaultSize(width: 1200, height: 800)     // first launch only; SwiftUI persists later resizes
            .windowResizability(.contentMinSize)
    }
}

struct ProviderRootView: View {
    // "all" = the All-in-One list; else a TerminalKind rawValue. Persisted so a
    // relaunch lands where you left off (previously it always reset to Claude).
    @AppStorage("leader.providerFilter") private var filterRaw: String = "all"
    private var filter: TerminalKind? {
        filterRaw == "all" ? nil : TerminalKind(rawValue: filterRaw)
    }

    private let items: [(id: String, label: String, png: String?, symbol: String)] = [
        ("all", "全部会话", nil, "square.grid.2x2"),
        ("claude", "Claude", "claude-logo", "sparkles"),
        ("codex", "Codex", "openai-logo", "chevron.left.forwardslash.chevron.right"),
        ("kimi", "Kimi", "kimi-logo", "moon.stars"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            providerRail
            // Subtle separator instead of Divider: a plain Divider reads
            // near-black against the frosted rail when a light wallpaper shows
            // through; primary-at-low-alpha adapts to both scheme and backdrop.
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
            // ONE view type for every rail entry — the filter is just a parameter,
            // so per-tab state (selection, embedded terminal) survives switching.
            SessionsView(filter: filter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear { SessionStore.shared.start() }   // idempotent
    }

    private var providerRail: some View {
        VStack(spacing: 4) {
            // traffic-light safe top inset for the hidden-titlebar window
            Color.clear.frame(height: 28)
            ForEach(items, id: \.id) { item in
                ProviderRailButton(
                    label: item.label,
                    png: item.png,
                    symbol: item.symbol,
                    selected: filterRaw == item.id
                ) {
                    filterRaw = item.id
                }
            }
            Spacer()
        }
        .frame(width: 44)
        .padding(.horizontal, 4)
        .background(VisualEffect().ignoresSafeArea())   // frosted like the sidebar, not opaque
    }
}

struct ProviderRailButton: View {
    let label: String
    var png: String? = nil        // bundle PNG (brand colors); nil = SF Symbol entry
    var symbol: String = "questionmark"
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected
                              ? AnyShapeStyle(Color.primary.opacity(0.14))
                              : (hover ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.clear)))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
    }

    @ViewBuilder private var icon: some View {
        if let png, let img = ProviderLogos.named(png) {
            Image(nsImage: img)
                .interpolation(.high)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
        } else {
            // SF Symbol entry (the "All" tile) or PNG-missing fallback.
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
    }
}
