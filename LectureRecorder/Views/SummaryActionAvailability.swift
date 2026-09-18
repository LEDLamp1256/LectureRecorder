import Foundation

/// Pure, deterministically-testable computation of what one session's
/// Summary action buttons should show, given the shared
/// `LectureSummaryGenerationService`'s app-wide ownership state, this
/// session's own last-loaded `SessionSummaryDisplayState`, and the
/// presenter's own independently-selected `currentUsableNotesGenerationID`
/// (see `SummaryNotesSourceSelection`). Never touches the service itself.
/// Ownership reuses `SessionOwnershipDisplay`/
/// `SessionActionAvailabilityCalculator.ownershipDisplay` from
/// `SessionActionAvailability.swift` — identical mechanism to Notes and
/// Transcription, and never consults `LectureNotesGenerationService`'s own
/// ownership/ownership-adjacent state (Summary has its own independent
/// admission slot).
nonisolated struct SummaryActionAvailability: Equatable {
    var canGenerate: Bool
    /// The exact Notes generation ID a Generate tap should pass to
    /// `LectureSummaryGenerationService.generate(sessionID:
    /// notesGenerationID:)`. Always `nil` when `canGenerate` is `false`; the
    /// service is never asked to choose the Notes generation itself.
    var generateNotesGenerationID: UUID?
    var canContinueOrRetry: Bool
    var canCancel: Bool
    /// `true` when the continue/retry action should be labeled "Retry"
    /// (recovering from a recorded failure) rather than "Continue" (resuming
    /// clean incompleteness/cancellation) — purely a label hint, mirrors
    /// `NotesActionAvailability.continueOrRetryIsRetry` exactly (Continue
    /// and Retry are mechanically the same operation).
    var continueOrRetryIsRetry: Bool
}

nonisolated enum SummaryActionAvailabilityCalculator {
    /// `displayState`/`currentUsableNotesGenerationID` are this session's own
    /// last-loaded durable Summary state — never reinterpreted as an
    /// integrity problem merely because a *different* session currently owns
    /// the shared Summary operation, mirroring
    /// `NotesActionAvailabilityCalculator.availability`'s own contract.
    static func availability(
        displayState: SessionSummaryDisplayState,
        currentUsableNotesGenerationID: UUID?,
        ownership: SessionOwnershipDisplay
    ) -> SummaryActionAvailability {
        switch ownership {
        case .activeHere:
            return SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: true, continueOrRetryIsRetry: false)
        case .busyElsewhere:
            return SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        case .none:
            return availabilityWhenIdle(displayState: displayState, currentUsableNotesGenerationID: currentUsableNotesGenerationID)
        }
    }

    private static func availabilityWhenIdle(
        displayState: SessionSummaryDisplayState,
        currentUsableNotesGenerationID: UUID?
    ) -> SummaryActionAvailability {
        switch displayState {
        case .loading, .loadError, .noValidNotesSource:
            return SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        case .noGeneration(let notesGenerationID):
            return SummaryActionAvailability(canGenerate: true, generateNotesGenerationID: notesGenerationID, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
        case .loaded(_, let classification, let advisoryStateIntegrity):
            return availability(
                forLoaded: classification,
                advisoryStateIntegrity: advisoryStateIntegrity,
                currentUsableNotesGenerationID: currentUsableNotesGenerationID
            )
        }
    }

    private static func availability(
        forLoaded classification: SummaryGenerationRecoveryClassification,
        advisoryStateIntegrity: SummaryAdvisoryStateIntegrity,
        currentUsableNotesGenerationID: UUID?
    ) -> SummaryActionAvailability {
        switch classification {
        case .completed:
            // A future explicit fresh Generate is still offered against
            // whatever Notes generation is currently usable — Generate
            // always mints a brand-new Summary generation ID and never
            // touches this completed one. Unaffected by
            // `advisoryStateIntegrity`: operation state is never consulted
            // for a `.completed` classification in the first place. Never
            // an automatic regeneration — this only ever enables the same
            // explicit user-initiated Generate action.
            return SummaryActionAvailability(
                canGenerate: currentUsableNotesGenerationID != nil,
                generateNotesGenerationID: currentUsableNotesGenerationID,
                canContinueOrRetry: false,
                canCancel: false,
                continueOrRetryIsRetry: false
            )
        case .readyForSynthesis:
            guard case .normal = advisoryStateIntegrity else {
                // `LectureSummaryGenerationService.run()` would itself
                // deterministically refuse a Continue for this generation
                // before ever reaching classification. Never offered here
                // either.
                return SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
            }
            return SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: true, canCancel: false, continueOrRetryIsRetry: false)
        case .resumable(_, let interruption):
            guard case .normal = advisoryStateIntegrity else {
                return SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: false, canCancel: false, continueOrRetryIsRetry: false)
            }
            let isRetry: Bool
            if case .recoverableFailure = interruption { isRetry = true } else { isRetry = false }
            return SummaryActionAvailability(canGenerate: false, generateNotesGenerationID: nil, canContinueOrRetry: true, canCancel: false, continueOrRetryIsRetry: isRetry)
        case .staleSource:
            // This generation is permanently pinned to its own original
            // source identity and can never safely resume once that source
            // has moved on — only a fresh Generate against whatever Notes
            // generation is currently usable is offered, and only if one
            // exists. Never Continue/Retry the stale generation, and never
            // silently repin it to the current Notes generation.
            return SummaryActionAvailability(
                canGenerate: currentUsableNotesGenerationID != nil,
                generateNotesGenerationID: currentUsableNotesGenerationID,
                canContinueOrRetry: false,
                canCancel: false,
                continueOrRetryIsRetry: false
            )
        case .damaged:
            // No UI-side recovery is attempted for this damaged generation's
            // own artifacts — they are preserved untouched, and
            // Continue/Retry are never offered for it. A fresh Generate
            // against whatever Notes generation is currently usable remains
            // available, mirroring Notes' own `.damaged` handling exactly.
            return SummaryActionAvailability(
                canGenerate: currentUsableNotesGenerationID != nil,
                generateNotesGenerationID: currentUsableNotesGenerationID,
                canContinueOrRetry: false,
                canCancel: false,
                continueOrRetryIsRetry: false
            )
        }
    }
}

/// Pure mapping from a `LectureSummaryGenerationService.AdmissionResult` to
/// the transient message F3B shows for it — never a second admission
/// policy, purely a presentation label for the service's own authoritative
/// result. Mirrors `NotesAdmissionMessage` exactly, adapted for the Summary
/// domain. `nil` for `.admitted` clears any stale prior message.
nonisolated enum SummaryAdmissionMessage {
    static func message(for result: LectureSummaryGenerationService.AdmissionResult) -> String? {
        switch result {
        case .admitted:
            return nil
        case .busy:
            return "Another Summary operation is already active. Try again once it finishes."
        case .shuttingDown:
            return "Summary generation can't start while the app is shutting down."
        }
    }
}
