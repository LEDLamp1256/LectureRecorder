import XCTest
@testable import LectureRecorder

/// Permanent regression coverage for the empirically-verified (not
/// Apple-documented) property `FoundationProcessRunner`'s design depends
/// on: `Process.terminationHandler` still fires — asynchronously, exactly
/// once — even when installed after the process has already exited.
/// `ManagedProcess.observeTermination` installs the handler strictly
/// after `launch()`, which can be well after a very fast child has
/// already exited; if this property ever stopped holding on a future
/// toolchain, `FoundationProcessRunner.waitForTermination`'s continuation
/// would never resume and every invocation would hang forever. A modest
/// repeated count (not the full 500-iteration stress probe used to
/// originally validate this) keeps this fast while still being a real,
/// non-trivial regression check rather than a single lucky sample.
///
/// The complementary "no continuation left unresolved on launch failure"
/// property is covered by
/// `FoundationProcessRunnerTests.testLaunchFailureReturnsPromptlyRatherThanHanging`
/// at the integration level — the property that actually matters in
/// production is whether `FoundationProcessRunner.run()` hangs, and
/// `ManagedProcess.observeTermination`'s own precondition (it may only be
/// called after a successful `launch()`) makes the misuse this test would
/// otherwise probe a hard, immediate crash rather than a silent hang, so
/// there is no meaningful separate unit-level "dangling continuation"
/// scenario to construct here without deliberately triggering that
/// precondition trap.
final class ManagedProcessTerminationHandlerTests: XCTestCase {
    private var fixtureURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureURL = try WorkerFixtureTestSupport.resolveFixtureURLOrFail()
    }

    func testHandlerFiresExactlyOnceWhenInstalledAfterAFastChildHasAlreadyExited() async throws {
        let iterations = 25
        var missed = 0

        for _ in 0..<iterations {
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            let managedProcess = ManagedProcess { process in
                process.executableURL = self.fixtureURL
                process.arguments = ["--mode=empty-stdout"]
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
            }

            guard case .success = managedProcess.launch() else {
                return XCTFail("Expected launch to succeed")
            }
            try? stdinPipe.fileHandleForWriting.close()

            // Deliberately wait past this fixture's own typical exit time
            // BEFORE installing the termination handler at all — the
            // scenario this test exists to prove safe.
            let deadline = Date().addingTimeInterval(2.0)
            while managedProcess.isRunning, Date() < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertFalse(managedProcess.isRunning, "fixture should have already exited before observation is installed")

            let fired = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var didFire = false
                managedProcess.observeTermination { _ in
                    didFire = true
                    continuation.resume(returning: didFire)
                }
                // Fallback in case the handler never fires: resume after a
                // bounded wait so this test fails loudly instead of
                // hanging the suite. (If this branch is ever hit, `fired`
                // is reported false and the assertion below fails.)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                    if !didFire {
                        continuation.resume(returning: false)
                    }
                }
            }

            if !fired {
                missed += 1
            }
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        XCTAssertEqual(missed, 0, "termination handler failed to fire for \(missed)/\(iterations) fast-exit-then-observe iterations")
    }
}
