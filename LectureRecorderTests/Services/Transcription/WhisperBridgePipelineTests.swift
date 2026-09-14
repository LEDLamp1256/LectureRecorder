import XCTest
@testable import LectureRecorder

final class WhisperBridgePipelineTests: XCTestCase {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var initializeCount = 0
        var destroyCount = 0
        var runCount = 0
    }

    private struct FakeBoundary: WhisperEngineBoundary {
        let state: State
        var initializeSucceeds = true
        var runResult: Int32 = 0
        var starts: [Int64] = [0, 100]
        var ends: [Int64] = [100, 200]
        var texts: [String?] = [" hello", " world"]

        func initialize() -> Int? {
            state.lock.withLock { state.initializeCount += 1 }
            return initializeSucceeds ? 1 : nil
        }
        func destroy(_ context: Int) { state.lock.withLock { state.destroyCount += 1 } }
        func run(_ context: Int, samples: [Float]) -> Int32 {
            state.lock.withLock { state.runCount += 1 }
            return runResult
        }
        func segmentCount(_ context: Int) -> Int { starts.count }
        func segmentStart(_ context: Int, index: Int) -> Int64 { starts[index] }
        func segmentEnd(_ context: Int, index: Int) -> Int64 { ends[index] }
        func segmentText(_ context: Int, index: Int) -> String? { texts[index] }
    }

    func testSuccessReturnsOrderedMillisecondsAndCleansUpExactlyOnce() throws {
        let state = State()
        var initializedCount = 0
        let segments = try WhisperBridgePipeline.infer(
            samples: [0, 0], boundary: FakeBoundary(state: state),
            initialized: { initializedCount += 1 }
        )
        XCTAssertEqual(segments, [
            WhisperBridgeSegment(startMilliseconds: 0, endMilliseconds: 1_000, text: " hello"),
            WhisperBridgeSegment(startMilliseconds: 1_000, endMilliseconds: 2_000, text: " world"),
        ])
        XCTAssertEqual(initializedCount, 1)
        XCTAssertEqual(state.initializeCount, 1)
        XCTAssertEqual(state.runCount, 1)
        XCTAssertEqual(state.destroyCount, 1)
    }

    func testInitializationFailureDoesNotDestroyAbsentContext() {
        let state = State()
        XCTAssertThrowsError(try WhisperBridgePipeline.infer(
            samples: [0],
            boundary: FakeBoundary(state: state, initializeSucceeds: false)
        )) {
            XCTAssertEqual($0 as? WhisperBridgePipelineError, .initialization)
        }
        XCTAssertEqual(state.destroyCount, 0)
    }

    func testInferenceAndMalformedOutputFailuresAlwaysCleanUp() {
        let inferenceState = State()
        XCTAssertThrowsError(try WhisperBridgePipeline.infer(
            samples: [0],
            boundary: FakeBoundary(state: inferenceState, runResult: -1)
        )) {
            XCTAssertEqual($0 as? WhisperBridgePipelineError, .inference)
        }
        XCTAssertEqual(inferenceState.destroyCount, 1)

        let malformedState = State()
        XCTAssertThrowsError(try WhisperBridgePipeline.infer(
            samples: [0],
            boundary: FakeBoundary(state: malformedState, starts: [100, 50], ends: [100, 60], texts: ["a", "b"])
        )) {
            XCTAssertEqual($0 as? WhisperBridgePipelineError, .malformedOutput)
        }
        XCTAssertEqual(malformedState.destroyCount, 1)
    }

    func testRejectsNegativeOverflowingMissingAndOversizedSegmentData() {
        let cases = [
            FakeBoundary(state: State(), starts: [-1], ends: [0], texts: ["a"]),
            FakeBoundary(state: State(), starts: [Int64.max / 10 + 1], ends: [Int64.max / 10 + 1], texts: ["a"]),
            FakeBoundary(state: State(), starts: [0], ends: [1], texts: [nil]),
            FakeBoundary(state: State(), starts: [0], ends: [1], texts: [String(repeating: "x", count: 65)]),
        ]
        for boundary in cases {
            XCTAssertThrowsError(try WhisperBridgePipeline.infer(
                samples: [0], boundary: boundary,
                maximumSegmentTextBytes: 64
            ))
            XCTAssertEqual(boundary.state.destroyCount, 1)
        }
    }
}
