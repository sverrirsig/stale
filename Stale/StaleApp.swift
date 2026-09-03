import SwiftUI

/// Stale — a menu bar tracker for open GitHub PRs, organised around how long they've been rotting.
@main
struct StaleApp: App {
    @State private var settings: SettingsStore
    @State private var store: PRStore

    init() {
        let settings = SettingsStore()
        _settings = State(initialValue: settings)
        _store = State(initialValue: PRStore(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView()
                .environment(settings)
                .environment(store)
        } label: {
            MenuBarLabel(tier: store.worstTier, attentionCount: store.attentionCount)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(store)
        }
    }
}

enum AppActions {
    /// LSUIElement apps are never "active", so windows we open (Settings) would land behind
    /// whatever the user was doing. Activate first.
    static func bringToFront() {
        NSApp.activate()
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
