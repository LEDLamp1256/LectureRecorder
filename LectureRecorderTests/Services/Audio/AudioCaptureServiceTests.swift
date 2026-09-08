//
//  TestBox.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/7/26.
//


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

        await service.stop()
        await service.stop()
    }

    func testFailureCoordinatorDeliversPendingFailureOnItsOwnQueue() async {
        let key = DispatchSpecificKey<Bool>()
        let testQueue = DispatchQueue(
            label: "test.failurecoordinator.pending"
        )
        testQueue.setSpecific(key: key, value: true)

        let coordinator = FailureCoordinator(queue: testQueue)
        let deliveredOnExpectedQueue = TestBox<Bool>(false)
        let delivered = XCTestExpectation(
            description: "onFailure delivered"
        )

        coordinator.reportAsyncFailure(TestError.example)

        coordinator.markCommitted { _ in
            deliveredOnExpectedQueue.set(
                DispatchQueue.getSpecific(key: key) == true
            )
            delivered.fulfill()
        }

        await fulfillment(
            of: [delivered],
            timeout: 1.0
        )

        XCTAssertTrue(
            deliveredOnExpectedQueue.get(),
            "onFailure must be delivered on FailureCoordinator's queue"
        )
    }

    func testFailureCoordinatorDeliversLaterFailureOnItsOwnQueue() async {
        let key = DispatchSpecificKey<Bool>()
        let testQueue = DispatchQueue(
            label: "test.failurecoordinator.later"
        )
        testQueue.setSpecific(key: key, value: true)

        let coordinator = FailureCoordinator(queue: testQueue)
        let deliveredOnExpectedQueue = TestBox<Bool>(false)
        let delivered = XCTestExpectation(
            description: "onFailure delivered"
        )

        coordinator.markCommitted { _ in
            deliveredOnExpectedQueue.set(
                DispatchQueue.getSpecific(key: key) == true
            )
            delivered.fulfill()
        }

        coordinator.reportAsyncFailure(TestError.example)

        await fulfillment(
            of: [delivered],
            timeout: 1.0
        )

        XCTAssertTrue(
            deliveredOnExpectedQueue.get(),
            "onFailure must be delivered on FailureCoordinator's queue"
        )
    }

    func testFailureCoordinatorDeliversAtMostOnceAcrossMultipleFailures() async {
        let coordinator = FailureCoordinator()
        let firstDelivery = XCTestExpectation(
            description: "at least one delivery"
        )
        let deliveryCount = TestBox<Int>(0)

        coordinator.markCommitted { _ in
            deliveryCount.mutate { $0 += 1 }
            firstDelivery.fulfill()
        }

        coordinator.reportAsyncFailure(TestError.example)
        coordinator.reportAsyncFailure(TestError.example)
        coordinator.reportAsyncFailure(TestError.example)

        await fulfillment(
            of: [firstDelivery],
            timeout: 1.0
        )

        try? await Task.sleep(
            nanoseconds: 100_000_000
        )

        XCTAssertEqual(
            deliveryCount.get(),
            1,
            "onFailure must be delivered at most once per cycle"
        )
    }
}

private enum TestError: Error {
    case example
}
