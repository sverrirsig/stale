import SwiftUI

/// The popover shown when the menu bar icon is clicked.
struct DropdownView: View {
    @Environment(PRStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openSettings) private var openSettings

    /// Measured height of the whole popover, handed to the window fitter below.
    @State private var rootHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            banners
            content
            Divider()
            footer
        }
        .frame(width: 380)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            rootHeight = height
        }
        .background(PopoverWindowFitter(contentHeight: rootHeight))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Stale")
                .font(.headline)
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else if let lastRefresh = store.lastRefresh {
                Text("Updated \(lastRefresh, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if case .limited(let resetAt) = store.rateLimit {
            banner(
                icon: "hourglass",
                text: resetAt.map { "GitHub rate limit hit — showing cached data. Resets at \($0.formatted(date: .omitted, time: .shortened))." }
                    ?? "GitHub rate limit hit — showing cached data.",
                tint: .orange
            )
        }
        if let error = store.lastError {
            banner(icon: "exclamationmark.triangle", text: error, tint: .secondary)
        }
    }

    private func banner(icon: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(3)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !settings.isSignedIn {
            emptyState(
                icon: "key",
                title: "No GitHub token",
                message: "Sign in with the GitHub CLI or paste a personal access token in Settings.",
                action: ("Open Settings…", showSettings)
            )
        } else if store.sections.isEmpty {
            if store.isRefreshing && store.lastRefresh == nil {
                ProgressView("Fetching pull requests…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                emptyState(
                    icon: "checkmark.circle",
                    title: "Nothing open",
                    message: "You have no open pull requests. Enjoy the quiet."
                )
            }
        } else {
            // The MenuBarExtra window sizes itself from this view's ideal height, so the list
            // must report a definite height in the same layout pass as everything else. The
            // layout below measures the rows and caps them, with no measure -> state -> re-layout
            // round trip for the window to catch mid-settle.
            ContentHeightCappedLayout(maxHeight: maxListHeight) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.sections, id: \.tier) { section in
                            sectionHeader(section.tier, count: section.pullRequests.count)
                            ForEach(section.pullRequests) { pr in
                                PRRowView(pullRequest: pr, store: store)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    /// Let the list grow to nearly the full screen so it only scrolls when it truly must.
    /// Leaves room for the menu bar, header/footer, and a little breathing space at the bottom.
    private var maxListHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        return max(300, screenHeight - 140)
    }

    private func sectionHeader(_ tier: StalenessTier, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tier.color)
                .frame(width: 7, height: 7)
            Text(tier.label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("· \(store.thresholds.rangeDescription(for: tier))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func emptyState(icon: String, title: String, message: String, action: (title: String, run: () -> Void)? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    /// `SettingsLink` is inert inside a MenuBarExtra popover because a menu-bar-only app is
    /// never "active". Activate first, then ask SwiftUI to open the Settings scene.
    private func showSettings() {
        AppActions.bringToFront()
        openSettings()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .disabled(store.isRefreshing || !settings.isSignedIn)

            Spacer()

            Button {
                showSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Sizes a `ScrollView` to its content in a single layout pass, capped at `maxHeight`.
///
/// Asked for its ideal size, a `ScrollView` reports its content's height, so measuring the
/// scroll view with an unspecified height gives the list's true height without a `GeometryReader`
/// or a `@State` round trip. Below the cap the list shows in full; above it the scroll view is
/// pinned to the cap and scrolls. Either way the height is settled before the popover window
/// reads it, which is what keeps the window from being sized for the previous content.
private struct ContentHeightCappedLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scrollView = subviews.first else { return .zero }
        let ideal = scrollView.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// Shrinks the popover window back down when its content gets shorter.
///
/// `MenuBarExtra(.window)` grows its window to fit taller content but never shrinks it: after
/// hiding an organisation the window keeps its old height, hangs from the menu bar as before,
/// and SwiftUI centres the now-shorter content inside it. The visible popover then floats
/// below the menu bar with a stretch of transparent window above it (measured live: a 317pt
/// window around 145pt of content). Nothing about the window changes, so this cannot be fixed
/// by reacting to window events; the content height has to be pushed onto the window.
///
/// `fittingSize` on the hosting view reports zero, so the height comes from SwiftUI's own
/// measurement of the root view. Shrink only: growth already works, and resizing both ways
/// would fight SwiftUI's layout.
private struct PopoverWindowFitter: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> FitterView { FitterView() }

    func updateNSView(_ view: FitterView, context: Context) {
        view.contentHeight = contentHeight
        // No window during the first update, and SwiftUI is mid-layout; let it settle first.
        DispatchQueue.main.async { view.shrinkWindowToFit() }
    }

    final class FitterView: NSView {
        var contentHeight: CGFloat = 0

        func shrinkWindowToFit() {
            guard let window, contentHeight > 0 else { return }
            var frame = window.frame
            guard frame.height - contentHeight > 1 else { return }
            frame.origin.y = frame.maxY - contentHeight
            frame.size.height = contentHeight
            window.setFrame(frame, display: true)
        }
    }
}
