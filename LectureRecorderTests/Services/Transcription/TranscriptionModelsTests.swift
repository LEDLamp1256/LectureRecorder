import XCTest
@testable import LectureRecorder

final class TranscriptionModelsTests: XCTestCase {
    private var historicalV1FixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-result-v1.json")
    }

    private func makeSource(sequenceNumber: Int = 0) -> TranscriptionSourceSnapshot {
        TranscriptionSourceSnapshot(
            sessionID: UUID(),
            chunkSequenceNumber: sequenceNumber,
            chunkFileName: "chunk_000000.caf",
            frameCount: 1_000,
            startOffsetSeconds: 0,
            durationSeconds: 30,
            audioFormat: AudioFormatDescriptor(
                sampleRate: 44_100,
                channelCount: 1,
                bitsPerChannel: 32,
                formatIdentifier: "lpcm-float32"
            )
        )
    }

    /// `AtomicFileWriter`'s ISO8601-with-fractional-seconds date strategy
    /// only preserves millisecond precision, while an in-memory `Date()`
    /// carries full `Double` precision. So a value decoded once already
    /// differs from the pre-encoding original at the sub-millisecond
    /// level by design — these round-trip tests compare a *second*
    /// decode against the first (both at the same, wire-stable precision)
    /// rather than against the original in-memory value, which is the
    /// correct way to verify "encode then decode is stable," not "decode
    /// recovers the exact original."
    func testTranscriptionJobRoundTripsThroughJSON() throws {
        let job = TranscriptionJob.newQueued(source: makeSource(), now: Date())
        let decoded = try AtomicFileWriter.defaultDecoder.decode(
            TranscriptionJob.self,
            from: try AtomicFileWriter.defaultEncoder.encode(job)
        )
        let redecoded = try AtomicFileWriter.defaultDecoder.decode(
            TranscriptionJob.self,
            from: try AtomicFileWriter.defaultEncoder.encode(decoded)
        )
        XCTAssertEqual(decoded, redecoded)
        XCTAssertEqual(decoded.source, job.source)
        XCTAssertEqual(decoded.state, job.state)
        XCTAssertEqual(decoded.schemaVersion, job.schemaVersion)
    }

    func testTranscriptResultRoundTripsThroughJSON() throws {
        let result = TranscriptResult(
            schemaVersion: TranscriptResult.legacySchemaVersion,
            source: makeSource(),
            output: TranscriptionEngineOutput(
                text: "hello",
                engineIdentifier: "fake-v1",
                modelIdentifier: nil,
                language: nil,
                segments: nil,
                engineVersion: nil
            ),
            attemptID: UUID(),
            completedDate: Date()
        )
        let decoded = try AtomicFileWriter.defaultDecoder.decode(
            TranscriptResult.self,
            from: try AtomicFileWriter.defaultEncoder.encode(result)
        )
        let redecoded = try AtomicFileWriter.defaultDecoder.decode(
            TranscriptResult.self,
            from: try AtomicFileWriter.defaultEncoder.encode(decoded)
        )
        XCTAssertEqual(decoded, redecoded)
        XCTAssertEqual(decoded.source, result.source)
        XCTAssertEqual(decoded.output, result.output)
        XCTAssertEqual(decoded.attemptID, result.attemptID)
        XCTAssertNil(decoded.output.provenance)
    }

    func testHistoricalV1BytesDecodeWithoutProvenanceAndAreNotRewritten() throws {
        let before = try Data(contentsOf: historicalV1FixtureURL)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: historicalV1FixtureURL.path)

        let result = try AtomicFileWriter.defaultDecoder.decode(TranscriptResult.self, from: before)

        XCTAssertEqual(result.schemaVersion, TranscriptResult.legacySchemaVersion)
        XCTAssertNil(result.output.provenance)
        XCTAssertEqual(result.output.text, "historical transcript")
        XCTAssertEqual(try Data(contentsOf: historicalV1FixtureURL), before)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: historicalV1FixtureURL.path)
        XCTAssertEqual(attributesBefore[.modificationDate] as? Date, attributesAfter[.modificationDate] as? Date)
    }

    func testCompleteProvenanceV2RoundTripsExactly() throws {
        let provenance = makeT3BProvenance()
        var output = TranscriptionEngineOutput(
            text: "hello",
            engineIdentifier: "whisper.cpp",
            modelIdentifier: "large-v3-turbo",
            language: "en",
            segments: [],
            engineVersion: "1.9.2"
        )
        output.provenance = provenance
        let result = TranscriptResult(
            schemaVersion: TranscriptResult.schemaVersion(for: output),
            source: makeSource(),
            output: output,
            attemptID: UUID(),
            completedDate: Date()
        )
        let data = try AtomicFileWriter.defaultEncoder.encode(result)
        let decoded = try AtomicFileWriter.defaultDecoder.decode(TranscriptResult.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.output.provenance, provenance)
    }

    func testV2DecodeRejectsEachLegacyIdentityContradiction() throws {
        var output = TranscriptionEngineOutput(
            text: "hello", engineIdentifier: "whisper.cpp", modelIdentifier: "large-v3-turbo",
            language: "en", segments: [], engineVersion: "1.9.2"
        )
        output.provenance = makeT3BProvenance()
        let valid = TranscriptResult(
            schemaVersion: 2, source: makeSource(), output: output,
            attemptID: UUID(), completedDate: Date()
        )
        let validData = try AtomicFileWriter.defaultEncoder.encode(valid)
        let contradictions: [(String, Any)] = [
            ("engineIdentifier", "other-engine"),
            ("engineVersion", "0.0.0"),
            ("modelIdentifier", "other-model"),
            ("language", "EN"),
        ]
        for (field, value) in contradictions {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
            var encodedOutput = try XCTUnwrap(object["output"] as? [String: Any])
            encodedOutput[field] = value
            object["output"] = encodedOutput
            let contradictoryData = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try AtomicFileWriter.defaultDecoder.decode(TranscriptResult.self, from: contradictoryData), field)
        }
    }

    func testV2WithoutProvenanceIsRejected() throws {
        let result = TranscriptResult(
            schemaVersion: 2,
            source: makeSource(),
            output: TranscriptionEngineOutput(
                text: "hello", engineIdentifier: "fake", modelIdentifier: nil,
                language: nil, segments: nil, engineVersion: nil
            ),
            attemptID: UUID(),
            completedDate: Date()
        )
        XCTAssertThrowsError(try AtomicFileWriter.defaultEncoder.encode(result))
    }

    func testProvenanceRejectsInvalidCanonicalAndBoundedFields() {
        var provenance = makeT3BProvenance()
        provenance.engine.sourceRevision = provenance.engine.sourceRevision.uppercased()
        XCTAssertThrowsError(try provenance.validate())

        provenance = makeT3BProvenance()
        provenance.model.sha256 = String(repeating: "a", count: 63)
        XCTAssertThrowsError(try provenance.validate())

        provenance = makeT3BProvenance()
        provenance.model.byteCount = 0
        XCTAssertThrowsError(try provenance.validate())

        provenance = makeT3BProvenance()
        provenance.configuration.threadCount = 65
        XCTAssertThrowsError(try provenance.validate())

        provenance = makeT3BProvenance()
        provenance.worker.identifier = String(repeating: "x", count: 129)
        XCTAssertThrowsError(try provenance.validate())
    }

    func testMalformedV2NumericAndEnumValuesAreRejected() throws {
        var output = TranscriptionEngineOutput(
            text: "hello", engineIdentifier: "whisper.cpp", modelIdentifier: "large-v3-turbo",
            language: "en", segments: [], engineVersion: "1.9.2"
        )
        output.provenance = makeT3BProvenance()
        let result = TranscriptResult(
            schemaVersion: 2, source: makeSource(), output: output,
            attemptID: UUID(), completedDate: Date()
        )
        let data = try AtomicFileWriter.defaultEncoder.encode(result)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertThrowsError(try AtomicFileWriter.defaultDecoder.decode(
            TranscriptResult.self,
            from: Data(json.replacingOccurrences(of: "\"greedy\"", with: "\"unknown\"").utf8)
        ))
        XCTAssertThrowsError(try AtomicFileWriter.defaultDecoder.decode(
            TranscriptResult.self,
            from: Data(json.replacingOccurrences(of: "1624555275", with: "-1").utf8)
        ))
        XCTAssertThrowsError(try AtomicFileWriter.defaultDecoder.decode(
            TranscriptResult.self,
            from: Data(json.replacingOccurrences(of: "1624555275", with: "18446744073709551616").utf8)
        ))
    }

    func testUnknownFutureResultVersionIsRejected() throws {
        let historical = try Data(contentsOf: historicalV1FixtureURL)
        let json = String(decoding: historical, as: UTF8.self)
        XCTAssertThrowsError(try AtomicFileWriter.defaultDecoder.decode(
            TranscriptResult.self,
            from: Data(json.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 999").utf8)
        ))
    }

    func testTranscriptionFailureRoundTripsThroughJSON() throws {
        let failure = TranscriptionFailure(
            category: .engineThrew,
            message: "boom",
            retryDisposition: .retryable,
            failureDate: Date(),
            attemptNumber: 1
        )
        let decoded = try AtomicFileWriter.defaultDecoder.decode(
            TranscriptionFailure.self,
            from: try AtomicFileWriter.defaultEncoder.encode(failure)
        )
        let redecoded = try AtomicFileWriter.defaultDecoder.decode(
            TranscriptionFailure.self,
            from: try AtomicFileWriter.defaultEncoder.encode(decoded)
        )
        XCTAssertEqual(decoded, redecoded)
        XCTAssertEqual(decoded.category, failure.category)
        XCTAssertEqual(decoded.message, failure.message)
        XCTAssertEqual(decoded.retryDisposition, failure.retryDisposition)
        XCTAssertEqual(decoded.attemptNumber, failure.attemptNumber)
    }

    func testNewQueuedJobStartsQueuedWithNoAttempt() {
        let job = TranscriptionJob.newQueued(source: makeSource(), now: Date())
        XCTAssertEqual(job.state, .queued)
        XCTAssertNil(job.currentAttemptID)
        XCTAssertEqual(job.attemptCount, 0)
        XCTAssertNil(job.lastFailure)
    }

    func testNewSourceMissingJobIsFailedWithSourceMissingCategory() {
        let job = TranscriptionJob.newSourceMissing(source: makeSource(), now: Date())
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.lastFailure?.category, .sourceMissing)
        XCTAssertEqual(job.lastFailure?.retryDisposition, .retryable)
        XCTAssertEqual(job.attemptCount, 0)
    }

    func testOrderedSegmentStatesAreDistinguishable() {
        XCTAssertNotEqual(OrderedSegment.State.missing, OrderedSegment.State.inProgress)
        XCTAssertNotEqual(
            OrderedSegment.State.completed(text: "a"),
            OrderedSegment.State.completed(text: "b")
        )
    }
}
