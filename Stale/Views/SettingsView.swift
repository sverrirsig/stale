import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            RefreshSettingsView()
                .tabItem { Label("Refresh", systemImage: "arrow.clockwise") }
            StalenessSettingsView()
                .tabItem { Label("Staleness", systemImage: "clock") }
            OrganizationSettingsView()
                .tabItem { Label("Organizations", systemImage: "building.2") }
        }
        .frame(width: 500, height: 420)
    }
}

// MARK: - Shared bits

/// Circular avatar with a neutral placeholder while loading or when there is no URL.
struct AvatarView: View {
    let url: URL?
    let size: CGFloat
    var placeholderSymbol = "person.crop.circle.fill"

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: placeholderSymbol)
                .resizable()
                .foregroundStyle(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PRStore.self) private var store

    @State private var tokenInput = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showTokenEntry = false

    private let cliAvailable = GitHubCLI.locate() != nil

    var body: some View {
        Form {
            if settings.isSignedIn, let login = settings.settings.accountLogin {
                signedInSection(login: login)
            } else {
                signedOutSection
            }

            if !settings.isSignedIn || showTokenEntry {
                tokenSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Signed in

    private func signedInSection(login: String) -> some View {
        Section {
            HStack(spacing: 14) {
                AvatarView(url: settings.settings.accountAvatarURL, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(login)")
                        .font(.title3.weight(.semibold))
                    Label {
                        Text("Connected via \(settings.settings.tokenSource?.label ?? "token") · \(host)")
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Menu("Manage") {
                    if cliAvailable {
                        Button("Re-import from GitHub CLI") { importFromGitHubCLI() }
                    }
                    Button(showTokenEntry ? "Hide token field" : "Use a different token…") {
                        showTokenEntry.toggle()
                    }
                    Divider()
                    Button("Sign Out", role: .destructive) { signOut() }
                }
                .fixedSize()
            }
            .padding(.vertical, 4)

            errorRow
        }
    }

    // MARK: Signed out

    private var signedOutSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Text("Connect your GitHub account")
                    .font(.headline)
                Text("Stale only reads your open pull requests. It never writes to GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if cliAvailable {
                    Button {
                        importFromGitHubCLI()
                    } label: {
                        Label("Sign in with GitHub CLI", systemImage: "terminal")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                    .padding(.top, 6)
                    Text("Uses the account from `gh auth login`. Nothing is stored; Stale asks gh each time it refreshes.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("For one-click sign-in, install the GitHub CLI:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    Text("brew install gh && gh auth login")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }

                if isWorking {
                    ProgressView().controlSize(.small).padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            errorRow
        }
    }

    // MARK: Token entry

    private var tokenSection: some View {
        Section {
            HStack(spacing: 8) {
                SecureField("Token", text: $tokenInput, prompt: Text("ghp_… or github_pat_…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button("Save") {
                    validateAndSave(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines), source: .personalAccessToken)
                }
                .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                .keyboardShortcut(.defaultAction)
            }
        } header: {
            Text(settings.isSignedIn ? "Use a different token" : "Or use a personal access token")
        } footer: {
            Text("Classic token with the `repo` scope, plus `read:org` for organization repositories. Stored in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var errorRow: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var host: String {
        GitHubCLI.hostname(forAPIBase: settings.settings.apiBaseURL)
    }

    // MARK: Actions

    private func importFromGitHubCLI() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let token = try await GitHubCLI.token(forHost: host)
                await validateAndSave(token, source: .gitHubCLI)
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func validateAndSave(_ token: String, source: TokenSource) {
        isWorking = true
        errorMessage = nil
        Task { await validateAndSave(token, source: source) }
    }

    /// Shared tail of both sign-in paths: prove the token works, then persist it and refetch.
    private func validateAndSave(_ token: String, source: TokenSource) async {
        defer { isWorking = false }
        do {
            let client = try GitHubClient(apiBase: settings.settings.apiBaseURL, token: token)
            let user = try await client.validateToken()
            try settings.signIn(token: token, account: user, source: source)
            tokenInput = ""
            showTokenEntry = false
            await store.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func signOut() {
        do {
            try settings.signOut()
            errorMessage = nil
            showTokenEntry = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Refresh

struct RefreshSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Polling") {
                Picker("Check GitHub every", selection: $settings.settings.pollIntervalMinutes) {
                    ForEach(AppSettings.pollIntervalChoices, id: \.self) { minutes in
                        Text(minutes == 60 ? "hour" : "\(minutes) minutes").tag(minutes)
                    }
                }
                Toggle("Hide draft pull requests", isOn: $settings.settings.hideDrafts)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Staleness

struct StalenessSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Measure staleness by", selection: $settings.settings.basis) {
                    ForEach(StalenessBasis.allCases) { basis in
                        Text(basis.label).tag(basis)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Drives the tier colours, the sort order, and the menu bar indicator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                thresholdStepper("Aging after", value: $settings.settings.thresholds.agingDays, tier: .aging, minimum: StalenessThresholds.minimumAging)
                thresholdStepper("Stale after", value: $settings.settings.thresholds.staleDays, tier: .stale, minimum: StalenessThresholds.minimumStale)
                thresholdStepper("Rotten after", value: $settings.settings.thresholds.rottenDays, tier: .rotten, minimum: StalenessThresholds.minimumRotten)
            } header: {
                Text("Tiers")
            } footer: {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.settings.thresholds) { old, new in
            // Keep aging < stale < rotten; the stepper the user moved drags the others along.
            var resolved = new
            resolved.resolveConflicts(changedFrom: old)
            if resolved != new {
                settings.settings.thresholds = resolved
            }
        }
    }

    /// e.g. "Fresh 0–2 · Aging 3–6 · Stale 7–13 · Rotten 14+ days"
    private var summary: String {
        let t = settings.settings.thresholds
        return StalenessTier.allCases
            .map { "\($0.label) \(t.rangeDescription(for: $0).replacingOccurrences(of: " days", with: "").replacingOccurrences(of: " day", with: ""))" }
            .joined(separator: " · ") + " days"
    }

    private func thresholdStepper(_ title: String, value: Binding<Int>, tier: StalenessTier, minimum: Int) -> some View {
        HStack {
            Circle().fill(tier.color).frame(width: 9, height: 9)
            Stepper(value: value, in: minimum...365) {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(value.wrappedValue) \(value.wrappedValue == 1 ? "day" : "days")")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Organizations

struct OrganizationSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PRStore.self) private var store

    var body: some View {
        Form {
            Section {
                if store.knownOwners.isEmpty {
                    Text(settings.isSignedIn ? "Loading your organizations…" : "Sign in on the Account tab to load your organizations.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.knownOwners) { owner in
                        Toggle(isOn: isIncluded(owner)) {
                            HStack(spacing: 10) {
                                AvatarView(url: owner.avatarURL, size: 22,
                                           placeholderSymbol: owner.isViewer ? "person.crop.circle.fill" : "building.2.crop.circle.fill")
                                Text(owner.login)
                                if owner.isViewer {
                                    Text("Personal")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.08), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                let count = store.openCount(for: owner)
                                if count > 0 {
                                    Text("\(count) open")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } header: {
                Text("Show pull requests from")
            } footer: {
                Text("Your account, the organizations you belong to, and any other owner of a pull request you've opened. New organizations are shown automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func isIncluded(_ owner: RepoOwner) -> Binding<Bool> {
        Binding(
            get: { !settings.settings.excludedOwners.contains(owner.id) },
            set: { included in
                if included {
                    settings.settings.excludedOwners.remove(owner.id)
                } else {
                    settings.settings.excludedOwners.insert(owner.id)
                }
            }
        )
    }
}
