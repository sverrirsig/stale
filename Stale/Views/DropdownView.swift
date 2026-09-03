import SwiftUI

/// The popover shown when the menu bar icon is clicked.
struct DropdownView: View {
    @Environment(PRStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openSettings) private var openSettings

    /// Measured height of the PR list content, so the scroll view can be sized explicitly.
    /// A ScrollView has no useful intrinsic height inside a MenuBarExtra window.
    @State private var listContentHeight: CGFloat = 0

    /// Measured height of the whole popover, used to trigger a window re-fit.
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
        .background(MenuBarWindowFitter(contentHeight: rootHeight))
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.sections, id: \.tier) { section in
                        sectionHeader(section.tier, count: section.pullRequests.count)
                        ForEach(section.pullRequests) { pr in
                            PRRowView(pullRequest: pr, store: store)
                        }
                    }
                }
                .padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    listContentHeight = height
                }
            }
            .frame(height: min(max(listContentHeight, 60), maxListHeight))
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


/// `MenuBarExtra(.window)` grows its popover to fit new content but never shrinks it back,
/// so hiding an organisation — or merging a batch of PRs — leaves the window padded with
/// dead space around a now-short list. Nudge the hosting window to re-fit when the content
/// gets shorter, pinning the top edge so the popover stays anchored under the menu bar.
///
/// Deliberately shrink-only: SwiftUI already handles growth correctly, and resizing in both
/// directions risks fighting its layout pass.
private struct MenuBarWindowFitter: NSViewRepresentable {
    /// Not read directly — its only job is to make SwiftUI re-run `updateNSView` on resize.
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        shrinkToFit(view, passesLeft: 4)
    }

    /// One resize is not always enough: `fittingSize` can still report the pre-layout height on
    /// the first pass, which leaves a sliver of dead space behind. Re-check after each resize and
    /// stop as soon as the height stops changing. Bounded so a disagreement between AppKit and
    /// SwiftUI can never spin.
    private func shrinkToFit(_ view: NSView, passesLeft: Int) {
        guard passesLeft > 0 else { return }
        // No window during the first update pass, and SwiftUI is mid-layout; settle first.
        DispatchQueue.main.async {
            guard let window = view.window, let content = window.contentView else { return }
            let fitting = content.fittingSize
            guard fitting.height > 0, fitting.height < content.frame.height - 0.5 else { return }

            let top = window.frame.maxY
            window.setContentSize(fitting)
            var frame = window.frame
            frame.origin.y = top - frame.height
            window.setFrame(frame, display: true)

            shrinkToFit(view, passesLeft: passesLeft - 1)
        }
    }
}
