import XCTest
@testable import LectureRecorder

final class NotesSectionTopicsFormattingTests: XCTestCase {
    func testTopicsAreShownInOrderUnmodifiedWithTheSeparator() {
        XCTAssertEqual(NotesSectionTopicsFormatting.displayText(for: ["Topic A"]), "Topic A")
        XCTAssertEqual(
            NotesSectionTopicsFormatting.displayText(for: ["Limit of a function", "Derivative of x squared", "Isotropy in Physics"]),
            "Limit of a function · Derivative of x squared · Isotropy in Physics"
        )
        XCTAssertEqual(NotesSectionTopicsFormatting.displayText(for: ["C", "A", "B"]), "C · A · B", "order preserved, never sorted")
    }

    func testTopicsAreNotDeduplicatedOrRewritten() {
        XCTAssertEqual(
            NotesSectionTopicsFormatting.displayText(for: ["Derivative of a function", "voltage and electron movement", "Derivative of a function"]),
            "Derivative of a function · voltage and electron movement · Derivative of a function"
        )
        let long = String(repeating: "q", count: 48)
        XCTAssertEqual(NotesSectionTopicsFormatting.displayText(for: [long, "Gauss's law"]), "\(long) · Gauss's law", "never truncated")
    }

    func testASectionWithoutTopicsShowsNothing() {
        XCTAssertNil(NotesSectionTopicsFormatting.displayText(for: []))
        XCTAssertNil(NotesSectionTopicsFormatting.displayText(for: LectureNoteSection(heading: "Section", items: []).topics),
                     "sections built with the default initializer render like the old UI")
    }

    func testLegacySectionDecodesToNoTopicsAndKeepsItsItems() throws {
        let sessionID = UUID()
        let item = LectureNoteItem(kind: .definition, body: "Definition body", fidelity: .transcriptSupported,
                                   sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: AtomicFileWriter.defaultEncoder.encode(LectureNoteSection(heading: "Legacy", items: [item], topics: ["Removed"]))
        ) as? [String: Any])
        object.removeValue(forKey: "topics")
        let legacy = try AtomicFileWriter.defaultDecoder.decode(LectureNoteSection.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(NotesSectionTopicsFormatting.displayText(for: legacy.topics))
        XCTAssertEqual(legacy.items, [item], "note items are unchanged")
    }

    func testAccessibilityLabelNamesTheTopicList() {
        XCTAssertEqual(NotesSectionTopicsFormatting.accessibilityLabel(for: "Ohm's Law · Resistor Characteristics"),
                       "Topics: Ohm's Law · Resistor Characteristics")
    }

    // MARK: - Empty Notes document

    private func document(sections: [LectureNoteSection], overview: String = "") -> LectureNotesDocument {
        LectureNotesDocument(
            generationID: UUID(), sessionID: UUID(),
            transcriptFingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "0", count: 64)),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test"),
            overview: overview, sections: sections
        )
    }

    func testAllAbstainDocumentIsShownAsAnIntentionalEmptyState() {
        XCTAssertTrue(NotesDocumentPresentation.hasNoStudyNotes(document(sections: [])))
        XCTAssertTrue(NotesDocumentPresentation.hasNoStudyNotes(document(sections: [LectureNoteSection(heading: "Empty", items: [])])))
        XCTAssertEqual(NotesDocumentPresentation.emptyTitle, "No Study Notes")
        let description = NotesDocumentPresentation.emptyDescription
        XCTAssertFalse(description.localizedCaseInsensitiveContains("error"))
        XCTAssertFalse(description.localizedCaseInsensitiveContains("fail"), "not presented as a failure, and never blames transcription")
    }

    func testDocumentWithNotesIsRenderedNormally() {
        let item = LectureNoteItem(kind: .definition, body: "A definition.", fidelity: .transcriptSupported,
                                   sourceReferences: [NotesSourceReference(sessionID: UUID(), sequenceNumber: 0)])
        let withNotes = document(sections: [LectureNoteSection(heading: "Topic", items: [item], topics: ["A", "B"])], overview: "Overview.")
        XCTAssertFalse(NotesDocumentPresentation.hasNoStudyNotes(withNotes))
        XCTAssertEqual(NotesSectionTopicsFormatting.displayText(for: withNotes.sections[0].topics), "A · B", "topics behavior unchanged")
    }
}
