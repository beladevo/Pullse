import Foundation
import Testing
@testable import PullseCore

// The ready-to-merge rule, and the transition machinery it rides on. Conditions are
// states rather than items, so these tests run two polls and look at what the second
// one says.

private func poll(
    _ nodes: [[String: Any]], state: SeenState = polled,
    settings: DetectorSettings = DetectorSettings(), at clock: Date = now
) throws -> (events: [PREvent], state: SeenState) {
    EventDetector.detect(try snapshot(mine: nodes), state: state, settings: settings, now: clock)
}

private func readyEvents(_ nodes: [[String: Any]]) throws -> [PREvent] {
    try poll(nodes).events.filter { $0.kind == .condition }
}

@Suite struct ReadyToMergeRuleTests {
    @Test func firesWhenApprovedMergeableAndGreen() throws {
        let events = try readyEvents([readyPR(checks: [checkRun("c1", name: "test", conclusion: "SUCCESS")])])
        #expect(events.count == 1)
        #expect(events[0].condition == .readyToMerge)
        #expect(events[0].headline == "Ready to merge")
        #expect(events[0].isNegative == false)
        #expect(events[0].url == "https://github.com/acme/api/pull/1")
    }

    @Test func firesWithNoChecksAtAll() throws {
        #expect(try readyEvents([readyPR()]).count == 1)
    }

    @Test func skippedAndNeutralCountAsGreen() throws {
        let checks = [
            checkRun("c1", name: "test", conclusion: "SUCCESS"),
            checkRun("c2", name: "lint", conclusion: "SKIPPED"),
            checkRun("c3", name: "optional", conclusion: "NEUTRAL"),
        ]
        #expect(try readyEvents([readyPR(checks: checks)]).count == 1)
    }

    @Test func draftBlocks() throws {
        #expect(try readyEvents([readyPR(isDraft: true)]).isEmpty)
    }

    @Test(arguments: [nil, "REVIEW_REQUIRED", "CHANGES_REQUESTED"])
    func onlyAnApprovedDecisionCounts(_ decision: String?) throws {
        #expect(try readyEvents([readyPR(reviewDecision: decision)]).isEmpty)
    }

    @Test(arguments: [nil, "CONFLICTING", "UNKNOWN"])
    func onlyAMergeableBranchCounts(_ mergeable: String?) throws {
        #expect(try readyEvents([readyPR(mergeable: mergeable)]).isEmpty)
    }

    @Test(arguments: ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"])
    func aBlockingConclusionBlocks(_ conclusion: String) throws {
        let checks = [
            checkRun("c1", name: "test", conclusion: "SUCCESS"),
            checkRun("c2", name: "lint", conclusion: conclusion),
        ]
        #expect(try readyEvents([readyPR(checks: checks)]).isEmpty)
    }

    @Test func aStillRunningCheckMeansNotYet() throws {
        let checks = [
            checkRun("c1", name: "test", conclusion: "SUCCESS"),
            checkRun("c2", name: "slow", conclusion: nil),
        ]
        #expect(try readyEvents([readyPR(checks: checks)]).isEmpty)
    }
}

@Suite struct ConditionTransitionTests {
    @Test func firesOnceThenStaysQuiet() throws {
        let first = try poll([readyPR()])
        #expect(first.events.filter { $0.kind == .condition }.count == 1)

        let second = try poll([readyPR()], state: first.state)
        #expect(second.events.filter { $0.kind == .condition }.isEmpty)
    }

    @Test func rearmsAfterDroppingOutOfTheState() throws {
        let ready = try poll([readyPR()])
        let broken = try poll([readyPR(mergeable: "CONFLICTING")], state: ready.state,
                              at: now.addingTimeInterval(60))
        #expect(broken.state.activeConditions.isEmpty)

        let again = try poll([readyPR()], state: broken.state, at: now.addingTimeInterval(120))
        let events = again.events.filter { $0.kind == .condition }
        #expect(events.count == 1)
        // The two firings must carry different ids or `PersistedState.record` keeps only
        // the first. A re-arm always spans two polls, so their times can't collide.
        #expect(events[0].id != ready.events.first { $0.kind == .condition }?.id)
    }

    @Test func aMergedPullRequestLeavesTheState() throws {
        let ready = try poll([readyPR()])
        #expect(ready.state.activeConditions.count == 1)

        let gone = try poll([], state: ready.state)
        #expect(gone.state.activeConditions.isEmpty)
    }

    @Test func theFirstRunBaselinesSilently() throws {
        let first = try poll([readyPR()], state: SeenState())
        #expect(first.events.isEmpty)
        #expect(first.state.activeConditions.count == 1)

        #expect(try poll([readyPR()], state: first.state).events.isEmpty)
    }

    @Test func eachPullRequestIsTrackedOnItsOwn() throws {
        let first = try poll([readyPR(number: 1)])
        let second = try poll([readyPR(number: 1), readyPR(number: 2)], state: first.state)
        let events = second.events.filter { $0.kind == .condition }
        #expect(events.count == 1)
        #expect(events[0].number == 2)
    }
}

@Suite struct ConditionFilterTests {
    private func off() -> DetectorSettings {
        var settings = DetectorSettings()
        settings.enabledConditions = []
        return settings
    }

    @Test func aDisabledConditionIsTrackedButNotAnnounced() throws {
        let first = try poll([readyPR()], settings: off())
        #expect(first.events.isEmpty)
        #expect(first.state.activeConditions.count == 1)

        // Switching it on must not replay a state the user already lived through.
        #expect(try poll([readyPR()], state: first.state).events.isEmpty)
    }

    @Test func aMutedRepositoryIsTrackedButNotAnnounced() throws {
        var settings = DetectorSettings()
        settings.mutedRepos = ["acme/api"]
        let first = try poll([readyPR()], settings: settings)
        #expect(first.events.isEmpty)
        #expect(first.state.activeConditions.count == 1)

        #expect(try poll([readyPR()], state: first.state).events.isEmpty)
    }

    @Test func settingsResolveAConditionsDefaultWhenTheKeyIsAbsent() {
        var settings = PullseSettings()
        #expect(settings.isEnabled(.readyToMerge))
        settings.setEnabled(.readyToMerge, false)
        #expect(!settings.isEnabled(.readyToMerge))
        #expect(settings.detectorSettings.enabledConditions.isEmpty)
    }
}

@Suite struct ConditionStateDecodingTests {
    /// A state file written before conditions existed must keep its history: decoding
    /// throws on a missing key under synthesized `Codable`, and `StateStore.load`
    /// turns a throw into a blank slate.
    @Test func aStateFileWithoutConditionsStillDecodes() throws {
        let json = """
        {"seen":{"lastPollAt":"2026-10-07T00:00:00Z","seen":{"c1":"2026-10-07T00:00:00Z"}},
         "history":[],"lastRunVersion":"0.8.1"}
        """
        let state: PersistedState = try JSONDecoder.github.decode(
            PersistedState.self, from: Data(json.utf8)
        )
        #expect(state.seen.seen["c1"] != nil)
        #expect(state.seen.lastPollAt != nil)
        #expect(state.seen.activeConditions.isEmpty)
        #expect(state.lastRunVersion == "0.8.1")
    }
}
