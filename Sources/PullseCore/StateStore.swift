import Foundation

/// Everything the app keeps across launches, in one JSON file.
public struct PersistedState: Codable, Sendable {
    public var seen = SeenState()
    /// Most recent events first, capped at `historyLimit`.
    public var history: [PREvent] = []
    /// The app version that last ran, to say "updated to x.y.z" once after an update.
    public var lastRunVersion: String?

    public static let historyLimit = 100

    public init() {}

    public mutating func record(_ events: [PREvent]) {
        let known = Set(history.map(\.id))
        let added = events.filter { !known.contains($0.id) }
        // A condition firing again takes the place of its earlier event, so the menu shows
        // it once, at its newest.
        let replaced = Set(added.compactMap(\.replacementKey))
        history = (added + history.filter { $0.replacementKey.map(replaced.contains) != true })
            .sorted { $0.date > $1.date }
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }
}

public struct StateStore: Sendable {
    public let url: URL

    public init(url: URL = StateStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pullse", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    /// A missing or unreadable file starts fresh, which is the same as a first launch:
    /// the next poll baselines silently.
    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder.github.decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
