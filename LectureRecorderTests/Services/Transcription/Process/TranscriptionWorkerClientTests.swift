import XCTest
@testable import LectureRecorder

/// Deterministic client/protocol decision-table tests. A fixed
/// `LocalProcessRunning` implementation supplies process-layer outcomes so
/// malformed responses, identity checks, and failure precedence remain
/// authoritative even when Xcode mutates the hosted helper's signature.
final class TranscriptionWorkerClientTests: XCTestCase {
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func set(_ data: Data) { lock.withLock { value = data } }
        func get() -> Data { lock.withLock { value } }
    }

    private struct DeterministicFixtureRunner: LocalProcessRunning {
        func run(_ request: ProcessInvocationRequest) async -> Result<ProcessRunResult, ProcessRunFailure> {
            let mode = request.arguments.first(where: { $0.hasPrefix("--mode=") })?
                .dropFirst("--mode=".count) ?? "success"

            if mode == "delayed-response" {
                if request.overallTimeout <= 0.2 {
                    return .failure(.timedOut(afterSeconds: request.overallTimeout))
                }
                while !Task.isCancelled { await Task.yield() }
                return .failure(.cancelled)
            }
            if mode == "respond-then-hang" {
                return .failure(.timedOut(afterSeconds: request.overallTimeout))
            }

            guard let envelope = try? JSONDecoder().decode(WorkerRequestEnvelope<EmptyTestPayload>.self, from: request.stdin) else {
                return .success(result(stdout: Data(), reason: .exited(status: 1)))
            }
            func response(
                schemaVersion: Int = WorkerProtocolConstants.currentSchemaVersion,
                requestID: UUID? = nil,
                attemptID: UUID? = nil,
                sessionID: UUID? = nil,
                chunkSequenceNumber: Int? = nil,
                sourceIdentity: String? = nil,
                workerIdentifier: String = TrustedWorkerDescriptor.fixture.expectedWorkerIdentifier,
                workerVersion: String = TrustedWorkerDescriptor.fixture.expectedWorkerVersion,
                outcome: WorkerOutcome = .success,
                output: TestFixtureOutput? = TestFixtureOutput(text: "fixture transcript"),
                failure: WorkerDeclaredFailure? = nil
            ) -> Data {
                (try? JSONEncoder().encode(WorkerResponseEnvelope(
                    schemaVersion: schemaVersion,
                    requestID: requestID ?? envelope.requestID,
                    attemptID: attemptID ?? envelope.attemptID,
                    sessionID: sessionID ?? envelope.sessionID,
                    chunkSequenceNumber: chunkSequenceNumber ?? envelope.chunkSequenceNumber,
                    sourceIdentity: sourceIdentity ?? envelope.sourceIdentity,
                    workerIdentifier: workerIdentifier,
                    workerVersion: workerVersion,
                    outcome: outcome,
                    output: output,
                    failure: failure
                ))) ?? Data()
            }

            switch mode {
            case "success": return .success(result(stdout: response()))
            case "failure": return .success(result(stdout: response(
                outcome: .failure,
                output: nil,
                failure: WorkerDeclaredFailure(message: "fixture declared failure")
            )))
            case "nonzero-no-response": return .success(result(stdout: Data(), reason: .exited(status: 7)))
            case "nonzero-with-success-json": return .success(result(stdout: response(), reason: .exited(status: 7)))
            case "self-signal": return .success(result(stdout: Data(), reason: .uncaughtSignal(5)))
            case "empty-stdout": return .success(result(stdout: Data()))
            case "malformed-json": return .success(result(stdout: Data("{not valid json".utf8)))
            case "truncated-json": return .success(result(stdout: response().prefix(12)))
            case "multiple-json-values":
                let one = response()
                return .success(result(stdout: one + one))
            case "trailing-garbage": return .success(result(stdout: response() + Data(" not json garbage".utf8)))
            case "unsupported-schema": return .success(result(stdout: response(schemaVersion: 999)))
            case "mismatch-request-id": return .success(result(stdout: response(requestID: UUID())))
            case "mismatch-attempt-id": return .success(result(stdout: response(attemptID: UUID())))
            case "mismatch-session-id": return .success(result(stdout: response(sessionID: UUID())))
            case "mismatch-chunk-sequence": return .success(result(stdout: response(chunkSequenceNumber: envelope.chunkSequenceNumber + 1)))
            case "mismatch-source-identity": return .success(result(stdout: response(sourceIdentity: envelope.sourceIdentity + "-corrupted")))
            case "wrong-worker-identity": return .success(result(stdout: response(workerIdentifier: "not-LectureRecorderWorkerFixture")))
            case "invalid-outcome-success-with-no-output": return .success(result(stdout: response(output: nil)))
            case "invalid-outcome-both-present": return .success(result(stdout: response(failure: WorkerDeclaredFailure(message: "unexpected"))))
            case "large-stderr-nonzero-exit":
                return .success(result(
                    stdout: Data(),
                    stderr: Data(repeating: 0x41, count: 1024 * 1024),
                    stderrTruncated: true,
                    reason: .exited(status: 3)
                ))
            case "invalid-utf8-stderr-nonzero-exit":
                return .success(result(stdout: Data(), stderr: Data([0xFF, 0xFE, 0xC0, 0x80, 0x41, 0x42, 0x43]), reason: .exited(status: 3)))
            case "short-stderr-nonzero-exit":
                return .success(result(stdout: Data(), stderr: Data("boom: something went wrong".utf8), reason: .exited(status: 3)))
            case "large-stderr":
                return .success(result(stdout: response(), stderr: Data(repeating: 0x41, count: 4096), stderrTruncated: true))
            default:
                return .failure(.launchFailed(underlying: "Unsupported deterministic fixture mode \(mode)"))
            }
        }

        private func result(
            stdout: Data,
            stderr: Data = Data(),
            stderrTruncated: Bool = false,
            reason: ProcessTerminationReason = .exited(status: 0)
        ) -> ProcessRunResult {
            ProcessRunResult(
                stdout: stdout,
                stderr: stderr,
                stderrTruncated: stderrTruncated,
                terminationReason: reason
            )
        }
    }

    private var client: TranscriptionWorkerClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        client = TranscriptionWorkerClient(processRunner: DeterministicFixtureRunner())
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
        guard case .infrastructureFailure(.processFailure(let status, _, _, _)) = outcome else {
            return XCTFail("Expected .processFailure, got \(outcome)")
        }
        XCTAssertEqual(status, 7)
    }

    func testNonzeroExitWithApparentlyValidSuccessJSONCannotBeOverriddenByJSON() async {
        let outcome = await submit(mode: "nonzero-with-success-json")
        guard case .infrastructureFailure(.processFailure(let status, _, _, _)) = outcome else {
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
        guard case .infrastructureFailure(.processFailure(let status, let signal, _, _)) = outcome else {
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

    // MARK: - Bounded error-description diagnostics

    func testLargeStderrProducesABoundedErrorDescriptionNotTheFullCapture() async {
        let outcome = await submit(mode: "large-stderr-nonzero-exit", overallTimeout: 10.0)
        guard case .infrastructureFailure(let failure) = outcome else {
            return XCTFail("Expected .infrastructureFailure, got \(outcome)")
        }
        guard case .processFailure(_, _, let stderr, _) = failure else {
            return XCTFail("Expected .processFailure, got \(failure)")
        }
        // The retained capture itself is the full ~1 MiB bounded-by-the-
        // runner value — that's approved and expected.
        XCTAssertGreaterThan(stderr.count, 512 * 1024)

        // The rendered description must stay short regardless.
        let description = failure.errorDescription ?? ""
        XCTAssertLessThan(description.utf8.count, 8 * 1024, "errorDescription must stay bounded even when the full retained stderr is ~1 MiB")
        XCTAssertTrue(description.contains("truncated"), "description should explicitly indicate truncation")
    }

    func testInvalidUTF8StderrDoesNotCrashDescriptionRendering() async {
        let outcome = await submit(mode: "invalid-utf8-stderr-nonzero-exit", overallTimeout: 10.0)
        guard case .infrastructureFailure(let failure) = outcome else {
            return XCTFail("Expected .infrastructureFailure, got \(outcome)")
        }
        guard case .processFailure(_, _, let stderr, _) = failure else {
            return XCTFail("Expected .processFailure, got \(failure)")
        }
        // The fixture actually wrote invalid-UTF-8 bytes — confirm that,
        // not just that some description exists (a wrong outcome case, or
        // a fixture that emitted nothing, would otherwise pass vacuously).
        XCTAssertEqual(stderr, Data([0xFF, 0xFE, 0xC0, 0x80, 0x41, 0x42, 0x43]))
        // Reaching this line without a crash is itself part of the proof.
        let description = failure.errorDescription ?? ""
        XCTAssertTrue(description.contains("7 bytes captured"))
        XCTAssertTrue(description.contains("ABC"), "the trailing valid ASCII bytes should still render through the replacement characters")
    }

    func testOrdinaryShortDiagnosticsRemainUsefulAndUntruncated() async {
        let outcome = await submit(mode: "short-stderr-nonzero-exit", overallTimeout: 5.0)
        guard case .infrastructureFailure(let failure) = outcome else {
            return XCTFail("Expected .infrastructureFailure, got \(outcome)")
        }
        guard case .processFailure(_, _, let stderr, let stderrTruncated) = failure else {
            return XCTFail("Expected .processFailure, got \(failure)")
        }
        XCTAssertEqual(stderr, Data("boom: something went wrong".utf8))
        XCTAssertFalse(stderrTruncated)
        let description = failure.errorDescription ?? ""
        XCTAssertTrue(description.contains("exit status 3"))
        XCTAssertTrue(description.contains("boom: something went wrong"), "a short diagnostic should render in full")
        XCTAssertFalse(description.contains("[stderr truncated]"))
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

    func testSuccessfulProcessStderrObserverReceivesCapturedDiagnostics() async {
        let observed = DataBox()
        let observingClient = TranscriptionWorkerClient(
            processRunner: DeterministicFixtureRunner(),
            successfulStderrObserver: { observed.set($0) }
        )
        let outcome: WorkerInvocationOutcome<TestFixtureOutput> = await observingClient.submit(
            payload: EmptyTestPayload(),
            identity: WorkerFixtureTestSupport.makeIdentity(),
            outputType: TestFixtureOutput.self,
            arguments: ["--mode=large-stderr"],
            limits: WorkerInvocationLimits(maximumStderrBytes: 4096, overallTimeout: 10.0)
        )
        guard case .success = outcome else {
            return XCTFail("Expected successful diagnostic observation, got \(outcome)")
        }
        XCTAssertEqual(observed.get(), Data(repeating: 0x41, count: 4096))
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
