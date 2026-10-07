import Foundation

// Decodable shapes for the GraphQL responses in Queries.swift. Only the fields the
// detector reads are modelled; everything is optional where GitHub may return null.

public struct Actor: Decodable, Sendable, Hashable {
    public let login: String
    public let typename: String?

    enum CodingKeys: String, CodingKey {
        case login
        case typename = "__typename"
    }

    public var isBot: Bool {
        typename == "Bot" || login.hasSuffix("[bot]")
    }
}

/// A GraphQL connection; `nodes` entries can be null when the viewer lacks access.
public struct Connection<Node: Decodable & Sendable>: Decodable, Sendable {
    public let nodes: [Node?]?

    public var items: [Node] { (nodes ?? []).compactMap { $0 } }
}

/// An issue comment or an inline review comment — both carry the same fields.
public struct Comment: Decodable, Sendable {
    public let id: String
    public let body: String?
    public let url: String
    public let createdAt: Date
    /// Inline review comments only: when the review holding it was submitted. A draft
    /// comment's `createdAt` is when it was written, which can be long before anyone
    /// could see it.
    public var publishedAt: Date? = nil
    public let author: Actor?

    /// When the comment became visible.
    public var date: Date { publishedAt ?? createdAt }
}

public struct Review: Decodable, Sendable {
    public let id: String
    public let state: String
    public let body: String?
    public let url: String
    public let submittedAt: Date?
    public let author: Actor?
    /// Its inline comments, including replies to older threads (each reply is a
    /// review of its own). Not requested in every query.
    public let comments: Connection<Comment>?
}

/// One entry of a commit's status check rollup: either a CheckRun (GitHub Actions and
/// other apps) or a legacy commit StatusContext.
public struct CheckContext: Decodable, Sendable {
    public let typename: String
    public let id: String
    // CheckRun
    public let name: String?
    public let status: String?
    public let conclusion: String?
    public let completedAt: Date?
    public let detailsUrl: String?
    // StatusContext
    public let context: String?
    public let state: String?
    public let targetUrl: String?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case id, name, status, conclusion, completedAt, detailsUrl
        case context, state, targetUrl, createdAt
    }

    public var displayName: String { name ?? context ?? "check" }

    /// The outcome in CheckRun vocabulary, or nil while the check is still running.
    public var outcome: String? {
        if typename == "StatusContext" {
            switch state {
            case "SUCCESS": return "SUCCESS"
            case "FAILURE", "ERROR": return "FAILURE"
            default: return nil
            }
        }
        return status == "COMPLETED" ? conclusion : nil
    }

    public var finishedAt: Date? { completedAt ?? createdAt }
    /// The check's own page, only when it is on GitHub: `detailsUrl` and `targetUrl` are
    /// set by whoever reports the check (see `GitHubLink`). Nil makes the event link to
    /// the PR's checks page instead.
    public var link: String? { GitHubLink.safe(detailsUrl ?? targetUrl) }
}

public struct StatusCheckRollup: Decodable, Sendable {
    public let contexts: Connection<CheckContext>
}

public struct Commit: Decodable, Sendable {
    public let statusCheckRollup: StatusCheckRollup?
}

public struct CommitNode: Decodable, Sendable {
    public let commit: Commit
}

public struct Repository: Decodable, Sendable {
    public let nameWithOwner: String

    public var name: String {
        nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner
    }
}

public struct PullRequest: Decodable, Sendable {
    public let id: String
    public let number: Int
    public let title: String
    public let url: String
    public let body: String?
    public let createdAt: Date
    public let author: Actor?
    public let repository: Repository
    public let comments: Connection<Comment>
    public let reviews: Connection<Review>
    /// Only requested for my own PRs (CI results, merge state); absent in the
    /// mentions query, which is why these are all optional.
    public let commits: Connection<CommitNode>?
    public let isDraft: Bool?
    /// "MERGEABLE", "CONFLICTING", or "UNKNOWN" while GitHub is still working it out.
    public let mergeable: String?
    /// "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", or null when the repository
    /// requires no review.
    public let reviewDecision: String?

    public var checks: [CheckContext] {
        commits?.items.last?.commit.statusCheckRollup?.contexts.items ?? []
    }

    /// Inline comments, read through the reviews rather than the review threads:
    /// threads come back in creation order, so on a busy PR a new reply in an old
    /// thread would fall outside the page, while its review is always among the latest.
    public var reviewComments: [Comment] {
        reviews.items.flatMap { $0.comments?.items ?? [] }
    }
}

/// A search result node. Search can in principle return non-PR nodes (as `{}`), so a
/// node that doesn't decode as a PullRequest is dropped rather than failing the poll.
struct SearchNode: Decodable, Sendable {
    let pullRequest: PullRequest?

    init(from decoder: Decoder) throws {
        pullRequest = try? PullRequest(from: decoder)
    }
}

struct SearchResult: Decodable, Sendable {
    let nodes: [SearchNode?]

    var pullRequests: [PullRequest] { nodes.compactMap { $0?.pullRequest } }
}

struct Viewer: Decodable, Sendable {
    let login: String
}

struct MyPullRequestsData: Decodable, Sendable {
    let viewer: Viewer
    let search: SearchResult
}

struct MentionsData: Decodable, Sendable {
    let search: SearchResult
}

/// Something worth telling the user about.
public struct PREvent: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case comment, review, ci, mention
        /// A state the pull request entered rather than an item someone created.
        case condition
        /// Made by "Send test notification"; not from GitHub activity.
        case test
    }

    public let id: String
    public let kind: Kind
    public let repo: String
    public let number: Int
    public let prTitle: String
    public let prURL: String
    public let author: String?
    /// "alice commented", "approved", "CI failed: lint, test"
    public let headline: String
    public let snippet: String
    public let url: String
    public let date: Date
    /// Which condition fired, for `.condition` events: the menu reads its rule for an
    /// icon and a tint.
    public let condition: PRCondition?
    /// Failed / changes requested — rendered in red.
    public let isNegative: Bool
    public var isUnread: Bool

    public init(
        id: String, kind: Kind, repo: String, number: Int, prTitle: String, prURL: String,
        author: String?, headline: String, snippet: String, url: String, date: Date,
        condition: PRCondition? = nil, isNegative: Bool = false, isUnread: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.repo = repo
        self.number = number
        self.prTitle = prTitle
        self.prURL = prURL
        self.author = author
        self.headline = headline
        self.snippet = snippet
        self.url = url
        self.date = date
        self.condition = condition
        self.isNegative = isNegative
        self.isUnread = isUnread
    }

    /// "api#1964"
    public var prLabel: String {
        if kind == .test { return "Pullse" }
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return "\(name)#\(number)"
    }
}
