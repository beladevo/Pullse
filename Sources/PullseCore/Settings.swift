import Foundation

/// Everything user-specific, kept in a JSON file outside the repository. Nothing about a
/// particular user or organization is compiled into the app.
public struct PullseSettings: Codable, Equatable, Sendable {
    /// GitHub organization to watch. Empty until the user sets one; the app does
    /// nothing until then.
    public var org = ""
    public var pollSeconds = 60
    public var notifyComments = true
    public var notifyReviews = true
    public var notifyCI = true
    public var notifyMentions = true
    public var ciResults: DetectorSettings.CIMode = .failuresOnly
    public var includeBots = false
    public var mutedRepos: [String] = []
    /// List every open PR of mine in the menu, with its CI and review status, even when
    /// it has no new activity.
    public var showOpenPullRequests = false
    /// Opens and closes the menu from any app. None until the user records one.
    public var openMenuShortcut: HotKey?
    /// Pull request states to notify about, keyed by `PRCondition` raw value. A key
    /// that isn't here takes its rule's default, so adding a condition needs no
    /// migration and an unknown key in a hand-edited file is ignored.
    public var conditions: [String: Bool] = [:]
    /// Look for new releases (on launch and every hour) and show when one exists.
    public var checkForUpdates = true
    /// Install a new release once it's found and Pullse isn't in use, then relaunch.
    public var autoUpdate = false
    public var includePrereleases = false
    /// Post "Pullse updated to x.y.z" on the first launch of a new version.
    public var notifyAfterUpdate = true
    /// Read by `scripts/build-app.sh` when bundling, never by the app itself. Macs key
    /// notification permission and login items by it, so it should stay the same
    /// between builds.
    public var bundleIdentifier: String?

    public static let minimumPollSeconds = 30

    public init() {}

    /// Hand-edited files may leave out any key; missing keys take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PullseSettings()
        org = try c.decodeIfPresent(String.self, forKey: .org) ?? d.org
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? d.pollSeconds
        notifyComments = try c.decodeIfPresent(Bool.self, forKey: .notifyComments) ?? d.notifyComments
        notifyReviews = try c.decodeIfPresent(Bool.self, forKey: .notifyReviews) ?? d.notifyReviews
        notifyCI = try c.decodeIfPresent(Bool.self, forKey: .notifyCI) ?? d.notifyCI
        notifyMentions = try c.decodeIfPresent(Bool.self, forKey: .notifyMentions) ?? d.notifyMentions
        ciResults = try c.decodeIfPresent(DetectorSettings.CIMode.self, forKey: .ciResults) ?? d.ciResults
        includeBots = try c.decodeIfPresent(Bool.self, forKey: .includeBots) ?? d.includeBots
        mutedRepos = try c.decodeIfPresent([String].self, forKey: .mutedRepos) ?? d.mutedRepos
        showOpenPullRequests = try c.decodeIfPresent(Bool.self, forKey: .showOpenPullRequests) ?? d.showOpenPullRequests
        // A hand-edited shortcut that doesn't decode is treated as none, not as a broken file.
        openMenuShortcut = (try? c.decodeIfPresent(HotKey.self, forKey: .openMenuShortcut)) ?? nil
        conditions = try c.decodeIfPresent([String: Bool].self, forKey: .conditions) ?? d.conditions
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? d.autoUpdate
        includePrereleases = try c.decodeIfPresent(Bool.self, forKey: .includePrereleases) ?? d.includePrereleases
        notifyAfterUpdate = try c.decodeIfPresent(Bool.self, forKey: .notifyAfterUpdate) ?? d.notifyAfterUpdate
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
    }

    /// The org, trimmed; nil when it hasn't been set.
    public var organization: String? {
        let trimmed = org.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func isEnabled(_ condition: PRCondition) -> Bool {
        conditions[condition.rawValue] ?? (PRConditions.rule(for: condition)?.defaultsOn ?? true)
    }

    public mutating func setEnabled(_ condition: PRCondition, _ on: Bool) {
        conditions[condition.rawValue] = on
    }

    public var pollInterval: TimeInterval {
        TimeInterval(max(Self.minimumPollSeconds, pollSeconds))
    }

    public var detectorSettings: DetectorSettings {
        var s = DetectorSettings()
        s.comments = notifyComments
        s.reviews = notifyReviews
        s.ci = notifyCI
        s.mentions = notifyMentions
        s.ciMode = ciResults
        s.includeBots = includeBots
        s.mutedRepos = DetectorSettings.parseRepoList(mutedRepos.joined(separator: ","))
        s.enabledConditions = Set(PRCondition.allCases.filter(isEnabled))
        return s
    }
}

public enum SettingsFileError: LocalizedError, Sendable {
    case unreadable(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            let reason = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
            return "Can't read \(path): \(reason). Fix or delete the file."
        }
    }
}

public struct SettingsFile: Sendable {
    public let url: URL

    public init(url: URL = SettingsFile.defaultURL) {
        self.url = url
    }

    /// `$PULLSE_SETTINGS`, else `~/.config/pullse/settings.json`. The build script
    /// resolves the same path.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["PULLSE_SETTINGS"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pullse/settings.json")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// A missing file is the defaults. A file that exists but doesn't parse throws: it
    /// was hand-edited, so it must never be silently replaced.
    public func load() throws -> PullseSettings {
        guard exists else { return PullseSettings() }
        do {
            return try JSONDecoder().decode(PullseSettings.self, from: Data(contentsOf: url))
        } catch {
            throw SettingsFileError.unreadable(path: url.path, reason: Self.describe(error))
        }
    }

    public func save(_ settings: PullseSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            return context.underlyingError.map { "\($0.localizedDescription)" } ?? context.debugDescription
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let key = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\"\(key)\" has the wrong type"
        default:
            return error.localizedDescription
        }
    }
}
