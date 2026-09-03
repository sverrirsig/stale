import Foundation

/// Which clock staleness is measured against.
enum StalenessBasis: String, Codable, CaseIterable, Identifiable {
    /// Days since the PR was opened.
    case daysOpen
    /// Days since the PR last saw any activity (push, comment, review…).
    case daysSinceActivity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daysOpen: return "Days open"
        case .daysSinceActivity: return "Days since last activity"
        }
    }
}

/// How the stored token was obtained. Purely informational, shown on the Account tab.
enum TokenSource: String, Codable {
    case gitHubCLI
    case personalAccessToken

    var label: String {
        switch self {
        case .gitHubCLI: return "GitHub CLI"
        case .personalAccessToken: return "personal access token"
        }
    }
}

/// Everything the user can tweak, persisted as one JSON blob in UserDefaults.
/// The GitHub token deliberately lives elsewhere (Keychain).
struct AppSettings: Codable, Equatable {
    /// REST API root. `https://api.github.com` for github.com,
    /// `https://ghe.example.com/api/v3` for GitHub Enterprise Server.
    var apiBaseURL: String = "https://api.github.com"
    var pollIntervalMinutes: Int = 5
    var thresholds: StalenessThresholds = .default
    var basis: StalenessBasis = .daysOpen
    var hideDrafts: Bool = false
    /// Owner logins (lowercased) whose pull requests are hidden. Empty means "show everything",
    /// and new organizations are visible by default.
    var excludedOwners: Set<String> = []

    // Non-sensitive facts about the signed-in account, captured when the token was validated.
    var accountLogin: String?
    var accountAvatarURL: URL?
    var tokenSource: TokenSource?

    static let pollIntervalChoices = [5, 10, 15, 30, 60]
    static let minimumPollInterval = 5

    init() {}

    /// Tolerant decoding: settings written by an older build simply fall back to defaults
    /// for any key they lack, instead of resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiBaseURL = try c.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? apiBaseURL
        pollIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .pollIntervalMinutes) ?? pollIntervalMinutes
        pollIntervalMinutes = max(Self.minimumPollInterval, pollIntervalMinutes)
        thresholds = try c.decodeIfPresent(StalenessThresholds.self, forKey: .thresholds) ?? thresholds
        basis = try c.decodeIfPresent(StalenessBasis.self, forKey: .basis) ?? basis
        hideDrafts = try c.decodeIfPresent(Bool.self, forKey: .hideDrafts) ?? hideDrafts
        excludedOwners = try c.decodeIfPresent(Set<String>.self, forKey: .excludedOwners) ?? excludedOwners
        accountLogin = try c.decodeIfPresent(String.self, forKey: .accountLogin)
        accountAvatarURL = try c.decodeIfPresent(URL.self, forKey: .accountAvatarURL)
        tokenSource = try c.decodeIfPresent(TokenSource.self, forKey: .tokenSource)
    }
}
