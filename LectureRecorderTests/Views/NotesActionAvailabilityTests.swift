import XCTest
@testable import LectureRecorder

/// Pure, fast tests for `NotesActionAvailabilityCalculator` — no filesystem
/// I/O, no presenter or service involved. Mirrors
/// `SessionActionAvailabilityTests`' own coverage shape for the
/// Transcription domain.
final class NotesActionAvailabilityTests: XCTestCase {
    private let sessionID = UUID()
    private let otherSessionID = UUID()

    private func makeRecord() -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord.newGeneration(
            generationID: UUID(),
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "a", count: 64)),
            windowPlan: NotesWindowPlan(windows: []),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1")
        )
    }

    // MARK: - Ownership (shared with Transcription's SessionOwnershipDisplay)

    func testOwnershipDisplayNoneWhenNoOperationActive() {
        XCTAssertEqual(SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: nil, sessionID: sessionID), .none)
    }

    func testOwnershipDisplayActiveHereWhenThisSessionOwnsOperation() {
        XCTAssertEqual(SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: sessionID, sessionID: sessionID), .activeHere)
    }

    func testOwnershipDisplayBusyElsewhereWhenAnotherSessionOwnsOperation() {
        XCTAssertEqual(SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: otherSessionID, sessionID: sessionID), .busyElsewhere)
    }

    // MARK: - Generate: no generation exists

    func testNoGenerationAllowsGenerateOnlyWhenNoOperationOwnsIt() {
        let idle = NotesActionAvailabilityCalculator.availability(displayState: .noGeneration, ownership: .none)
        XCTAssertEqual(idle, NotesActionAvailability(canGenerate: true, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))

        let activeHere = NotesActionAvailabilityCalculator.availability(displayState: .noGeneration, ownership: .activeHere)
        XCTAssertFalse(activeHere.canGenerate)

        let busyElsewhere = NotesActionAvailabilityCalculator.availability(displayState: .noGeneration, ownership: .busyElsewhere)
        XCTAssertFalse(busyElsewhere.canGenerate)
    }

    // MARK: - Continue

    func testReadyForSynthesisAllowsContinueOnlyWhenNoOperationOwnsIt() {
        let state = SessionNotesDisplayState.loaded(record: makeRecord(), classification: .readyForSynthesis(analyses: []), advisoryStateIntegrity: .normal)

        let idle = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .none)
        XCTAssertTrue(idle.canContinueOrRetry)
        XCTAssertFalse(idle.continueOrRetryIsRetry)

        let busyElsewhere = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .busyElsewhere)
        XCTAssertFalse(busyElsewhere.canContinueOrRetry)
    }

    func testResumableAfterCancellationLabelsContinueNotRetry() {
        let state = SessionNotesDisplayState.loaded(
            record: makeRecord(),
            classification: .resumable(nextWindowIndex: 1, interruption: .cancelled),
            advisoryStateIntegrity: .normal
        )
        let availability = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .none)
        XCTAssertTrue(availability.canContinueOrRetry)
        XCTAssertFalse(availability.continueOrRetryIsRetry)
    }

    // MARK: - Retry

    func testResumableAfterRecoverableFailureLabelsRetry() {
        let state = SessionNotesDisplayState.loaded(
            record: makeRecord(),
            classification: .resumable(nextWindowIndex: 1, interruption: .recoverableFailure(description: "boom")),
            advisoryStateIntegrity: .normal
        )
        let availability = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .none)
        XCTAssertTrue(availability.canContinueOrRetry)
        XCTAssertTrue(availability.continueOrRetryIsRetry)
    }

    // MARK: - Advisory operation-state problem disables Continue/Retry (correction #1)

    func testMismatchedAdvisoryStateDisablesContinueForReadyForSynthesis() {
        let state = SessionNotesDisplayState.loaded(
            record: makeRecord(),
            classification: .readyForSynthesis(analyses: []),
            advisoryStateIntegrity: .problem(reason: "recovery metadata does not match this generation")
        )
        let availability = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .none)
        XCTAssertEqual(availability, NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testMismatchedAdvisoryStateDisablesContinueForResumable() {
        let state = SessionNotesDisplayState.loaded(
            record: makeRecord(),
            classification: .resumable(nextWindowIndex: 1, interruption: .recoverableFailure(description: "boom")),
            advisoryStateIntegrity: .problem(reason: "recovery metadata could not be read")
        )
        let availability = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .none)
        XCTAssertEqual(availability, NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testAdvisoryStateProblemDoesNotHideOrDisableGenerateOnACompletedDocument() {
        // A completed document is proven entirely from canonical artifacts
        // — an advisory operation-state problem must never suppress or
        // disable it (correction #1/#6).
        let state = SessionNotesDisplayState.loaded(
            record: makeRecord(),
            classification: .completed(document: makeCompletedDocument()),
            advisoryStateIntegrity: .problem(reason: "recovery metadata could not be read")
        )
        let availability = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .none)
        XCTAssertEqual(availability, NotesActionAvailability(canGenerate: true, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    // MARK: - Cancel

    func testActiveHereAllowsOnlyCancel() {
        let availability = NotesActionAvailabilityCalculator.availability(displayState: .loading, ownership: .activeHere)
        XCTAssertEqual(availability, NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: true, continueOrRetryIsRetry: false))
    }

    func testBusyElsewhereDisablesAllActionsRegardlessOfDisplayState() {
        let states: [SessionNotesDisplayState] = [
            .loading,
            .noGeneration,
            .loadError("boom"),
            .loaded(record: makeRecord(), classification: .completed(document: makeCompletedDocument()), advisoryStateIntegrity: .normal),
        ]
        for state in states {
            let availability = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .busyElsewhere)
            XCTAssertEqual(availability, NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
        }
    }

    // MARK: - Completed / staleSource / damaged Generate mapping

    func testCompletedAllowsGenerateAgainButNotContinueOrCancel() {
        let state = SessionNotesDisplayState.loaded(record: makeRecord(), classification: .completed(document: makeCompletedDocument()), advisoryStateIntegrity: .normal)
        let availability = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .none)
        XCTAssertEqual(availability, NotesActionAvailability(canGenerate: true, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    func testStaleSourceAllowsGenerateButNeverContinue() {
        let state = SessionNotesDisplayState.loaded(record: makeRecord(), classification: .staleSource, advisoryStateIntegrity: .normal)
        let availability = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .none)
        XCTAssertEqual(availability, NotesActionAvailability(canGenerate: true, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    /// Correction #3: `LectureNotesGenerationService.generate(sessionID:)`
    /// always mints a completely fresh generation ID and never overwrites
    /// or touches an existing (including damaged) generation, so a fresh
    /// Generate must remain available for a damaged one — it must never
    /// be repaired, retried, or continued, but a brand-new attempt is
    /// always a distinct, unaffected generation.
    func testDamagedAllowsGenerateButNotContinueOrCancel() {
        let state = SessionNotesDisplayState.loaded(record: makeRecord(), classification: .damaged(reason: .documentWithoutCompleteCoverage), advisoryStateIntegrity: .normal)
        let availability = NotesActionAvailabilityCalculator.availability(displayState: state, ownership: .none)
        XCTAssertEqual(availability, NotesActionAvailability(canGenerate: true, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false))
    }

    // MARK: - AdmissionResult presentation (correction #4)

    func testAdmissionMessageForAdmittedIsNil() {
        XCTAssertNil(NotesAdmissionMessage.message(for: .admitted))
    }

    func testAdmissionMessageForBusyExplainsAnotherOperationIsActive() {
        XCTAssertEqual(NotesAdmissionMessage.message(for: .busy), "Another Notes operation is already active. Try again once it finishes.")
    }

    func testAdmissionMessageForShuttingDownExplainsAppIsShuttingDown() {
        XCTAssertEqual(NotesAdmissionMessage.message(for: .shuttingDown), "Notes generation can't start while the app is shutting down.")
    }

    // MARK: - Loading / load error

    func testLoadingAndLoadErrorAllowNoActionsWhenIdle() {
        XCTAssertEqual(
            NotesActionAvailabilityCalculator.availability(displayState: .loading, ownership: .none),
            NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        )
        XCTAssertEqual(
            NotesActionAvailabilityCalculator.availability(displayState: .loadError("boom"), ownership: .none),
            NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        )
    }

    // MARK: - Fixtures

    private func makeCompletedDocument() -> LectureNotesDocument {
        let generation = makeRecord()
        return LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: "overview",
            sections: []
        )
    }
}
