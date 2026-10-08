import Foundation
@testable import PullseCore

// Shared builders for the tests. Snapshots are built as GraphQL JSON and run through
// the real decoder, so the tests cover the response models as well as the rules.

let t0 = Date(timeIntervalSince1970: 1_790_000_000)
let lastPoll = t0
let now = t0.addingTimeInterval(60)
let polled = SeenState(lastPollAt: lastPoll)

func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

func actor(_ login: String, bot: Bool = false) -> [String: Any] {
    ["login": login, "__typename": bot ? "Bot" : "User"]
}

func comment(
    _ id: String, by author: [String: Any] = actor("reviewer"), body: String = "looks off",
    at date: Date = now, publishedAt: Date? = nil
) -> [String: Any] {
    ["id": id, "body": body, "url": "https://github.com/c/\(id)", "createdAt": stamp(date),
     "publishedAt": publishedAt.map(stamp) ?? NSNull(), "author": author]
}

func review(
    _ id: String, state: String, body: String = "", by author: [String: Any] = actor("reviewer"),
    at date: Date? = now, comments: [[String: Any]] = []
) -> [String: Any] {
    ["id": id, "state": state, "body": body, "url": "https://github.com/r/\(id)",
     "submittedAt": date.map(stamp) ?? NSNull(), "author": author,
     "comments": ["nodes": comments]]
}

func checkRun(
    _ id: String, name: String, conclusion: String?, at date: Date = now
) -> [String: Any] {
    ["__typename": "CheckRun", "id": id, "name": name,
     "status": conclusion == nil ? "IN_PROGRESS" : "COMPLETED",
     "conclusion": conclusion ?? NSNull(), "completedAt": stamp(date),
     "detailsUrl": "https://github.com/checks/\(id)"]
}

func pr(
    repo: String = "acme/api", number: Int = 1, body: String = "",
    author: [String: Any] = actor("me"),
    comments: [[String: Any]] = [], reviews: [[String: Any]] = [],
    threads: [[[String: Any]]] = [], checks: [[String: Any]] = [],
    isDraft: Bool = false, reviewDecision: String? = nil, rollupState: String? = nil,
    mergeable: String? = nil, createdAt: Date = t0.addingTimeInterval(-86_400)
) -> [String: Any] {
    [
        "id": "PR_\(repo)_\(number)", "number": number, "title": "A change",
        "isDraft": isDraft, "reviewDecision": reviewDecision ?? NSNull(),
        "url": "https://github.com/\(repo)/pull/\(number)", "body": body,
        "createdAt": stamp(createdAt), "author": author,
        "repository": ["nameWithOwner": repo],
        "mergeable": mergeable ?? NSNull(),
        "comments": ["nodes": comments],
        // Inline comments arrive nested in the (empty "commented") review that holds them.
        "reviews": ["nodes": reviews + threads.enumerated().map { index, comments in
            review("rv\(index)", state: "COMMENTED", comments: comments)
        }],
        "commits": ["nodes": [["commit": ["statusCheckRollup": [
            "state": rollupState.map { $0 as Any } ?? NSNull(), "contexts": ["nodes": checks],
        ]]]]],
    ]
}

func snapshot(mine: [[String: Any]] = [], mentioned: [[String: Any]] = []) throws -> Snapshot {
    func decode(_ nodes: [[String: Any]]) throws -> [PullRequest] {
        let json = try JSONSerialization.data(withJSONObject: ["data": ["search": ["nodes": nodes]]])
        let data: MentionsData = try GitHubClient.decode(json)
        return data.search.pullRequests
    }
    return Snapshot(login: "me", myPullRequests: try decode(mine), mentionedPullRequests: try decode(mentioned))
}

func detect(
    _ snapshot: Snapshot, state: SeenState = polled, settings: DetectorSettings = DetectorSettings()
) -> [PREvent] {
    EventDetector.detect(snapshot, state: state, settings: settings, now: now).events
}

/// A pull request that satisfies every part of the ready-to-merge rule, so each test
/// can take one thing away.
func readyPR(
    number: Int = 1, repo: String = "acme/api", checks: [[String: Any]] = [],
    isDraft: Bool = false, mergeable: String? = "MERGEABLE",
    reviewDecision: String? = "APPROVED"
) -> [String: Any] {
    pr(repo: repo, number: number, checks: checks, isDraft: isDraft,
       reviewDecision: reviewDecision, mergeable: mergeable)
}
