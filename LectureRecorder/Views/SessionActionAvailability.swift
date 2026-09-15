import Foundation

/// Pure, deterministically-testable computation of what one session's
/// action buttons/status banner should show, given the shared service's
/// app-wide ownership state and this session's own last-peeked saved
/// status. Never touches the service/coordinator itself — a plain
/// value-in, value-out helper so multi-window Busy semantics are testable
/// without a UI harness.
nonisolated enum SessionOwnershipDisplay: Equatable {
    /// No operation is active app-wide.
    case none
    /// This session's window is showing the one active operation.
    case activeHere
    /// A different session owns the one active operation app-wide.
    case busyElsewhere
}

nonisolated struct SessionActionAvailability: Equatable {
    var canTranscribe: Bool
    var canContinueOrRetry: Bool
    var canCancel: Bool
}

nonisolated enum SessionActionAvailabilityCalculator {
    static func ownershipDisplay(activeSessionID: UUID?, sessionID: UUID) -> SessionOwnershipDisplay {
        guard let activeSessionID else { return .none }
        return activeSessionID == sessionID ? .activeHere : .busyElsewhere
    }

    /// `peekedStatus` is this session's own last-peeked saved status —
    /// never reinterpreted as an integrity problem merely because a
    /// *different* session currently owns the shared operation.
    static func availability(
        peekedStatus: SessionTranscriptionStatus?,
        ownership: SessionOwnershipDisplay
    ) -> SessionActionAvailability {
        switch ownership {
        case .activeHere:
            return SessionActionAvailability(canTranscribe: false, canContinueOrRetry: false, canCancel: true)
        case .busyElsewhere:
            return SessionActionAvailability(canTranscribe: false, canContinueOrRetry: false, canCancel: false)
        case .none:
            guard let peekedStatus else {
                return SessionActionAvailability(canTranscribe: false, canContinueOrRetry: false, canCancel: false)
            }
            let canTranscribe: Bool
            if case .notTranscribed = peekedStatus { canTranscribe = true } else { canTranscribe = false }
            let canContinueOrRetry: Bool
            switch peekedStatus {
            case .incomplete, .interrupted, .recoveryPending: canContinueOrRetry = true
            default: canContinueOrRetry = false
            }
            return SessionActionAvailability(canTranscribe: canTranscribe, canContinueOrRetry: canContinueOrRetry, canCancel: false)
        }
    }
}

/// Pure decision of whether *this* session's window should reload its
/// durable status/transcript, given an `activeSessionID` transition
/// observed via `.onChange(of: service.activeSessionID)`.
///
/// This is deliberately keyed on ownership loss, not on
/// `service.phase == .finished`: `phase` and `activeSessionID` are two
/// separate `@Published` properties written in the same MainActor method
/// (`finishFromDurableState` sets `phase`; `releaseOperation`, which runs
/// afterward, clears `activeSessionID`), and SwiftUI/Combine give no
/// ordering guarantee that a `.phase`-keyed observer processes the
/// `.finished` transition before `activeSessionID` has already been
/// cleared — a `.phase`-keyed `isActiveOperation` guard can therefore be
/// evaluated as already-false and silently swallow the refresh. Keying on
/// the *transition* of `activeSessionID` itself has no such race: this
/// session held ownership before and does not hold it after, regardless of
/// whatever session (if any) holds it now.
nonisolated enum SessionOwnershipTransition {
    /// `true` exactly when `sessionID` owned the shared operation before
    /// this change and no longer owns it after — covers both `A -> nil`
    /// and `A -> B` (a new operation already admitted before this window
    /// observed the change). Never true for `nil -> A` (a *new* admission
    /// starting is not a completed-operation handoff) or `A -> A` (no
    /// change).
    static func shouldRefreshDurableState(
        oldActiveSessionID: UUID?,
        newActiveSessionID: UUID?,
        sessionID: UUID
    ) -> Bool {
        oldActiveSessionID == sessionID && newActiveSessionID != sessionID
    }
}

/// Pure formatting for durable-progress display. Internal chunk sequence
/// numbers are, and remain, zero-based (filenames, coordinator ordering,
/// persisted schema); only this human-facing string converts the
/// currently-processing sequence to a one-based ordinal, so "sequence 18"
/// (the 19th chunk) reads as "processing 19", not "processing 18".
nonisolated enum SessionProgressFormatting {
    static func processingLabel(completed: Int, total: Int, currentlyProcessingSequence: Int) -> String {
        "\(completed) / \(total) saved — processing \(currentlyProcessingSequence + 1)"
    }
}
