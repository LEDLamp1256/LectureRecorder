import XCTest
@testable import LectureRecorder

/// Shared manifest builder for playback tests. Chunk offsets are derived
/// from frames exactly as `AudioChunkWriter` derives them.
enum PlaybackTestManifest {
    static func make(
        sessionID: UUID = UUID(),
        sampleRate: Double = 44_100,
        channelCount: UInt32 = 1,
        frameCounts: [Int]
    ) -> SessionManifest {
        var cumulative = 0
        let chunks = frameCounts.enumerated().map { index, frames -> ChunkMetadata in
            defer { cumulative &+= frames }
            return ChunkMetadata(
                sequenceNumber: index,
                fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: index),
                startOffsetSeconds: Double(cumulative) / sampleRate,
                durationSeconds: Double(frames) / sampleRate,
                frameCount: frames,
                state: .completed
            )
        }
        var format = AudioFormatDescriptor.defaultTarget
        format.sampleRate = sampleRate
        format.channelCount = channelCount
        return SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion,
            sessionID: sessionID,
            creationDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 2_000),
            status: .completed,
            audioFormat: format,
            targetChunkDurationSeconds: 30,
            chunks: chunks,
            endReason: .userStopped,
            endedCleanly: true,
            failureDescription: nil,
            observedCaptureCopyFailureCount: 0
        )
    }
}

final class LecturePlaybackTimelineTests: XCTestCase {
    /// Deliberately uneven chunks, like a real session's final short chunk.
    private let frameCounts = [1_323_000, 1_323_001, 44_100]

    private func makeTimeline(_ manifest: SessionManifest? = nil) throws -> LecturePlaybackTimeline {
        try LecturePlaybackTimeline(manifest: manifest ?? PlaybackTestManifest.make(frameCounts: frameCounts))
    }

    private func assertRejects(
        _ manifest: SessionManifest,
        _ expected: LecturePlaybackTimelineError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try LecturePlaybackTimeline(manifest: manifest), file: file, line: line) { error in
            XCTAssertEqual(error as? LecturePlaybackTimelineError, expected, file: file, line: line)
        }
    }

    func testBuildsOrderedFrameExactChunks() throws {
        let sessionID = UUID()
        let timeline = try makeTimeline(PlaybackTestManifest.make(sessionID: sessionID, frameCounts: frameCounts))

        XCTAssertEqual(timeline.sessionID, sessionID)
        XCTAssertEqual(timeline.sampleRate, 44_100)
        XCTAssertEqual(timeline.chunks, [
            LecturePlaybackChunk(sequenceNumber: 0, fileName: "chunk_000000.caf", startFrame: 0, frameCount: 1_323_000),
            LecturePlaybackChunk(sequenceNumber: 1, fileName: "chunk_000001.caf", startFrame: 1_323_000, frameCount: 1_323_001),
            LecturePlaybackChunk(sequenceNumber: 2, fileName: "chunk_000002.caf", startFrame: 2_646_001, frameCount: 44_100),
        ])
        XCTAssertEqual(timeline.chunks.map(\.endFrame), [1_323_000, 2_646_001, 2_690_101])
    }

    func testTotalIsExactFrameSumIgnoringPersistedSeconds() throws {
        var manifest = PlaybackTestManifest.make(frameCounts: frameCounts)
        // Corrupt the derived-for-readability seconds; the timeline must not care.
        for index in manifest.chunks.indices {
            manifest.chunks[index].startOffsetSeconds = 999
            manifest.chunks[index].durationSeconds = 0.5
        }
        let timeline = try makeTimeline(manifest)

        XCTAssertEqual(timeline.totalFrameCount, 2_690_101)
        XCTAssertEqual(timeline.durationSeconds, 2_690_101.0 / 44_100.0)
    }

    func testChunksInManifestOrderOtherThanSequenceAreOrderedBySequence() throws {
        var manifest = PlaybackTestManifest.make(frameCounts: frameCounts)
        let expected = try makeTimeline(manifest)
        manifest.chunks.reverse()
        XCTAssertEqual(try makeTimeline(manifest), expected)
    }

    func testFirstFrameMapsToChunkZeroOffsetZero() throws {
        let timeline = try makeTimeline()
        XCTAssertEqual(timeline.location(forSessionFrame: 0), .chunk(chunkIndex: 0, frameOffset: 0))
        XCTAssertEqual(timeline.sessionFrame(forSessionTime: 0), 0)
    }

    func testInteriorPositionMapsToChunkAndLocalFrame() throws {
        let timeline = try makeTimeline()
        XCTAssertEqual(timeline.location(forSessionFrame: 1_323_000 + 500), .chunk(chunkIndex: 1, frameOffset: 500))
        XCTAssertEqual(timeline.location(forSessionFrame: 1_322_999), .chunk(chunkIndex: 0, frameOffset: 1_322_999))

        let frame = try XCTUnwrap(timeline.sessionFrame(forSessionTime: 45))
        XCTAssertEqual(frame, 1_984_500)
        XCTAssertEqual(timeline.location(forSessionFrame: frame), .chunk(chunkIndex: 1, frameOffset: 661_500))
    }

    func testExactChunkBoundaryMapsToNextChunk() throws {
        let timeline = try makeTimeline()
        XCTAssertEqual(timeline.location(forSessionFrame: 1_323_000), .chunk(chunkIndex: 1, frameOffset: 0))
        XCTAssertEqual(timeline.location(forSessionFrame: 2_646_001), .chunk(chunkIndex: 2, frameOffset: 0))
    }

    func testPersistedStartOffsetSecondsRoundTripsToExactBoundaryFrame() throws {
        // A T6-A chunk-bounded offset is Double(frames) / sampleRate; the
        // non-integral 2_646_001-frame boundary must not fall into chunk 1.
        let manifest = PlaybackTestManifest.make(frameCounts: frameCounts)
        let timeline = try makeTimeline(manifest)
        for (index, chunk) in manifest.chunks.enumerated() {
            let frame = try XCTUnwrap(timeline.sessionFrame(forSessionTime: chunk.startOffsetSeconds))
            XCTAssertEqual(frame, timeline.chunks[index].startFrame)
            XCTAssertEqual(timeline.location(forSessionFrame: frame), .chunk(chunkIndex: index, frameOffset: 0))
        }
    }

    func testFinalPlayableFrameMapsToFinalChunk() throws {
        let timeline = try makeTimeline()
        XCTAssertEqual(timeline.location(forSessionFrame: 2_690_100), .chunk(chunkIndex: 2, frameOffset: 44_099))
    }

    func testExactEndIsLogicalEnd() throws {
        let timeline = try makeTimeline()
        XCTAssertEqual(timeline.location(forSessionFrame: 2_690_101), .end)
        XCTAssertEqual(timeline.sessionFrame(forSessionTime: timeline.durationSeconds), 2_690_101)
    }

    func testNegativePositionsClampOrRejectWithoutWrapping() throws {
        let timeline = try makeTimeline()
        XCTAssertEqual(timeline.sessionFrame(forSessionTime: -0.001), 0)
        XCTAssertEqual(timeline.sessionFrame(forSessionTime: -.greatestFiniteMagnitude), 0)
        XCTAssertNil(timeline.location(forSessionFrame: -1))
        XCTAssertNil(timeline.location(forSessionFrame: .min))
    }

    func testPositionsPastEndClampToEndOrReject() throws {
        let timeline = try makeTimeline()
        XCTAssertEqual(timeline.sessionFrame(forSessionTime: timeline.durationSeconds + 1), 2_690_101)
        XCTAssertEqual(timeline.sessionFrame(forSessionTime: .greatestFiniteMagnitude), 2_690_101)
        XCTAssertNil(timeline.location(forSessionFrame: 2_690_102))
        XCTAssertNil(timeline.location(forSessionFrame: .max))
    }

    func testNonFiniteTimeIsRejected() throws {
        let timeline = try makeTimeline()
        XCTAssertNil(timeline.sessionFrame(forSessionTime: .nan))
        XCTAssertNil(timeline.sessionFrame(forSessionTime: .infinity))
        XCTAssertNil(timeline.sessionFrame(forSessionTime: -.infinity))
    }

    func testInvalidSampleRatesAreRejected() {
        for rate in [0, -44_100, .nan, .infinity] as [Double] {
            assertRejects(PlaybackTestManifest.make(sampleRate: rate, frameCounts: frameCounts), .invalidSampleRate)
        }
    }

    func testEmptySessionIsRejected() {
        assertRejects(PlaybackTestManifest.make(frameCounts: []), .noChunks)
    }

    func testNonpositiveChunkFrameCountIsRejected() {
        assertRejects(PlaybackTestManifest.make(frameCounts: [100, 0, 100]), .nonPositiveChunkFrameCount(sequenceNumber: 1))
        assertRejects(PlaybackTestManifest.make(frameCounts: [-5]), .nonPositiveChunkFrameCount(sequenceNumber: 0))
    }

    func testSequenceGapDuplicateAndOffsetAreRejected() {
        var gap = PlaybackTestManifest.make(frameCounts: [10, 10, 10])
        gap.chunks[2].sequenceNumber = 3
        assertRejects(gap, .nonContiguousChunkSequence)

        var duplicate = PlaybackTestManifest.make(frameCounts: [10, 10])
        duplicate.chunks[1].sequenceNumber = 0
        assertRejects(duplicate, .nonContiguousChunkSequence)

        var offset = PlaybackTestManifest.make(frameCounts: [10])
        offset.chunks[0].sequenceNumber = 1
        assertRejects(offset, .nonContiguousChunkSequence)
    }

    func testNonCanonicalFileNameAndNonCompletedChunkAreRejected() {
        var misnamed = PlaybackTestManifest.make(frameCounts: [10, 10])
        misnamed.chunks[1].fileName = "../chunk_000001.caf"
        assertRejects(misnamed, .nonCanonicalChunkFileName(sequenceNumber: 1))

        var recording = PlaybackTestManifest.make(frameCounts: [10, 10])
        recording.chunks[1].state = .recording
        assertRejects(recording, .nonCompletedChunk(sequenceNumber: 1))
    }

    func testFrameCountAccumulationOverflowIsRejected() {
        assertRejects(PlaybackTestManifest.make(frameCounts: [Int.max, 1]), .frameCountOverflow)
    }
}
