import XCTest
@testable import LectureRecorder

/// Pure codec/protocol tests — no process spawned. Proves envelope
/// round-tripping and, critically, the exact `JSONDecoder` framing
/// behavior `TranscriptionWorkerClient` relies on instead of a
/// hand-written brace/bracket scanner.
final class WorkerProtocolTests: XCTestCase {
    private struct Payload: Codable, Sendable, Equatable { var a: Int }

    // MARK: - Empirically-verified JSONDecoder framing behavior
    // (see TranscriptionWorkerClient.decodeAndValidate's doc comment —
    // this is the permanent regression test for that empirical finding,
    // captured on Xcode 26.6 / Swift 6.3.3.)

    func testJSONDecoderRejectsTrailingNonWhitespaceGarbage() {
        let data = Data("{\"a\":1} not json garbage".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Payload.self, from: data))
    }

    func testJSONDecoderRejectsMultipleTopLevelJSONValues() {
        let data = Data("{\"a\":1}{\"a\":2}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Payload.self, from: data))
    }

    func testJSONDecoderRejectsTruncatedJSON() {
        let data = Data("{\"a\":1".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Payload.self, from: data))
    }

    func testJSONDecoderRejectsEmptyData() {
        XCTAssertThrowsError(try JSONDecoder().decode(Payload.self, from: Data()))
    }

    func testJSONDecoderAllowsTrailingWhitespace() throws {
        let data = Data("{\"a\":1}   \n".utf8)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        XCTAssertEqual(decoded.a, 1)
    }

    // MARK: - Envelope round-tripping

    func testRequestEnvelopeRoundTrips() throws {
        let identity = WorkerFixtureTestSupport.makeIdentity(chunkSequenceNumber: 3, sourceIdentity: "sess:3")
        let envelope = WorkerRequestEnvelope(
            schemaVersion: WorkerProtocolConstants.currentSchemaVersion,
            requestID: identity.requestID,
            attemptID: identity.attemptID,
            sessionID: identity.sessionID,
            chunkSequenceNumber: identity.chunkSequenceNumber,
            sourceIdentity: identity.sourceIdentity,
            payload: Payload(a: 42)
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(WorkerRequestEnvelope<Payload>.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, envelope.schemaVersion)
        XCTAssertEqual(decoded.requestID, envelope.requestID)
        XCTAssertEqual(decoded.attemptID, envelope.attemptID)
        XCTAssertEqual(decoded.sessionID, envelope.sessionID)
        XCTAssertEqual(decoded.chunkSequenceNumber, envelope.chunkSequenceNumber)
        XCTAssertEqual(decoded.sourceIdentity, envelope.sourceIdentity)
        XCTAssertEqual(decoded.payload, envelope.payload)
    }

    func testResponseEnvelopeRoundTripsSuccess() throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let envelope = WorkerResponseEnvelope(
            schemaVersion: WorkerProtocolConstants.currentSchemaVersion,
            requestID: identity.requestID,
            attemptID: identity.attemptID,
            sessionID: identity.sessionID,
            chunkSequenceNumber: identity.chunkSequenceNumber,
            sourceIdentity: identity.sourceIdentity,
            workerIdentifier: "fixture",
            workerVersion: "1.0",
            outcome: .success,
            output: TestFixtureOutput(text: "hi"),
            failure: nil
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(WorkerResponseEnvelope<TestFixtureOutput>.self, from: data)

        XCTAssertEqual(decoded.outcome, .success)
        XCTAssertEqual(decoded.output, TestFixtureOutput(text: "hi"))
        XCTAssertNil(decoded.failure)
    }

    func testResponseEnvelopeRoundTripsFailure() throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let envelope = WorkerResponseEnvelope<TestFixtureOutput>(
            schemaVersion: WorkerProtocolConstants.currentSchemaVersion,
            requestID: identity.requestID,
            attemptID: identity.attemptID,
            sessionID: identity.sessionID,
            chunkSequenceNumber: identity.chunkSequenceNumber,
            sourceIdentity: identity.sourceIdentity,
            workerIdentifier: "fixture",
            workerVersion: "1.0",
            outcome: .failure,
            output: nil,
            failure: WorkerDeclaredFailure(message: "nope")
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(WorkerResponseEnvelope<TestFixtureOutput>.self, from: data)

        XCTAssertEqual(decoded.outcome, .failure)
        XCTAssertNil(decoded.output)
        XCTAssertEqual(decoded.failure, WorkerDeclaredFailure(message: "nope"))
    }
}
