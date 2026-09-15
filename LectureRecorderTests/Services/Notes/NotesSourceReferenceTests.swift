import XCTest
@testable import LectureRecorder

final class NotesSourceReferenceTests: XCTestCase {
    private func makeSnapshot(sessionID: UUID = UUID(), unitCount: Int) -> NotesTranscriptSourceSnapshot {
        let units = (0..<unitCount).map { seq in
            NotesTranscriptSourceUnit(
                sequenceNumber: seq,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                text: "unit \(seq)",
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30
            )
        }
        return NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        )
    }

    func testValidSingleSourceReferenceValidates() {
        let snapshot = makeSnapshot(unitCount: 3)
        let reference = NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: 1)
        XCTAssertNoThrow(try reference.validate(against: snapshot))
    }

    func testValidContiguousRangeValidates() {
        let snapshot = makeSnapshot(unitCount: 5)
        let reference = NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 1, lastSequenceNumber: 3)
        XCTAssertNoThrow(try reference.validate(against: snapshot))
    }

    func testOutOfRangeReferenceRejected() {
        let snapshot = makeSnapshot(unitCount: 3)
        let reference = NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: 5)
        XCTAssertThrowsError(try reference.validate(against: snapshot)) { error in
            guard case NotesSourceReferenceError.outOfRange = error else {
                return XCTFail("expected outOfRange, got \(error)")
            }
        }
    }

    func testInvertedRangeRejected() {
        let snapshot = makeSnapshot(unitCount: 3)
        let reference = NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 2, lastSequenceNumber: 0)
        XCTAssertThrowsError(try reference.validate(against: snapshot)) { error in
            guard case NotesSourceReferenceError.invertedRange = error else {
                return XCTFail("expected invertedRange, got \(error)")
            }
        }
    }

    func testReferenceBelongingToWrongSessionRejected() {
        let snapshot = makeSnapshot(unitCount: 3)
        let reference = NotesSourceReference(sessionID: UUID(), sequenceNumber: 0)
        XCTAssertThrowsError(try reference.validate(against: snapshot)) { error in
            XCTAssertEqual(error as? NotesSourceReferenceError, .sessionMismatch)
        }
    }

    /// A snapshot deliberately constructed with a gap (sequence 1 missing)
    /// — direct construction bypasses `NotesTranscriptSourceBuilder`'s own
    /// topology enforcement, letting this test isolate
    /// `NotesSourceReference.validate`'s independent defense: a reference
    /// spanning the gap must be rejected even though both its endpoints
    /// (0 and 2) individually exist and fall within the min/max range.
    private func makeSparseSnapshot(sessionID: UUID = UUID()) -> NotesTranscriptSourceSnapshot {
        let units = [0, 2].map { seq in
            NotesTranscriptSourceUnit(
                sequenceNumber: seq,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                text: "unit \(seq)",
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30
            )
        }
        return NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        )
    }

    func testReferenceSpanningAGapInASparseSnapshotRejected() {
        let snapshot = makeSparseSnapshot()
        let reference = NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 0, lastSequenceNumber: 2)
        XCTAssertThrowsError(try reference.validate(against: snapshot)) { error in
            guard case NotesSourceReferenceError.outOfRange = error else {
                return XCTFail("expected outOfRange, got \(error)")
            }
        }
    }

    func testReferenceToEachActualUnitInASparseSnapshotValidates() {
        let snapshot = makeSparseSnapshot()
        XCTAssertNoThrow(try NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: 0).validate(against: snapshot))
        XCTAssertNoThrow(try NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: 2).validate(against: snapshot))
    }
}
