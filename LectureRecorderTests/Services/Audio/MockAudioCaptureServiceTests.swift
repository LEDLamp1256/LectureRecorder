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

    func testStopWaitsForInFlightInjection() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let onBufferStarted = XCTestExpectation(
            description: "onBuffer started"
        )

        let onBufferFinished = XCTestExpectation(
            description: "onBuffer finished"
        )

        try mock.start(
            onBuffer: { _ in
                onBufferStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.2)
                onBufferFinished.fulfill()
            },
            onFailure: { _ in }
        )

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

        let stopStart = Date()
        await mock.stop()
        let stopDuration = Date().timeIntervalSince(stopStart)

        XCTAssertGreaterThanOrEqual(
            stopDuration,
            0.15,
            "stop() should wait for the in-flight onBuffer to finish"
        )

        await fulfillment(
            of: [onBufferFinished],
            timeout: 1.0
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

    func testConcurrentStopCallsAllWaitForFullDrain() async throws {
        let format = makeMonoFormat()
        let mock = MockAudioCaptureService(formatToPrepare: format)
        _ = try mock.prepare()

        let onBufferStarted = XCTestExpectation(
            description: "onBuffer started"
        )

        let onBufferFinished = XCTestExpectation(
            description: "onBuffer finished"
        )

        try mock.start(
            onBuffer: { _ in
                onBufferStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.15)
                onBufferFinished.fulfill()
            },
            onFailure: { _ in }
        )

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

        async let firstStop: Void = mock.stop()
        async let secondStop: Void = mock.stop()

        _ = await (firstStop, secondStop)

        await fulfillment(
            of: [onBufferFinished],
            timeout: 1.0
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

    func testOnFailureNeverDeliveredForACycleWhoseStartThrew() async throws {
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

        mock.simulateAsyncFailure(TestError.example)

        await mock.stop()

        await fulfillment(
            of: [onFailureCalled],
            timeout: 0.3
        )
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
}

private enum TestError: Error {
    case example
}
