import Foundation

/// Pure, deterministically-testable computation of what one session's Notes
/// action buttons should show, given the shared `LectureNotesGenerationService`'s
/// app-wide ownership state and this session's own last-loaded
/// `SessionNotesDisplayState`. Never touches the service itself. Ownership
/// itself reuses `SessionOwnershipDisplay`/`SessionActionAvailabilityCalculator
/// .ownershipDisplay` from `SessionActionAvailability.swift` — the "is this
/// session's own operation active, someone else's, or none" question is
/// identical for Notes and Transcription and is not redefined here.
nonisolated struct NotesActionAvailability: Equatable {
    var canGenerate: Bool
    var canContinueOrRetry: Bool
    var canCancel: Bool
    /// `true` when the continue/retry action should be labeled "Retry"
    /// (recovering from a recorded failure) rather than "Continue" (resuming
    /// clean incompleteness/cancellation). Purely a label hint — both cases
    /// call the identical `continueGeneration(sessionID:generationID:)` /
    /// `retry(sessionID:generationID:)` mechanics on the service (T5-D
    /// contract: Continue and Retry are mechanically the same operation).
    var continueOrRetryIsRetry: Bool
}

nonisolated enum NotesActionAvailabilityCalculator {
    /// `displayState` is this session's own last-loaded durable Notes
    /// state — never reinterpreted as an integrity problem merely because a
    /// *different* session currently owns the shared operation, mirroring
    /// `SessionActionAvailabilityCalculator.availability`'s own contract.
    static func availability(
        displayState: SessionNotesDisplayState,
        ownership: SessionOwnershipDisplay
    ) -> NotesActionAvailability {
        switch ownership {
        case .activeHere:
            return NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: true, continueOrRetryIsRetry: false)
        case .busyElsewhere:
            return NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        case .none:
            return availabilityWhenIdle(displayState: displayState)
        }
    }

    private static func availabilityWhenIdle(displayState: SessionNotesDisplayState) -> NotesActionAvailability {
        switch displayState {
        case .loading, .loadError:
            return NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        case .noGeneration(let transcriptSourceReady):
            return NotesActionAvailability(canGenerate: transcriptSourceReady, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        case .loaded(_, let classification, let advisoryStateIntegrity):
            return availability(forLoaded: classification, advisoryStateIntegrity: advisoryStateIntegrity)
        }
    }

    private static func availability(
        forLoaded classification: NotesGenerationRecoveryClassification,
        advisoryStateIntegrity: NotesAdvisoryStateIntegrity
    ) -> NotesActionAvailability {
        switch classification {
        case .completed:
            // The user may explicitly start a brand-new generation later;
            // Generate always mints a fresh generation ID and never
            // touches this completed one. Unaffected by
            // `advisoryStateIntegrity`: operation state is never consulted
            // for a `.completed` classification in the first place.
            return NotesActionAvailability(canGenerate: true, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        case .readyForSynthesis:
            guard case .normal = advisoryStateIntegrity else {
                // `LectureNotesGenerationService.run()` would itself
                // deterministically refuse a Continue for this generation
                // before ever reaching classification — see
                // `operationStateIdentity`/`loadOperationState`'s catch
                // block. Never offered here either.
                return NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
            }
            return NotesActionAvailability(canGenerate: false, canContinueOrRetry: true, canCancel: false, continueOrRetryIsRetry: false)
        case .resumable(_, let interruption):
            guard case .normal = advisoryStateIntegrity else {
                return NotesActionAvailability(canGenerate: false, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
            }
            let isRetry: Bool
            if case .recoverableFailure = interruption { isRetry = true } else { isRetry = false }
            return NotesActionAvailability(canGenerate: false, canContinueOrRetry: true, canCancel: false, continueOrRetryIsRetry: isRetry)
        case .staleSource:
            // This generation can never safely resume once the transcript
            // has moved on — only a fresh Generate is offered.
            return NotesActionAvailability(canGenerate: true, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        case .damaged:
            // No UI-side recovery is attempted for this damaged
            // generation's own artifacts — they are preserved untouched,
            // and Continue/Retry are never offered for it. `generate(
            // sessionID:)` always mints a completely fresh generation ID
            // and never overwrites or touches the damaged one, so a fresh
            // Generate remains available while no operation owns the app.
            return NotesActionAvailability(canGenerate: true, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        }
    }
}

/// Pure mapping from a `LectureNotesGenerationService.AdmissionResult` to
/// the transient message T5-D shows for it — never a second admission
/// policy, purely a presentation label for the service's own authoritative
/// result. `nil` for `.admitted` clears any stale prior message.
nonisolated enum NotesAdmissionMessage {
    static func message(for result: LectureNotesGenerationService.AdmissionResult) -> String? {
        switch result {
        case .admitted:
            return nil
        case .busy:
            return "Another Notes operation is already active. Try again once it finishes."
        case .shuttingDown:
            return "Notes generation can't start while the app is shutting down."
        }
    }
}
