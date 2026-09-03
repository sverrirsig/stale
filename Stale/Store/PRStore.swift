import Foundation
import Observation

enum RateLimitState: Equatable {
    case unknown
    case ok
    case limited(resetAt: Date?)

    var isLimited: Bool {
        if case .limited = self { return true }
        return false
    }
}

/// Central state: the raw PR list, refresh/polling, cache, and the derived
/// filtered + sorted view the UI renders. Everything runs on the main actor.
@MainActor
@Observable
final class PRStore {
    private(set) var pullRequests: [PullRequest] = []
    /// Viewer + organizations as reported by GitHub on the last fetch.
    private(set) var fetchedOwners: [RepoOwner] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var rateLimit: RateLimitState = .unknown

    /// Re-set once a minute so "days open" rolls over without a fetch.
    private(set) var now = Date()

    let settings: SettingsStore

    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var settingsDebounceTask: Task<Void, Never>?
    /// The fetch-affecting settings the poll loop was started with.
    private var activeFetchConfig: FetchConfig

    private struct FetchConfig: Equatable {
        var apiBaseURL: String
        var pollIntervalMinutes: Int
        var isSignedIn: Bool
        var tokenSource: TokenSource?
    }

    init(settings: SettingsStore) {
        self.settings = settings
        self.activeFetchConfig = Self.fetchConfig(from: settings)

        if let cached = PRCache.load() {
            pullRequests = cached.pullRequests
            fetchedOwners = cached.owners ?? []
            lastRefresh = cached.fetchedAt
        }

        startPolling()
        startClock()
        observeSettings()
    }

    // MARK: - Derived state for the UI

    var basis: StalenessBasis { settings.settings.basis }
    var thresholds: StalenessThresholds { settings.settings.thresholds }

    /// After the organization and draft filters, sorted most-neglected first.
    var visiblePullRequests: [PullRequest] {
        let config = settings.settings
        let filtered = pullRequests.filter { pr in
            if config.hideDrafts && pr.isDraft { return false }
            return !config.excludedOwners.contains(Self.owner(of: pr).lowercased())
        }
        return Staleness.sorted(filtered, basis: config.basis)
    }

    /// Owners the user can toggle: the account itself, its organizations, and any other owner
    /// of a PR they've opened (e.g. a repo they contribute to as an outside collaborator).
    /// Personal account first, then alphabetical.
    var knownOwners: [RepoOwner] {
        var byID: [String: RepoOwner] = [:]
        for owner in fetchedOwners { byID[owner.id] = owner }
        for pr in pullRequests {
            let login = Self.owner(of: pr)
            if byID[login.lowercased()] == nil {
                byID[login.lowercased()] = RepoOwner(login: login, avatarURL: nil, isViewer: false)
            }
        }
        return byID.values.sorted { a, b in
            if a.isViewer != b.isViewer { return a.isViewer }
            return a.login.localizedCaseInsensitiveCompare(b.login) == .orderedAscending
        }
    }

    /// Open PR count per owner, before filtering, for the Organizations settings list.
    func openCount(for owner: RepoOwner) -> Int {
        pullRequests.filter { Self.owner(of: $0).lowercased() == owner.id }.count
    }

    private static func fetchConfig(from settings: SettingsStore) -> FetchConfig {
        FetchConfig(
            apiBaseURL: settings.settings.apiBaseURL,
            pollIntervalMinutes: settings.settings.pollIntervalMinutes,
            isSignedIn: settings.isSignedIn,
            tokenSource: settings.settings.tokenSource
        )
    }

    static func owner(of pr: PullRequest) -> String {
        String(pr.repository.split(separator: "/", maxSplits: 1).first ?? "")
    }

    func tier(for pr: PullRequest) -> StalenessTier {
        Staleness.tier(pr, thresholds: thresholds, basis: basis, now: now)
    }

    /// Visible PRs grouped by tier, worst tier first, each group already sorted.
    var sections: [(tier: StalenessTier, pullRequests: [PullRequest])] {
        let grouped = Dictionary(grouping: visiblePullRequests, by: tier(for:))
        return StalenessTier.allCases.reversed().compactMap { tier in
            guard let prs = grouped[tier], !prs.isEmpty else { return nil }
            return (tier, prs)
        }
    }

    /// The single tier the menu bar icon reflects. `nil` when nothing is open.
    var worstTier: StalenessTier? {
        visiblePullRequests.map(tier(for:)).max()
    }

    /// Count of PRs in the tiers that need attention (stale + rotten).
    var attentionCount: Int {
        visiblePullRequests.filter { tier(for: $0).needsAttention }.count
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        guard settings.isSignedIn else {
            pullRequests = []
            lastError = nil
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let token = try await settings.currentToken()
            let client = try GitHubClient(apiBase: settings.settings.apiBaseURL, token: token)
            let result = try await client.fetchOpenPullRequests()
            pullRequests = result.pullRequests
            if !result.owners.isEmpty { fetchedOwners = result.owners }
            // Tokens saved by older builds didn't record who they belong to; fill that in.
            if settings.settings.accountLogin == nil, let viewer = result.owners.first(where: \.isViewer) {
                settings.settings.accountLogin = viewer.login
                settings.settings.accountAvatarURL = viewer.avatarURL
            }
            lastRefresh = Date()
            lastError = nil
            rateLimit = .ok
            PRCache.save(.init(pullRequests: result.pullRequests, owners: fetchedOwners, fetchedAt: lastRefresh!))
        } catch GitHubError.rateLimited(let resetAt) {
            // Keep whatever we had; the dropdown shows a warning instead of going blank.
            rateLimit = .limited(resetAt: resetAt)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Background work

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let minutes = max(AppSettings.minimumPollInterval, self.settings.settings.pollIntervalMinutes)
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.now = Date()
            }
        }
    }

    /// Settings edits arrive per keystroke; wait for a pause, then restart polling
    /// only if something that affects fetching actually changed.
    private func observeSettings() {
        Task { [weak self] in
            let changes = NotificationCenter.default.notifications(named: .staleSettingsChanged)
            for await _ in changes {
                guard let self else { return }
                self.settingsDebounceTask?.cancel()
                self.settingsDebounceTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    let config = Self.fetchConfig(from: self.settings)
                    if config != self.activeFetchConfig {
                        self.activeFetchConfig = config
                        if !config.isSignedIn { PRCache.clear() }
                        self.startPolling()
                    }
                }
            }
        }
    }
}
