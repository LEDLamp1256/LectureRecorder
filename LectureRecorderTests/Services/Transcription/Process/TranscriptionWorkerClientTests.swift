import XCTest
@testable import LectureRecorder

/// End-to-end tests: `TranscriptionWorkerClient` driving the real,
/// embedded, signed `LectureRecorderWorkerFixture` through
/// `FoundationProcessRunner`. Proves the approved exit-code decision table
/// and identity-validation rules against a real process boundary, not a
/// mock.
final class TranscriptionWorkerClientTests: XCTestCase {
    private var client: TranscriptionWorkerClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = try WorkerFixtureTestSupport.resolveFixtureURLOrFail() // fail fast with a clear message if missing
        client = TranscriptionWorkerClient(processRunner: FoundationProcessRunner(pollInterval: 0.01))
    }

    private func submit(
        mode: String,
        identity: WorkerRequestIdentity = WorkerFixtureTestSupport.makeIdentity(),
        overallTimeout: TimeInterval = 5.0,
        gracePeriod: TimeInterval = 0.3
    ) async -> WorkerInvocationOutcome<TestFixtureOutput> {
        await client.submit(
            payload: EmptyTestPayload(),
            identity: identity,
            outputType: TestFixtureOutput.self,
            arguments: ["--mode=\(mode)"],
            limits: WorkerInvocationLimits(overallTimeout: overallTimeout, gracePeriod: gracePeriod)
        )
    }

    // MARK: - Exit-code decision table

    func testValidZeroExitSuccessIsAccepted() async {
        let outcome = await submit(mode: "success")
        guard case .success(let output) = outcome else {
            return XCTFail("Expected success, got \(outcome)")
        }
        XCTAssertEqual(output.text, "fixture transcript")
    }

    func testValidZeroExitStructuredFailureIsReturnedAsWorkerDeclaredFailure() async {
        let outcome = await submit(mode: "failure")
        guard case .workerDeclaredFailure(let failure) = outcome else {
            return XCTFail("Expected workerDeclaredFailure, got \(outcome)")
        }
        XCTAssertEqual(failure.message, "fixture declared failure")
    }

    func testNonzeroExitWithNoResponseIsProcessFailure() async {
        let outcome = await submit(mode: "nonzero-no-response")
        guard case .infrastructureFailure(.processFailure(let status, _, _)) = outcome else {
            return XCTFail("Expected .processFailure, got \(outcome)")
        }
        XCTAssertEqual(status, 7)
    }

    func testNonzeroExitWithApparentlyValidSuccessJSONCannotBeOverriddenByJSON() async {
        let outcome = await submit(mode: "nonzero-with-success-json")
        guard case .infrastructureFailure(.processFailure(let status, _, _)) = outcome else {
            return XCTFail("A nonzero exit must never be overridden by well-formed JSON on stdout; got \(outcome)")
        }
        XCTAssertEqual(status, 7)
    }

    func testSignaledTerminationIsProcessFailure() async {
        // A genuine, unprompted signal death (the child kills itself) —
        // distinct from a runner-triggered SIGKILL escalation, which
        // correctly classifies as .timedOut/.cancelled instead (see
        // FoundationProcessRunnerTests.testForcedTerminationWhenSIGTERMIsIgnored).
        // The generous timeout here must never itself fire.
        let outcome = await submit(mode: "self-signal", overallTimeout: 5.0)
        guard case .infrastructureFailure(.processFailure(let status, let signal, _)) = outcome else {
            return XCTFail("Expected .processFailure from a signaled termination, got \(outcome)")
        }
        XCTAssertNil(status)
        XCTAssertNotNil(signal)
    }

    func testEmptyStdoutIsMissingResponse() async {
        let outcome = await submit(mode: "empty-stdout")
        guard case .infrastructureFailure(.missingResponse) = outcome else {
            return XCTFail("Expected .missingResponse, got \(outcome)")
        }
    }

    func testMalformedJSONIsRejected() async {
        let outcome = await submit(mode: "malformed-json")
        guard case .infrastructureFailure(.malformedResponse) = outcome else {
            return XCTFail("Expected .malformedResponse, got \(outcome)")
        }
    }

    func testTruncatedJSONIsRejected() async {
        let outcome = await submit(mode: "truncated-json")
        guard case .infrastructureFailure(.malformedResponse) = outcome else {
            return XCTFail("Expected .malformedResponse, got \(outcome)")
        }
    }

    func testMultipleJSONValuesIsRejected() async {
        let outcome = await submit(mode: "multiple-json-values")
        guard case .infrastructureFailure(.malformedResponse) = outcome else {
            return XCTFail("Expected .malformedResponse, got \(outcome)")
        }
    }

    func testTrailingGarbageIsRejected() async {
        let outcome = await submit(mode: "trailing-garbage")
        guard case .infrastructureFailure(.malformedResponse) = outcome else {
            return XCTFail("Expected .malformedResponse, got \(outcome)")
        }
    }

    func testUnsupportedSchemaIsRejected() async {
        let outcome = await submit(mode: "unsupported-schema")
        guard case .infrastructureFailure(.unsupportedSchemaVersion(let version)) = outcome else {
            return XCTFail("Expected .unsupportedSchemaVersion, got \(outcome)")
        }
        XCTAssertEqual(version, 999)
    }

    // MARK: - Identity validation

    func testRequestIDMismatchIsRejected() async {
        let outcome = await submit(mode: "mismatch-request-id")
        guard case .infrastructureFailure(.identityMismatch(let field)) = outcome else {
            return XCTFail("Expected .identityMismatch, got \(outcome)")
        }
        XCTAssertEqual(field, "requestID")
    }

    func testAttemptIDMismatchIsRejected() async {
        let outcome = await submit(mode: "mismatch-attempt-id")
        guard case .infrastructureFailure(.identityMismatch(let field)) = outcome else {
            return XCTFail("Expected .identityMismatch, got \(outcome)")
        }
        XCTAssertEqual(field, "attemptID")
    }

    func testSessionIDMismatchIsRejected() async {
        let outcome = await submit(mode: "mismatch-session-id")
        guard case .infrastructureFailure(.identityMismatch(let field)) = outcome else {
            return XCTFail("Expected .identityMismatch, got \(outcome)")
        }
        XCTAssertEqual(field, "sessionID")
    }

    func testChunkSequenceMismatchIsRejected() async {
        let outcome = await submit(mode: "mismatch-chunk-sequence")
        guard case .infrastructureFailure(.identityMismatch(let field)) = outcome else {
            return XCTFail("Expected .identityMismatch, got \(outcome)")
        }
        XCTAssertEqual(field, "chunkSequenceNumber")
    }

    func testSourceIdentityMismatchIsRejected() async {
        let outcome = await submit(mode: "mismatch-source-identity")
        guard case .infrastructureFailure(.identityMismatch(let field)) = outcome else {
            return XCTFail("Expected .identityMismatch, got \(outcome)")
        }
        XCTAssertEqual(field, "sourceIdentity")
    }

    func testUnexpectedWorkerIdentityIsRejected() async {
        let outcome = await submit(mode: "wrong-worker-identity")
        guard case .infrastructureFailure(.unexpectedWorkerIdentity(let expected, let actual)) = outcome else {
            return XCTFail("Expected .unexpectedWorkerIdentity, got \(outcome)")
        }
        XCTAssertEqual(expected, "LectureRecorderWorkerFixture")
        XCTAssertTrue(actual.hasPrefix("not-"))
    }

    // MARK: - Timeout / cancellation surfaced as infrastructure failures

    func testTimeoutProducesInfrastructureFailure() async {
        let outcome = await submit(mode: "delayed-response", overallTimeout: 0.2, gracePeriod: 0.2)
        guard case .infrastructureFailure(.process(.timedOut)) = outcome else {
            return XCTFail("Expected .process(.timedOut), got \(outcome)")
        }
    }

    func testCancellationProducesInfrastructureFailure() async {
        let task = Task {
            await self.submit(mode: "delayed-response", overallTimeout: 5.0)
        }
        task.cancel()
        let outcome = await task.value
        guard case .infrastructureFailure(.process(.cancelled)) = outcome else {
            return XCTFail("Expected .process(.cancelled), got \(outcome)")
        }
    }

    // MARK: - No response accepted after an intervention

    func testValidResponseAlreadyDeliveredIsDiscardedIfInterventionClaimsFirst() async {
        // The fixture writes a fully valid, matching success response and
        // then hangs. Proves a complete, well-formed response already
        // sitting in the pipe is discarded — never returned as success —
        // once a fatal intervention (here: timeout) has already claimed
        // the outcome.
        let outcome = await submit(mode: "respond-then-hang", overallTimeout: 0.3, gracePeriod: 0.3)
        guard case .infrastructureFailure(.process(.timedOut)) = outcome else {
            return XCTFail("Expected .process(.timedOut) even though a valid response was already written, got \(outcome)")
        }
    }

    // MARK: - Invalid success/failure shape

    func testOutcomeSuccessWithMissingOutputIsRejected() async {
        let outcome = await submit(mode: "invalid-outcome-success-with-no-output")
        guard case .infrastructureFailure(.invalidOutcomeShape) = outcome else {
            return XCTFail("Expected .invalidOutcomeShape, got \(outcome)")
        }
    }

    func testOutcomeWithBothOutputAndFailurePresentIsRejected() async {
        let outcome = await submit(mode: "invalid-outcome-both-present")
        guard case .infrastructureFailure(.invalidOutcomeShape) = outcome else {
            return XCTFail("Expected .invalidOutcomeShape, got \(outcome)")
        }
    }

    // MARK: - Stderr truncation does not corrupt an otherwise-valid success

    func testStderrOutputAlongsideSuccessDoesNotInvalidateTheResult() async {
        let outcome = await client.submit(
            payload: EmptyTestPayload(),
            identity: WorkerFixtureTestSupport.makeIdentity(),
            outputType: TestFixtureOutput.self,
            arguments: ["--mode=large-stderr"],
            limits: WorkerInvocationLimits(maximumStderrBytes: 4096, overallTimeout: 10.0)
        )
        guard case .success(let output) = outcome else {
            return XCTFail("Verbose stderr must not invalidate an otherwise-valid success; got \(outcome)")
        }
        XCTAssertEqual(output.text, "fixture transcript")
    }

    // MARK: - No production call site

    func testNoProductionCodePathReferencesTheWorkerClient() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TranscriptionWorkerClientTests.swift -> Process (tests)
            .deletingLastPathComponent() // Process (tests) -> Transcription (tests)
            .deletingLastPathComponent() // Transcription (tests) -> Services (tests)
            .deletingLastPathComponent() // Services (tests) -> LectureRecorderTests
            .deletingLastPathComponent() // LectureRecorderTests -> repo root

        let productionFilesToCheck = [
            "LectureRecorder/Services/SessionManager.swift",
            "LectureRecorder/AppEnvironment.swift",
        ]

        var checkedAtLeastOneFile = false
        for relativePath in productionFilesToCheck {
            let url = repositoryRoot.appendingPathComponent(relativePath)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("Could not read \(relativePath) at resolved path \(url.path) — path resolution may be wrong, not just a missing file")
                continue
            }
            checkedAtLeastOneFile = true
            XCTAssertFalse(contents.contains("TranscriptionWorkerClient"), "\(relativePath) must not reference TranscriptionWorkerClient")
            XCTAssertFalse(contents.contains("FoundationProcessRunner"), "\(relativePath) must not reference FoundationProcessRunner")
            XCTAssertFalse(contents.contains("EmbeddedWorkerLocator"), "\(relativePath) must not reference EmbeddedWorkerLocator")
        }
        XCTAssertTrue(checkedAtLeastOneFile, "Expected to actually check at least one production file, not silently skip all of them")
    }
}
