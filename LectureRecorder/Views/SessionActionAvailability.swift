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
    /// "Try Failed Parts Again": the explicit override for parts the
    /// automatic policy considers permanent. Independent of Continue.
    var canRetryFailedParts: Bool = false
}

nonisolated enum SessionActionAvailabilityCalculator {
    static func ownershipDisplay(activeSessionID: UUID?, sessionID: UUID) -> SessionOwnershipDisplay {
        guard let activeSessionID else { return .none }
        return activeSessionID == sessionID ? .activeHere : .busyElsewhere
    }

    /// `peekedStatus` is this session's own last-peeked saved status —
    /// never reinterpreted as an integrity problem merely because a
    /// *different* session currently owns the shared operation.
    ///
    /// `failureOverview` only ever narrows Continue: when it positively
    /// shows no automatic work remains (every gap is a permanent failure),
    /// Continue would be a silent no-op and is disabled. A missing overview
    /// leaves the status-only decision unchanged.
    static func availability(
        peekedStatus: SessionTranscriptionStatus?,
        failureOverview: TranscriptionFailureOverview? = nil,
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
            case .incomplete, .interrupted, .recoveryPending:
                canContinueOrRetry = failureOverview?.hasAutomaticWork ?? true
            default:
                canContinueOrRetry = false
            }
            let canRetryFailedParts: Bool
            switch peekedStatus {
            case .incomplete, .interrupted, .recoveryPending:
                canRetryFailedParts = failureOverview?.hasManualRetryEligibleParts ?? false
            default:
                canRetryFailedParts = false
            }
            return SessionActionAvailability(
                canTranscribe: canTranscribe,
                canContinueOrRetry: canContinueOrRetry,
                canCancel: false,
                canRetryFailedParts: canRetryFailedParts
            )
        }
    }

    /// Why Continue is disabled for an otherwise-continuable status, or
    /// `nil` when it is not disabled for that reason.
    static func continueUnavailableExplanation(
        peekedStatus: SessionTranscriptionStatus?,
        failureOverview: TranscriptionFailureOverview?,
        ownership: SessionOwnershipDisplay
    ) -> String? {
        guard ownership == .none, let failureOverview, !failureOverview.hasAutomaticWork else { return nil }
        switch peekedStatus {
        case .incomplete, .interrupted, .recoveryPending:
            if failureOverview.hasManualRetryEligibleParts {
                return TranscriptionStatusMessage.nothingToContinue + " " + TranscriptionStatusMessage.manualRetryHint
            }
            return TranscriptionStatusMessage.nothingToContinue
        default:
            return nil
        }
    }
}

/// Pure mapping from a `CompletedSessionTranscriptionService.AdmissionResult`
/// to the transient message shown for it — a presentation label for the
/// service's own authoritative result, never a second admission policy.
/// `nil` for `.admitted` clears any stale prior message.
nonisolated enum TranscriptionAdmissionMessage {
    static func message(for result: CompletedSessionTranscriptionService.AdmissionResult) -> String? {
        switch result {
        case .admitted:
            return nil
        case .recordingActive:
            return "Transcription can't start while a recording is in progress."
        case .busy:
            return "Another transcription is already running. Try again once it finishes."
        case .shuttingDown:
            return "Transcription can't start while the app is quitting."
        }
    }
}

/// Fixed, user-facing transcription status wording.
nonisolated enum TranscriptionStatusMessage {
    /// Shown for every `.blocked` status in place of its raw reasons, which
    /// are internal diagnostics (artifact names, decoder text).
    static let blocked = "Saved transcription data needs attention. Existing files have been preserved."
    static let nothingToContinue = "Continue has nothing left to retry automatically — the remaining parts couldn't be transcribed."
    static let manualRetryHint = "Choose Try Failed Parts Again to retry them anyway."
}

/// Sanitized, one-line descriptions of failed transcription parts. Built
/// only from the closed failure category and retry disposition — never from
/// `TranscriptionFailure.message`. Part numbers are one-based.
nonisolated enum TranscriptionFailedPartMessage {
    /// How many failed parts the status area lists before summarizing.
    static let displayLimit = 5

    static func message(sequenceNumber: Int, category: TranscriptionFailureCategory?, retryDisposition: RetryDisposition?) -> String {
        let part = "Part \(sequenceNumber + 1)"
        switch category {
        case .sourceMissing:
            return "\(part): audio file is missing."
        case .cancellation, .abandonedRunningAttempt:
            return "\(part): interrupted."
        default:
            if retryDisposition == .retryable {
                return "\(part): transcription engine failed — Continue may succeed."
            }
            return "\(part): couldn't be transcribed."
        }
    }

    static func message(for part: TranscriptionFailedPart) -> String {
        message(sequenceNumber: part.sequenceNumber, category: part.category, retryDisposition: part.retryDisposition)
    }

    /// At most `displayLimit` part lines, then one "…and N more" line.
    static func lines(for overview: TranscriptionFailureOverview) -> [String] {
        let parts = overview.failedParts
        var lines = parts.prefix(displayLimit).map { message(for: $0) }
        if parts.count > displayLimit {
            let remaining = parts.count - displayLimit
            lines.append("…and \(remaining) more failed part\(remaining == 1 ? "" : "s").")
        }
        return lines
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
