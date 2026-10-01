import XCTest
@testable import LectureRecorder

final class SummaryNotesRevealSelectionTests: XCTestCase {
    private let sessionID = UUID()
    private let notesGenerationID = UUID()

    private var transcriptFingerprint: TranscriptSourceFingerprint {
        TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "a", count: 64))
    }

    private let notesDocumentFingerprint = NotesDocumentFingerprint(algorithmVersion: 1, digestHex: String(repeating: "b", count: 64))

    private func item(_ id: UUID = UUID(), title: String? = nil, body: String = "body", sequenceNumber: Int = 0) -> LectureNoteItem {
        LectureNoteItem(
            id: id,
            kind: .explanation,
            title: title,
            body: body,
            fidelity: .transcriptSupported,
            sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: sequenceNumber)]
        )
    }

    private func notesDocument(
        _ sections: [LectureNoteSection],
        sessionID: UUID? = nil,
        generationID: UUID? = nil,
        transcriptFingerprint: TranscriptSourceFingerprint? = nil
    ) -> LectureNotesDocument {
        LectureNotesDocument(
            generationID: generationID ?? notesGenerationID,
            sessionID: sessionID ?? self.sessionID,
            transcriptFingerprint: transcriptFingerprint ?? self.transcriptFingerprint,
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            overview: "overview",
            sections: sections
        )
    }

    private func target(_ supportingNoteItemIDs: [UUID]) -> SummaryNotesRevealTarget {
        SummaryNotesRevealTarget(
            sessionID: sessionID,
            sourceNotesGenerationID: notesGenerationID,
            sourceNotesDocumentFingerprint: notesDocumentFingerprint,
            transcriptFingerprint: transcriptFingerprint,
            supportingNoteItemIDs: supportingNoteItemIDs
        )
    }

    // MARK: - Target

    func testTargetPreservesSummarySourceIdentityAndSupport() throws {
        let supportIDs = [UUID(), UUID()]
        let passage = LectureSummaryPassage(
            text: "passage",
            supportingNoteItemIDs: supportIDs,
            sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)],
            fidelity: .transcriptSupported
        )
        let summary = LectureSummaryDocument(
            generationID: UUID(),
            sessionID: sessionID,
            sourceNotesGenerationID: notesGenerationID,
            transcriptFingerprint: transcriptFingerprint,
            sourceNotesDocumentFingerprint: notesDocumentFingerprint,
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            sections: [LectureSummarySection(heading: "Section", passages: [passage])]
        )

        let target = try XCTUnwrap(SummaryNotesRevealTarget(document: summary, passage: passage))

        XCTAssertEqual(target.sessionID, sessionID)
        XCTAssertEqual(target.sourceNotesGenerationID, notesGenerationID)
        XCTAssertEqual(target.sourceNotesDocumentFingerprint, notesDocumentFingerprint)
        XCTAssertEqual(target.transcriptFingerprint, transcriptFingerprint)
        XCTAssertEqual(target.supportingNoteItemIDs, supportIDs)
    }

    func testTargetRejectsPassageFromAnotherSummary() {
        let summary = LectureSummaryDocument(
            generationID: UUID(),
            sessionID: sessionID,
            sourceNotesGenerationID: notesGenerationID,
            transcriptFingerprint: transcriptFingerprint,
            sourceNotesDocumentFingerprint: notesDocumentFingerprint,
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            sections: []
        )
        let foreign = LectureSummaryPassage(text: "x", supportingNoteItemIDs: [UUID()], sourceReferences: [], fidelity: .transcriptSupported)

        XCTAssertNil(SummaryNotesRevealTarget(document: summary, passage: foreign))
    }

    // MARK: - Selection

    func testSingleSupportingNoteIsSelectedAndIsTheScrollTarget() throws {
        let supporting = item()
        let document = notesDocument([LectureNoteSection(heading: "A", items: [item(), supporting, item()])])

        let selection = try XCTUnwrap(SummaryNotesRevealSelectionBuilder.select(target([supporting.id]), in: document))

        XCTAssertEqual(selection.scrollTargetItemID, supporting.id)
        XCTAssertEqual(selection.selectedItemIDs, [supporting.id])
    }

    /// Items span sections; the target lists them out of document order to
    /// prove the result follows the document, not the request.
    func testMultipleSupportingNotesAreSelectedInDocumentOrderAndUnrelatedExcluded() throws {
        let first = item()
        let second = item()
        let third = item()
        let unrelatedA = item()
        let unrelatedB = item()
        let document = notesDocument([
            LectureNoteSection(heading: "A", items: [unrelatedA, first]),
            LectureNoteSection(heading: "B", items: [second, unrelatedB, third]),
        ])

        let selection = try XCTUnwrap(SummaryNotesRevealSelectionBuilder.select(target([third.id, first.id, second.id]), in: document))

        XCTAssertEqual(selection.selectedItemIDs, [first.id, second.id, third.id])
        XCTAssertEqual(selection.scrollTargetItemID, first.id)
        XCTAssertFalse(selection.selectedItemIDs.contains(unrelatedA.id))
        XCTAssertFalse(selection.selectedItemIDs.contains(unrelatedB.id))
    }

    func testMissingSupportingNoteFailsClosed() {
        let present = item()
        let document = notesDocument([LectureNoteSection(heading: "A", items: [present])])

        XCTAssertNil(SummaryNotesRevealSelectionBuilder.select(target([present.id, UUID()]), in: document))
    }

    func testEmptySupportFailsClosed() {
        let document = notesDocument([LectureNoteSection(heading: "A", items: [item()])])

        XCTAssertNil(SummaryNotesRevealSelectionBuilder.select(target([]), in: document))
    }

    func testDuplicateRequestedSupportIDFailsClosed() {
        let supporting = item()
        let document = notesDocument([LectureNoteSection(heading: "A", items: [supporting])])

        XCTAssertNil(SummaryNotesRevealSelectionBuilder.select(target([supporting.id, supporting.id]), in: document))
    }

    func testDuplicateNoteItemIDInMalformedDocumentFailsClosed() {
        let sharedID = UUID()
        let document = notesDocument([
            LectureNoteSection(heading: "A", items: [item(sharedID)]),
            LectureNoteSection(heading: "B", items: [item(sharedID)]),
        ])

        XCTAssertNil(SummaryNotesRevealSelectionBuilder.select(target([sharedID]), in: document))
    }

    func testWrongSessionFails() {
        let supporting = item()
        let document = notesDocument([LectureNoteSection(heading: "A", items: [supporting])], sessionID: UUID())

        XCTAssertNil(SummaryNotesRevealSelectionBuilder.select(target([supporting.id]), in: document))
    }

    func testWrongNotesGenerationFails() {
        let supporting = item()
        let document = notesDocument([LectureNoteSection(heading: "A", items: [supporting])], generationID: UUID())

        XCTAssertNil(SummaryNotesRevealSelectionBuilder.select(target([supporting.id]), in: document))
    }

    func testWrongTranscriptFingerprintFails() {
        let supporting = item()
        let other = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "c", count: 64))
        let document = notesDocument([LectureNoteSection(heading: "A", items: [supporting])], transcriptFingerprint: other)

        XCTAssertNil(SummaryNotesRevealSelectionBuilder.select(target([supporting.id]), in: document))
    }

    /// Items identical to the supporting one in every field but `id`, in a
    /// section with the same heading, are never selected — and a document
    /// holding only such look-alikes fails closed.
    func testSelectionUsesNoteIDsOnlyNeverTextHeadingsOrSourceReferences() throws {
        let supporting = item(title: "Title", body: "same body", sequenceNumber: 3)
        let lookAlike = item(title: "Title", body: "same body", sequenceNumber: 3)
        let document = notesDocument([
            LectureNoteSection(heading: "Same", items: [lookAlike]),
            LectureNoteSection(heading: "Same", items: [supporting]),
        ])

        let selection = try XCTUnwrap(SummaryNotesRevealSelectionBuilder.select(target([supporting.id]), in: document))
        XCTAssertEqual(selection.selectedItemIDs, [supporting.id])

        let lookAlikeOnly = notesDocument([LectureNoteSection(heading: "Same", items: [lookAlike])])
        XCTAssertNil(SummaryNotesRevealSelectionBuilder.select(target([supporting.id]), in: lookAlikeOnly))
    }
}
