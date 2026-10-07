import XCTest
@testable import LectureRecorder

final class DiarizationSegmentNormalizerTests: XCTestCase {
    private typealias F = DiarizationTestFixtures

    private func segment(_ label: String, _ start: Double, _ end: Double) -> DiarizationBackendSegment {
        DiarizationBackendSegment(label: label, startSeconds: start, endSeconds: end)
    }

    // MARK: - Speaker IDs

    func testLabelsBecomeIDsInOrderOfFirstSpeech() throws {
        // Backend labels deliberately sort the other way, and the later
        // speaker talks longest — neither may decide the numbering.
        let ranges = try DiarizationSegmentNormalizer.normalize(
            [segment("S9", 30, 90), segment("S1", 100, 110), segment("S9", 110, 120), segment("S1", 5, 10)],
            audioDurationSeconds: 200
        )
        XCTAssertEqual(ranges, [
            try F.range(0, 5, 10), try F.range(1, 30, 90), try F.range(0, 100, 110), try F.range(1, 110, 120),
        ])
    }

    func testSimultaneousFirstSpeechTiesBreakByBackendLabel() throws {
        let ranges = try DiarizationSegmentNormalizer.normalize(
            [segment("b", 0, 5), segment("a", 0, 4)], audioDurationSeconds: 10
        )
        XCTAssertEqual(ranges, [try F.range(0, 0, 4), try F.range(1, 0, 5)])
    }

    func testNumberingIsIndependentOfInputOrder() throws {
        let segments = [segment("x", 3, 8), segment("y", 1, 2), segment("z", 9, 12), segment("x", 12, 14)]
        let forward = try DiarizationSegmentNormalizer.normalize(segments, audioDurationSeconds: 20)
        let reversed = try DiarizationSegmentNormalizer.normalize(segments.reversed(), audioDurationSeconds: 20)
        XCTAssertEqual(forward, reversed)
    }

    func testMoreThanTenSpeakersAreNumberedAndOrderedNumerically() throws {
        let segments = (0..<12).map { segment("L\(11 - $0)", Double($0), Double($0) + 0.5) }
        let ranges = try DiarizationSegmentNormalizer.normalize(segments, audioDurationSeconds: 20)
        XCTAssertEqual(ranges.map(\.speakerID.index), Array(0..<12))
        XCTAssertEqual(ranges.last?.speakerID.rawValue, "speaker_11")
    }

    // MARK: - Times and overlap

    func testOverlappingSpeakersArePreserved() throws {
        let ranges = try DiarizationSegmentNormalizer.normalize(
            [segment("A", 60, 75.5), segment("B", 70, 80)], audioDurationSeconds: 120
        )
        XCTAssertEqual(ranges, [try F.range(0, 60, 75.5), try F.range(1, 70, 80)], "overlapped speech keeps both speakers")
    }

    func testSameSpeakerOverlappingOrTouchingRangesMerge() throws {
        let ranges = try DiarizationSegmentNormalizer.normalize(
            [segment("A", 0, 10), segment("A", 8, 12), segment("A", 12, 15), segment("A", 20, 25), segment("A", 21, 22)],
            audioDurationSeconds: 30
        )
        XCTAssertEqual(ranges, [try F.range(0, 0, 15), try F.range(0, 20, 25)])
    }

    func testRangesAreClippedToTheAudioAndEmptyOnesDropped() throws {
        let ranges = try DiarizationSegmentNormalizer.normalize(
            [segment("A", 0, 0), segment("A", 5, 12), segment("B", 11, 20), segment("C", 10, 18)],
            audioDurationSeconds: 10
        )
        XCTAssertEqual(ranges, [try F.range(0, 5, 10)], "B and C start at or past the end and get no speaker ID")
    }

    func testEmptyBackendOutputIsAValidEmptyResult() throws {
        let ranges = try DiarizationSegmentNormalizer.normalize([], audioDurationSeconds: 10)
        XCTAssertEqual(ranges, [])
        XCTAssertNoThrow(try F.result(source: try F.source(), ranges: ranges))
    }

    func testMalformedBackendSegmentsFailTheRun() {
        let malformed: [DiarizationBackendSegment] = [
            segment("A", .nan, 2),
            segment("A", 0, .infinity),
            segment("A", -0.5, 2),
            segment("A", 5, 4),
        ]
        for bad in malformed {
            XCTAssertThrowsError(try DiarizationSegmentNormalizer.normalize([segment("B", 0, 1), bad], audioDurationSeconds: 10)) {
                XCTAssertEqual($0 as? DiarizationSegmentNormalizerError, .malformedSegment(index: 1))
            }
        }
    }

    func testInvalidAudioDurationIsRejected() {
        for duration in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try DiarizationSegmentNormalizer.normalize([], audioDurationSeconds: duration)) {
                XCTAssertEqual($0 as? DiarizationSegmentNormalizerError, .invalidAudioDuration)
            }
        }
    }

    func testNormalizedOutputAlwaysPassesResultValidation() throws {
        let source = try F.source()
        let ranges = try DiarizationSegmentNormalizer.normalize(
            [segment("A", 0, 10), segment("B", 2, 3), segment("A", 9, 20), segment("C", 2, 3), segment("B", 25, 30),
             segment("D", 2, 2.5), segment("C", 65, 90)],
            audioDurationSeconds: source.timeline.durationSeconds
        )
        let result = try F.result(source: source, ranges: ranges)
        XCTAssertNoThrow(try result.validate(against: source.timeline))
    }

    // MARK: - Backend output → result

    func testBackendOutputBecomesAResultBoundToItsAudio() throws {
        let source = try F.source()
        let output = SpeakerDiarizationOutput(
            provenance: F.provenance,
            segments: [segment("spk-b", 65, 80), segment("spk-a", 1, 4), segment("spk-b", 3, 5)]
        )
        let result = try SpeakerDiarizationResult(output: output, source: source, createdDate: F.createdDate)
        XCTAssertEqual(result.sessionID, source.timeline.sessionID)
        XCTAssertEqual(result.audioSource, DiarizationAudioSourceFingerprint.compute(source: source))
        XCTAssertEqual(result.provenance, F.provenance)
        XCTAssertEqual(result.createdDate, F.createdDate)
        XCTAssertEqual(result.ranges, [try F.range(0, 1, 4), try F.range(1, 3, 5), try F.range(1, 65, 70)],
                       "clipped to the frame-exact 70 s duration")
    }

    func testFakeBackendConformsToTheProtocol() async throws {
        struct FakeDiarizer: SpeakerDiarizing {
            func diarize(_ request: SpeakerDiarizationRequest) async throws -> SpeakerDiarizationOutput {
                SpeakerDiarizationOutput(
                    provenance: DiarizationTestFixtures.provenance,
                    segments: [DiarizationBackendSegment(label: request.sessionID.uuidString, startSeconds: 0, endSeconds: 1)]
                )
            }
        }
        let source = try F.source()
        let output = try await FakeDiarizer().diarize(SpeakerDiarizationRequest(source: source))
        let result = try SpeakerDiarizationResult(output: output, source: source, createdDate: F.createdDate)
        XCTAssertEqual(result.ranges, [try F.range(0, 0, 1)])
    }
}
