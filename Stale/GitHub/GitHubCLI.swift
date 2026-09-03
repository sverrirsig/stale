import Foundation

/// Imports a token from the GitHub CLI (`gh`), so users who already ran `gh auth login`
/// never have to create or paste a token by hand. We shell out to `gh auth token` rather
/// than reading gh's config/keychain ourselves, so gh stays the single source of truth
/// for how it stores credentials.
enum GitHubCLI {
    enum CLIError: LocalizedError {
        case notInstalled
        case notLoggedIn(host: String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "GitHub CLI not found. Install it with `brew install gh`, then run `gh auth login`."
            case .notLoggedIn(let host):
                return "gh is not logged in to \(host). Run `gh auth login --hostname \(host)` in a terminal first."
            case .failed(let message):
                return "gh failed: \(message)"
            }
        }
    }

    /// Apps launched from Finder get a minimal PATH, so check the usual install spots explicitly.
    private static let candidatePaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/opt/local/bin/gh",
        "/usr/bin/gh",
        "/run/current-system/sw/bin/gh",
        NSHomeDirectory() + "/.nix-profile/bin/gh",
        NSHomeDirectory() + "/.local/bin/gh",
    ]

    static func locate() -> URL? {
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/gh" }
        for path in candidatePaths + fromPath where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// `gh` keys its logins by hostname, not API URL: `https://api.github.com` → `github.com`,
    /// `https://ghe.example.com/api/v3` → `ghe.example.com`.
    static func hostname(forAPIBase apiBase: String) -> String {
        let host = URL(string: apiBase.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        if host == nil || host == "api.github.com" { return "github.com" }
        return host!
    }

    /// Runs `gh auth token --hostname <host>` off the main thread and returns the token.
    static func token(forHost host: String) async throws -> String {
        guard let gh = locate() else { throw CLIError.notInstalled }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = gh
            process.arguments = ["auth", "token", "--hostname", host]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw CLIError.failed(error.localizedDescription)
            }
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()

            let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !token.isEmpty else {
                let message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
                if message.localizedCaseInsensitiveContains("no oauth token")
                    || message.localizedCaseInsensitiveContains("not logged in")
                    || message.localizedCaseInsensitiveContains("gh auth login") {
                    throw CLIError.notLoggedIn(host: host)
                }
                throw CLIError.failed(message.isEmpty ? "exit code \(process.terminationStatus)" : message)
            }
            return token
        }.value
    }
}
