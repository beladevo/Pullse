import Foundation

enum Queries {
    private static let fragments = """
    fragment ActorFields on Actor { login __typename }
    fragment IssueCommentFields on IssueComment {
      id body url createdAt author { ...ActorFields }
    }
    fragment ReviewCommentFields on PullRequestReviewComment {
      id body url createdAt publishedAt author { ...ActorFields }
    }
    fragment ConversationFields on PullRequest {
      id number title url body createdAt
      author { ...ActorFields }
      repository { nameWithOwner }
      comments(last: 30) { nodes { ...IssueCommentFields } }
      reviews(last: 50) {
        nodes {
          id state body url submittedAt author { ...ActorFields }
          comments(first: 30) { nodes { ...ReviewCommentFields } }
        }
      }
    }
    """

    /// Every open PR I authored in the org, with its conversation and the check
    /// rollup of its head commit — one request no matter how many repos or PRs.
    static let myPullRequests = """
    query($q: String!) {
      viewer { login }
      search(query: $q, type: ISSUE, first: 50) {
        nodes {
          ... on PullRequest {
            ...ConversationFields
            isDraft
            mergeable
            reviewDecision
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    contexts(first: 100) {
                      nodes {
                        __typename
                        ... on CheckRun { id name status conclusion completedAt detailsUrl }
                        ... on StatusContext { id context state targetUrl createdAt }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """ + fragments

    /// Recently updated PRs by other people that mention me somewhere.
    static let mentions = """
    query($q: String!) {
      search(query: $q, type: ISSUE, first: 30) {
        nodes { ... on PullRequest { ...ConversationFields } }
      }
    }
    """ + fragments

    static func myPullRequestsSearch(org: String) -> String {
        "is:pr is:open author:@me org:\(org)"
    }

    static func mentionsSearch(org: String, since: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: since)
        return "is:pr mentions:@me -author:@me org:\(org) updated:>=\(stamp)"
    }
}
