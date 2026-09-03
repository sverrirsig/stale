import Foundation

struct GitHubUser: Decodable, Equatable {
    let login: String
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

struct RateLimitInfo: Equatable {
    let remaining: Int
    let resetAt: Date?
}

enum GitHubError: LocalizedError {
    case invalidBaseURL
    case unauthorized
    case rateLimited(resetAt: Date?)
    case http(status: Int, message: String)
    case graphQL([String])
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The API base URL is not a valid http(s) URL."
        case .unauthorized:
            return "GitHub rejected the token (401). Check that it is valid and has the right scopes."
        case .rateLimited(let resetAt):
            if let resetAt {
                return "GitHub rate limit reached. Resets at \(resetAt.formatted(date: .omitted, time: .shortened))."
            }
            return "GitHub rate limit reached."
        case .http(let status, let message):
            return "GitHub returned HTTP \(status): \(message)"
        case .graphQL(let messages):
            return messages.joined(separator: " ")
        case .invalidResponse:
            return "Unexpected response from GitHub."
        }
    }
}

/// Thin GitHub API wrapper. REST is used for token validation; a single GraphQL request
/// pulls every open PR the user authored, together with review decision and CI rollup,
/// so one poll costs one round-trip.
struct GitHubClient: Sendable {
    struct FetchResult {
        let pullRequests: [PullRequest]
        /// The signed-in user plus the organizations they belong to, for the org filter.
        let owners: [RepoOwner]
        let rateLimit: RateLimitInfo?
    }

    let restBaseURL: URL
    let graphQLURL: URL
    private let token: String
    private let session: URLSession

    /// - Parameter apiBase: `https://api.github.com` or `https://ghe.example.com/api/v3`.
    init(apiBase: String, token: String, session: URLSession = .shared) throws {
        var trimmed = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else {
            throw GitHubError.invalidBaseURL
        }

        restBaseURL = url
        if trimmed.lowercased().hasSuffix("/api/v3") {
            // GitHub Enterprise Server: REST lives at /api/v3, GraphQL at /api/graphql.
            graphQLURL = URL(string: String(trimmed.dropLast("/v3".count)) + "/graphql")!
        } else {
            // github.com (and anything else): <base>/graphql
            graphQLURL = url.appending(path: "graphql")
        }
        self.token = token
        self.session = session
    }

    // MARK: - Public API

    /// `GET /user` — cheapest way to prove the token works.
    func validateToken() async throws -> GitHubUser {
        var request = makeRequest(url: restBaseURL.appending(path: "user"))
        request.httpMethod = "GET"
        let (data, _) = try await perform(request)
        return try Self.decoder.decode(GitHubUser.self, from: data)
    }

    func fetchOpenPullRequests() async throws -> FetchResult {
        var request = makeRequest(url: graphQLURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["query": Self.searchQuery])

        let (data, response) = try await perform(request)
        let envelope = try Self.decoder.decode(GraphQLResponse.self, from: data)

        if let errors = envelope.errors, !errors.isEmpty {
            if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
                throw GitHubError.rateLimited(resetAt: Self.rateLimit(from: response)?.resetAt)
            }
            // Partial data can still be usable; only fail if we got nothing back.
            if envelope.data == nil {
                throw GitHubError.graphQL(errors.map(\.message))
            }
        }
        guard let payload = envelope.data else { throw GitHubError.invalidResponse }

        // Non-PR hits and null nodes decode as empty and are dropped here.
        let pullRequests = (payload.authored?.nodes ?? []).compactMap { $0?.toPullRequest() }

        var owners: [RepoOwner] = []
        if let viewer = payload.viewer {
            owners.append(RepoOwner(login: viewer.login, avatarURL: viewer.avatarUrl, isViewer: true))
            for org in viewer.organizations?.nodes ?? [] {
                if let org { owners.append(RepoOwner(login: org.login, avatarURL: org.avatarUrl, isViewer: false)) }
            }
        }

        let headerLimit = Self.rateLimit(from: response)
        let bodyLimit = payload.rateLimit.map { RateLimitInfo(remaining: $0.remaining, resetAt: $0.resetAt) }

        return FetchResult(
            pullRequests: pullRequests,
            owners: owners,
            rateLimit: bodyLimit ?? headerLimit
        )
    }

    // MARK: - Plumbing

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Stale-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, urlResponse) = try await session.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse else { throw GitHubError.invalidResponse }

        switch response.statusCode {
        case 200..<300:
            return (data, response)
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            let limit = Self.rateLimit(from: response)
            if response.statusCode == 429 || limit?.remaining == 0 {
                throw GitHubError.rateLimited(resetAt: limit?.resetAt)
            }
            throw GitHubError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        default:
            throw GitHubError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        }
    }

    private static func rateLimit(from response: HTTPURLResponse) -> RateLimitInfo? {
        guard let remainingString = response.value(forHTTPHeaderField: "x-ratelimit-remaining"),
              let remaining = Int(remainingString) else { return nil }
        let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        return RateLimitInfo(remaining: remaining, resetAt: reset)
    }

    private static func errorMessage(from data: Data) -> String {
        struct Body: Decodable { let message: String? }
        if let body = try? JSONDecoder().decode(Body.self, from: data), let message = body.message {
            return message
        }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? "no details"
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Open PRs authored by the token's owner (`@me` resolves server-side), plus the
    /// viewer's organizations for the filter. Capped at 100 PRs — plenty for one person's
    /// open PRs; pagination is a non-goal.
    static let searchQuery = """
    query StaleOpenPullRequests {
      viewer {
        login
        avatarUrl
        organizations(first: 100) { nodes { login avatarUrl } }
      }
      authored: search(query: "is:pr is:open archived:false author:@me", type: ISSUE, first: 100) {
        nodes {
        ... on PullRequest {
          id
          title
          number
          url
          createdAt
          updatedAt
          isDraft
          author { login avatarUrl }
          repository { nameWithOwner }
          reviewDecision
          commits(last: 1) {
            nodes { commit { statusCheckRollup { state } } }
          }
        }
      }
      }
      rateLimit { remaining resetAt }
    }
    """
}

// MARK: - GraphQL wire types (private to the client)

private struct GraphQLResponse: Decodable {
    let data: SearchData?
    let errors: [GraphQLErrorEntry]?
}

private struct GraphQLErrorEntry: Decodable {
    let message: String
    let type: String?
}

private struct SearchData: Decodable {
    let viewer: ViewerNode?
    let authored: SearchConnection?
    let rateLimit: RateLimitNode?
}

private struct ViewerNode: Decodable {
    struct Organizations: Decodable {
        struct Org: Decodable { let login: String; let avatarUrl: URL? }
        let nodes: [Org?]
    }
    let login: String
    let avatarUrl: URL?
    let organizations: Organizations?
}

private struct RateLimitNode: Decodable {
    let remaining: Int
    let resetAt: Date?
}

private struct SearchConnection: Decodable {
    let nodes: [PullRequestNode?]
}

/// Every field is optional because non-PR search hits decode as `{}`.
private struct PullRequestNode: Decodable {
    struct Actor: Decodable { let login: String; let avatarUrl: URL? }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Commits: Decodable {
        struct Node: Decodable {
            struct Commit: Decodable {
                struct Rollup: Decodable { let state: String }
                let statusCheckRollup: Rollup?
            }
            let commit: Commit
        }
        let nodes: [Node]
    }

    let id: String?
    let title: String?
    let number: Int?
    let url: URL?
    let createdAt: Date?
    let updatedAt: Date?
    let isDraft: Bool?
    let author: Actor?
    let repository: Repository?
    let reviewDecision: String?
    let commits: Commits?

    func toPullRequest() -> PullRequest? {
        guard let id, let title, let number, let url, let createdAt, let updatedAt, let repository else {
            return nil
        }
        return PullRequest(
            id: id,
            title: title,
            number: number,
            repository: repository.nameWithOwner,
            authorLogin: author?.login ?? "ghost",
            authorAvatarURL: author?.avatarUrl,
            url: url,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isDraft: isDraft ?? false,
            reviewStatus: Self.reviewStatus(from: reviewDecision),
            ciStatus: Self.ciStatus(from: commits?.nodes.first?.commit.statusCheckRollup?.state)
        )
    }

    private static func reviewStatus(from decision: String?) -> ReviewStatus {
        switch decision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .pending
        default: return .none
        }
    }

    private static func ciStatus(from state: String?) -> CIStatus {
        switch state {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        case "PENDING", "EXPECTED": return .pending
        default: return .unknown
        }
    }
}
