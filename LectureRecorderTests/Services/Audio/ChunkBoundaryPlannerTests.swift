import XCTest
@testable import LectureRecorder

/// Minimal seeded PRNG (SplitMix64) so the property-style tests below are
/// reproducible across runs, instead of depending on
/// `SystemRandomNumberGenerator`, which is intentionally non-seedable. If
/// one of these tests ever fails, it will fail the same way every time.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class ChunkBoundaryPlannerTests: XCTestCase {

    func testZeroFramesProducesNoSegments() {
        let segments = ChunkBoundaryPlanner.plan(
            bufferFrameCount: 0,
            framesAlreadyInCurrentChunk: 0,
            framesPerChunk: 1_000,
            currentChunkSequenceNumber: 0
        )
        XCTAssertTrue(segments.isEmpty)
    }

    func testBufferEntirelyWithinCurrentChunk() {
        let segments = ChunkBoundaryPlanner.plan(
            bufferFrameCount: 100,
            framesAlreadyInCurrentChunk: 200,
            framesPerChunk: 1_000,
            currentChunkSequenceNumber: 5
        )
        XCTAssertEqual(segments, [
            .init(sourceOffset: 0, frameCount: 100, chunkSequenceNumber: 5, completesChunk: false)
        ])
    }

    func testBufferExactlyCompletesChunk() {
        let segments = ChunkBoundaryPlanner.plan(
            bufferFrameCount: 300,
            framesAlreadyInCurrentChunk: 700,
            framesPerChunk: 1_000,
            currentChunkSequenceNumber: 2
        )
        XCTAssertEqual(segments, [
            .init(sourceOffset: 0, frameCount: 300, chunkSequenceNumber: 2, completesChunk: true)
        ])
    }

    func testBufferCrossesSingleBoundary() {
        let segments = ChunkBoundaryPlanner.plan(
            bufferFrameCount: 500,
            framesAlreadyInCurrentChunk: 800,
            framesPerChunk: 1_000,
            currentChunkSequenceNumber: 4
        )
        XCTAssertEqual(segments, [
            .init(sourceOffset: 0, frameCount: 200, chunkSequenceNumber: 4, completesChunk: true),
            .init(sourceOffset: 200, frameCount: 300, chunkSequenceNumber: 5, completesChunk: false)
        ])
    }

    func testBufferCrossesMultipleBoundaries() {
        let segments = ChunkBoundaryPlanner.plan(
            bufferFrameCount: 3_500,
            framesAlreadyInCurrentChunk: 0,
            framesPerChunk: 1_000,
            currentChunkSequenceNumber: 0
        )
        XCTAssertEqual(segments, [
            .init(sourceOffset: 0, frameCount: 1_000, chunkSequenceNumber: 0, completesChunk: true),
            .init(sourceOffset: 1_000, frameCount: 1_000, chunkSequenceNumber: 1, completesChunk: true),
            .init(sourceOffset: 2_000, frameCount: 1_000, chunkSequenceNumber: 2, completesChunk: true),
            .init(sourceOffset: 3_000, frameCount: 500, chunkSequenceNumber: 3, completesChunk: false)
        ])
    }

    func testFrameCountConservationAcrossManyDeterministicInputs() {
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<500 {
            let framesPerChunk = Int.random(in: 1...5_000, using: &rng)
            let framesAlready = Int.random(in: 0..<framesPerChunk, using: &rng)
            let bufferFrameCount = Int.random(in: 0...10_000, using: &rng)
            let startSequence = Int.random(in: 0...100, using: &rng)

            let segments = ChunkBoundaryPlanner.plan(
                bufferFrameCount: bufferFrameCount,
                framesAlreadyInCurrentChunk: framesAlready,
                framesPerChunk: framesPerChunk,
                currentChunkSequenceNumber: startSequence
            )

            let totalPlanned = segments.reduce(0) { $0 + $1.frameCount }
            XCTAssertEqual(totalPlanned, bufferFrameCount, "Planned frames must equal input frames exactly")

            for (index, segment) in segments.enumerated() {
                XCTAssertEqual(segment.chunkSequenceNumber, startSequence + index)
            }

            for segment in segments.dropLast() {
                XCTAssertTrue(segment.completesChunk, "All but the final segment must complete their chunk")
            }
        }
    }

    func testNoSegmentExceedsFramesPerChunkOrIsEmpty() {
        var rng = SeededGenerator(seed: 1_337)
        for _ in 0..<200 {
            let framesPerChunk = Int.random(in: 1...2_000, using: &rng)
            let framesAlready = Int.random(in: 0..<framesPerChunk, using: &rng)
            let bufferFrameCount = Int.random(in: 0...8_000, using: &rng)

            let segments = ChunkBoundaryPlanner.plan(
                bufferFrameCount: bufferFrameCount,
                framesAlreadyInCurrentChunk: framesAlready,
                framesPerChunk: framesPerChunk,
                currentChunkSequenceNumber: 0
            )

            for segment in segments {
                XCTAssertLessThanOrEqual(segment.frameCount, framesPerChunk)
                XCTAssertGreaterThan(segment.frameCount, 0)
            }
        }
    }
}
