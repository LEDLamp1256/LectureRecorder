import XCTest
@testable import LectureRecorder

final class TranscriptionModelsTests: XCTestCase {
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
            schemaVersion: TranscriptResult.currentSchemaVersion,
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
