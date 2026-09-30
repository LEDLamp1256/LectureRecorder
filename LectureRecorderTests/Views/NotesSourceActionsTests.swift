import XCTest
@testable import LectureRecorder

final class NotesSourceActionsTests: XCTestCase {
    private let sessionID = UUID()

    func testNoReferencesYieldNoActions() {
        XCTAssertEqual(NotesSourceActions.actions(for: []), [])
    }

    func testSingleReferenceIsOneUnnumberedSourceWithTheExactReference() {
        let reference = NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 3, lastSequenceNumber: 5)
        XCTAssertEqual(NotesSourceActions.actions(for: [reference]), [NotesSourceAction(label: "Source", reference: reference)])
    }

    func testMultipleReferencesAreNumberedInStoredOrderUnmodified() {
        let references = [
            NotesSourceReference(sessionID: sessionID, sequenceNumber: 7),
            NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 1, lastSequenceNumber: 2),
            NotesSourceReference(sessionID: sessionID, sequenceNumber: 4),
        ]
        XCTAssertEqual(NotesSourceActions.actions(for: references), [
            NotesSourceAction(label: "Source 1", reference: references[0]),
            NotesSourceAction(label: "Source 2", reference: references[1]),
            NotesSourceAction(label: "Source 3", reference: references[2]),
        ], "stored order, never sorted")
    }

    func testDuplicateReferencesEachKeepTheirOwnAction() {
        let reference = NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)
        XCTAssertEqual(NotesSourceActions.actions(for: [reference, reference]).map(\.label), ["Source 1", "Source 2"])
    }
}
