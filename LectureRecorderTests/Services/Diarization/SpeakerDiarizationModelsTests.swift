import XCTest
@testable import LectureRecorder

/// Pure diarization fixtures: a validated-looking `LecturePlaybackSource`
/// built from the shared playback manifest helper (chunk URLs are never
/// opened by diarization domain code), and range/result shorthands.
enum DiarizationTestFixtures {
    static let provenance = SpeakerDiarizationProvenance(
        backendIdentifier: "fake-diarizer",
        backendVersion: "1",
        configurationIdentifier: "default"
    )
    static let createdDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Default: 16 kHz mono, chunks of 30 s, 30 s, and a short final 10 s.
    static func source(
        sessionID: UUID = UUID(),
        sampleRate: Double = 16_000,
        channelCount: UInt32 = 1,
        frameCounts: [Int] = [480_000, 480_000, 160_000]
    ) throws -> LecturePlaybackSource {
        let manifest = PlaybackTestManifest.make(
            sessionID: sessionID,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCounts: frameCounts
        )
        let timeline = try LecturePlaybackTimeline(manifest: manifest)
        let chunkURLs = timeline.chunks.map {
            URL(fileURLWithPath: "/nonexistent/\(sessionID.uuidString)/chunks/\($0.fileName)")
        }
        return LecturePlaybackSource(timeline: timeline, chunkURLs: chunkURLs, channelCount: channelCount)
    }

    static func speaker(_ index: Int) throws -> SpeakerID {
        try SpeakerID(index: index)
    }

    static func range(_ index: Int, _ start: Double, _ end: Double) throws -> SpeakerTimeRange {
        SpeakerTimeRange(speakerID: try speaker(index), startSeconds: start, endSeconds: end)
    }

    static func result(
        source: LecturePlaybackSource,
        ranges: [SpeakerTimeRange],
        createdDate: Date = DiarizationTestFixtures.createdDate
    ) throws -> SpeakerDiarizationResult {
        try SpeakerDiarizationResult(
            sessionID: source.timeline.sessionID,
            createdDate: createdDate,
            provenance: provenance,
            audioSource: DiarizationAudioSourceFingerprint.compute(source: source),
            ranges: ranges
        )
    }
}

final class SpeakerDiarizationModelsTests: XCTestCase {
    private typealias F = DiarizationTestFixtures

    private func assertInvalid(
        _ ranges: [SpeakerTimeRange],
        _ expected: SpeakerDiarizationValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try F.source()
        XCTAssertThrowsError(try F.result(source: source, ranges: ranges), file: file, line: line) {
            XCTAssertEqual($0 as? SpeakerDiarizationValidationError, expected, file: file, line: line)
        }
    }

    // MARK: - SpeakerID

    func testCanonicalSpeakerIDsAreAccepted() throws {
        for (raw, index) in [("speaker_0", 0), ("speaker_7", 7), ("speaker_10", 10), ("speaker_999999", 999_999)] {
            let id = try SpeakerID(raw)
            XCTAssertEqual(id.index, index, raw)
            XCTAssertEqual(id.rawValue, raw)
            XCTAssertEqual(id, try SpeakerID(index: index))
        }
    }

    func testMalformedSpeakerIDsAreRejected() {
        let malformed = [
            "", "speaker_", "speaker_01", "speaker_00", "speaker_-1", "speaker_+1", "Speaker_0", "SPEAKER_0",
            "speaker_1a", "speaker_ 1", " speaker_1", "speaker_1\n", "speaker_1000000", "speaker_\u{0663}",
            "speaker_１", "lecturer", "Speaker 1", "speaker-1", "../speaker_0",
        ]
        for raw in malformed {
            XCTAssertThrowsError(try SpeakerID(raw), raw) {
                XCTAssertEqual($0 as? SpeakerDiarizationValidationError, .invalidSpeakerID, raw)
            }
        }
        for index in [-1, SpeakerID.maximumIndex + 1] {
            XCTAssertThrowsError(try SpeakerID(index: index))
        }
    }

    func testSpeakerIDsOrderNumericallyNotLexically() throws {
        let ids = try [10, 2, 0, 1].map { try SpeakerID(index: $0) }.sorted()
        XCTAssertEqual(ids.map(\.rawValue), ["speaker_0", "speaker_1", "speaker_2", "speaker_10"])
    }

    func testSpeakerIDCodesAsItsRawStringAndRejectsMalformedJSON() throws {
        let data = try JSONEncoder().encode([try SpeakerID(index: 3)])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["speaker_3"]"#)
        XCTAssertEqual(try JSONDecoder().decode([SpeakerID].self, from: data), [try SpeakerID(index: 3)])
        XCTAssertThrowsError(try JSONDecoder().decode([SpeakerID].self, from: Data(#"["Speaker 1"]"#.utf8))) {
            XCTAssertEqual($0 as? SpeakerDiarizationValidationError, .invalidSpeakerID)
        }
    }

    // MARK: - Ranges

    func testValidRangesBuildAResult() throws {
        let source = try F.source()
        let ranges = [try F.range(0, 0, 4.5), try F.range(1, 4.5, 9), try F.range(0, 9, 70)]
        let result = try F.result(source: source, ranges: ranges)
        XCTAssertEqual(result.schemaVersion, SpeakerDiarizationResult.currentSchemaVersion)
        XCTAssertEqual(result.ranges, ranges)
        XCTAssertEqual(result.speakerIDs, [try F.speaker(0), try F.speaker(1)])
        XCTAssertNoThrow(try result.validate(against: source.timeline))
    }

    func testEmptyRangesAreAValidResult() throws {
        XCTAssertEqual(try F.result(source: try F.source(), ranges: []).speakerIDs, [])
    }

    func testNonFiniteNegativeEmptyAndReversedRangesAreRejected() throws {
        try assertInvalid([try F.range(0, .nan, 1)], .nonFiniteBoundary(index: 0))
        try assertInvalid([try F.range(0, 0, .infinity)], .nonFiniteBoundary(index: 0))
        try assertInvalid([try F.range(0, 0, 1), try F.range(0, 2, -.infinity)], .nonFiniteBoundary(index: 1))
        try assertInvalid([try F.range(0, -0.25, 1)], .negativeStart(index: 0))
        try assertInvalid([try F.range(0, 3, 3)], .emptyOrReversedRange(index: 0))
        try assertInvalid([try F.range(0, 3, 2)], .emptyOrReversedRange(index: 0))
    }

    func testRangesMustBeInCanonicalOrder() throws {
        try assertInvalid([try F.range(0, 5, 6), try F.range(1, 1, 2)], .unordered(index: 1))
        // Same start: shorter first.
        try assertInvalid([try F.range(0, 1, 6), try F.range(1, 1, 2)], .unordered(index: 1))
        // Same start and end: lower speaker first.
        try assertInvalid([try F.range(1, 0, 1), try F.range(0, 0, 1)], .unordered(index: 1))
        try assertInvalid([try F.range(0, 0, 1), try F.range(2, 1, 2), try F.range(1, 1, 2)], .unordered(index: 2))
    }

    func testSameSpeakerRangesMayTouchButNotOverlap() throws {
        let source = try F.source()
        XCTAssertNoThrow(try F.result(source: source, ranges: [try F.range(0, 0, 2), try F.range(0, 2, 3)]))
        try assertInvalid([try F.range(0, 0, 2), try F.range(0, 1.5, 3)], .overlappingSameSpeaker(index: 1))
        try assertInvalid(
            [try F.range(0, 0, 10), try F.range(1, 1, 2), try F.range(0, 5, 6)],
            .overlappingSameSpeaker(index: 2)
        )
    }

    func testDifferentSpeakersMayOverlap() throws {
        let ranges = [try F.range(0, 0, 10), try F.range(1, 2, 3), try F.range(2, 2, 12)]
        XCTAssertEqual(try F.result(source: try F.source(), ranges: ranges).ranges, ranges)
    }

    func testSpeakerIDsMustBeDenseAndNumberedByFirstSpeech() throws {
        try assertInvalid([try F.range(0, 0, 1), try F.range(2, 1, 2)], .nonDenseSpeakerIDs)
        try assertInvalid([try F.range(1, 0, 1)], .nonDenseSpeakerIDs)
        try assertInvalid([try F.range(1, 0, 1), try F.range(0, 1, 2)], .speakerNumberingNotByFirstSpeech)
        // A simultaneous first start may be numbered either way by the
        // normalizer's label tie-break; only order by start is required.
        XCTAssertNoThrow(try F.result(source: try F.source(), ranges: [try F.range(1, 0, 1), try F.range(0, 0, 2)]))
    }

    func testRangesMustEndWithinTheSessionAudio() throws {
        let source = try F.source()
        let duration = source.timeline.durationSeconds
        XCTAssertEqual(duration, 70)
        XCTAssertNoThrow(try F.result(source: source, ranges: [try F.range(0, 60, duration)]).validate(against: source.timeline))
        let beyond = try F.result(source: source, ranges: [try F.range(0, 1, 2), try F.range(0, 60, duration.nextUp)])
        XCTAssertThrowsError(try beyond.validate(against: source.timeline)) {
            XCTAssertEqual($0 as? SpeakerDiarizationValidationError, .rangeBeyondAudio(index: 1))
        }
    }

    // MARK: - Result fields

    func testEmptyProvenanceAndMalformedFingerprintAreRejected() throws {
        let source = try F.source()
        var result = try F.result(source: source, ranges: [])

        result.provenance.backendVersion = "  \n"
        XCTAssertThrowsError(try result.validate()) {
            XCTAssertEqual($0 as? SpeakerDiarizationValidationError, .emptyProvenanceField("backendVersion"))
        }
        result.provenance = F.provenance

        let good = result.audioSource
        for bad in [
            DiarizationAudioSourceFingerprint(algorithmVersion: 2, digestHex: good.digestHex),
            DiarizationAudioSourceFingerprint(algorithmVersion: 1, digestHex: good.digestHex.uppercased()),
            DiarizationAudioSourceFingerprint(algorithmVersion: 1, digestHex: String(good.digestHex.dropLast())),
            DiarizationAudioSourceFingerprint(algorithmVersion: 1, digestHex: ""),
        ] {
            result.audioSource = bad
            XCTAssertThrowsError(try result.validate()) {
                XCTAssertEqual($0 as? SpeakerDiarizationValidationError, .malformedAudioSourceFingerprint)
            }
        }
    }

    func testUnsupportedSchemaVersionIsRejected() throws {
        var result = try F.result(source: try F.source(), ranges: [])
        result.schemaVersion = 2
        XCTAssertThrowsError(try result.validate()) {
            XCTAssertEqual($0 as? SpeakerDiarizationValidationError, .unsupportedSchemaVersion(2))
        }
    }

    func testPersistedShapeHasNoTranscriptIdentityOrDisplayLabels() throws {
        let result = try F.result(source: try F.source(), ranges: [try F.range(0, 0, 1)])
        let data = try AtomicFileWriter.defaultEncoder.encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "sessionID", "createdDate", "provenance", "audioSource", "ranges"])
        let range = try XCTUnwrap((object["ranges"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(range.keys), ["speakerID", "startSeconds", "endSeconds"])
        XCTAssertEqual(range["speakerID"] as? String, "speaker_0")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Speaker 1"))
        XCTAssertEqual(try AtomicFileWriter.defaultDecoder.decode(SpeakerDiarizationResult.self, from: data), result)
    }
}

final class DiarizationAudioSourceFingerprintTests: XCTestCase {
    private typealias F = DiarizationTestFixtures
    private let sessionID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func chunk(_ sequence: Int, _ fileName: String? = nil, frames: Int64, start: Int64 = 0) -> LecturePlaybackChunk {
        LecturePlaybackChunk(
            sequenceNumber: sequence,
            fileName: fileName ?? TranscriptionArtifactPaths.canonicalChunkFileName(for: sequence),
            startFrame: start,
            frameCount: frames
        )
    }

    private func fingerprint(
        sessionID: UUID? = nil,
        sampleRate: Double = 16_000,
        channelCount: UInt32 = 1,
        chunks: [LecturePlaybackChunk]? = nil
    ) -> DiarizationAudioSourceFingerprint {
        DiarizationAudioSourceFingerprint.compute(
            sessionID: sessionID ?? self.sessionID,
            sampleRate: sampleRate,
            channelCount: channelCount,
            chunks: chunks ?? [chunk(0, frames: 480_000), chunk(1, frames: 160_000, start: 480_000)]
        )
    }

    func testIdenticalSourcesProduceIdenticalWellFormedFingerprints() throws {
        let first = DiarizationAudioSourceFingerprint.compute(source: try F.source(sessionID: sessionID))
        let second = DiarizationAudioSourceFingerprint.compute(source: try F.source(sessionID: sessionID))
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.isWellFormed)
        XCTAssertEqual(first.algorithmVersion, DiarizationAudioSourceFingerprint.currentAlgorithmVersion)
    }

    /// Pins the v1 encoding: a change here means persisted sidecars would
    /// silently stop matching, so the algorithm version must be bumped.
    /// The expected value was cross-checked against an independent
    /// implementation of the documented byte encoding.
    func testVersionOneDigestIsStable() {
        XCTAssertEqual(fingerprint().digestHex, "82773140dc497054624886f3670ac901749515305de45df58148cd7e392a31ca")
    }

    func testEachAuthoritativeInputChangesTheFingerprint() {
        let base = fingerprint()
        let variants: [(String, DiarizationAudioSourceFingerprint)] = [
            ("session", fingerprint(sessionID: UUID())),
            ("sample rate", fingerprint(sampleRate: 48_000)),
            ("sample rate by one ulp", fingerprint(sampleRate: Double(16_000).nextUp)),
            ("channel count", fingerprint(channelCount: 2)),
            ("sequence", fingerprint(chunks: [chunk(0, frames: 480_000), chunk(2, "chunk_000001.caf", frames: 160_000)])),
            ("file name", fingerprint(chunks: [chunk(0, frames: 480_000), chunk(1, "chunk_000009.caf", frames: 160_000)])),
            ("frame count", fingerprint(chunks: [chunk(0, frames: 480_000), chunk(1, frames: 160_001)])),
            ("frames moved between chunks", fingerprint(chunks: [chunk(0, frames: 480_001), chunk(1, frames: 159_999)])),
            ("chunk added", fingerprint(chunks: [chunk(0, frames: 480_000), chunk(1, frames: 160_000), chunk(2, frames: 1)])),
            ("chunk removed", fingerprint(chunks: [chunk(0, frames: 480_000)])),
        ]
        for (name, variant) in variants {
            XCTAssertNotEqual(variant, base, name)
        }
        XCTAssertEqual(Set(variants.map(\.1.digestHex)).count, variants.count, "every mutation yields a distinct digest")
    }

    func testChunkEnumerationOrderAndDerivedStartFramesDoNotMatter() {
        let base = fingerprint()
        XCTAssertEqual(fingerprint(chunks: [chunk(1, frames: 160_000), chunk(0, frames: 480_000)]), base)
        XCTAssertEqual(fingerprint(chunks: [chunk(0, frames: 480_000, start: 7), chunk(1, frames: 160_000, start: 9)]), base)
    }

    func testPersistedFloatTimingAloneDoesNotChangeTheFingerprint() throws {
        let manifest = PlaybackTestManifest.make(sessionID: sessionID, sampleRate: 16_000, frameCounts: [480_000, 160_000])
        var drifted = manifest
        for index in drifted.chunks.indices {
            drifted.chunks[index].startOffsetSeconds += 0.123 * Double(index + 1)
            drifted.chunks[index].durationSeconds = 29.97
        }
        let original = try LecturePlaybackSource(timeline: LecturePlaybackTimeline(manifest: manifest), chunkURLs: [], channelCount: 1)
        let driftedSource = try LecturePlaybackSource(timeline: LecturePlaybackTimeline(manifest: drifted), chunkURLs: [], channelCount: 1)
        XCTAssertEqual(
            DiarizationAudioSourceFingerprint.compute(source: driftedSource),
            DiarizationAudioSourceFingerprint.compute(source: original)
        )
        XCTAssertEqual(DiarizationAudioSourceFingerprint.compute(source: original), fingerprint())
    }

    func testChunkURLsAreNotPartOfTheFingerprint() throws {
        let source = try F.source(sessionID: sessionID)
        let moved = LecturePlaybackSource(
            timeline: source.timeline,
            chunkURLs: source.chunkURLs.map { URL(fileURLWithPath: "/elsewhere").appendingPathComponent($0.lastPathComponent) },
            channelCount: source.channelCount
        )
        XCTAssertEqual(DiarizationAudioSourceFingerprint.compute(source: moved), DiarizationAudioSourceFingerprint.compute(source: source))
    }
}
