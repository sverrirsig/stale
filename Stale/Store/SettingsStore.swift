import Foundation
import Observation

extension Notification.Name {
    /// Posted on the main queue whenever `SettingsStore.settings` changes.
    static let staleSettingsChanged = Notification.Name("StaleSettingsChanged")
}

enum SignInError: LocalizedError {
    case tokenMissing

    var errorDescription: String? {
        "The saved token is no longer in your Keychain. Sign in again from Settings."
    }
}

/// Owns user settings (UserDefaults) and knows how to obtain the GitHub token.
///
/// Two sign-in modes:
/// - **GitHub CLI**: nothing is stored. Each refresh asks `gh auth token`, which already
///   guards the credential, so Stale never touches the Keychain and never triggers a prompt.
/// - **Personal access token**: the pasted token lives in the Keychain.
@MainActor
@Observable
final class SettingsStore {
    private static let defaultsKey = "stale.settings"

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            NotificationCenter.default.post(name: .staleSettingsChanged, object: nil)
        }
    }

    /// True once the user has connected an account by either method.
    /// The token itself is never held here.
    private(set) var isSignedIn: Bool

    init() {
        var loaded = AppSettings()
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loaded = decoded
        }
        settings = loaded

        switch loaded.tokenSource {
        case .gitHubCLI:
            isSignedIn = true
            // Earlier builds also copied CLI tokens into the Keychain; that copy is no longer needed.
            try? KeychainStore.deleteToken()
        case .personalAccessToken, nil:
            isSignedIn = KeychainStore.loadToken() != nil
        }
    }

    /// Resolves the token for a request. Throws with a user-facing message if it can't.
    func currentToken() async throws -> String {
        switch settings.tokenSource {
        case .gitHubCLI:
            return try await GitHubCLI.token(forHost: GitHubCLI.hostname(forAPIBase: settings.apiBaseURL))
        case .personalAccessToken, nil:
            guard let token = KeychainStore.loadToken() else { throw SignInError.tokenMissing }
            return token
        }
    }

    /// Records a sign-in whose token has already been validated.
    func signIn(token: String, account: GitHubUser, source: TokenSource) throws {
        switch source {
        case .gitHubCLI:
            try? KeychainStore.deleteToken()   // gh owns the credential from here on
        case .personalAccessToken:
            try KeychainStore.saveToken(token)
        }
        isSignedIn = true
        settings.accountLogin = account.login
        settings.accountAvatarURL = account.avatarURL
        settings.tokenSource = source
        NotificationCenter.default.post(name: .staleSettingsChanged, object: nil)
    }

    func signOut() throws {
        try KeychainStore.deleteToken()
        isSignedIn = false
        settings.accountLogin = nil
        settings.accountAvatarURL = nil
        settings.tokenSource = nil
        NotificationCenter.default.post(name: .staleSettingsChanged, object: nil)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
