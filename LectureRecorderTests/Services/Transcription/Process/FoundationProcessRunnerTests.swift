import Darwin
import XCTest
@testable import LectureRecorder

/// Real-child-process integration tests against the embedded, signed
/// `LectureRecorderWorkerFixture` helper, launched from this (hosted)
/// XCTest environment via the same `FoundationProcessRunner` and
/// `EmbeddedWorkerLocator` production code uses. These prove real OS-level
/// process/pipe/signal behavior; they do not prove sandbox feasibility on
/// their own beyond the fact that they succeed at all while hosted — see
/// `EmbeddedWorkerSmokeTests` for dedicated sandbox/signing evidence.
final class FoundationProcessRunnerTests: XCTestCase {
    private var fixtureURL: URL!
    private var runner: FoundationProcessRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureURL = try WorkerFixtureTestSupport.resolveFixtureURLOrFail()
        runner = FoundationProcessRunner(pollInterval: 0.01)
    }

    // MARK: - Argument transmission (no shell, literal bytes)

    func testLiteralArgumentTransmissionWithSpacesQuotesMetacharactersAndUnicode() async throws {
        let literalArguments = [
            "has space",
            "has\"quote",
            "semi;colon",
            "pipe|char",
            "$(command substitution)",
            "`backtick`",
            "unicode-日本語-emoji-🎧",
        ]
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=echo-args"] + literalArguments,
            stdin: Data()
        )

        let result = try await requireSuccess(await runner.run(request))
        let decoded = try JSONDecoder().decode([String].self, from: result.stdout)
        XCTAssertEqual(decoded, literalArguments)
    }

    // MARK: - Stdin delivery

    func testExactStdinBytesRoundTripUnmodified() async throws {
        var bytes = Data()
        for value: UInt8 in 0...255 {
            bytes.append(value)
        }
        bytes.append(contentsOf: Array("special: \"quotes\" ; | $() `tick` 日本語 🎧".utf8))

        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=echo-stdin"],
            stdin: bytes
        )

        let result = try await requireSuccess(await runner.run(request))
        XCTAssertEqual(result.stdout, bytes)
    }

    func testLargeStdinExceedingTypicalPipeCapacityRoundTripsWithoutDeadlock() async throws {
        let largeStdin = Data(repeating: 0x41, count: 2 * 1024 * 1024) // 2 MiB, well beyond default pipe buffer
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=echo-stdin"],
            stdin: largeStdin,
            maximumStdinBytes: 4 * 1024 * 1024
        )

        let result = try await requireSuccess(await runner.run(request))
        XCTAssertEqual(result.stdout, largeStdin)
    }

    func testSimultaneousLargeStdoutAndStderrCompleteWithoutDeadlock() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=large-both"],
            stdin: requestData,
            maximumStdinBytes: 1024,
            maximumStdoutBytes: 32 * 1024 * 1024,
            maximumStderrBytes: 8 * 1024 * 1024,
            overallTimeout: 10.0
        )

        let started = Date()
        let result = try await requireSuccess(await runner.run(request))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8.0, "concurrent drainage should not need to wait out a deadlock-avoidance timeout")
        XCTAssertGreaterThan(result.stdout.count, 1024)
        XCTAssertGreaterThan(result.stderr.count, 0)
    }

    func testChildClosingStdinEarlyBecomesTypedWriteFailureAndDoesNotCrashTestProcess() async throws {
        let largeStdin = Data(repeating: 0x42, count: 2 * 1024 * 1024)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=close-stdin-early"],
            stdin: largeStdin,
            maximumStdinBytes: 4 * 1024 * 1024,
            overallTimeout: 5.0
        )

        let outcome = await runner.run(request)
        switch outcome {
        case .failure(.stdinDeliveryFailed):
            break // expected: caught Swift error, not a crash
        case .success:
            XCTFail("Expected a stdin delivery failure when the child closes stdin early with a large payload in flight")
        case .failure(let other):
            XCTFail("Expected .stdinDeliveryFailed, got \(other)")
        }
        // Reaching this line at all proves this (test host) process was not
        // terminated by an uncaught SIGPIPE.
    }

    func testCancellationWhileStdinGenuinelyBlockedTerminatesChildAndFinishes() async throws {
        let largeStdin = Data(repeating: 0x43, count: 4 * 1024 * 1024)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=delay-read-stdin", "--delay-ms=5000"],
            stdin: largeStdin,
            maximumStdinBytes: 8 * 1024 * 1024,
            overallTimeout: 10.0
        )

        let task = Task { await runner.run(request) }
        try await Task.sleep(nanoseconds: 100_000_000) // let the write genuinely start blocking
        task.cancel()

        let started = Date()
        let outcome = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0, "cancellation should not need to wait for the full 5s read delay")

        switch outcome {
        case .failure(.cancelled), .failure(.stdinDeliveryFailed):
            break // either is a legitimate outcome of this race, both are typed, prompt failures
        default:
            XCTFail("Expected cancellation to produce a prompt, typed failure, got \(outcome)")
        }
    }

    // MARK: - Fail-closed stdin rule

    /// Deterministic proof of the ratified fail-closed stdin rule: the
    /// child closes its read end before the parent's large stdin write
    /// can complete, causing `.stdinDeliveryFailed`, yet still writes a
    /// fully well-formed-looking response and exits 0. The overall
    /// outcome must remain `.stdinDeliveryFailed` — an otherwise-valid
    /// response produced after failed/partial stdin delivery is
    /// discarded, never returned as success.
    func testStdinDeliveryFailureDiscardsAnOtherwiseValidResponse() async throws {
        let largeStdin = Data(repeating: 0x44, count: 4 * 1024 * 1024)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=close-stdin-early-then-respond"],
            stdin: largeStdin,
            maximumStdinBytes: 8 * 1024 * 1024,
            overallTimeout: 5.0
        )

        let outcome = await runner.run(request)
        guard case .failure(.stdinDeliveryFailed) = outcome else {
            return XCTFail("Expected .stdinDeliveryFailed to discard the child's response even though it exited 0 with well-formed-looking JSON, got \(outcome)")
        }
    }

    // MARK: - Raw response bytes pass through unvalidated (layer boundary)

    func testRunnerNeverValidatesJSONShapeItPassesRawBytesThrough() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=malformed-json"],
            stdin: requestData
        )

        let result = try await requireSuccess(await runner.run(request))
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "{not valid json")
    }

    // MARK: - Limits

    func testOversizedRequestIsRejectedBeforeLaunch() async throws {
        let oversized = Data(repeating: 0x41, count: 2048)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=empty-stdout"],
            stdin: oversized,
            maximumStdinBytes: 1024
        )

        let outcome = await runner.run(request)
        guard case .failure(.requestTooLarge(let byteCount, let limit)) = outcome else {
            return XCTFail("Expected .requestTooLarge, got \(outcome)")
        }
        XCTAssertEqual(byteCount, 2048)
        XCTAssertEqual(limit, 1024)
    }

    func testOversizedStdoutTerminatesProcessButFinishesPromptly() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=large-stdout"],
            stdin: requestData,
            maximumStdoutBytes: 1024,
            overallTimeout: 10.0,
            gracePeriod: 0.3
        )

        let started = Date()
        let outcome = await runner.run(request)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
        guard case .failure(.stdoutLimitExceeded(let limit)) = outcome else {
            return XCTFail("Expected .stdoutLimitExceeded, got \(outcome)")
        }
        XCTAssertEqual(limit, 1024)
    }

    func testOversizedStderrIsTruncatedMarkedAndDoesNotInvalidateSuccess() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=large-stderr"],
            stdin: requestData,
            maximumStderrBytes: 1024,
            overallTimeout: 10.0
        )

        let result = try await requireSuccess(await runner.run(request))
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertEqual(result.stderr.count, 1024)
        XCTAssertEqual(result.terminationReason, .exited(status: 0))
    }

    // MARK: - Timeout, cancellation, termination escalation

    func testTimeoutWhileRunningTerminatesPromptlyWithoutWaitingOutTheDelay() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=delayed-response", "--delay-ms=3000"],
            stdin: requestData,
            overallTimeout: 0.3,
            gracePeriod: 0.3
        )

        let started = Date()
        let outcome = await runner.run(request)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2.0, "should not wait out the full 3s delay")
        guard case .failure(.timedOut) = outcome else {
            return XCTFail("Expected .timedOut, got \(outcome)")
        }
    }

    func testCancellationBeforeLaunchPreventsLaunch() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=delayed-response", "--delay-ms=3000"],
            stdin: requestData,
            overallTimeout: 5.0
        )

        let task = Task<Result<ProcessRunResult, ProcessRunFailure>, Never> {
            await runner.run(request)
        }
        task.cancel()

        let started = Date()
        let outcome = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        guard case .failure(.cancelled) = outcome else {
            return XCTFail("Expected .cancelled, got \(outcome)")
        }
    }

    func testCancellationDuringOutputTerminatesPromptly() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=delayed-response", "--delay-ms=3000"],
            stdin: requestData,
            overallTimeout: 10.0
        )

        let task = Task { await runner.run(request) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        let started = Date()
        let outcome = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        guard case .failure(.cancelled) = outcome else {
            return XCTFail("Expected .cancelled, got \(outcome)")
        }
    }

    func testGracefulTerminationAloneIsSufficientForAnOrdinaryChild() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        // No SIGTERM handler installed -> default disposition terminates immediately.
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=delayed-response", "--delay-ms=5000"],
            stdin: requestData,
            overallTimeout: 0.3,
            gracePeriod: 3.0 // generous grace period we should NOT need to wait out
        )

        let started = Date()
        let outcome = await runner.run(request)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.5, "plain SIGTERM should end the child well before the 3s grace period elapses")
        guard case .failure(.timedOut) = outcome else {
            return XCTFail("Expected .timedOut, got \(outcome)")
        }
    }

    func testForcedTerminationWhenSIGTERMIsIgnored() async throws {
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=ignore-sigterm"],
            stdin: Data(),
            overallTimeout: 0.3,
            gracePeriod: 0.3
        )

        let started = Date()
        let outcome = await runner.run(request)
        let elapsed = Date().timeIntervalSince(started)
        // Should take roughly overallTimeout + gracePeriod (escalation needed),
        // but must finish well short of the fixture's own 30s sleep.
        XCTAssertGreaterThan(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 5.0)
        guard case .failure(.timedOut) = outcome else {
            return XCTFail("Expected .timedOut, got \(outcome)")
        }
    }

    // MARK: - Race safety (exactly one outcome, no crash from double-resume)

    func testNaturalExitRacingCancellationYieldsExactlyOneConsistentOutcome() async throws {
        // Cancelling immediately after `Task { ... }` creation lands
        // before the task body ever starts running, every time — the
        // pre-launch check at the top of `performInvocation` catches it,
        // and the process never actually launches. That only proves the
        // pre-launch path works, not the race this test is named for.
        // Staggering an increasing delay before each cancel (0ms up to
        // ~38ms, comfortably past this fixture's own measured ~15ms
        // launch-to-exit time) spreads cancellation across the whole
        // window — some iterations still land pre-launch, others land
        // mid-run, and others land after the process has already exited
        // naturally, which is the actual race this test claims to cover.
        for index in 0..<20 {
            let identity = WorkerFixtureTestSupport.makeIdentity()
            let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
            let request = WorkerFixtureTestSupport.makeRequest(
                executableURL: fixtureURL,
                arguments: ["--mode=success"],
                stdin: requestData,
                overallTimeout: 5.0
            )

            let task = Task { await runner.run(request) }
            try? await Task.sleep(nanoseconds: UInt64(index) * 2_000_000)
            task.cancel()
            let outcome = await task.value

            switch outcome {
            case .success, .failure(.cancelled):
                break // both are legitimate, internally consistent outcomes
            default:
                XCTFail("Unexpected outcome under a natural-exit/cancellation race: \(outcome)")
            }
        }
        // Reaching this point 20 times without a CheckedContinuation
        // double-resume trap (which would crash the process) is itself
        // empirical evidence against double-completion.
    }

    func testNaturalExitRacingTimeoutYieldsExactlyOneConsistentOutcome() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=success"],
            stdin: requestData,
            overallTimeout: 0.001 // races the fixture's own fast completion
        )

        let outcome = await runner.run(request)
        switch outcome {
        case .success, .failure(.timedOut):
            break
        default:
            XCTFail("Unexpected outcome under a natural-exit/timeout race: \(outcome)")
        }
    }

    // MARK: - Launch failure

    /// Regression test for a real, independently-corroborated deadlock: an
    /// earlier implementation created the `terminationHandler` bridge
    /// (`async let`) before calling `process.run()`, so a launch failure
    /// returned without ever awaiting it — Swift's implicit cancel-and-
    /// await at scope exit then blocked forever on a continuation that
    /// could never resume. Before the fix, this exact test would hang
    /// indefinitely rather than fail; the wall-clock bound below is the
    /// actual proof, not merely the returned case.
    func testLaunchFailureReturnsPromptlyRatherThanHanging() async throws {
        let nonexistentURL = URL(fileURLWithPath: "/nonexistent/path/to/nothing-\(UUID().uuidString)")
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: nonexistentURL,
            arguments: [],
            stdin: Data(),
            overallTimeout: 5.0
        )

        let started = Date()
        let outcome = await runner.run(request)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "launch failure must return promptly, not hang")
        guard case .failure(.launchFailed) = outcome else {
            return XCTFail("Expected .launchFailed, got \(outcome)")
        }
    }

    // MARK: - Descriptor-scoped SIGPIPE suppression (F_SETNOSIGPIPE)

    /// Proves the underlying OS mechanism `FoundationProcessRunner`'s
    /// stdin-pipe setup depends on: `fcntl(fd, F_SETNOSIGPIPE, 1)` on an
    /// invalid descriptor fails and reports a recognizable errno. This is
    /// a focused unit test against the raw syscall, not against
    /// `FoundationProcessRunner` itself — injecting a forced-failure seam
    /// into the runner's own pipe creation would distort its production
    /// design for a configuration failure that is not otherwise
    /// deterministically reachable (a freshly-created `Pipe`'s own
    /// descriptor essentially never fails this call in practice).
    func testFcntlSetNoSigPipeFailsWithRecognizableErrnoOnAnInvalidDescriptor() {
        let closedDescriptor: Int32 = 999_999 // never a valid open fd
        errno = 0
        let result = fcntl(closedDescriptor, F_SETNOSIGPIPE, 1)
        XCTAssertNotEqual(result, 0)
        XCTAssertEqual(errno, EBADF)
    }

    /// Confirms this file never installs a process-wide SIGPIPE
    /// disposition change (`signal(SIGPIPE, ...)` / `sigaction`) — the
    /// approved fix is scoped to one file descriptor via `F_SETNOSIGPIPE`
    /// only. A static source check rather than a runtime assertion, since
    /// "no global handler was ever installed" has no runtime-observable
    /// signature to assert against.
    func testFoundationProcessRunnerSourceInstallsNoProcessGlobalSignalHandler() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FoundationProcessRunnerTests.swift -> Process (tests)
            .deletingLastPathComponent() // Process (tests) -> Transcription (tests)
            .deletingLastPathComponent() // Transcription (tests) -> Services (tests)
            .deletingLastPathComponent() // Services (tests) -> LectureRecorderTests
            .deletingLastPathComponent() // LectureRecorderTests -> repo root
            .appendingPathComponent("LectureRecorder/Services/Transcription/Process/FoundationProcessRunner.swift")

        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Strip `//`-prefixed comment lines before scanning: this file's
        // own doc comments legitimately *describe*, in prose, why
        // `signal(SIGPIPE, ...)`/`sigaction()` are avoided — a naive
        // substring search over the raw file (including comments) would
        // false-positive on that very explanation.
        let codeOnlyLines = source
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let codeOnly = codeOnlyLines.joined(separator: "\n")

        XCTAssertFalse(codeOnly.contains("signal(SIGPIPE"), "must not install a process-global SIGPIPE disposition")
        XCTAssertFalse(codeOnly.contains("sigaction("), "must not install a process-global signal handler via sigaction")
        XCTAssertTrue(source.contains("F_SETNOSIGPIPE"), "expected the descriptor-scoped fix to be present")
    }

    // MARK: - Helpers

    private func requireSuccess(
        _ outcome: Result<ProcessRunResult, ProcessRunFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ProcessRunResult {
        switch outcome {
        case .success(let result):
            return result
        case .failure(let failure):
            XCTFail("Expected success, got failure: \(failure)", file: file, line: line)
            throw failure
        }
    }
}
