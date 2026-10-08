import Foundation

public struct DetectorSettings: Sendable {
    public enum CIMode: String, Codable, Sendable, CaseIterable {
        case failuresOnly, all
    }

    public var comments = true
    public var reviews = true
    public var ci = true
    public var mentions = true
    public var ciMode: CIMode = .failuresOnly
    public var includeBots = false
    /// Repo names, either `owner/name` or bare `name`, compared case-insensitively.
    public var mutedRepos: Set<String> = []
    public var enabledConditions: Set<PRCondition> = Set(PRCondition.allCases)

    public init() {}

    /// "docs, Acme/API web" → ["docs", "acme/api", "web"]: separated by
    /// commas and/or whitespace, lowercased for matching.
    public static func parseRepoList(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { $0.lowercased() })
    }

    func isMuted(_ repository: Repository) -> Bool {
        isMuted(nameWithOwner: repository.nameWithOwner)
    }

    /// `owner/name` is muted when either it or its bare name is in the list.
    public func isMuted(nameWithOwner: String) -> Bool {
        let name = nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner
        return mutedRepos.contains(nameWithOwner.lowercased()) || mutedRepos.contains(name.lowercased())
    }
}

/// What the detector remembers between polls.
public struct SeenState: Codable, Sendable, Equatable {
    /// When the last successful poll ran; nil means the app has never polled.
    public var lastPollAt: Date?
    /// Every item already considered, keyed by id, valued by the item's own timestamp
    /// (used only for pruning).
    public var seen: [String: Date] = [:]
    /// Which conditions were true at the end of the last poll, keyed
    /// `condition:prID`. A condition notifies when it enters this set.
    public var activeConditions: Set<String> = []

    public init(
        lastPollAt: Date? = nil, seen: [String: Date] = [:],
        activeConditions: Set<String> = []
    ) {
        self.lastPollAt = lastPollAt
        self.seen = seen
        self.activeConditions = activeConditions
    }

    /// Hand-written so that a state file saved before a key existed still decodes:
    /// synthesized decoding would throw on the missing key, and `StateStore.load`
    /// turns a throw into a fresh state, silently dropping the user's history.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastPollAt = try c.decodeIfPresent(Date.self, forKey: .lastPollAt)
        seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
        activeConditions = try c.decodeIfPresent(Set<String>.self, forKey: .activeConditions) ?? []
    }
}

/// Turns a GitHub snapshot into new events. Pure: no I/O, no clock.
///
/// An item is new when it hasn't been seen and it happened after the previous poll
/// (minus some slack for GitHub's search index lag and clock skew). The time rule is
/// what keeps a freshly opened PR, a re-enabled event type or a first launch from
/// dumping its whole history as notifications; the seen set dedups inside the slack.
public enum EventDetector {
    static let slack: TimeInterval = 5 * 60
    /// Seen entries older than this are pruned. Must exceed `slack`.
    static let retention: TimeInterval = 24 * 60 * 60

    static let failedConclusions: Set<String> = [
        "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED",
    ]
    static let otherReportedConclusions: Set<String> = ["SUCCESS", "CANCELLED"]

    public static func detect(
        _ snapshot: Snapshot, state: SeenState, settings: DetectorSettings, now: Date
    ) -> (events: [PREvent], state: SeenState) {
        let firstRun = state.lastPollAt == nil
        let cutoff = (state.lastPollAt ?? now).addingTimeInterval(-slack)
        var seen = state.seen
        let me = snapshot.login.lowercased()

        /// Marks the item seen and says whether it's new. Items are marked seen even
        /// when filtered out, so flipping a setting later never replays them.
        func isNew(_ id: String, at date: Date) -> Bool {
            let unseen = seen[id] == nil
            seen[id] = date
            return !firstRun && unseen && date >= cutoff
        }

        func wanted(_ author: Actor?) -> Bool {
            guard let author else { return true }  // deleted ("ghost") user
            if author.login.lowercased() == me { return false }
            return settings.includeBots || !author.isBot
        }

        var events: [PREvent] = []

        for pr in snapshot.myPullRequests {
            let muted = settings.isMuted(pr.repository)

            for comment in pr.comments.items + pr.reviewComments {
                guard isNew(comment.id, at: comment.date),
                      settings.comments, !muted, wanted(comment.author)
                else { continue }
                events.append(event(
                    .comment, pr: pr, id: comment.id, author: comment.author,
                    headline: "\(comment.author?.login ?? "someone") commented",
                    body: comment.body, url: comment.url, date: comment.date
                ))
            }

            for review in pr.reviews.items {
                guard let submitted = review.submittedAt,  // pending reviews have none
                      isNew(review.id, at: submitted),
                      settings.reviews, !muted, wanted(review.author)
                else { continue }
                let who = review.author?.login ?? "someone"
                let headline: String
                switch review.state {
                case "APPROVED": headline = "\(who) approved"
                case "CHANGES_REQUESTED": headline = "\(who) requested changes"
                case "COMMENTED":
                    // A plain "comment" review with no summary is just the envelope for
                    // inline comments, which are already reported individually.
                    if TextCleaner.clean(review.body ?? "").isEmpty { continue }
                    headline = "\(who) reviewed"
                default: continue
                }
                events.append(event(
                    .review, pr: pr, id: review.id, author: review.author,
                    headline: headline, body: review.body, url: review.url, date: submitted,
                    isNegative: review.state == "CHANGES_REQUESTED"
                ))
            }

            // CI: one event per PR per poll, however many checks finished.
            var failed: [CheckContext] = []
            var other: [CheckContext] = []
            for check in pr.checks {
                guard let outcome = check.outcome, let finished = check.finishedAt else { continue }
                // A re-run gets a new CheckRun id, but a StatusContext keeps its id
                // across fail → pass → fail on the same commit; the finish time tells
                // those apart.
                let key = "\(check.id):\(outcome):\(Int(finished.timeIntervalSince1970))"
                guard isNew(key, at: finished),
                      settings.ci, !muted
                else { continue }
                if failedConclusions.contains(outcome) {
                    failed.append(check)
                } else if settings.ciMode == .all, otherReportedConclusions.contains(outcome) {
                    other.append(check)
                }
            }
            if !failed.isEmpty {
                events.append(ciEvent(pr: pr, checks: failed, verb: "failed", negative: true))
            }
            if !other.isEmpty {
                events.append(ciEvent(pr: pr, checks: other, verb: "finished", negative: false))
            }
        }

        let mention = "@\(me)"
        for pr in snapshot.mentionedPullRequests {
            let muted = settings.isMuted(pr.repository)
            let prAsComment = Comment(
                id: pr.id, body: pr.body, url: pr.url, createdAt: pr.createdAt, author: pr.author
            )
            let reviews = pr.reviews.items.compactMap { review -> Comment? in
                guard let submitted = review.submittedAt else { return nil }
                return Comment(
                    id: review.id, body: review.body, url: review.url,
                    createdAt: submitted, author: review.author
                )
            }
            for item in [prAsComment] + pr.comments.items + pr.reviewComments + reviews {
                guard mentions(item.body, handle: mention) else { continue }
                // Namespaced: the same review id could also be one of my PRs' items.
                guard isNew("mention:\(item.id)", at: item.date),
                      settings.mentions, !muted, wanted(item.author)
                else { continue }
                events.append(event(
                    .mention, pr: pr, id: "mention:\(item.id)", author: item.author,
                    headline: "\(item.author?.login ?? "someone") mentioned you",
                    body: item.body, url: item.url, date: item.date
                ))
            }
        }

        let active = PRConditions.active(for: snapshot.myPullRequests)
        // Computed from the pull requests alone, never from the settings: a muted repo
        // or a switched-off condition is still tracked, so turning it back on can't
        // replay a state the user already lived through.
        let fired = active.subtracting(state.activeConditions)
        if !firstRun {
            for pr in snapshot.myPullRequests {
                let muted = settings.isMuted(pr.repository)
                for rule in PRConditions.rules
                where fired.contains(PRConditions.key(rule.condition, pr: pr)) {
                    guard settings.enabledConditions.contains(rule.condition), !muted else { continue }
                    events.append(PREvent(
                        // GitHub publishes nothing when a pull request changes state, so
                        // there's no id or timestamp to borrow. The poll time keeps a
                        // re-arm's id apart from the first firing's, which
                        // `PersistedState.record` needs to keep both; a re-arm takes at
                        // least one poll out of the state and one back in, so the two are
                        // always more than a second apart.
                        id: "\(PRConditions.key(rule.condition, pr: pr)):\(Int(now.timeIntervalSince1970))",
                        kind: .condition, repo: pr.repository.nameWithOwner, number: pr.number,
                        prTitle: pr.title, prURL: pr.url, author: nil, headline: rule.headline,
                        snippet: pr.title, url: pr.url, date: now, condition: rule.condition,
                        isNegative: rule.tint == .negative
                    ))
                }
            }
        }

        let keepAfter = now.addingTimeInterval(-retention)
        seen = seen.filter { $0.value >= keepAfter }

        return (
            events.sorted { $0.date > $1.date },
            SeenState(lastPollAt: now, seen: seen, activeConditions: active)
        )
    }

    /// Case-insensitive `@login` match that doesn't fire on `@login-bot` or emails.
    static func mentions(_ body: String?, handle: String) -> Bool {
        guard let body = body?.lowercased() else { return false }
        var search = body.startIndex..<body.endIndex
        while let range = body.range(of: handle, range: search) {
            let before = range.lowerBound == body.startIndex
                ? nil : body[body.index(before: range.lowerBound)]
            let after = range.upperBound == body.endIndex ? nil : body[range.upperBound]
            let isHandleChar: (Character?) -> Bool = {
                guard let c = $0 else { return false }
                return c.isLetter || c.isNumber || c == "-" || c == "_"
            }
            if !isHandleChar(before), !isHandleChar(after) {
                return true
            }
            search = range.upperBound..<body.endIndex
        }
        return false
    }

    private static func event(
        _ kind: PREvent.Kind, pr: PullRequest, id: String, author: Actor?,
        headline: String, body: String?, url: String, date: Date, isNegative: Bool = false
    ) -> PREvent {
        PREvent(
            id: id, kind: kind, repo: pr.repository.nameWithOwner, number: pr.number,
            prTitle: pr.title, prURL: pr.url, author: author?.login, headline: headline,
            snippet: TextCleaner.clean(body ?? ""), url: url, date: date, isNegative: isNegative
        )
    }

    private static func ciEvent(
        pr: PullRequest, checks: [CheckContext], verb: String, negative: Bool
    ) -> PREvent {
        // Matrix jobs share a name; list each name once.
        var names: [String] = []
        for check in checks where !names.contains(check.displayName) {
            names.append(check.displayName)
        }
        let shown = names.prefix(2).joined(separator: ", ")
        let more = names.count > 2 ? " +\(names.count - 2)" : ""
        let latest = checks.compactMap(\.finishedAt).max() ?? pr.createdAt
        let ids = checks.map(\.id).sorted().joined(separator: ",")
        let snippet = negative
            ? names.joined(separator: ", ")
            : checks.map { "\($0.displayName): \(($0.outcome ?? "").lowercased())" }
                .joined(separator: ", ")
        return PREvent(
            id: "ci:\(verb):\(ids)", kind: .ci, repo: pr.repository.nameWithOwner,
            number: pr.number, prTitle: pr.title, prURL: pr.url, author: nil,
            headline: "CI \(verb): \(shown)\(more)", snippet: snippet,
            url: (checks.count == 1 ? checks[0].link : nil) ?? "\(pr.url)/checks",
            date: latest, isNegative: negative
        )
    }
}

public enum TextCleaner {
    private static let htmlComment = try! NSRegularExpression(
        pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators]
    )
    private static let htmlTag = try! NSRegularExpression(pattern: "<[^>]+>")

    /// Strip HTML comments and tags, collapse whitespace, truncate.
    public static func clean(_ text: String, limit: Int = 200) -> String {
        var clean = text
        for regex in [htmlComment, htmlTag] {
            clean = regex.stringByReplacingMatches(
                in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: " "
            )
        }
        clean = clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
