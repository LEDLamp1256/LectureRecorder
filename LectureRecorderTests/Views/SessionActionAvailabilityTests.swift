import XCTest
@testable import LectureRecorder

final class SessionActionAvailabilityTests: XCTestCase {
    private let sessionID = UUID()
    private let otherSessionID = UUID()

    // MARK: - Ownership display

    func testOwnershipDisplayNoneWhenNoOperationActive() {
        XCTAssertEqual(SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: nil, sessionID: sessionID), .none)
    }

    func testOwnershipDisplayActiveHereWhenThisSessionOwnsOperation() {
        XCTAssertEqual(SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: sessionID, sessionID: sessionID), .activeHere)
    }

    func testOwnershipDisplayBusyElsewhereWhenAnotherSessionOwnsOperation() {
        XCTAssertEqual(SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: otherSessionID, sessionID: sessionID), .busyElsewhere)
    }

    // MARK: - Correction 2: another window observing global Busy

    func testBusyElsewhereDisablesAllActionsRegardlessOfPeekedStatus() {
        for status: SessionTranscriptionStatus? in [nil, .notTranscribed, .incomplete(completed: 1, total: 2), .interrupted(retryableSequenceNumbers: [0]), .recoveryPending, .completed, .blocked(reasons: ["x"])] {
            let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: status, ownership: .busyElsewhere)
            XCTAssertFalse(availability.canTranscribe, "status \(String(describing: status))")
            XCTAssertFalse(availability.canContinueOrRetry, "status \(String(describing: status))")
            XCTAssertFalse(availability.canCancel, "status \(String(describing: status))")
        }
    }

    func testActiveHereAllowsOnlyCancel() {
        let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: nil, ownership: .activeHere)
        XCTAssertFalse(availability.canTranscribe)
        XCTAssertFalse(availability.canContinueOrRetry)
        XCTAssertTrue(availability.canCancel)
    }

    // MARK: - Correction 1: eligibility returns after ownership is released

    func testNotTranscribedAllowsTranscribeOnlyWhenNoOperationOwnsIt() {
        let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: .notTranscribed, ownership: .none)
        XCTAssertTrue(availability.canTranscribe)
        XCTAssertFalse(availability.canContinueOrRetry)
        XCTAssertFalse(availability.canCancel)
    }

    func testIncompleteInterruptedRecoveryPendingAllowContinueOrRetryOnlyWhenNoOperationOwnsIt() {
        for status: SessionTranscriptionStatus in [.incomplete(completed: 1, total: 2), .interrupted(retryableSequenceNumbers: [0]), .recoveryPending] {
            let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: status, ownership: .none)
            XCTAssertTrue(availability.canContinueOrRetry, "status \(status)")
            XCTAssertFalse(availability.canTranscribe, "status \(status)")
            XCTAssertFalse(availability.canCancel, "status \(status)")
        }
    }

    func testCompletedAndBlockedAllowNoActions() {
        for status: SessionTranscriptionStatus in [.completed, .blocked(reasons: ["x"]), .zeroChunkSession] {
            let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: status, ownership: .none)
            XCTAssertFalse(availability.canTranscribe, "status \(status)")
            XCTAssertFalse(availability.canContinueOrRetry, "status \(status)")
            XCTAssertFalse(availability.canCancel, "status \(status)")
        }
    }

    // MARK: - Correction 4: human-facing processing ordinal

    func testProcessingLabelConvertsZeroBasedSequenceToOneBasedOrdinal() {
        let label = SessionProgressFormatting.processingLabel(completed: 18, total: 42, currentlyProcessingSequence: 18)
        XCTAssertEqual(label, "18 / 42 saved — processing 19")
    }

    func testProcessingLabelForFirstChunk() {
        let label = SessionProgressFormatting.processingLabel(completed: 0, total: 1, currentlyProcessingSequence: 0)
        XCTAssertEqual(label, "0 / 1 saved — processing 1")
    }

    // MARK: - Ownership-transition refresh predicate

    func testRefreshesWhenThisSessionLosesOwnershipToNoOwner() {
        XCTAssertTrue(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: sessionID, newActiveSessionID: nil, sessionID: sessionID))
    }

    func testRefreshesWhenThisSessionLosesOwnershipToAnotherSession() {
        XCTAssertTrue(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: sessionID, newActiveSessionID: otherSessionID, sessionID: sessionID))
    }

    func testDoesNotRefreshWhenAnotherSessionLosesOwnership() {
        XCTAssertFalse(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: otherSessionID, newActiveSessionID: nil, sessionID: sessionID))
    }

    func testDoesNotRefreshWhenThisSessionNewlyGainsOwnership() {
        XCTAssertFalse(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: nil, newActiveSessionID: sessionID, sessionID: sessionID))
    }

    func testDoesNotRefreshWhenOwnershipIsUnchanged() {
        XCTAssertFalse(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: sessionID, newActiveSessionID: sessionID, sessionID: sessionID))
    }
}
