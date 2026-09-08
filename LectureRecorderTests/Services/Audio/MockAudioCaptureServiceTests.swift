//
//  TestBox.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/7/26.
//


import AVFoundation
import XCTest
@testable import LectureRecorder

private nonisolated final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func mutate(_ transform: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        transform(&value)
    }
}

private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

private func injectOnDetachedThread(
    _ mock: MockAudioCaptureService,
    _ buffer: AVAudioPCMBuffer
) {
    let box = UnsafeSendableBox(value: buffer)

    Thread.detachNewThread {
        mock.injectBuffer(box.value)
    }
}

final class MockAudioCaptureServiceTests: XCTestCase {
    private func makeMonoFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        )!
    }

    private func makeSilentBuffer(
        frameCount: Int,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!

        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }

    private func assertFormatsEqual(
        _ lhs: AVAudioFormat,
        _ rhs: AVAudioFormat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.sampleRate, rhs.sampleRate, file: file, line: line)
        XCTAssertEqual(lhs.channelCount, rhs.channelCount, file: file, line: line)
        XCTAssertEqual(lhs.commonFormat, rhs.commonFormat, file: file, line: line)
        XCTAssertEqual(lhs.isInterleaved, rhs.isInterleaved, file: file, line: line)
    }

    func testPrepareReturnsExpectedFormatWithoutDeliveringBuffers() throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)

        let returned = try mock.prepare()

        assertFormatsEqual(returned, format)
    }

    func testInjectionBeforeStartIsRejected() throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let delivered = TestBox<Bool>(false)

        mock.injectBuffer(
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        try mock.start(
            onBuffer: { _ in
                delivered.set(true)
            },
            onFailure: { _ in }
        )

        XCTAssertFalse(
            delivered.get(),
            "A buffer injected before start() must never reach onBuffer"
        )
    }

    func testInjectionAfterStartDelivers() throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let delivered = TestBox<AVAudioPCMBuffer?>(nil)

        try mock.start(
            onBuffer: { buffer in
                delivered.set(buffer)
            },
            onFailure: { _ in }
        )

        mock.injectBuffer(
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        XCTAssertEqual(
            delivered.get()?.frameLength,
            4
        )
    }

    func testStopPreventsFurtherDelivery() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let deliveryCount = TestBox<Int>(0)

        try mock.start(
            onBuffer: { _ in
                deliveryCount.mutate { $0 += 1 }
            },
            onFailure: { _ in }
        )

        mock.injectBuffer(
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        await mock.stop()

        mock.injectBuffer(
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        XCTAssertEqual(
            deliveryCount.get(),
            1,
            "No delivery should occur after stop()"
        )
    }

    func testStopWaitsForExplicitlyHeldAdmittedCallback() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let onBufferStarted = XCTestExpectation(
            description: "onBuffer started"
        )
        let stopEnteredDraining = XCTestExpectation(
            description: "stop entered draining"
        )
        let stopReturnedPrematurely = XCTestExpectation(
            description: "stop returned prematurely"
        )
        stopReturnedPrematurely.isInverted = true
        let releaseCallback = DispatchSemaphore(value: 0)
        let eventLog = TestBox<[String]>([])

        // Ensure a held callback is always released, even if an
        // assertion above fails and unwinds the test early. Signaling a
        // semaphore more than once is harmless.
        defer { releaseCallback.signal() }

        try mock.start(
            onBuffer: { _ in
                eventLog.mutate { $0.append("callbackStarted") }
                onBufferStarted.fulfill()
                releaseCallback.wait()
                eventLog.mutate { $0.append("callbackFinished") }
            },
            onFailure: { _ in }
        )

        mock.setDidEnterStoppingHookForTesting {
            stopEnteredDraining.fulfill()
        }

        injectOnDetachedThread(
            mock,
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        await fulfillment(
            of: [onBufferStarted],
            timeout: 1.0
        )

        let stopTask = Task<CaptureStopOutcome, Never> {
            let outcome = await mock.stop()
            stopReturnedPrematurely.fulfill()
            return outcome
        }

        // Deterministic: wait for stop() to have actually transitioned
        // into its draining path — not a fixed delay — before relying on
        // (and checking) non-completion.
        await fulfillment(of: [stopEnteredDraining], timeout: 1.0)
        await fulfillment(of: [stopReturnedPrematurely], timeout: 0.3)

        releaseCallback.signal()

        _ = await stopTask.value
        eventLog.mutate { $0.append("stopReturned") }

        XCTAssertEqual(
            eventLog.get(),
            ["callbackStarted", "callbackFinished", "stopReturned"],
            "stop() must not return before the explicitly held admitted callback finishes"
        )
    }

    func testHeldOnFailureInvocationBlocksStopCompletionAndRejectsNewPrepare() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let handlerStarted = XCTestExpectation(description: "onFailure started")
        let stopEnteredDraining = XCTestExpectation(
            description: "stop entered draining"
        )
        let stopReturnedPrematurely = XCTestExpectation(
            description: "stop returned prematurely"
        )
        stopReturnedPrematurely.isInverted = true
        let releaseHandler = DispatchSemaphore(value: 0)
        let eventLog = TestBox<[String]>([])

        defer { releaseHandler.signal() }

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in
                eventLog.mutate { $0.append("handlerStarted") }
                handlerStarted.fulfill()
                releaseHandler.wait()
                eventLog.mutate { $0.append("handlerFinished") }
            }
        )

        mock.setDidEnterStoppingHookForTesting {
            stopEnteredDraining.fulfill()
        }

        mock.simulateAsyncFailure(TestError.tagged(42))

        await fulfillment(of: [handlerStarted], timeout: 1.0)

        let stopTask = Task<CaptureStopOutcome, Never> {
            let outcome = await mock.stop()
            stopReturnedPrematurely.fulfill()
            return outcome
        }

        // Deterministic: wait for stop() to have actually transitioned
        // into its draining path before checking prepare-rejection.
        await fulfillment(of: [stopEnteredDraining], timeout: 1.0)

        XCTAssertThrowsError(
            try mock.prepare()
        ) { error in
            guard case MockAudioCaptureServiceError.prepareCalledFromInvalidState = error else {
                return XCTFail(
                    "Expected prepareCalledFromInvalidState, got \(error)"
                )
            }
        }

        // Bounded guard against premature completion, checked only after
        // the draining transition above is already established.
        await fulfillment(of: [stopReturnedPrematurely], timeout: 0.3)
        XCTAssertFalse(
            eventLog.get().contains("handlerFinished"),
            "the claimed handler must still be executing while stop() drains"
        )

        releaseHandler.signal()

        let outcome = await stopTask.value
        eventLog.mutate { $0.append("stopReturned") }

        XCTAssertEqual(outcome.failure as? TestError, .tagged(42))
        XCTAssertEqual(outcome.observedCopyFailureCount, 0)
        XCTAssertEqual(
            eventLog.get(),
            ["handlerStarted", "handlerFinished", "stopReturned"],
            "stop() must not return, and a new prepare() must be rejected, before the claimed onFailure invocation returns"
        )

        // After releasing: a fresh prepare/start/stop cycle succeeds
        // cleanly and no old callback invocation crosses into it.
        let reprepared = try mock.prepare()
        assertFormatsEqual(reprepared, format)

        let newCycleFailures = TestBox<[Error]>([])

        try mock.start(
            onBuffer: { _ in },
            onFailure: { error in
                newCycleFailures.mutate { $0.append(error) }
            }
        )

        let newOutcome = await mock.stop()

        XCTAssertNil(
            newOutcome.failure,
            "a fresh cycle must not inherit the previous cycle's retained failure"
        )
        XCTAssertEqual(
            newOutcome.observedCopyFailureCount,
            0,
            "a fresh cycle must not inherit the previous cycle's copy-failure count"
        )
        XCTAssertTrue(
            newCycleFailures.get().isEmpty,
            "no old callback invocation may cross into the new cycle"
        )
    }

    func testConcurrentStopCallersRemainPendingDuringHeldFailureHandlerAndReturnSameOutcome() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let handlerStarted = XCTestExpectation(description: "onFailure started")
        let secondCallerJoined = XCTestExpectation(
            description: "second stop() joined in-progress drain"
        )
        let eitherStopReturnedPrematurely = XCTestExpectation(
            description: "a stop() call returned prematurely"
        )
        eitherStopReturnedPrematurely.isInverted = true
        let releaseHandler = DispatchSemaphore(value: 0)
        let eventLog = TestBox<[String]>([])

        defer { releaseHandler.signal() }

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in
                eventLog.mutate { $0.append("handlerStarted") }
                handlerStarted.fulfill()
                releaseHandler.wait()
                eventLog.mutate { $0.append("handlerFinished") }
            }
        )

        mock.setDidJoinInProgressStopHookForTesting {
            secondCallerJoined.fulfill()
        }

        mock.simulateAsyncFailure(TestError.tagged(7))

        await fulfillment(of: [handlerStarted], timeout: 1.0)

        let outcome1Box = TestBox<CaptureStopOutcome?>(nil)
        let outcome2Box = TestBox<CaptureStopOutcome?>(nil)

        let firstTask = Task {
            outcome1Box.set(await mock.stop())
            eitherStopReturnedPrematurely.fulfill()
        }
        let secondTask = Task {
            outcome2Box.set(await mock.stop())
            eitherStopReturnedPrematurely.fulfill()
        }

        // Deterministic: prove the second caller actually observed
        // .stopping and joined the first caller's in-progress drain
        // before relying on (and checking) neither having completed.
        await fulfillment(of: [secondCallerJoined], timeout: 1.0)
        await fulfillment(of: [eitherStopReturnedPrematurely], timeout: 0.3)

        releaseHandler.signal()

        await firstTask.value
        await secondTask.value
        eventLog.mutate { $0.append("stopReturned") }

        XCTAssertEqual(outcome1Box.get()?.failure as? TestError, .tagged(7))
        XCTAssertEqual(outcome1Box.get()?.observedCopyFailureCount, 0)
        XCTAssertEqual(outcome2Box.get()?.failure as? TestError, .tagged(7))
        XCTAssertEqual(outcome2Box.get()?.observedCopyFailureCount, 0)
        XCTAssertEqual(
            eventLog.get(),
            ["handlerStarted", "handlerFinished", "stopReturned"],
            "concurrent stop() callers must both wait for the claimed onFailure invocation to finish and return the same outcome"
        )
    }

    func testStopIsIdempotent() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in }
        )

        await mock.stop()
        await mock.stop()
    }

    func testStopCalledAgainAfterCompletionReturnsSameOutcome() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in }
        )

        // Inject the forced copy failure before reporting the async
        // failure: reportFailure's first-acceptance side effect closes
        // the gate, so admission must happen while it's still open.
        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )
        mock.simulateAsyncFailure(TestError.tagged(9))

        let firstOutcome = await mock.stop()
        let secondOutcome = await mock.stop()

        XCTAssertEqual(firstOutcome.failure as? TestError, .tagged(9))
        XCTAssertEqual(firstOutcome.observedCopyFailureCount, 1)
        XCTAssertEqual(secondOutcome.failure as? TestError, .tagged(9))
        XCTAssertEqual(
            secondOutcome.observedCopyFailureCount,
            1,
            "a repeated idle stop() must retain the completed cycle's copy-failure count"
        )
    }

    func testConcurrentStopCallersJoinSameDrainAndReceiveSameOutcome() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let onBufferStarted = XCTestExpectation(
            description: "onBuffer started"
        )
        let secondCallerJoined = XCTestExpectation(
            description: "second stop() joined in-progress drain"
        )
        let eitherStopReturnedPrematurely = XCTestExpectation(
            description: "a stop() call returned prematurely"
        )
        eitherStopReturnedPrematurely.isInverted = true
        let releaseCallback = DispatchSemaphore(value: 0)
        let eventLog = TestBox<[String]>([])

        defer { releaseCallback.signal() }

        try mock.start(
            onBuffer: { _ in
                eventLog.mutate { $0.append("callbackStarted") }
                onBufferStarted.fulfill()
                releaseCallback.wait()
                eventLog.mutate { $0.append("callbackFinished") }
            },
            onFailure: { _ in }
        )

        mock.setDidJoinInProgressStopHookForTesting {
            secondCallerJoined.fulfill()
        }

        injectOnDetachedThread(
            mock,
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        // Wait until the callback is definitely in flight before stopping.
        await fulfillment(
            of: [onBufferStarted],
            timeout: 1.0
        )

        // A separate, non-blocking forced copy failure, admitted while
        // the gate is still open, so both concurrent callers must
        // observe the same nonzero count in addition to the same error.
        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )

        // Report the failure only once the buffer is already admitted and
        // blocked, so injection isn't rejected by the resulting gate
        // closure.
        mock.simulateAsyncFailure(TestError.tagged(8))

        let outcome1Box = TestBox<CaptureStopOutcome?>(nil)
        let outcome2Box = TestBox<CaptureStopOutcome?>(nil)

        let firstTask = Task {
            outcome1Box.set(await mock.stop())
            eitherStopReturnedPrematurely.fulfill()
        }
        let secondTask = Task {
            outcome2Box.set(await mock.stop())
            eitherStopReturnedPrematurely.fulfill()
        }

        // Deterministic: prove the second caller actually observed
        // .stopping and joined the first caller's in-progress drain
        // before relying on (and checking) neither having completed.
        await fulfillment(of: [secondCallerJoined], timeout: 1.0)
        await fulfillment(of: [eitherStopReturnedPrematurely], timeout: 0.3)

        releaseCallback.signal()

        await firstTask.value
        await secondTask.value
        eventLog.mutate { $0.append("stopReturned") }

        XCTAssertEqual(outcome1Box.get()?.failure as? TestError, .tagged(8))
        XCTAssertEqual(outcome1Box.get()?.observedCopyFailureCount, 1)
        XCTAssertEqual(outcome2Box.get()?.failure as? TestError, .tagged(8))
        XCTAssertEqual(
            outcome2Box.get()?.observedCopyFailureCount,
            1,
            "concurrent stop() callers must receive equivalent failure and copy-failure-count results"
        )
        XCTAssertEqual(
            eventLog.get(),
            ["callbackStarted", "callbackFinished", "stopReturned"],
            "concurrent stop() callers must join the same drain and only return after it completes"
        )
    }

    func testSuccessfulPrepareResetsPreviousOutcome() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in }
        )

        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )
        mock.simulateAsyncFailure(TestError.tagged(10))

        let firstOutcome = await mock.stop()
        XCTAssertEqual(firstOutcome.failure as? TestError, .tagged(10))
        XCTAssertEqual(firstOutcome.observedCopyFailureCount, 1)

        _ = try mock.prepare()

        let secondOutcome = await mock.stop()
        XCTAssertNil(
            secondOutcome.failure,
            "a successful prepare() must reset the previous cycle's outcome"
        )
        XCTAssertEqual(
            secondOutcome.observedCopyFailureCount,
            0,
            "a successful prepare() must reset the previous cycle's copy-failure count"
        )
    }

    func testFailedPrepareWhileRunningLeavesActiveCycleAndOutcomeUnchanged() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in }
        )

        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )
        mock.simulateAsyncFailure(TestError.tagged(11))

        XCTAssertThrowsError(
            try mock.prepare()
        ) { error in
            guard case MockAudioCaptureServiceError.prepareCalledFromInvalidState = error else {
                return XCTFail(
                    "Expected prepareCalledFromInvalidState, got \(error)"
                )
            }
        }

        let outcome = await mock.stop()

        XCTAssertEqual(
            outcome.failure as? TestError,
            .tagged(11),
            "a failed prepare() attempt must not disturb the active cycle's retained outcome"
        )
        XCTAssertEqual(
            outcome.observedCopyFailureCount,
            1,
            "a failed prepare() attempt must not disturb the active cycle's retained copy-failure count"
        )
    }

    func testServiceSupportsSecondFullCycle() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)

        _ = try mock.prepare()

        let firstCycleDeliveries = TestBox<Int>(0)

        try mock.start(
            onBuffer: { _ in
                firstCycleDeliveries.mutate { $0 += 1 }
            },
            onFailure: { _ in }
        )

        mock.injectBuffer(
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        await mock.stop()

        XCTAssertEqual(
            firstCycleDeliveries.get(),
            1
        )

        let secondFormat = try mock.prepare()
        assertFormatsEqual(secondFormat, format)

        let secondCycleDeliveries = TestBox<Int>(0)

        try mock.start(
            onBuffer: { _ in
                secondCycleDeliveries.mutate { $0 += 1 }
            },
            onFailure: { _ in }
        )

        mock.injectBuffer(
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        mock.injectBuffer(
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        await mock.stop()

        XCTAssertEqual(
            secondCycleDeliveries.get(),
            2
        )
    }

    func testMockBehavesDeterministicallyAcrossManyCycles() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)

        for cycle in 0..<5 {
            let returned = try mock.prepare()

            assertFormatsEqual(
                returned,
                format,
                file: #filePath,
                line: UInt(cycle)
            )

            let deliveries = TestBox<Int>(0)

            try mock.start(
                onBuffer: { _ in
                    deliveries.mutate { $0 += 1 }
                },
                onFailure: { _ in }
            )

            mock.injectBuffer(
                makeSilentBuffer(
                    frameCount: 4,
                    format: format
                )
            )

            mock.injectBuffer(
                makeSilentBuffer(
                    frameCount: 4,
                    format: format
                )
            )

            await mock.stop()

            XCTAssertEqual(
                deliveries.get(),
                2,
                "Cycle \(cycle)"
            )
        }
    }

    func testStartFailsWhenPreparedFormatCanNoLongerBeHonored() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        mock.setShouldFailNextStart(true)

        XCTAssertThrowsError(
            try mock.start(
                onBuffer: { _ in },
                onFailure: { _ in }
            )
        ) { error in
            guard case MockAudioCaptureServiceError.simulatedStartFailure = error else {
                return XCTFail(
                    "Expected simulatedStartFailure, got \(error)"
                )
            }
        }

        await mock.stop()

        let reprepared = try mock.prepare()
        assertFormatsEqual(reprepared, format)
    }

    func testThrowingStartRequiresStopBeforeNextPrepareAndNeverDeliversFailure() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        mock.setShouldFailNextStart(true)

        let onFailureCalled = XCTestExpectation(
            description: "onFailure should NOT be called"
        )
        onFailureCalled.isInverted = true

        XCTAssertThrowsError(
            try mock.start(
                onBuffer: { _ in },
                onFailure: { _ in
                    onFailureCalled.fulfill()
                }
            )
        )

        // A prepare() immediately after a throwing start() must fail —
        // the caller has not yet run stop() cleanup for the uncommitted
        // attempt.
        XCTAssertThrowsError(
            try mock.prepare()
        ) { error in
            guard case MockAudioCaptureServiceError.prepareCalledFromInvalidState = error else {
                return XCTFail(
                    "Expected prepareCalledFromInvalidState, got \(error)"
                )
            }
        }

        let outcome = await mock.stop()
        XCTAssertNil(
            outcome.failure,
            "an uncommitted attempt with no failure ever reported has no retained asynchronous outcome"
        )
        XCTAssertEqual(outcome.observedCopyFailureCount, 0)

        await fulfillment(
            of: [onFailureCalled],
            timeout: 0.3
        )

        // Only after stop() completes is a new prepare() allowed.
        let reprepared = try mock.prepare()
        assertFormatsEqual(reprepared, format)
    }

    func testFailureReportedDuringUncommittedThrowingStartCycleIsRetainedButNeverDelivered() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        mock.setShouldFailNextStart(true)

        let onFailureCalled = XCTestExpectation(
            description: "onFailure should NOT be called"
        )
        onFailureCalled.isInverted = true

        XCTAssertThrowsError(
            try mock.start(
                onBuffer: { _ in },
                onFailure: { _ in
                    onFailureCalled.fulfill()
                }
            )
        )

        // A prepare() immediately after a throwing start() must fail —
        // the caller has not yet run stop() cleanup for the uncommitted
        // attempt.
        XCTAssertThrowsError(
            try mock.prepare()
        ) { error in
            guard case MockAudioCaptureServiceError.prepareCalledFromInvalidState = error else {
                return XCTFail(
                    "Expected prepareCalledFromInvalidState, got \(error)"
                )
            }
        }

        // start() throws only after cycleState is already set to
        // .running(resources) — the gate and coordinator for this
        // attempt exist even though onFailure was never committed. Lack
        // of commitment must not be conflated with lack of a retained
        // failure: an asynchronous failure reported into this window is
        // still admitted, and stop()/closeAdmission() must still surface
        // it, even though no handler was ever committed to receive it.
        mock.simulateAsyncFailure(TestError.tagged(13))

        let outcome = await mock.stop()

        XCTAssertEqual(
            outcome.failure as? TestError,
            .tagged(13),
            "stop() must return whatever failure was actually admitted for the cycle, even though no handler was ever committed to receive it"
        )
        XCTAssertEqual(outcome.observedCopyFailureCount, 0)

        await fulfillment(
            of: [onFailureCalled],
            timeout: 0.3
        )

        // Only after stop() completes is a new prepare() allowed.
        let reprepared = try mock.prepare()
        assertFormatsEqual(reprepared, format)
    }

    func testNormalCleanStopNeverTriggersFailure() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let onFailureCalled = XCTestExpectation(
            description: "onFailure should not fire"
        )
        onFailureCalled.isInverted = true

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in
                onFailureCalled.fulfill()
            }
        )

        mock.injectBuffer(
            makeSilentBuffer(
                frameCount: 4,
                format: format
            )
        )

        await mock.stop()

        await fulfillment(
            of: [onFailureCalled],
            timeout: 0.3
        )
    }

    func testSimulateAsyncFailureDeliversAtMostOnce() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let failureCount = TestBox<Int>(0)

        let firstDelivery = XCTestExpectation(
            description: "onFailure delivered"
        )

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in
                failureCount.mutate { $0 += 1 }
                firstDelivery.fulfill()
            }
        )

        mock.simulateAsyncFailure(TestError.example)
        mock.simulateAsyncFailure(TestError.example)
        mock.simulateAsyncFailure(TestError.example)

        await fulfillment(
            of: [firstDelivery],
            timeout: 1.0
        )

        try? await Task.sleep(
            nanoseconds: 100_000_000
        )

        XCTAssertEqual(
            failureCount.get(),
            1
        )

        await mock.stop()
    }

    // MARK: - CaptureStopOutcome

    func testInitialIdleStopReturnsCleanOutcome() async {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)

        let outcome = await mock.stop()

        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.observedCopyFailureCount, 0)
    }

    func testPreparedButNeverStartedStopReturnsCleanOutcome() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let outcome = await mock.stop()

        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.observedCopyFailureCount, 0)
    }

    func testForcedCopyFailureRecordsDropAndDoesNotHandOffBuffer() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let delivered = TestBox<Bool>(false)

        try mock.start(
            onBuffer: { _ in
                delivered.set(true)
            },
            onFailure: { _ in }
        )

        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )

        let outcome = await mock.stop()

        XCTAssertFalse(
            delivered.get(),
            "a forced copy failure must never hand a buffer to onBuffer"
        )
        XCTAssertEqual(outcome.observedCopyFailureCount, 1)
    }

    func testAdmittedCopyFailureAfterStopBeginsIsWaitedForAndIncluded() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let copyStarted = XCTestExpectation(description: "copy started")
        let stopEnteredDraining = XCTestExpectation(
            description: "stop entered draining"
        )
        let stopReturnedPrematurely = XCTestExpectation(
            description: "stop returned prematurely"
        )
        stopReturnedPrematurely.isInverted = true
        let releaseCopy = DispatchSemaphore(value: 0)
        let eventLog = TestBox<[String]>([])

        defer { releaseCopy.signal() }

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in }
        )

        mock.setDidEnterStoppingHookForTesting {
            stopEnteredDraining.fulfill()
        }

        let box = UnsafeSendableBox(
            value: makeSilentBuffer(frameCount: 4, format: format)
        )

        // The admission (tryEnter) happens on this detached thread before
        // stop() is ever called below — the callback is already admitted
        // by the time stop() begins closing the gate. It only *records*
        // its failure after being released, which happens after stop()
        // has already entered its draining path.
        Thread.detachNewThread {
            mock.injectBufferForcingCopyFailureBlockingUntilReleased(
                box.value,
                onCopyStarted: {
                    eventLog.mutate { $0.append("copyStarted") }
                    copyStarted.fulfill()
                },
                releaseCopy: releaseCopy
            )
        }

        await fulfillment(of: [copyStarted], timeout: 1.0)

        let stopTask = Task<CaptureStopOutcome, Never> {
            let outcome = await mock.stop()
            stopReturnedPrematurely.fulfill()
            return outcome
        }

        // Deterministic: wait for stop() to have actually transitioned
        // into its draining path — not a fixed delay — before relying on
        // (and checking) non-completion.
        await fulfillment(of: [stopEnteredDraining], timeout: 1.0)
        await fulfillment(of: [stopReturnedPrematurely], timeout: 0.3)

        releaseCopy.signal()

        let outcome = await stopTask.value
        eventLog.mutate { $0.append("stopReturned") }

        XCTAssertEqual(
            outcome.observedCopyFailureCount,
            1,
            "stop() must wait for an admitted-but-still-copying callback and include its recorded failure"
        )
        XCTAssertEqual(
            eventLog.get(),
            ["copyStarted", "stopReturned"],
            "stop() must not return before the admitted copy failure resolves"
        )
    }

    func testRetainedFailureAndObservedCopyFailureCountCoexist() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in }
        )

        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )
        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )
        mock.simulateAsyncFailure(TestError.tagged(14))

        let outcome = await mock.stop()

        XCTAssertEqual(outcome.failure as? TestError, .tagged(14))
        XCTAssertEqual(outcome.observedCopyFailureCount, 2)
    }

    func testOldStopCallerReceivesOwnCycleResultEvenAfterNewCycleBeginsAndCompletes() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let handlerStarted = XCTestExpectation(description: "onFailure started")
        let stopEnteredDraining = XCTestExpectation(
            description: "stop entered draining"
        )
        let reachedPostResolutionHook = XCTestExpectation(
            description: "old caller reached post-resolution hook"
        )
        let releaseHandler = DispatchSemaphore(value: 0)
        let releasePostResolutionHook = DispatchSemaphore(value: 0)

        // Ensure both holds are always released, even if an assertion
        // above fails and unwinds the test early.
        defer {
            releaseHandler.signal()
            releasePostResolutionHook.signal()
        }

        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in
                handlerStarted.fulfill()
                releaseHandler.wait()
            }
        )

        mock.setDidEnterStoppingHookForTesting {
            stopEnteredDraining.fulfill()
        }

        // Cycle A gets a distinctive failure AND a distinctive
        // copy-failure count, injected before the async failure closes
        // the gate, so the eventual assertion can't pass by coincidence
        // against cycle B's (different) values.
        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )
        mock.simulateAsyncFailure(TestError.tagged(100))

        await fulfillment(of: [handlerStarted], timeout: 1.0)

        // Set the post-resolution hook before starting the old caller,
        // so the old caller is guaranteed to reach it once its shared
        // task resolves — this deterministically pauses that specific
        // caller after cycleState/lastCompletedOutcome are already
        // published, but strictly before it returns its outcome.
        mock.setPostResolutionHookForTesting {
            reachedPostResolutionHook.fulfill()
            releasePostResolutionHook.wait()
        }

        // Old caller: its stop() call is the one that transitions cycle
        // A from .running to .stopping and owns the shared drain task.
        // It is deliberately never awaited to completion until the very
        // end of this test — well after cycle B has begun and finished.
        let oldCallerTask = Task<CaptureStopOutcome, Never> {
            await mock.stop()
        }

        await fulfillment(of: [stopEnteredDraining], timeout: 1.0)

        // Release cycle A's handler so its shared task can resolve and
        // publish cycleState = .idle / lastCompletedOutcome.
        releaseHandler.signal()

        // The old caller's `await task.value` has now returned (task
        // resolved, idle state already published) and it has reached
        // the new post-resolution hook, where it is deterministically
        // blocked — not yet having returned its CaptureStopOutcome.
        await fulfillment(of: [reachedPostResolutionHook], timeout: 1.0)

        // Confirm cycle A has already published idle state: a fresh,
        // independent stop() call — distinct from the still-blocked old
        // caller — observes .idle directly and returns the retained
        // outcome immediately, without needing to await any task.
        let settledOutcome = await mock.stop()
        XCTAssertEqual(settledOutcome.failure as? TestError, .tagged(100))
        XCTAssertEqual(settledOutcome.observedCopyFailureCount, 1)

        // Cycle B: a full, independent cycle with a different failure
        // AND a different copy-failure count, begun and completed
        // entirely while the old caller remains blocked inside the
        // post-resolution hook.
        _ = try mock.prepare()
        try mock.start(
            onBuffer: { _ in },
            onFailure: { _ in }
        )
        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )
        mock.injectBufferForcingCopyFailure(
            makeSilentBuffer(frameCount: 4, format: format)
        )
        mock.simulateAsyncFailure(TestError.tagged(200))
        let cycleBOutcome = await mock.stop()
        XCTAssertEqual(cycleBOutcome.failure as? TestError, .tagged(200))
        XCTAssertEqual(cycleBOutcome.observedCopyFailureCount, 2)

        // Release the old caller only now — strictly after cycle B has
        // begun and fully completed.
        releasePostResolutionHook.signal()

        let oldOutcome = await oldCallerTask.value

        XCTAssertEqual(
            oldOutcome.failure as? TestError,
            .tagged(100),
            "an old stop() caller must receive its own cycle's failure, not a later cycle's"
        )
        XCTAssertEqual(
            oldOutcome.observedCopyFailureCount,
            1,
            "an old stop() caller must receive its own cycle's copy-failure count, not a later cycle's"
        )
    }
}

private enum TestError: Error, Equatable {
    case example
    case tagged(Int)
}
