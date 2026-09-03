import SwiftUI

/// Urgency tier for an open PR. Ordered from least to most neglected so tiers are `Comparable`.
enum StalenessTier: Int, Codable, CaseIterable, Comparable, Identifiable {
    case fresh
    case aging
    case stale
    case rotten

    var id: Int { rawValue }

    static func < (lhs: StalenessTier, rhs: StalenessTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .fresh: return "Fresh"
        case .aging: return "Aging"
        case .stale: return "Stale"
        case .rotten: return "Rotten"
        }
    }

    var color: Color {
        switch self {
        case .fresh: return .green
        case .aging: return .yellow
        case .stale: return .orange
        case .rotten: return .red
        }
    }

    /// True for the tiers that should nag: they drive the menu bar count and icon tint.
    var needsAttention: Bool { self >= .stale }
}

/// Day counts at which a PR *enters* each tier. Anything below `agingDays` is fresh.
struct StalenessThresholds: Codable, Equatable {
    var agingDays: Int = 3
    var staleDays: Int = 7
    var rottenDays: Int = 14

    static let `default` = StalenessThresholds()

    func tier(forDays days: Int) -> StalenessTier {
        if days >= rottenDays { return .rotten }
        if days >= staleDays { return .stale }
        if days >= agingDays { return .aging }
        return .fresh
    }

    /// Smallest legal values: tiers must stay strictly increasing, so stale ≥ 1 and rotten ≥ 2.
    static let minimumAging = 0
    static let minimumStale = 1
    static let minimumRotten = 2

    /// Keeps the thresholds strictly increasing after the user edits one of them.
    /// The threshold that moved wins: it drags its neighbours along in the direction it
    /// travelled, so pushing Stale up bumps Rotten, and pulling Rotten down pulls Stale
    /// (and Aging, if needed) down with it.
    mutating func resolveConflicts(changedFrom old: StalenessThresholds) {
        if agingDays != old.agingDays {
            agingDays = max(Self.minimumAging, agingDays)
            staleDays = max(staleDays, agingDays + 1)
            rottenDays = max(rottenDays, staleDays + 1)
        } else if staleDays != old.staleDays {
            staleDays = max(Self.minimumStale, staleDays)
            if staleDays > old.staleDays {
                rottenDays = max(rottenDays, staleDays + 1)
            } else {
                agingDays = min(agingDays, staleDays - 1)
            }
        } else if rottenDays != old.rottenDays {
            rottenDays = max(Self.minimumRotten, rottenDays)
            if rottenDays < old.rottenDays {
                staleDays = min(staleDays, rottenDays - 1)
                agingDays = min(agingDays, staleDays - 1)
            }
        } else {
            // Nothing the user touched; just make sure stored values are sane.
            agingDays = max(Self.minimumAging, agingDays)
            staleDays = max(agingDays + 1, staleDays)
            rottenDays = max(staleDays + 1, rottenDays)
        }
    }

    /// Human-readable range for a tier, e.g. "3–6 days", "7 days", "14+ days".
    /// Fresh is "—" when Aging starts at 0, since nothing can be fresh then.
    func rangeDescription(for tier: StalenessTier) -> String {
        func span(_ from: Int, _ to: Int) -> String {
            from == to ? "\(from) \(from == 1 ? "day" : "days")" : "\(from)–\(to) days"
        }
        switch tier {
        case .fresh: return agingDays == 0 ? "—" : span(0, agingDays - 1)
        case .aging: return span(agingDays, staleDays - 1)
        case .stale: return span(staleDays, rottenDays - 1)
        case .rotten: return "\(rottenDays)+ days"
        }
    }
}

/// Pure functions for age, tiering and ordering. No I/O, easy to test.
enum Staleness {
    static func wholeDays(from start: Date, to now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start) / 86_400))
    }

    static func daysOpen(_ pr: PullRequest, now: Date) -> Int {
        wholeDays(from: pr.createdAt, to: now)
    }

    static func daysSinceActivity(_ pr: PullRequest, now: Date) -> Int {
        wholeDays(from: pr.updatedAt, to: now)
    }

    /// The number the app is organised around, per the user's chosen basis.
    static func age(_ pr: PullRequest, basis: StalenessBasis, now: Date) -> Int {
        switch basis {
        case .daysOpen: return daysOpen(pr, now: now)
        case .daysSinceActivity: return daysSinceActivity(pr, now: now)
        }
    }

    static func tier(_ pr: PullRequest, thresholds: StalenessThresholds, basis: StalenessBasis, now: Date) -> StalenessTier {
        thresholds.tier(forDays: age(pr, basis: basis, now: now))
    }

    /// Most neglected first. Ties broken by the other clock, so two PRs opened the same
    /// day are ordered by which one has been quiet longest.
    static func sorted(_ prs: [PullRequest], basis: StalenessBasis) -> [PullRequest] {
        prs.sorted { a, b in
            switch basis {
            case .daysOpen:
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.updatedAt < b.updatedAt
            case .daysSinceActivity:
                if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
                return a.createdAt < b.createdAt
            }
        }
    }
}
