import XCTest
@testable import LectureRecorder

/// Canonical-looking transcript results for navigation tests. Persisted
/// offsets are deliberately settable so tests can prove they are ignored.
enum NavigationTestResults {
    static func result(
        sessionID: UUID,
        sequenceNumber: Int,
        frameCount: Int,
        text: String,
        segments: [TranscriptionTimingSegment]?,
        startOffsetSeconds: Double = 0
    ) -> TranscriptResult {
        TranscriptResult(
            schemaVersion: TranscriptResult.legacySchemaVersion,
            source: TranscriptionSourceSnapshot(
                sessionID: sessionID,
                chunkSequenceNumber: sequenceNumber,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber),
                frameCount: frameCount,
                startOffsetSeconds: startOffsetSeconds,
                durationSeconds: 30,
                audioFormat: .defaultTarget
            ),
            output: TranscriptionEngineOutput(
                text: text,
                engineIdentifier: "fake-v1",
                modelIdentifier: nil,
                language: "en",
                segments: segments,
                engineVersion: nil
            ),
            attemptID: UUID(),
            completedDate: Date(timeIntervalSince1970: 0)
        )
    }

    static func segment(_ start: Double, _ end: Double, _ text: String) -> TranscriptionTimingSegment {
        TranscriptionTimingSegment(startSeconds: start, endSeconds: end, text: text)
    }
}

final class TranscriptPlaybackNavigationTests: XCTestCase {
    /// Uneven chunks: exactly 30 s, 30 s + 1 frame, and a short final 1 s.
    private let frameCounts = [1_323_000, 1_323_001, 44_100]
    private let chunkStarts: [Int64] = [0, 1_323_000, 2_646_001]

    private func makeTimeline(sampleRate: Double = 44_100, frameCounts: [Int]? = nil) throws -> LecturePlaybackTimeline {
        try LecturePlaybackTimeline(manifest: PlaybackTestManifest.make(sampleRate: sampleRate, frameCounts: frameCounts ?? self.frameCounts))
    }

    /// Chunk `i` gets `segments[i]` (nil = historical) and text equal to the
    /// segments' concatenation unless `texts` overrides it.
    private func build(
        _ timeline: LecturePlaybackTimeline,
        segments: [[TranscriptionTimingSegment]?],
        texts: [String?]? = nil
    ) throws -> TranscriptPlaybackNavigation {
        let results = timeline.chunks.map { chunk -> TranscriptResult in
            let chunkSegments = segments[chunk.sequenceNumber]
            let override: String? = texts.flatMap { $0[chunk.sequenceNumber] }
            let text = override ?? chunkSegments?.map(\.text).joined() ?? "chunk \(chunk.sequenceNumber) text"
            return NavigationTestResults.result(
                sessionID: timeline.sessionID,
                sequenceNumber: chunk.sequenceNumber,
                frameCount: Int(chunk.frameCount),
                text: text,
                segments: chunkSegments
            )
        }
        return try XCTUnwrap(TranscriptPlaybackNavigationBuilder.build(timeline: timeline, results: results))
    }

    private typealias S = NavigationTestResults

    // MARK: - Chunk-start mapping / historical fallback

    func testHistoricalResultsWithoutSegmentsFallBackToExactChunkStarts() throws {
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [nil, nil, nil])

        XCTAssertEqual(navigation.items.map(\.target), [.chunkStart, .chunkStart, .chunkStart])
        XCTAssertEqual(navigation.items.map(\.startSessionFrame), chunkStarts)
        XCTAssertEqual(navigation.items.map(\.endSessionFrame), [1_323_000, 2_646_001, 2_690_101])
        XCTAssertEqual(navigation.items.map(\.text), ["chunk 0 text", "chunk 1 text", "chunk 2 text"])
        XCTAssertEqual(navigation.items.map(\.chunkSequenceNumber), [0, 1, 2])
    }

    func testEmptySegmentArrayFallsBackToChunkStartKeepingDurableText() throws {
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [[], nil, nil], texts: ["", nil, nil])

        XCTAssertEqual(navigation.items[0].target, .chunkStart)
        XCTAssertEqual(navigation.items[0].text, "")
        XCTAssertEqual(navigation.items[0].startSessionFrame, 0)
    }

    // MARK: - Timed segments

    func testTimedSegmentsWithinFirstChunkMapToExactFrames() throws {
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [[S.segment(0, 1.5, " Hello"), S.segment(1.5, 2.25, " world")], nil, nil])

        let first = Array(navigation.items.prefix(2))
        XCTAssertEqual(first.map(\.target), [.timedSegment(index: 0), .timedSegment(index: 1)])
        XCTAssertEqual(first.map(\.startSessionFrame), [0, 66_150])
        XCTAssertEqual(first.map(\.endSessionFrame), [66_150, 99_225])
        XCTAssertEqual(first.map(\.text), [" Hello", " world"])
    }

    func testTimedSegmentInLaterChunkIncludesExactAccumulatedFrameCounts() throws {
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [nil, nil, [S.segment(0.5, 0.75, " tail")]])

        let item = try XCTUnwrap(navigation.items.last)
        XCTAssertEqual(item.chunkSequenceNumber, 2)
        XCTAssertEqual(item.startSessionFrame, 1_323_000 + 1_323_001 + 22_050)
        XCTAssertEqual(item.endSessionFrame, 2_646_001 + 33_075)
    }

    func testNonWholeSecondChunkPlacesLaterSegmentsByFramesNotSeconds() throws {
        // Chunk 1 is 30 s + 1 frame; chunk 2 must start one frame later
        // than 60 s would suggest.
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [nil, [S.segment(12.34, 13, " a")], [S.segment(0, 0.5, " b")]])

        let timed = navigation.items.filter { $0.target != .chunkStart }
        XCTAssertEqual(timed.map(\.startSessionFrame), [1_323_000 + 544_194, 2_646_001])
        XCTAssertNotEqual(timed[1].startSessionFrame, Int64(60 * 44_100))
    }

    func testSegmentFrameUsesNearestFrameRounding() {
        // 1 / 88_200 s is exactly half a frame at 44.1 kHz → rounds away.
        XCTAssertEqual(TranscriptPlaybackNavigationBuilder.chunkRelativeFrame(forSeconds: 1.0 / 88_200, sampleRate: 44_100, limit: 1_000), 1)
        XCTAssertEqual(TranscriptPlaybackNavigationBuilder.chunkRelativeFrame(forSeconds: 0.4 / 44_100, sampleRate: 44_100, limit: 1_000), 0)
    }

    func testTimingDoesNotDependOnPersistedStartOffsets() throws {
        let timeline = try makeTimeline()
        var skewed = PlaybackTestManifest.make(sessionID: timeline.sessionID, frameCounts: frameCounts)
        skewed.chunks = skewed.chunks.map { chunk in
            var chunk = chunk
            chunk.startOffsetSeconds = 999_999 - Double(chunk.sequenceNumber) * 17.3
            return chunk
        }
        let skewedTimeline = try LecturePlaybackTimeline(manifest: skewed)

        let segments: [[TranscriptionTimingSegment]?] = [nil, [S.segment(2, 3, " x")], [S.segment(0.25, 0.5, " y")]]
        let results = skewedTimeline.chunks.map { chunk in
            NavigationTestResults.result(
                sessionID: skewedTimeline.sessionID,
                sequenceNumber: chunk.sequenceNumber,
                frameCount: Int(chunk.frameCount),
                text: segments[chunk.sequenceNumber]?.map(\.text).joined() ?? "t",
                segments: segments[chunk.sequenceNumber],
                startOffsetSeconds: 12_345.678
            )
        }
        let skewedNavigation = try XCTUnwrap(TranscriptPlaybackNavigationBuilder.build(timeline: skewedTimeline, results: results))
        let expected = try build(timeline, segments: segments, texts: ["t", nil, nil])

        XCTAssertEqual(skewedNavigation.items.map(\.startSessionFrame), expected.items.map(\.startSessionFrame))
        XCTAssertEqual(skewedNavigation.items.map(\.startSessionFrame), [0, 1_323_000 + 88_200, 2_646_001 + 11_025])
    }

    func testItemsAreOrderedByChunkThenSegmentWithUniqueIDs() throws {
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [
            [S.segment(0, 1, " a"), S.segment(1, 2, " b"), S.segment(2, 3, " c")],
            nil,
            [S.segment(0, 0.5, " d"), S.segment(0.5, 1, " e")]
        ])

        XCTAssertEqual(navigation.items.map(\.id), [
            .init(chunkSequenceNumber: 0, target: .timedSegment(index: 0)),
            .init(chunkSequenceNumber: 0, target: .timedSegment(index: 1)),
            .init(chunkSequenceNumber: 0, target: .timedSegment(index: 2)),
            .init(chunkSequenceNumber: 1, target: .chunkStart),
            .init(chunkSequenceNumber: 2, target: .timedSegment(index: 0)),
            .init(chunkSequenceNumber: 2, target: .timedSegment(index: 1))
        ])
        XCTAssertEqual(Set(navigation.items.map(\.id)).count, navigation.items.count)
        XCTAssertEqual(navigation.items.map(\.startSessionFrame), navigation.items.map(\.startSessionFrame).sorted())
    }

    // MARK: - Malformed timing stays inside its chunk

    func testMalformedTimingFallsBackToChunkStartForThatChunkOnly() throws {
        let timeline = try makeTimeline()
        let malformedCases: [(String, [TranscriptionTimingSegment], String?)] = [
            ("non-finite start", [S.segment(.nan, 1, " a")], nil),
            ("infinite end", [S.segment(0, .infinity, " a")], nil),
            ("negative start", [S.segment(-0.5, 1, " a")], nil),
            ("end before start", [S.segment(2, 1, " a")], nil),
            ("overlap", [S.segment(0, 2, " a"), S.segment(1.5, 3, " b")], nil),
            ("beyond chunk plus allowance", [S.segment(29, 30.3, " a")], nil),
            ("far outside chunk", [S.segment(500, 501, " a")], nil),
            ("text mismatch", [S.segment(0, 1, " a")], " different durable text")
        ]

        for (name, segments, overrideText) in malformedCases {
            let navigation = try build(
                timeline,
                segments: [segments, nil, [S.segment(0.5, 0.75, " ok")]],
                texts: [overrideText, nil, nil]
            )
            let first = navigation.items[0]
            XCTAssertEqual(first.target, .chunkStart, name)
            XCTAssertEqual(first.startSessionFrame, 0, name)
            XCTAssertEqual(first.endSessionFrame, 1_323_000, name)
            XCTAssertEqual(first.text, overrideText ?? segments.map(\.text).joined(), "\(name): durable chunk text is kept")
            XCTAssertEqual(navigation.items.last?.target, .timedSegment(index: 0), "\(name): other chunks keep their timing")
        }
    }

    // The final chunk is exactly 1 s (44_100 frames): session frames
    // 2_646_001 ..< 2_690_101.

    private func assertFinalChunkFallsBack(
        _ segments: [TranscriptionTimingSegment],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [nil, nil, segments])
        let finalChunkItems = navigation.items.filter { $0.chunkSequenceNumber == 2 }
        XCTAssertEqual(finalChunkItems.count, 1, "one whole-chunk item, no partial timing", file: file, line: line)
        let item = try XCTUnwrap(finalChunkItems.first, file: file, line: line)
        XCTAssertEqual(item.target, .chunkStart, file: file, line: line)
        XCTAssertEqual(item.startSessionFrame, 2_646_001, file: file, line: line)
        XCTAssertEqual(item.endSessionFrame, 2_690_101, file: file, line: line)
        XCTAssertEqual(item.text, segments.map(\.text).joined(), "durable chunk text is kept", file: file, line: line)
    }

    func testStartExactlyAtPhysicalChunkEndFallsBackWholeChunk() throws {
        try assertFinalChunkFallsBack([S.segment(0, 0.9, " a"), S.segment(1.0, 1.1, " b")])
    }

    func testStartInsideEndToleranceTailFallsBackAndIsNotClamped() throws {
        try assertFinalChunkFallsBack([S.segment(0, 0.9, " a"), S.segment(1.1, 1.2, " b")])
    }

    func testStartThatRoundsOntoChunkEndFallsBackWholeChunk() throws {
        // 0.4 frame before the end rounds to frame 44_100 — not playable.
        let start = 1.0 - 0.4 / 44_100
        try assertFinalChunkFallsBack([S.segment(0, 0.5, " a"), S.segment(start, start, " b")])
    }

    func testValidStartWithEndOvershootWithinToleranceStaysTimedAndClampsEnd() throws {
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [nil, nil, [S.segment(0.5, 1.2, " tail")]])

        let item = try XCTUnwrap(navigation.items.last)
        XCTAssertEqual(item.target, .timedSegment(index: 0))
        XCTAssertEqual(item.startSessionFrame, 2_646_001 + 22_050, "start stays exact")
        XCTAssertEqual(item.endSessionFrame, 2_690_101, "end clamps to the exact exclusive chunk end")
    }

    func testEndBeyondToleranceFallsBackWholeChunk() throws {
        try assertFinalChunkFallsBack([S.segment(0.5, 1.26, " tail")])
    }

    func testOneBadSegmentAmongValidOnesFallsBackWholeChunk() throws {
        try assertFinalChunkFallsBack([
            S.segment(0, 0.3, " a"),
            S.segment(0.3, 0.6, " b"),
            S.segment(1.05, 1.1, " c")
        ])
    }

    func testZeroDurationSegmentInsideAudioStaysTimed() throws {
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [nil, nil, [S.segment(0.5, 0.5, " blip")]])

        let item = try XCTUnwrap(navigation.items.last)
        XCTAssertEqual(item.target, .timedSegment(index: 0))
        XCTAssertEqual(item.startSessionFrame, 2_646_001 + 22_050)
        XCTAssertEqual(item.endSessionFrame, item.startSessionFrame)
    }

    func testEveryItemStaysInsideItsChunk() throws {
        let timeline = try makeTimeline()
        let navigation = try build(timeline, segments: [
            [S.segment(0, 29.99, " a"), S.segment(29.99, 30.2, " b")],
            [S.segment(0, 30.1, " c")],
            [S.segment(0.99, 1.24, " d")]
        ])
        for item in navigation.items {
            let chunk = timeline.chunks[item.chunkSequenceNumber]
            XCTAssertGreaterThanOrEqual(item.startSessionFrame, chunk.startFrame)
            XCTAssertLessThan(item.startSessionFrame, chunk.endFrame)
            XCTAssertGreaterThanOrEqual(item.endSessionFrame, item.startSessionFrame)
            XCTAssertLessThanOrEqual(item.endSessionFrame, chunk.endFrame)
        }
    }

    // MARK: - Coverage rejection

    func testBuildRejectsResultsThatDoNotCoverTheTimelineExactly() throws {
        let timeline = try makeTimeline()
        func result(_ sequence: Int, session: UUID? = nil, frames: Int? = nil) -> TranscriptResult {
            NavigationTestResults.result(
                sessionID: session ?? timeline.sessionID,
                sequenceNumber: sequence,
                frameCount: frames ?? frameCounts[min(sequence, frameCounts.count - 1)],
                text: "t",
                segments: nil
            )
        }

        XCTAssertNil(TranscriptPlaybackNavigationBuilder.build(timeline: timeline, results: [result(0), result(1)]), "missing chunk")
        XCTAssertNil(TranscriptPlaybackNavigationBuilder.build(timeline: timeline, results: [result(0), result(1), result(2), result(2)]), "duplicate")
        XCTAssertNil(TranscriptPlaybackNavigationBuilder.build(timeline: timeline, results: [result(0), result(1), result(2, session: UUID())]), "foreign session")
        XCTAssertNil(TranscriptPlaybackNavigationBuilder.build(timeline: timeline, results: [result(0), result(1), result(2, frames: 44_101)]), "frame mismatch")
        XCTAssertNil(TranscriptPlaybackNavigationBuilder.build(timeline: timeline, results: [result(0), result(1), result(2), result(3)]), "extra chunk")
        XCTAssertNotNil(TranscriptPlaybackNavigationBuilder.build(timeline: timeline, results: [result(2), result(0), result(1)]), "order-independent input")
    }

    // MARK: - Seek round trip

    func testStartTimeRoundTripsToTheExactFrameThroughTheTimeline() throws {
        // ~95-minute lecture at 48 kHz: 190 full chunks and a short tail.
        let frameCounts = Array(repeating: 1_440_000, count: 190) + [777_777]
        let timeline = try makeTimeline(sampleRate: 48_000, frameCounts: frameCounts)
        let segments: [[TranscriptionTimingSegment]?] = frameCounts.indices.map { index in
            index.isMultiple(of: 2) ? [S.segment(0.013, 7.777, " a"), S.segment(7.777, 16.2, " b")] : nil
        }
        let navigation = try build(timeline, segments: segments)

        for item in navigation.items {
            XCTAssertEqual(timeline.sessionFrame(forSessionTime: navigation.startTime(of: item)), item.startSessionFrame)
        }
    }
}

final class PlaybackTimeFormattingTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(PlaybackTimeFormatting.label(forSeconds: 0), "0:00")
        XCTAssertEqual(PlaybackTimeFormatting.label(forSeconds: 59.999), "0:59")
        XCTAssertEqual(PlaybackTimeFormatting.label(forSeconds: 754.9), "12:34")
        XCTAssertEqual(PlaybackTimeFormatting.label(forSeconds: 3_600), "1:00:00")
        XCTAssertEqual(PlaybackTimeFormatting.label(forSeconds: 5_214.4), "1:26:54")
        XCTAssertEqual(PlaybackTimeFormatting.label(forSeconds: 36_005), "10:00:05")
    }

    func testInvalidInputDisplaysZero() {
        XCTAssertEqual(PlaybackTimeFormatting.label(forSeconds: -3), "0:00")
        XCTAssertEqual(PlaybackTimeFormatting.label(forSeconds: .nan), "0:00")
        XCTAssertEqual(PlaybackTimeFormatting.label(forSeconds: .infinity), "0:00")
    }

    func testProgressLabel() {
        XCTAssertEqual(PlaybackTimeFormatting.progressLabel(elapsedSeconds: 754, totalSeconds: 5_214), "12:34 / 1:26:54")
    }
}
