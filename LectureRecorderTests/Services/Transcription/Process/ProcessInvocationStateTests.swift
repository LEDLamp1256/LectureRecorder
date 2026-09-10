import XCTest
@testable import LectureRecorder

/// Deterministic, real-process-free unit coverage for
/// `ProcessInvocationState`'s linearization contract. Unlike the
/// integration-level races exercised against a live `Process` in
/// `FoundationProcessRunnerTests` (which prove the production wiring calls
/// this type correctly, but can only ever demonstrate *a* interleaving that
/// happened to occur on a given run), these tests call the type's own
/// methods directly and therefore can force every interleaving the
/// documented contract claims to guarantee, with no reliance on scheduling
/// luck.
final class ProcessInvocationStateTests: XCTestCase {

    // MARK: - Single-actor sequencing

    func testFailureRecordedBeforeSuccessAttemptPermanentlyBlocksSuccess() {
        let state = ProcessInvocationState()

        XCTAssertTrue(state.recordFatalIntervention(.cancelled))
        XCTAssertFalse(state.tryCommitSuccess())
        XCTAssertEqual(state.claimedFailure, .cancelled)
    }

    func testSuccessCommittedBeforeAnyFailureRefusesAllLaterInterventions() {
        let state = ProcessInvocationState()

        XCTAssertTrue(state.tryCommitSuccess())
        XCTAssertFalse(state.recordFatalIntervention(.cancelled))
        XCTAssertNil(state.claimedFailure)

        // A second, different failure arriving even later must also be refused.
        XCTAssertFalse(state.recordFatalIntervention(.timedOut(afterSeconds: 5.0)))
        XCTAssertNil(state.claimedFailure)
    }

    func testFirstOfMultipleFailuresIsTheOneThatIsRetainedAndAuthoritative() {
        let state = ProcessInvocationState()

        XCTAssertTrue(state.recordFatalIntervention(.timedOut(afterSeconds: 3.0)))
        XCTAssertFalse(state.recordFatalIntervention(.cancelled))
        XCTAssertFalse(state.recordFatalIntervention(.stdinDeliveryFailed(underlying: "broken pipe")))

        XCTAssertEqual(state.claimedFailure, .timedOut(afterSeconds: 3.0))
        XCTAssertFalse(state.tryCommitSuccess())
    }

    func testSecondTryCommitSuccessWithNoInterveningFailureRemainsIdempotentlyTrue() {
        let state = ProcessInvocationState()

        // The documented contract only guards `tryCommitSuccess()` against a
        // fatal intervention that was already recorded — it says nothing
        // about refusing a second, redundant success commit. Production
        // code calls this exactly once per invocation, so this is
        // deliberately proving the actual (harmless, idempotent) behavior
        // rather than an unstated assumption.
        XCTAssertTrue(state.tryCommitSuccess())
        XCTAssertTrue(state.tryCommitSuccess())
        XCTAssertNil(state.claimedFailure)
    }

    func testFreshStateHasNoClaimedFailureAndPermitsSuccess() {
        let state = ProcessInvocationState()

        XCTAssertNil(state.claimedFailure)
        XCTAssertTrue(state.tryCommitSuccess())
    }

    // MARK: - Concurrent racing: exactly one authoritative outcome

    /// Fires many concurrent `recordFatalIntervention` calls, each carrying
    /// a distinct failure value, with no `tryCommitSuccess` in the mix.
    /// Regardless of which task's write actually lands first, exactly one
    /// failure must end up retained, and it must be stable (rereading
    /// `claimedFailure` repeatedly must not observe it change afterward).
    func testConcurrentFailureInterventionsLeaveExactlyOneAuthoritativeFailure() async {
        let state = ProcessInvocationState()
        let contenders: [ProcessRunFailure] = (0..<64).map { .timedOut(afterSeconds: TimeInterval($0)) }

        await withTaskGroup(of: Bool.self) { group in
            for failure in contenders {
                group.addTask {
                    state.recordFatalIntervention(failure)
                }
            }
            var winners = 0
            for await won in group where won {
                winners += 1
            }
            XCTAssertEqual(winners, 1, "exactly one concurrent recordFatalIntervention call must win")
        }

        guard let retained = state.claimedFailure else {
            return XCTFail("expected a retained failure after concurrent interventions")
        }
        XCTAssertTrue(contenders.contains(retained), "retained failure must be one of the contenders, not a corrupted value")

        // Stability: rereading must not change the answer, and success must
        // remain permanently refused.
        XCTAssertEqual(state.claimedFailure, retained)
        XCTAssertFalse(state.tryCommitSuccess())
        XCTAssertEqual(state.claimedFailure, retained)
    }

    /// Races `tryCommitSuccess` against a concurrent flood of
    /// `recordFatalIntervention` calls. The contract does not promise which
    /// side wins a genuine race — only that the outcome is singular and
    /// self-consistent: if success won, no failure is ever retained; if a
    /// failure won, success must have been refused.
    func testConcurrentSuccessVersusFailureRaceIsAlwaysSelfConsistent() async {
        for _ in 0..<200 {
            let state = ProcessInvocationState()

            async let successResult: Bool = state.tryCommitSuccess()
            async let failureResults: [Bool] = withTaskGroup(of: Bool.self) { group in
                for i in 0..<8 {
                    group.addTask {
                        state.recordFatalIntervention(.stdoutLimitExceeded(limit: i))
                    }
                }
                var results: [Bool] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            let succeeded = await successResult
            let failureWins = await failureResults.filter { $0 }.count

            if succeeded {
                XCTAssertEqual(failureWins, 0, "success committed, so no fatal intervention may have won")
                XCTAssertNil(state.claimedFailure)
            } else {
                XCTAssertEqual(failureWins, 1, "success was refused, so exactly one fatal intervention must have won")
                XCTAssertNotNil(state.claimedFailure)
            }
        }
    }
}
