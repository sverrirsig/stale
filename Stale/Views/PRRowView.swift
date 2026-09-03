import SwiftUI

/// One PR in the dropdown. The whole row is a button that opens the PR in the browser.
struct PRRowView: View {
    let pullRequest: PullRequest
    let tier: StalenessTier
    let primaryDays: Int
    let secondaryDays: Int
    let basis: StalenessBasis

    @State private var isHovering = false

    var body: some View {
        Button {
            AppActions.open(pullRequest.url)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tier.color)
                    .frame(width: 3)
                    .padding(.vertical, 2)

                avatar

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pullRequest.repository)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if pullRequest.isDraft {
                            tag("Draft")
                        }
                    }
                    Text(pullRequest.title)
                        .font(.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        Text("#\(pullRequest.number) · \(pullRequest.authorLogin)")
                        reviewIndicator
                        ciIndicator
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(primaryDays)d")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tier.color)
                    Text(secondaryLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isHovering ? Color.primary.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    // MARK: - Pieces

    private var avatar: some View {
        AsyncImage(url: pullRequest.authorAvatarURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.quaternary)
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var reviewIndicator: some View {
        switch pullRequest.reviewStatus {
        case .approved:
            Label("Approved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .changesRequested:
            Label("Changes requested", systemImage: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.orange)
        case .pending:
            Label("Review pending", systemImage: "eye")
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var ciIndicator: some View {
        switch pullRequest.ciStatus {
        case .passing:
            Label("CI passing", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
        case .failing:
            Label("CI failing", systemImage: "xmark.octagon")
                .foregroundStyle(.red)
        case .pending:
            Label("CI running", systemImage: "circle.dotted")
        case .unknown:
            EmptyView()
        }
    }

    private var secondaryLabel: String {
        switch basis {
        case .daysOpen: return "\(secondaryDays)d idle"
        case .daysSinceActivity: return "open \(secondaryDays)d"
        }
    }

    private var helpText: String {
        "\(pullRequest.title)\nOpened \(pullRequest.createdAt.formatted(date: .abbreviated, time: .omitted)) · last activity \(pullRequest.updatedAt.formatted(.relative(presentation: .named)))"
    }
}

extension PRRowView {
    /// Convenience so the dropdown doesn't repeat the age arithmetic.
    init(pullRequest: PullRequest, store: PRStore) {
        let now = store.now
        let basis = store.basis
        let open = Staleness.daysOpen(pullRequest, now: now)
        let idle = Staleness.daysSinceActivity(pullRequest, now: now)
        self.init(
            pullRequest: pullRequest,
            tier: store.tier(for: pullRequest),
            primaryDays: basis == .daysOpen ? open : idle,
            secondaryDays: basis == .daysOpen ? idle : open,
            basis: basis
        )
    }
}
