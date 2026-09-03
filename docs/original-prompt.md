# Prompt for Claude Code

Build a native macOS menu bar app called **Stale**.

## Purpose
Stale tracks a developer's open GitHub pull requests and makes it impossible to ignore the ones that have been sitting open too long. The core insight: most PR trackers show *what's new*; Stale should show *what's rotting*. The whole app is organized around age/staleness, not activity.

## Tech stack
- Swift + SwiftUI, targeting macOS 14+
- `NSStatusItem` for the menu bar icon (use `MenuBarExtra` in SwiftUI if it meets the needs; otherwise `NSStatusItem` directly for more control over custom rendering)
- No backend — talks directly to the GitHub REST/GraphQL API from the client
- Store the GitHub token in the macOS Keychain (never UserDefaults, never plaintext)
- Local persistence for cached PR data and settings via `UserDefaults` or a small SQLite/`swift-data` store — keep it lightweight

## Core functionality

1. **Authentication**
   - User provides a GitHub Personal Access Token (fine-grained, with `repo` and `read:org` scopes) via a simple settings window.
   - Validate the token against `GET /user` and show inline success/failure.

2. **Data fetching**
   - Fetch open PRs where the authenticated user is: author, assignee, or requested reviewer.
   - Support both github.com and GitHub Enterprise base URLs (configurable).
   - Poll on a configurable interval (default: every 5 minutes) plus a manual "Refresh now" action.
   - For each PR, capture: title, number, repo, author, URL, created date, last updated date, review status (approved / changes requested / pending review), and CI status if easily available.

3. **Staleness logic (the core differentiator)**
   - Compute "days open" (and optionally "days since last activity") for each PR.
   - Bucket PRs into urgency tiers, e.g.:
     - Fresh: 0–2 days
     - Aging: 3–6 days
     - Stale: 7–13 days
     - Rotten: 14+ days
   - Make these thresholds user-configurable in settings.
   - Sort the dropdown list by staleness (oldest/most-neglected first), not by recency of activity.

4. **Menu bar indicator**
   - Menu bar icon should give an at-a-glance signal of the *worst* staleness tier present (e.g. icon color or a small badge/count of PRs in the "Stale"+ tiers).
   - Keep this subtle and native-feeling — no aggressive red badges unless something is genuinely rotten.

5. **Dropdown UI**
   - Clicking the menu bar icon opens a simple popover/dropdown (not a full window).
   - List of open PRs, each row showing: repo name, PR title, PR number, author avatar (optional), days open, and a color-coded age indicator.
   - Clicking a PR row opens it in the default browser.
   - A small settings/gear affordance to open a preferences window (token, poll interval, staleness thresholds, which repos/orgs to include or exclude).
   - Include a "Quit" option and a manual "Refresh" option in the dropdown footer.

## Non-goals (keep this simple)
- No commenting, approving, or merging from within the app — this is a visibility tool, not a review client.
- No support for GitLab, Bitbucket, etc. — GitHub only.
- No complex dashboards, charts, or historical analytics.
- No local git repo scanning or CI log inspection.

## Architecture expectations
- Clean separation between: GitHub API client, data models, staleness/business logic, and SwiftUI views.
- Token and sensitive data access isolated in a small Keychain wrapper.
- Use async/await for networking.
- Handle GitHub API rate limiting gracefully (show a subtle warning in the dropdown if rate-limited, fall back to cached data).
- Write the project so it can be built and run via Xcode with minimal setup (standard Xcode project, no exotic build tooling).

## Deliverables
- A working Xcode project for "Stale" that builds and runs.
- A README with setup instructions (how to generate a GitHub PAT, required scopes, how to build/run).
- Reasonably commented code, but don't over-engineer — this should stay a small, maintainable codebase true to the "simple utility" spirit of the app.

Start by scaffolding the Xcode project structure and the menu bar shell (icon + empty dropdown), then wire up GitHub auth, then fetching, then the staleness logic and sorting, then polish the UI.
