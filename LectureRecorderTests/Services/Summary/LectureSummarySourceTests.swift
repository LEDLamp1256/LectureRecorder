import XCTest
@testable import LectureRecorder

final class LectureSummarySourceTests: XCTestCase {
    func testBuildFlattensCanonicalOrderAndPreservesOriginalEvidence() throws {
        let source = try SummaryTestSupport.source()
        XCTAssertEqual(source.sourceItems.map(\.sourceIndex), [0, 1, 2])
        XCTAssertEqual(source.sourceItems.map(\.item.id), SummaryTestSupport.itemIDs)
        XCTAssertEqual(source.sourceItems.map(\.sectionHeading), ["Concepts", "Concepts", "Conclusion"])
        XCTAssertEqual(source.sourceItems[1].item.fidelity, .reconstructed)
        XCTAssertEqual(source.sourceItems[1].item.uncertaintyNote, "Normalized from spoken notation.")
    }

    func testFingerprintIsStableAndCoversDetailedDocumentNotOnlyOverview() throws {
        let evidence = SummaryTestSupport.notesEvidence()
        let first = try LectureSummarySourceBuilder.fingerprint(document: evidence.1)
        let second = try LectureSummarySourceBuilder.fingerprint(document: evidence.1)
        XCTAssertEqual(first, second)

        var changedOverview = evidence.1
        changedOverview.overview = "different overview"
        XCTAssertNotEqual(first, try LectureSummarySourceBuilder.fingerprint(document: changedOverview))

        var changedItem = evidence.1
        changedItem.sections[0].items[0].body = "different detailed content"
        XCTAssertNotEqual(first, try LectureSummarySourceBuilder.fingerprint(document: changedItem))
    }

    func testStaleTranscriptAndMismatchedDocumentAreRejected() {
        let evidence = SummaryTestSupport.notesEvidence()
        var stale = evidence.2
        stale.units[0].text = "changed"
        stale.fingerprint = TranscriptSourceFingerprint.compute(sessionID: stale.sessionID, units: stale.units)
        XCTAssertThrowsError(try LectureSummarySourceBuilder.build(generation: evidence.0, analyses: evidence.3, document: evidence.1, transcriptSnapshot: stale))

        var mismatched = evidence.1
        mismatched.generationID = UUID()
        XCTAssertThrowsError(try LectureSummarySourceBuilder.build(generation: evidence.0, analyses: evidence.3, document: mismatched, transcriptSnapshot: evidence.2))
    }

    func testDamagedNotesEvidenceIsRejected() {
        let evidence = SummaryTestSupport.notesEvidence()
        var damaged = evidence.1
        damaged.sections[1].items[0].id = damaged.sections[0].items[0].id
        XCTAssertThrowsError(try LectureSummarySourceBuilder.build(generation: evidence.0, analyses: evidence.3, document: damaged, transcriptSnapshot: evidence.2)) { error in
            guard case LectureSummarySourceError.duplicateItemID = error else { return XCTFail("unexpected \(error)") }
        }

        damaged = evidence.1
        damaged.sections[0].items[1].uncertaintyNote = "  "
        XCTAssertThrowsError(try LectureSummarySourceBuilder.build(generation: evidence.0, analyses: evidence.3, document: damaged, transcriptSnapshot: evidence.2))
    }

    func testIncompleteOrDamagedAnalysisCoverageIsRejected() {
        let evidence = SummaryTestSupport.notesEvidence()
        XCTAssertThrowsError(try LectureSummarySourceBuilder.build(
            generation: evidence.0, analyses: [], document: evidence.1, transcriptSnapshot: evidence.2
        ))
        var damaged = evidence.3[0]
        damaged.generationID = UUID()
        XCTAssertThrowsError(try LectureSummarySourceBuilder.build(
            generation: evidence.0, analyses: [damaged], document: evidence.1, transcriptSnapshot: evidence.2
        ))
    }
}
