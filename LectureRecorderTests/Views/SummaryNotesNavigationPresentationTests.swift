import XCTest
@testable import LectureRecorder

final class SessionNotesRefreshModeTests: XCTestCase {
    func testNoPinUsesDefaultRefreshForEveryCause() {
        for cause in SessionNotesRefreshCause.allCases {
            XCTAssertEqual(SessionNotesRefreshMode.mode(for: cause, pinnedNotesGenerationID: nil), .latest, "\(cause)")
        }
    }

    func testPinUsesExactGenerationRefresh() {
        let pinned = UUID()
        XCTAssertEqual(SessionNotesRefreshMode.mode(for: .pinChanged, pinnedNotesGenerationID: pinned), .exact(generationID: pinned))
        XCTAssertEqual(SessionNotesRefreshMode.mode(for: .sessionAppeared, pinnedNotesGenerationID: pinned), .exact(generationID: pinned))
    }

    /// Automatic refreshes from either service releasing ownership must
    /// never switch a pinned pane to the newest Notes.
    func testServiceTriggeredRefreshWhilePinnedStillRequestsExactGeneration() {
        let pinned = UUID()
        XCTAssertEqual(SessionNotesRefreshMode.mode(for: .notesServiceReleased, pinnedNotesGenerationID: pinned), .exact(generationID: pinned))
        XCTAssertEqual(SessionNotesRefreshMode.mode(for: .transcriptionServiceReleased, pinnedNotesGenerationID: pinned), .exact(generationID: pinned))
    }

    func testClearingPinReturnsToDefaultRefresh() {
        let pinned = UUID()
        XCTAssertEqual(SessionNotesRefreshMode.mode(for: .pinChanged, pinnedNotesGenerationID: pinned), .exact(generationID: pinned))
        XCTAssertEqual(SessionNotesRefreshMode.mode(for: .pinChanged, pinnedNotesGenerationID: nil), .latest)
    }
}

final class SummaryPassageNotesActionsTests: XCTestCase {
    private let sessionID = UUID()

    private func passage(supportingNoteItemIDs: [UUID]) -> LectureSummaryPassage {
        LectureSummaryPassage(
            text: "passage",
            supportingNoteItemIDs: supportingNoteItemIDs,
            sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)],
            fidelity: .transcriptSupported
        )
    }

    private func summary(_ passages: [LectureSummaryPassage]) -> LectureSummaryDocument {
        LectureSummaryDocument(
            generationID: UUID(),
            sessionID: sessionID,
            sourceNotesGenerationID: UUID(),
            transcriptFingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "a", count: 64)),
            sourceNotesDocumentFingerprint: NotesDocumentFingerprint(algorithmVersion: 1, digestHex: String(repeating: "b", count: 64)),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            sections: [LectureSummarySection(heading: "Summary", passages: passages)]
        )
    }

    func testValidPassageProducesOneSupportingNotesAction() {
        let valid = passage(supportingNoteItemIDs: [UUID()])
        XCTAssertEqual(
            SummaryPassageNotesActions.actions(for: valid, in: summary([valid])),
            [SummaryPassageNotesAction(label: "Supporting Notes")]
        )
    }

    func testManySupportingNotesStillProduceOneUnnumberedAction() {
        let valid = passage(supportingNoteItemIDs: [UUID(), UUID(), UUID()])
        let actions = SummaryPassageNotesActions.actions(for: valid, in: summary([valid]))
        XCTAssertEqual(actions.map(\.label), ["Supporting Notes"])
    }

    func testInvalidOrMismatchedPassageProducesNoAction() {
        let inDocument = passage(supportingNoteItemIDs: [UUID()])
        let document = summary([inDocument])
        let foreign = passage(supportingNoteItemIDs: [UUID()])
        XCTAssertEqual(SummaryPassageNotesActions.actions(for: foreign, in: document), [])

        let unsupported = passage(supportingNoteItemIDs: [])
        XCTAssertEqual(SummaryPassageNotesActions.actions(for: unsupported, in: summary([unsupported])), [])

        let repeated = UUID()
        let duplicated = passage(supportingNoteItemIDs: [repeated, repeated])
        XCTAssertEqual(SummaryPassageNotesActions.actions(for: duplicated, in: summary([duplicated])), [])
    }
}
