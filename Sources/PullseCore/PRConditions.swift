import Foundation

/// A state a pull request can be in, as opposed to an item someone created on it.
/// Nothing is published when the last approval lands on an already-green pull request,
/// so these are detected by comparing one poll's truth against the last one's.
public enum PRCondition: String, Codable, Sendable, CaseIterable {
    case readyToMerge
}

public enum ConditionTint: String, Codable, Sendable {
    case positive, negative, neutral
}

/// One condition's whole definition: how to recognise it, what to call it and how to
/// draw it. `symbol` is an SF Symbol name and `tint` an enum rather than SwiftUI types,
/// because this target has no AppKit or SwiftUI.
public struct PRConditionRule: Sendable {
    public let condition: PRCondition
    /// The Settings toggle's label.
    public let title: String
    public let headline: String
    public let symbol: String
    public let tint: ConditionTint
    public let defaultsOn: Bool
    public let matches: @Sendable (PullRequest) -> Bool

    public init(
        condition: PRCondition, title: String, headline: String, symbol: String,
        tint: ConditionTint, defaultsOn: Bool, matches: @escaping @Sendable (PullRequest) -> Bool
    ) {
        self.condition = condition
        self.title = title
        self.headline = headline
        self.symbol = symbol
        self.tint = tint
        self.defaultsOn = defaultsOn
        self.matches = matches
    }
}

public enum PRConditions {
    public static let rules: [PRConditionRule] = [
        PRConditionRule(
            condition: .readyToMerge,
            title: "My pull requests becoming ready to merge",
            headline: "Ready to merge",
            symbol: "arrow.triangle.merge",
            tint: .positive,
            defaultsOn: true,
            matches: { isReadyToMerge($0) }
        )
    ]

    public static func rule(for condition: PRCondition) -> PRConditionRule? {
        rules.first { $0.condition == condition }
    }

    /// Conclusions that don't stand in the way of a merge. GitHub treats a skipped or
    /// neutral job as satisfied, so we do too.
    static let greenConclusions: Set<String> = ["SUCCESS", "SKIPPED", "NEUTRAL"]

    /// Computed rather than read from `mergeStateStatus`, which needs a preview `Accept`
    /// header. The trade-off is that we don't know what the repository actually
    /// *requires*, so on a repository without branch protection this can disagree with
    /// the Merge button.
    ///
    /// `reviewDecision` is null when no review is required; that counts as not ready.
    /// `mergeable` is "UNKNOWN" for a few seconds after a push while GitHub works it
    /// out, which also counts as not ready and resolves itself on the next poll.
    static func isReadyToMerge(_ pr: PullRequest) -> Bool {
        guard pr.isDraft != true,
              pr.reviewDecision == "APPROVED",
              pr.mergeable == "MERGEABLE"
        else { return false }
        // A check with no outcome is still running, so the pull request isn't ready yet.
        return pr.checks.allSatisfy { greenConclusions.contains($0.outcome ?? "") }
    }

    /// The conditions a pull request is in right now, keyed so that one set holds every
    /// pull request's conditions at once.
    static func active(for pullRequests: [PullRequest]) -> Set<String> {
        var active: Set<String> = []
        for pr in pullRequests {
            for rule in rules where rule.matches(pr) {
                active.insert(key(rule.condition, pr: pr))
            }
        }
        return active
    }

    static func key(_ condition: PRCondition, pr: PullRequest) -> String {
        "\(condition.rawValue):\(pr.id)"
    }
}
