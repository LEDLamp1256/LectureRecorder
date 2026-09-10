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

    /// Unlike the test above (large stdout + large stderr, but a trivially
    /// small stdin), this exercises all three directions under genuine
    /// pressure at once: a multi-megabyte stdin write that must remain
    /// in flight *while* the child is simultaneously writing large stdout
    /// and stderr streams it expects to be drained concurrently. See the
    /// `three-way-pipe-pressure` fixture mode's own comment for exactly
    /// which serialized-I/O ordering this would deadlock under.
    func testThreeDirectionPipePressureCompletesWithoutDeadlock() async throws {
        let stdinPayload = Data(repeating: 0x53, count: 4 * 1024 * 1024) // 'S', 4MiB
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=three-way-pipe-pressure"],
            stdin: stdinPayload,
            maximumStdinBytes: 8 * 1024 * 1024,
            maximumStdoutBytes: 16 * 1024 * 1024,
            maximumStderrBytes: 16 * 1024 * 1024,
            overallTimeout: 10.0
        )

        let started = Date()
        let result = try await requireSuccess(await runner.run(request))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8.0, "genuine concurrent three-direction drainage should not need to wait out a deadlock-avoidance timeout")
        // Stdout carries the 2MiB filler plus a trailing "STDIN_BYTES=..."
        // marker, so it is strictly greater; stderr is exactly the 2MiB
        // filler (64 * 32KiB) with nothing appended, so it must be compared
        // with >=, not >.
        XCTAssertGreaterThan(result.stdout.count, 2 * 1024 * 1024, "expected the interleaved stdout filler to have been fully drained")
        XCTAssertGreaterThanOrEqual(result.stderr.count, 2 * 1024 * 1024, "expected the interleaved stderr filler to have been fully drained")

        guard let stdoutText = String(data: result.stdout, encoding: .utf8) else {
            return XCTFail("expected stdout to decode as UTF-8")
        }
        XCTAssertTrue(
            stdoutText.contains("STDIN_BYTES=\(stdinPayload.count)"),
            "expected the child to confirm it fully drained the large stdin payload, proving the parent's write was not left stuck mid-delivery"
        )
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

    /// `deliverStdin` never checks `Task.isCancelled` — it only stops
    /// writing on a genuine write failure. `onCancel` (in `run(_:)`)
    /// synchronously calls `state.recordFatalIntervention(.cancelled)`
    /// the instant `task.cancel()` returns, strictly before anything else
    /// could cause this blocked write to fail (nothing else is happening:
    /// the child isn't reading, isn't exiting, isn't closing its read
    /// end — the only thing that can ever unblock or fail this write is
    /// the escalation watcher's later `terminate()` call, which itself
    /// only fires after observing `.cancelled` already recorded). So once
    /// the write is confirmed genuinely blocked, cancellation winning is
    /// not a coin flip — it is a direct consequence of `recordFatalIntervention`'s
    /// first-wins, mutex-guarded semantics. The readiness gate below (the
    /// child announces it has committed to not reading, immediately before
    /// its read-free delay) replaces the previous approach of guessing a
    /// sleep is long enough for the write to have genuinely started
    /// blocking, letting this test assert exactly `.cancelled`.
    func testCancellationWhileStdinGenuinelyBlockedTerminatesChildAndFinishes() async throws {
        let readyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("t2-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyFileURL) }

        let largeStdin = Data(repeating: 0x43, count: 4 * 1024 * 1024)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=delay-read-stdin", "--delay-ms=5000", "--ready-file=\(readyFileURL.path)"],
            stdin: largeStdin,
            maximumStdinBytes: 8 * 1024 * 1024,
            overallTimeout: 10.0
        )

        let task = Task { await runner.run(request) }

        // Poll the genuine, out-of-band readiness signal — the child has
        // committed to not reading stdin — rather than sleeping an
        // arbitrary guessed duration.
        let readinessDeadline = Date().addingTimeInterval(5.0)
        while !FileManager.default.fileExists(atPath: readyFileURL.path) {
            if Date() > readinessDeadline {
                XCTFail("Fixture never announced readiness")
                task.cancel()
                _ = await task.value
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // The child has stopped reading; with a 4MiB payload against a
        // pipe buffer several orders of magnitude smaller, the parent's
        // write is at this point either already blocked or about to block
        // imminently. A short margin here only guards against scheduling
        // jitter between the readiness signal landing and the write call
        // being dispatched onto its own queue — it does not paper over any
        // genuine race in the outcome itself (see doc comment above).
        try await Task.sleep(nanoseconds: 100_000_000)

        let started = Date()
        task.cancel()
        let outcome = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0, "cancellation should not need to wait for the full 5s read delay")

        guard case .failure(.cancelled) = outcome else {
            return XCTFail("Expected exactly .cancelled once the write is confirmed genuinely blocked, got \(outcome)")
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

    // MARK: - I/O failures publish at discovery time (not only after join)

    /// Regression test for a real, confirmed bug: an earlier version only
    /// recorded a stdin-delivery failure into `ProcessInvocationState`
    /// after every `async let` (including the timeout watcher) had
    /// already been joined. A child that broke the stdin contract and
    /// then hung would wait out the *entire* `overallTimeout` and
    /// misclassify as `.timedOut` instead of `.stdinDeliveryFailed`,
    /// because the watcher's own timeout won the race to
    /// `recordFatalIntervention` first. The fixture here closes stdin
    /// immediately and then hangs for 30s — well past `overallTimeout` —
    /// so a correct implementation must classify this as
    /// `.stdinDeliveryFailed`, promptly, well before the 30s hang or even
    /// the (deliberately generous) `overallTimeout` below.
    func testStdinFailsThenHangsProducesPromptStdinDeliveryFailedNotTimedOut() async throws {
        let largeStdin = Data(repeating: 0x45, count: 4 * 1024 * 1024)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=close-stdin-then-hang"],
            stdin: largeStdin,
            maximumStdinBytes: 8 * 1024 * 1024,
            overallTimeout: 10.0 // deliberately generous — the point is we must NOT wait this long
        )

        let started = Date()
        let outcome = await runner.run(request)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3.0, "a stdin-delivery failure must be published and terminate the invocation promptly, not wait out the 10s overallTimeout")
        guard case .failure(.stdinDeliveryFailed) = outcome else {
            return XCTFail("Expected prompt .stdinDeliveryFailed, got \(outcome) after \(elapsed)s")
        }
    }

    // MARK: - Grace period genuinely elapses (not skipped by cancellation)

    /// Regression test for a second real, confirmed bug introduced while
    /// fixing the first: making the grace-period loop cancellation-aware
    /// (to stop a busy-spin) caused cancellation to skip the entire grace
    /// period instead of merely avoiding the spin, because
    /// `watchAndEscalate` inherits cancellation from `run(_:)`'s task and
    /// is almost always already cancelled by the time it reaches the
    /// escalation loop. This test uses a genuine file-based readiness
    /// gate (not an arbitrary sleep) to prove the SIGTERM-ignore handler
    /// is installed before cancellation is triggered, then asserts the
    /// configured grace period actually elapses before forced termination
    /// — and that the child is confirmed terminated before the call
    /// returns.
    func testCancellationAgainstSIGTERMResistantChildWaitsOutRealGracePeriod() async throws {
        let readyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("t2-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyFileURL) }

        let gracePeriod: TimeInterval = 1.0
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=ignore-sigterm-announce-ready", "--ready-file=\(readyFileURL.path)"],
            stdin: Data(),
            overallTimeout: 10.0,
            gracePeriod: gracePeriod
        )

        let task = Task { await runner.run(request) }

        // Poll the genuine, out-of-band readiness signal rather than
        // sleeping an arbitrary guessed duration.
        let readinessDeadline = Date().addingTimeInterval(5.0)
        while !FileManager.default.fileExists(atPath: readyFileURL.path) {
            if Date() > readinessDeadline {
                XCTFail("Fixture never announced readiness")
                task.cancel()
                _ = await task.value
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let cancelledAt = Date()
        task.cancel()
        let outcome = await task.value
        let elapsedSinceCancel = Date().timeIntervalSince(cancelledAt)

        guard case .failure(.cancelled) = outcome else {
            return XCTFail("Expected .cancelled, got \(outcome)")
        }
        // The grace period must have genuinely elapsed (SIGTERM alone
        // cannot have ended this child — it's ignored — so reaching
        // termination at all proves SIGKILL escalation happened, and the
        // elapsed time proves it didn't happen immediately).
        XCTAssertGreaterThanOrEqual(elapsedSinceCancel, gracePeriod * 0.8, "the configured grace period should genuinely elapse, not be skipped by cancellation")
        XCTAssertLessThan(elapsedSinceCancel, gracePeriod + 5.0, "escalation must still complete promptly after the grace period, not hang")
    }

    /// Confirms the reverse ordering: timeout (not cancellation) is what
    /// first claims the outcome and begins the grace period, and a
    /// cancellation arriving *during* that already-in-progress grace wait
    /// neither shortens it, restarts it, nor changes the final
    /// classification away from `.timedOut`. Timing/scheduling-based
    /// supplementary coverage, not a deterministic gate: it relies on a
    /// fixed `Task.sleep` landing the cancellation inside the grace
    /// window under whatever scheduler this happens to run under, rather
    /// than on an out-of-band readiness signal the way the deterministic
    /// tests elsewhere in this file do.
    func testTimeoutGraceContinuesUnaffectedByLaterCancellation() async throws {
        let gracePeriod: TimeInterval = 1.0
        let overallTimeout: TimeInterval = 0.2
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=ignore-sigterm"],
            stdin: Data(),
            overallTimeout: overallTimeout,
            gracePeriod: gracePeriod
        )

        let started = Date()
        let task = Task { await runner.run(request) }

        // Let the overall timeout fire and grace begin, then cancel partway
        // through the already-in-progress grace window.
        try await Task.sleep(nanoseconds: UInt64((overallTimeout + gracePeriod / 2) * 1_000_000_000))
        task.cancel()

        let outcome = await task.value
        let elapsed = Date().timeIntervalSince(started)

        guard case .failure(.timedOut) = outcome else {
            return XCTFail("Expected .timedOut to remain the classification despite a later cancellation, got \(outcome)")
        }
        // Elapsed time should still reflect the full timeout+grace
        // sequence, not be cut short by the cancellation landing mid-grace.
        XCTAssertGreaterThanOrEqual(elapsed, overallTimeout + gracePeriod * 0.8)
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
