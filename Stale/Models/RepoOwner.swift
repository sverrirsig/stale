import Foundation

/// A GitHub user or organization that owns repositories: the unit the org filter works on.
struct RepoOwner: Codable, Hashable, Identifiable {
    let login: String
    let avatarURL: URL?
    /// True for the signed-in user's own account (their personal repositories).
    let isViewer: Bool

    /// Logins are case-insensitive on GitHub.
    var id: String { login.lowercased() }
}
