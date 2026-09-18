import XCTest
@testable import LectureRecorder

final class SummaryActionAvailabilityTests: XCTestCase {
    private func makeGeneration() throws -> LectureSummaryGenerationRecord {
        try SummaryTestSupport.generation()
    }

    private func makeDocument(generation: LectureSummaryGenerationRecord) -> LectureSummaryDocument {
        LectureSummaryDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: generation.provenance,
            sections: [LectureSummarySection(heading: "Summary", passages: [])]
        )
    }

    private let currentNotesID = UUID()

    // MARK: - Ownership takes priority over durable state

    func testActiveHereOffersOnlyCancel() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .completed(document: makeDocument(generation: generation)), advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .activeHere
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: true, continueOrRetryIsRetry: false))
    }

    func testBusyElsewhereOffersNoActions() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .readyForSynthesis(analyses: []), advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .busyElsewhere
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    // MARK: - Idle, durable-state-driven availability

    func testNoValidNotesSourceOffersNoActions() {
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .noValidNotesSource,
            currentUsableNotesGenerationID: nil,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testNoGenerationOffersGenerateWithExactNotesGenerationID() {
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .noGeneration(notesGenerationID: currentNotesID),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: true, generateNotesGenerationID: currentNotesID, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testCompletedOffersFreshGenerateAgainstCurrentNotes() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .completed(document: makeDocument(generation: generation)), advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: true, generateNotesGenerationID: currentNotesID, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testCompletedWithNoCurrentNotesOffersNoGenerate() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .completed(document: makeDocument(generation: generation)), advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: nil,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testReadyForSynthesisOffersContinueLabel() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .readyForSynthesis(analyses: []), advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: true, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testReadyForSynthesisWithAdvisoryProblemOffersNoActions() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .readyForSynthesis(analyses: []), advisoryStateIntegrity: .problem(reason: "mismatch")),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testResumableNonFailureOffersContinueLabel() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .resumable(nextBatchIndex: 1, interruption: .cancelled), advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: true, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testResumableRecoverableFailureOffersRetryLabel() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .resumable(nextBatchIndex: 1, interruption: .recoverableFailure(description: "boom")), advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: true, canCancel: false, continueOrRetryIsRetry: true))
    }

    func testResumableWithAdvisoryProblemOffersNoActions() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .resumable(nextBatchIndex: 1, interruption: .recoverableFailure(description: "boom")), advisoryStateIntegrity: .problem(reason: "mismatch")),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    // MARK: - Stale source: never Continue/Retry, fresh Generate only when a current Notes generation exists

    func testStaleSourceWithCurrentNotesOffersFreshGenerateNeverContinueOrRetry() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .staleSource, advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: true, generateNotesGenerationID: currentNotesID, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
        // Never the stale generation's own pinned source.
        XCTAssertNotEqual(availability.generateNotesGenerationID, generation.sourceNotesGenerationID)
    }

    func testStaleSourceWithNoCurrentNotesOffersNoGenerate() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .staleSource, advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: nil,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    // MARK: - Damaged mirrors Notes' own handling: fresh Generate only, never Continue/Retry

    func testDamagedOffersFreshGenerateNeverContinueOrRetry() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .damaged(reason: .documentWithoutCompleteCoverage), advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: true, generateNotesGenerationID: currentNotesID, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testDamagedWithNoCurrentNotesOffersNoGenerate() throws {
        let generation = try makeGeneration()
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loaded(record: generation, classification: .damaged(reason: .documentWithoutCompleteCoverage), advisoryStateIntegrity: .normal),
            currentUsableNotesGenerationID: nil,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    // MARK: - Conservative fallbacks

    func testLoadingOffersNoActions() {
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loading,
            currentUsableNotesGenerationID: nil,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testLoadErrorOffersNoActions() {
        let availability = SummaryActionAvailabilityCalculator.availability(
            displayState: .loadError("disk hiccup"),
            currentUsableNotesGenerationID: currentNotesID,
            ownership: .none
        )
        XCTAssertEqual(availability, SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    // MARK: - Admission message mapping

    func testAdmissionMessageMapping() {
        XCTAssertNil(SummaryAdmissionMessage.message(for: .admitted))
        XCTAssertNotNil(SummaryAdmissionMessage.message(for: .busy))
        XCTAssertNotNil(SummaryAdmissionMessage.message(for: .shuttingDown))
    }
}
