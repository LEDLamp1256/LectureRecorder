import XCTest
@testable import LectureRecorder

/// Aligns real `TranscriptPlaybackNavigationBuilder` output. The default
/// source is 16 kHz (one frame = 62.5 µs) with chunks starting at 0 s, 30 s,
/// and 60 s; frame arithmetic below is exact at that rate.
final class SpeakerTranscriptAlignerTests: XCTestCase {
    private typealias F = DiarizationTestFixtures
    private typealias S = NavigationTestResults

    private var source: LecturePlaybackSource!
    private let aligner = SpeakerTranscriptAligner()

    override func setUpWithError() throws {
        try super.setUpWithError()
        source = try F.source()
    }

    /// Chunk `i` gets `segments[i]` (nil = `.chunkStart` fallback); missing
    /// trailing entries are nil. Text is the segments' concatenation.
    private func navigation(
        _ segments: [[TranscriptionTimingSegment]?],
        source: LecturePlaybackSource? = nil
    ) throws -> TranscriptPlaybackNavigation {
        let timeline = (source ?? self.source).timeline
        let results = timeline.chunks.map { chunk -> TranscriptResult in
            let chunkSegments = chunk.sequenceNumber < segments.count ? segments[chunk.sequenceNumber] : nil
            return S.result(
                sessionID: timeline.sessionID,
                sequenceNumber: chunk.sequenceNumber,
                frameCount: Int(chunk.frameCount),
                text: chunkSegments?.map(\.text).joined() ?? "chunk \(chunk.sequenceNumber) text",
                segments: chunkSegments
            )
        }
        return try XCTUnwrap(TranscriptPlaybackNavigationBuilder.build(timeline: timeline, results: results))
    }

    private func align(
        _ segments: [[TranscriptionTimingSegment]?],
        _ ranges: [SpeakerTimeRange]
    ) throws -> [SpeakerItemAlignment] {
        try aligner.align(try navigation(segments), with: try F.result(source: source, ranges: ranges), source: source)
    }

    private func overlap(_ index: Int, _ frames: Int64) throws -> SpeakerOverlap {
        SpeakerOverlap(speakerID: try F.speaker(index), frames: frames)
    }

    // MARK: - Thresholds and frame conversion

    func testThresholdsAreWholeFramesDerivedFromTheSampleRate() {
        XCTAssertEqual(SpeakerTranscriptAligner.minimumOverlapFrames(seconds: 0.5, sampleRate: 16_000), 8_000)
        XCTAssertEqual(SpeakerTranscriptAligner.minimumOverlapFrames(seconds: 0.5, sampleRate: 44_100), 22_050)
        XCTAssertEqual(SpeakerTranscriptAligner.minimumOverlapFrames(seconds: 0.5, sampleRate: 11_025), 5_513, "rounded up: at least 0.5 s")
        XCTAssertEqual(SpeakerTranscriptAligner.minimumOverlapFrames(seconds: 1e-9, sampleRate: 16_000), 1)
        XCTAssertEqual(SpeakerTranscriptAligner.tieToleranceFrames(sampleRate: 16_000), 16)
        XCTAssertEqual(SpeakerTranscriptAligner.tieToleranceFrames(sampleRate: 44_100), 44, "rounded down: at most 1 ms")
        XCTAssertEqual(SpeakerTranscriptAligner.tieToleranceFrames(sampleRate: 48_000), 48)
    }

    func testRangeBoundariesRoundToTheNearestFrameAndClampToTheTimeline() throws {
        let timeline = source.timeline
        func interval(_ start: Double, _ end: Double) throws -> (Int64, Int64) {
            let frames = SpeakerTranscriptAligner.sessionFrameInterval(of: try F.range(0, start, end), on: timeline)
            return (frames.start, frames.end)
        }
        XCTAssertTrue(try interval(0, 1) == (0, 16_000))
        XCTAssertTrue(try interval(1.0 / 32_000, 0.00003 + 1) == (1, 16_000), "a half frame rounds away from zero; 0.48 frame rounds down")
        XCTAssertTrue(try interval(69.9999, 70) == (1_119_998, 1_120_000))
        XCTAssertTrue(try interval(60, 1_000) == (960_000, timeline.totalFrameCount), "clamped to the logical end")
        XCTAssertTrue(try interval(1, 1.00003) == (16_000, 16_000), "shorter than half a frame rounds to empty")
    }

    // MARK: - Timed segment alignment

    func testExactItemBoundariesAndASpeakerChangeAtTheEdge() throws {
        let alignments = try align(
            [[S.segment(0, 2, "a"), S.segment(2, 4, "b")]],
            [try F.range(0, 0, 2), try F.range(1, 2, 4)]
        )
        XCTAssertEqual(alignments[0].attribution, .speaker(try F.speaker(0)))
        XCTAssertEqual(alignments[0].overlaps, [try overlap(0, 32_000)], "a touching range contributes nothing")
        XCTAssertEqual(alignments[1].attribution, .speaker(try F.speaker(1)))
        XCTAssertEqual(alignments[1].overlaps, [try overlap(1, 32_000)])
    }

    func testRangeLongerThanTheItemCountsOnlyTheIntersection() throws {
        let alignments = try align([[S.segment(0, 2, "a"), S.segment(2, 4, "b")]], [try F.range(0, 0, 10)])
        XCTAssertEqual(alignments[1].overlaps, [try overlap(0, 32_000)])
    }

    func testPartialOverlap() throws {
        let alignments = try align([[S.segment(0, 4, "a")]], [try F.range(0, 1, 2.5)])
        XCTAssertEqual(alignments[0].attribution, .speaker(try F.speaker(0)))
        XCTAssertEqual(alignments[0].overlaps, [try overlap(0, 24_000)])
    }

    func testSpeakerSwitchInsideAnItemGoesToTheLargerShare() throws {
        let alignments = try align([[S.segment(0, 4, "a")]], [try F.range(0, 0, 1.5), try F.range(1, 1.5, 4)])
        XCTAssertEqual(alignments[0].attribution, .speaker(try F.speaker(1)))
        XCTAssertEqual(alignments[0].overlaps, [try overlap(1, 40_000), try overlap(0, 24_000)])
    }

    func testSilenceAndEmptyItemsAreUnknown() throws {
        let alignments = try align(
            [[S.segment(0, 2, "a"), S.segment(2, 2, "b"), S.segment(2, 4, "c"), S.segment(10, 12, "d")]],
            [try F.range(0, 0, 4)]
        )
        XCTAssertEqual(alignments[1].attribution, .unknown, "a zero-length item")
        XCTAssertEqual(alignments[1].overlaps, [])
        XCTAssertEqual(alignments[3].attribution, .unknown, "no speech overlaps it")
        XCTAssertEqual(alignments[3].overlaps, [])
    }

    func testOverlappingSpeakersEachContribute() throws {
        let alignments = try align([[S.segment(0, 4, "a")]], [try F.range(0, 0, 3.5), try F.range(1, 2, 4)])
        XCTAssertEqual(alignments[0].attribution, .speaker(try F.speaker(0)))
        XCTAssertEqual(alignments[0].overlaps, [try overlap(0, 56_000), try overlap(1, 32_000)])
    }

    func testExactTieIsAmbiguous() throws {
        let alignments = try align([[S.segment(0, 4, "a")]], [try F.range(0, 0, 2), try F.range(1, 2, 4)])
        XCTAssertEqual(alignments[0].attribution, .ambiguous([try F.speaker(0), try F.speaker(1)]))
        XCTAssertEqual(alignments[0].overlaps, [try overlap(0, 32_000), try overlap(1, 32_000)], "ties ordered by label")
    }

    func testNearTieWithinOneMillisecondIsAmbiguousAndBeyondItIsNot() throws {
        // 2.001 s = frame 32_016: speaker_1 has 16 frames (exactly 1 ms) less.
        let within = try align([[S.segment(0, 4, "a")]], [try F.range(0, 0, 2), try F.range(1, 2.001, 4)])
        XCTAssertEqual(within[0].overlaps, [try overlap(0, 32_000), try overlap(1, 31_984)])
        XCTAssertEqual(within[0].attribution, .ambiguous([try F.speaker(0), try F.speaker(1)]))

        // Frame 32_017: 17 frames less.
        let beyond = try align([[S.segment(0, 4, "a")]], [try F.range(0, 0, 2), try F.range(1, 32_017.0 / 16_000, 4)])
        XCTAssertEqual(beyond[0].overlaps, [try overlap(0, 32_000), try overlap(1, 31_983)])
        XCTAssertEqual(beyond[0].attribution, .speaker(try F.speaker(0)))
    }

    func testBelowTheMinimumOverlapIsUnknown() throws {
        let below = try align([[S.segment(0, 4, "a")]], [try F.range(0, 1, 23_999.0 / 16_000)])
        XCTAssertEqual(below[0].overlaps, [try overlap(0, 7_999)])
        XCTAssertEqual(below[0].attribution, .unknown)

        let atThreshold = try align([[S.segment(0, 4, "a")]], [try F.range(0, 1, 1.5)])
        XCTAssertEqual(atThreshold[0].overlaps, [try overlap(0, 8_000)])
        XCTAssertEqual(atThreshold[0].attribution, .speaker(try F.speaker(0)))
    }

    func testSubFrameRangeCountsForNobody() throws {
        let alignments = try align([[S.segment(0, 4, "a")]], [try F.range(0, 1, 1.00003)])
        XCTAssertEqual(alignments[0].attribution, .unknown)
        XCTAssertEqual(alignments[0].overlaps, [])
    }

    func testSpeakerChangeAtASegmentBoundaryLandsOnTheSameFrame() throws {
        // 1.23456 s × 16 kHz = 19_752.96 → frame 19_753 for both.
        let alignments = try align(
            [[S.segment(0, 1.23456, "a"), S.segment(1.23456, 3, "b")]],
            [try F.range(0, 0, 1.23456), try F.range(1, 1.23456, 3)]
        )
        XCTAssertEqual(alignments[0].overlaps, [try overlap(0, 19_753)])
        XCTAssertEqual(alignments[1].overlaps, [try overlap(1, 48_000 - 19_753)])
    }

    func testLaterChunkItemsUseExactSessionFrames() throws {
        // Chunk 2 starts at frame 960_000 (60 s); its segment [1, 3) is session [61, 63).
        let alignments = try align([nil, nil, [S.segment(1, 3, "x")]], [try F.range(0, 61, 63)])
        let item = try XCTUnwrap(alignments.first { $0.itemID == .init(chunkSequenceNumber: 2, target: .timedSegment(index: 0)) })
        XCTAssertEqual(item.attribution, .speaker(try F.speaker(0)))
        XCTAssertEqual(item.overlaps, [try overlap(0, 32_000)])
    }

    // MARK: - Chunk-start fallback

    func testChunkStartFallbackItemsNeverReceiveASpeaker() throws {
        // Chunk 1 has no usable timing: one `.chunkStart` item spanning all
        // 30 s, entirely covered by one speaker.
        let alignments = try align([[S.segment(0, 4, "a")], nil], [try F.range(0, 0, 4), try F.range(1, 30, 60)])
        let fallback = try XCTUnwrap(alignments.first { $0.itemID == .init(chunkSequenceNumber: 1, target: .chunkStart) })
        XCTAssertEqual(fallback.attribution, .ineligible)
        XCTAssertEqual(fallback.overlaps, [], "never measured, so no dominant speaker can be inferred")
        XCTAssertEqual(alignments[0].attribution, .speaker(try F.speaker(0)), "timed items in the same session still align")
    }

    // MARK: - Determinism and identity

    func testOutputFollowsNavigationOrderAndIsDeterministic() throws {
        let segments: [[TranscriptionTimingSegment]?] = [[S.segment(0, 2, "a"), S.segment(2, 4, "b")], nil, [S.segment(0, 5, "c")]]
        let nav = try navigation(segments)
        let result = try F.result(source: source, ranges: [try F.range(0, 0, 3), try F.range(1, 1, 4), try F.range(0, 60, 62)])
        let first = try aligner.align(nav, with: result, source: source)
        let second = try aligner.align(nav, with: result, source: source)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.itemID), nav.items.map(\.id))
    }

    func testDiarizationPresenceNeverChangesTranscriptIdentityOrderOrSourceFingerprint() throws {
        let segments: [[TranscriptionTimingSegment]?] = [[S.segment(0, 2, "a"), S.segment(2, 4, "b")], nil, [S.segment(0, 5, "c")]]
        let withoutDiarization = try navigation(segments)
        let manifest = PlaybackTestManifest.make(
            sessionID: source.timeline.sessionID,
            sampleRate: 16_000,
            frameCounts: [480_000, 480_000, 160_000]
        )
        func transcriptFingerprint(_ nav: TranscriptPlaybackNavigation) -> TranscriptSourceFingerprint {
            let textBySequence = Dictionary(grouping: nav.items, by: \.chunkSequenceNumber)
                .mapValues { $0.map(\.text).joined() }
            let units = manifest.chunks.map {
                NotesTranscriptSourceUnit(
                    sequenceNumber: $0.sequenceNumber,
                    chunkFileName: $0.fileName,
                    text: textBySequence[$0.sequenceNumber] ?? "",
                    startOffsetSeconds: $0.startOffsetSeconds,
                    durationSeconds: $0.durationSeconds
                )
            }
            return TranscriptSourceFingerprint.compute(sessionID: manifest.sessionID, units: units)
        }
        let fingerprintBefore = transcriptFingerprint(withoutDiarization)

        let navigationToAlign = try navigation(segments)
        let speakers = try aligner.align(
            navigationToAlign,
            with: try F.result(source: source, ranges: [try F.range(0, 0, 3), try F.range(1, 30, 60)]),
            source: source
        )
        let noSpeakers = try aligner.align(navigationToAlign, with: try F.result(source: source, ranges: []), source: source)

        XCTAssertEqual(navigationToAlign, withoutDiarization, "alignment never alters the navigation it reads")
        XCTAssertEqual(speakers.map(\.itemID), withoutDiarization.items.map(\.id))
        XCTAssertEqual(noSpeakers.map(\.itemID), withoutDiarization.items.map(\.id))
        XCTAssertEqual(transcriptFingerprint(navigationToAlign), fingerprintBefore)
    }

    // MARK: - Mismatched inputs

    func testMismatchedInputsAreRejected() throws {
        let nav = try navigation([[S.segment(0, 4, "a")]])
        let good = try F.result(source: source, ranges: [try F.range(0, 0, 4)])

        let otherSession = try F.result(source: try F.source(), ranges: [])
        XCTAssertThrowsError(try aligner.align(nav, with: otherSession, source: source)) {
            XCTAssertEqual($0 as? SpeakerTranscriptAlignmentError, .sessionMismatch)
        }

        let otherSource = try F.source()
        let otherNavigation = try navigation([[S.segment(0, 4, "a")]], source: otherSource)
        XCTAssertThrowsError(try aligner.align(otherNavigation, with: good, source: source)) {
            XCTAssertEqual($0 as? SpeakerTranscriptAlignmentError, .sessionMismatch)
        }

        let resampled = TranscriptPlaybackNavigation(sessionID: nav.sessionID, sampleRate: 48_000, items: nav.items)
        XCTAssertThrowsError(try aligner.align(resampled, with: good, source: source)) {
            XCTAssertEqual($0 as? SpeakerTranscriptAlignmentError, .sampleRateMismatch)
        }

        let staleAudio = try F.result(
            source: try F.source(sessionID: source.timeline.sessionID, frameCounts: [480_000, 480_000, 160_001]),
            ranges: []
        )
        XCTAssertThrowsError(try aligner.align(nav, with: staleAudio, source: source)) {
            XCTAssertEqual($0 as? SpeakerTranscriptAlignmentError, .audioSourceMismatch)
        }

        var invalid = good
        invalid.ranges = [try F.range(0, 4, 1)]
        XCTAssertThrowsError(try aligner.align(nav, with: invalid, source: source)) {
            XCTAssertEqual($0 as? SpeakerTranscriptAlignmentError, .invalidResult(.emptyOrReversedRange(index: 0)))
        }
    }
}
