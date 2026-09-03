import Foundation

/// One of the user's own open pull requests, normalised from the GitHub API into the fields Stale cares about.
struct PullRequest: Identifiable, Codable, Hashable {
    /// GitHub's global node ID — stable across fetches.
    let id: String
    let title: String
    let number: Int
    /// "owner/name"
    let repository: String
    let authorLogin: String
    let authorAvatarURL: URL?
    let url: URL
    let createdAt: Date
    let updatedAt: Date
    let isDraft: Bool
    let reviewStatus: ReviewStatus
    let ciStatus: CIStatus
}

enum ReviewStatus: String, Codable, Hashable {
    case approved
    case changesRequested
    case pending
    /// No review required / no reviewers involved.
    case none
}

enum CIStatus: String, Codable, Hashable {
    case passing
    case failing
    case pending
    case unknown
}
