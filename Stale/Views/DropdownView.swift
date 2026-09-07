import SwiftUI

/// The popover shown when the menu bar icon is clicked.
struct DropdownView: View {
    @Environment(PRStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openSettings) private var openSettings

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
        .background(PopoverTopAnchor())
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

/// Keeps the popover hanging from the menu bar when its content changes height.
///
/// `MenuBarExtra(.window)` resizes its window around the centre, so when the list gets
/// shorter (hiding an organisation in Settings, PRs merging) the top edge drops by half the
/// change and the popover floats below the menu bar with nothing above it. The resize usually
/// happens while the popover is closed, and the window is not re-anchored when it reopens, so
/// the drift is fixed here on every height change whether or not the window is on screen.
///
/// The anchor is the top edge last seen while the window was visible with its height
/// unchanged: that is where MenuBarExtra put it. Repositioning on show (a different screen,
/// the status item moving) arrives as a move with the height unchanged, so it updates the
/// anchor instead of being undone.
private struct PopoverTopAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var lastFrame: NSRect?
        /// Top edge (in screen coordinates) the window should keep.
        private var anchorTop: CGFloat?
        private var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observedWindow {
                NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow)
            }
            observedWindow = window
            anchorTop = nil
            lastFrame = window?.frame
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            noteAnchor(window)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowChanged(_ note: Notification) {
            guard let window, window == note.object as? NSWindow else { return }
            defer { lastFrame = window.frame }
            var frame = window.frame
            let heightChanged = lastFrame.map { abs(frame.height - $0.height) > 0.5 } ?? false
            guard heightChanged else {
                noteAnchor(window)
                return
            }
            guard let anchorTop, abs(frame.maxY - anchorTop) > 0.5 else { return }
            frame.origin.y = anchorTop - frame.height
            window.setFrame(frame, display: true)
        }

        /// Trust the window's position only while it is on screen; hidden windows can be resized
        /// around their centre before anything has placed them.
        private func noteAnchor(_ window: NSWindow) {
            guard window.isVisible else { return }
            anchorTop = window.frame.maxY
        }
    }
}
