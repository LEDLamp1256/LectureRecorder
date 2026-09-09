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

final class AudioCaptureServiceTests: XCTestCase {
    func testStartBeforePrepareThrows() {
        let service = AudioCaptureService()

        XCTAssertThrowsError(
            try service.start(
                onBuffer: { _ in },
                onFailure: { _ in }
            )
        ) { error in
            guard case AudioCaptureServiceError.startCalledFromInvalidState = error else {
                return XCTFail(
                    "Expected startCalledFromInvalidState, got \(error)"
                )
            }
        }
    }

    func testStopFromIdleIsHarmlessNoOp() async {
        let service = AudioCaptureService()

        let firstOutcome = await service.stop()
        let secondOutcome = await service.stop()

        XCTAssertNil(firstOutcome.failure)
        XCTAssertEqual(firstOutcome.observedCopyFailureCount, 0)
        XCTAssertNil(secondOutcome.failure)
        XCTAssertEqual(secondOutcome.observedCopyFailureCount, 0)
    }

    /// Both tests below construct a real `AudioCaptureService` and call
    /// its real `prepare()` against whatever audio hardware and
    /// microphone permission state actually exist on the machine running
    /// the test — deliberately, since a hardware-free double cannot
    /// reproduce an AVFoundation-internal assertion (see the doc comment
    /// on `testPrepareSucceedsAgainstRealHardwareWithoutCrashing` below).
    /// That makes both opt-in only: skipped by default so the rest of
    /// the suite stays portable to CI/headless environments with no
    /// input device or ungranted microphone permission, and runnable
    /// on demand with `LECTURE_RECORDER_RUN_HARDWARE_TESTS=1`.
    private func skipUnlessHardwareTestsEnabled() throws {
        guard ProcessInfo.processInfo.environment["LECTURE_RECORDER_RUN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip(
                "Skipped by default: exercises a real AVAudioEngine against real audio hardware and requires microphone permission already granted to the test host. Set the environment variable LECTURE_RECORDER_RUN_HARDWARE_TESTS=1 to run it."
            )
        }
    }

    /// Regression test for a real-hardware-only crash: no other test in
    /// this suite ever calls `prepare()` on a real `AudioCaptureService`
    /// against a real `AVAudioEngine` — every other test either exercises
    /// `FailureCoordinator` in isolation or uses the hardware-free
    /// `MockAudioCaptureService`, which has no `AVAudioEngine` at all and
    /// so cannot reproduce an AVFoundation-internal assertion. `prepare()`
    /// previously called `engine.prepare()` before ever accessing
    /// `engine.inputNode`, which crashed on real hardware with "required
    /// condition is false: inputNode != nullptr || outputNode !=
    /// nullptr" — `AVAudioEngine.prepare()` requires the graph to already
    /// contain an instantiated input or output node, and that node is
    /// only lazily attached the first time `.inputNode`/`.outputNode` is
    /// accessed. This exercises the exact previously-crashing call
    /// sequence directly; a mock cannot substitute for it.
    func testPrepareSucceedsAgainstRealHardwareWithoutCrashing() async throws {
        try skipUnlessHardwareTestsEnabled()

        let service = AudioCaptureService()

        let format = try service.prepare()

        XCTAssertGreaterThan(format.sampleRate, 0)
        XCTAssertGreaterThan(format.channelCount, 0)

        _ = await service.stop()
    }

    /// Confirms `cycleState` is only committed away from `.idle` once
    /// `prepare()` fully succeeds: a second `prepare()` attempt while
    /// already `.prepared` is rejected, and `stop()` correctly returns
    /// the cycle to `.idle` so `prepare()` is reusable afterward. Both
    /// share the same single `controlQueue.sync` closure and
    /// mutate-only-at-the-end structure a hardware-format-negotiation
    /// failure would also go through, so this exercises the same
    /// commit-only-on-full-success discipline without needing to force
    /// an actual hardware failure from a test.
    func testPrepareFailureLeavesCycleStateReusable() async throws {
        try skipUnlessHardwareTestsEnabled()

        let service = AudioCaptureService()

        _ = try service.prepare()
        XCTAssertThrowsError(try service.prepare()) { error in
            guard case AudioCaptureServiceError.prepareCalledFromInvalidState = error else {
                return XCTFail("Expected prepareCalledFromInvalidState, got \(error)")
            }
        }

        _ = await service.stop()

        XCTAssertNoThrow(try service.prepare(), "prepare() must be reusable from .idle after stop()")
    }

    // MARK: - FailureCoordinator contract

    func testReportBeforeCloseRunsSideEffectOnceRetainsErrorAndRejectsLaterReports() {
        let coordinator = FailureCoordinator()
        let sideEffectCount = TestBox<Int>(0)

        coordinator.reportFailure(TestError.example) {
            sideEffectCount.mutate { $0 += 1 }
        }

        XCTAssertEqual(
            coordinator.closeAdmission() as? TestError,
            .example
        )

        // A later report must be rejected and must not overwrite the
        // retained error or re-run the first-acceptance side effect.
        coordinator.reportFailure(TestError.tagged(999)) {
            sideEffectCount.mutate { $0 += 1 }
        }

        XCTAssertEqual(
            sideEffectCount.get(),
            1,
            "the first-acceptance side effect must run exactly once"
        )
        XCTAssertEqual(
            coordinator.closeAdmission() as? TestError,
            .example,
            "the retained error must not be overwritten by a later report"
        )
    }

    func testCloseBeforeReportRejectsReportAndLeavesOutcomeNil() {
        let coordinator = FailureCoordinator()
        let sideEffectCount = TestBox<Int>(0)

        XCTAssertNil(coordinator.closeAdmission())

        coordinator.reportFailure(TestError.example) {
            sideEffectCount.mutate { $0 += 1 }
        }

        XCTAssertEqual(
            sideEffectCount.get(),
            0,
            "a report arriving after closure must never run its side effect"
        )
        XCTAssertNil(coordinator.closeAdmission())
    }

    func testFailureAcceptedBeforeCommitmentIsDeliveredOnceOnCommitAndRemainsAvailable() async {
        let coordinator = FailureCoordinator()
        let deliveryCount = TestBox<Int>(0)
        let delivered = XCTestExpectation(description: "delivered")

        coordinator.reportFailure(TestError.example) {}

        coordinator.markCommitted { error in
            deliveryCount.mutate { $0 += 1 }
            XCTAssertEqual(error as? TestError, .example)
            delivered.fulfill()
        }

        await fulfillment(of: [delivered], timeout: 1.0)

        XCTAssertEqual(deliveryCount.get(), 1)
        XCTAssertEqual(
            coordinator.closeAdmission() as? TestError,
            .example,
            "closeAdmission must still return the outcome after delivery"
        )
    }

    func testFailureAcceptedAfterCommitmentIsDeliveredOnceAndRemainsAvailable() async {
        let coordinator = FailureCoordinator()
        let deliveryCount = TestBox<Int>(0)
        let delivered = XCTestExpectation(description: "delivered")

        coordinator.markCommitted { error in
            deliveryCount.mutate { $0 += 1 }
            XCTAssertEqual(error as? TestError, .example)
            delivered.fulfill()
        }

        coordinator.reportFailure(TestError.example) {}

        await fulfillment(of: [delivered], timeout: 1.0)

        XCTAssertEqual(deliveryCount.get(), 1)
        XCTAssertEqual(
            coordinator.closeAdmission() as? TestError,
            .example,
            "closeAdmission must still return the outcome after delivery"
        )
    }

    func testFailureAcceptedBeforeCommitmentIsDeliveredOnDeliveryQueueNeverStateQueue() async {
        let coordinator = FailureCoordinator()
        let observedRole = TestBox<FailureCoordinator.QueueRole?>(nil)
        let delivered = XCTestExpectation(description: "delivered")

        coordinator.reportFailure(TestError.example) {}

        coordinator.markCommitted { error in
            observedRole.set(FailureCoordinator.currentQueueRole())
            XCTAssertEqual(error as? TestError, .example)
            delivered.fulfill()
        }

        await fulfillment(of: [delivered], timeout: 1.0)

        XCTAssertEqual(
            observedRole.get(),
            .delivery,
            "delivery must occur on the dedicated delivery queue, never the coordinator's state queue"
        )
    }

    func testFailureAcceptedAfterCommitmentIsDeliveredOnDeliveryQueueNeverStateQueue() async {
        let coordinator = FailureCoordinator()
        let observedRole = TestBox<FailureCoordinator.QueueRole?>(nil)
        let delivered = XCTestExpectation(description: "delivered")

        coordinator.markCommitted { error in
            observedRole.set(FailureCoordinator.currentQueueRole())
            XCTAssertEqual(error as? TestError, .example)
            delivered.fulfill()
        }

        coordinator.reportFailure(TestError.example) {}

        await fulfillment(of: [delivered], timeout: 1.0)

        XCTAssertEqual(
            observedRole.get(),
            .delivery,
            "delivery must occur on the dedicated delivery queue, never the coordinator's state queue"
        )
    }

    func testDrainDeliveryCompletesImmediatelyWhenNoFailureWasEverClaimed() async {
        let coordinator = FailureCoordinator()

        // Reaching this line without hanging is the proof: an empty
        // deliveryGroup notifies immediately.
        await coordinator.drainDelivery()
    }

    func testDrainDeliveryWaitsForHeldHandlerInvocationToReturn() async {
        let coordinator = FailureCoordinator()
        let handlerStarted = XCTestExpectation(description: "handler started")
        let drainReturnedPrematurely = XCTestExpectation(
            description: "drainDelivery returned prematurely"
        )
        drainReturnedPrematurely.isInverted = true
        let releaseHandler = DispatchSemaphore(value: 0)
        let eventLog = TestBox<[String]>([])

        defer { releaseHandler.signal() }

        coordinator.markCommitted { _ in
            eventLog.mutate { $0.append("handlerStarted") }
            handlerStarted.fulfill()
            releaseHandler.wait()
            eventLog.mutate { $0.append("handlerFinished") }
        }

        coordinator.reportFailure(TestError.example) {}

        await fulfillment(of: [handlerStarted], timeout: 1.0)

        let drainTask = Task {
            await coordinator.drainDelivery()
            drainReturnedPrematurely.fulfill()
        }

        // Bounded guard against premature completion: drainDelivery()
        // must not have returned yet while the claimed handler is still
        // blocked on releaseHandler below.
        await fulfillment(of: [drainReturnedPrematurely], timeout: 0.3)

        releaseHandler.signal()

        await drainTask.value
        eventLog.mutate { $0.append("drainReturned") }

        XCTAssertEqual(
            eventLog.get(),
            ["handlerStarted", "handlerFinished", "drainReturned"],
            "drainDelivery() must not return before the claimed handler invocation finishes"
        )
    }

    func testFailureAcceptedButNeverCommittedIsRetainedNeverDeliveredAndDrainsImmediately() async {
        let coordinator = FailureCoordinator()

        coordinator.reportFailure(TestError.example) {}

        XCTAssertEqual(
            coordinator.closeAdmission() as? TestError,
            .example,
            "a failure accepted before any commitment must still be retained"
        )

        // No markCommitted(...) call ever happens for this coordinator —
        // there is no handler to invoke, so delivery must never be
        // claimed, and drainDelivery() must complete immediately rather
        // than hang waiting for a delivery that was never claimed.
        await coordinator.drainDelivery()
    }

    func testCallbackReentrancyDoesNotDeadlock() async {
        let coordinator = FailureCoordinator()
        let delivered = XCTestExpectation(description: "delivered")
        let reentrantResult = TestBox<Error?>(nil)

        coordinator.markCommitted { _ in
            // A reentrant call back into the coordinator from inside the
            // callback. If delivery happened while still inside the
            // coordinator's queue.sync, this would deadlock and the
            // expectation below would time out.
            reentrantResult.set(coordinator.closeAdmission())
            delivered.fulfill()
        }

        coordinator.reportFailure(TestError.example) {}

        await fulfillment(of: [delivered], timeout: 1.0)

        XCTAssertEqual(reentrantResult.get() as? TestError, .example)
    }

    func testConcurrentReportAndCloseTrialsAreConsistent() async {
        for trial in 0..<50 {
            let coordinator = FailureCoordinator()
            let sideEffectRan = TestBox<Bool>(false)

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    coordinator.reportFailure(TestError.tagged(trial)) {
                        sideEffectRan.set(true)
                    }
                }
                group.addTask {
                    _ = coordinator.closeAdmission()
                }
            }

            let retained = coordinator.closeAdmission()

            XCTAssertEqual(
                retained != nil,
                sideEffectRan.get(),
                "trial \(trial): a retained error must exist if and only if the first-acceptance side effect ran"
            )
        }
    }

    func testClosedOldCoordinatorRejectsLateReportWhileFreshCoordinatorIsIndependent() {
        let oldCoordinator = FailureCoordinator()
        let oldSideEffectCount = TestBox<Int>(0)

        XCTAssertNil(oldCoordinator.closeAdmission())

        oldCoordinator.reportFailure(TestError.example) {
            oldSideEffectCount.mutate { $0 += 1 }
        }

        XCTAssertEqual(oldSideEffectCount.get(), 0)
        XCTAssertNil(oldCoordinator.closeAdmission())

        let freshCoordinator = FailureCoordinator()
        let freshSideEffectCount = TestBox<Int>(0)

        freshCoordinator.reportFailure(TestError.example) {
            freshSideEffectCount.mutate { $0 += 1 }
        }

        XCTAssertEqual(freshSideEffectCount.get(), 1)
        XCTAssertEqual(
            freshCoordinator.closeAdmission() as? TestError,
            .example
        )
    }
}

private enum TestError: Error, Equatable {
    case example
    case tagged(Int)
}
