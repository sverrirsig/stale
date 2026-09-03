import Foundation

/// Last successful fetch, written to Application Support so the dropdown is populated
/// instantly on launch and stays useful while rate-limited or offline.
enum PRCache {
    struct Snapshot: Codable {
        var pullRequests: [PullRequest]
        /// Optional so snapshots from older builds still decode.
        var owners: [RepoOwner]?
        var fetchedAt: Date
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "Stale", directoryHint: .isDirectory)
            .appending(path: "pull-requests.json")
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
