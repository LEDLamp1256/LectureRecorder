import Foundation

/// Why saved speaker labels are unreadable — kept for diagnosis and tests;
/// the user-facing copy is the same for every cause.
enum SpeakerUnreadableCause: Equatable {
    /// The sidecar itself cannot be used (corrupt, unsupported schema,
    /// invalid result, or another session's).
    case sidecar(SpeakerDiarizationUnavailableReason)
    /// A loaded result could not be aligned to the displayed transcript.
    case alignment(SpeakerTranscriptAlignmentError)
}

/// One session's durable speaker-label state as presented. Reconstructed
/// from disk only; never says anything about a live operation, which
/// `SessionDiarizationService` alone reports.
enum SpeakerDurableDisplay: Equatable {
    case loading
    /// The session's audio is not a diarization source.
    case sourceUnavailable(SessionDiarizationSourceError)
    /// Never identified.
    case absent
    /// A usable result for the session's current audio.
    case available(speakerCount: Int)
    /// Saved labels describe audio other than the session's current audio.
    case outOfDate
    /// Saved labels cannot be used; a new run can replace them.
    case unreadable(SpeakerUnreadableCause)
    /// The sidecar's storage path is a symlink or the wrong file type.
    /// `SpeakerDiarizationStore.save` rejects exactly these paths, so a new
    /// run could never be saved: identification is unavailable.
    case storageUnavailable

    init(_ state: SessionDiarizationService.PresentationState) {
        switch state {
        case .sourceUnavailable(let error): self = .sourceUnavailable(error)
        case .absent: self = .absent
        case .available(let result, _): self = .available(speakerCount: result.speakerIDs.count)
        case .unavailable(.audioSourceMismatch): self = .outOfDate
        case .unavailable(.unsafePath): self = .storageUnavailable
        case .unavailable(let reason): self = .unreadable(.sidecar(reason))
        }
    }
}

/// Presentation-only speaker names. Machine IDs are never shown or
/// persisted as display text: `speaker_0` is "Speaker 1". D1 validation
/// guarantees a loaded result's IDs are exactly `speaker_0..<count`,
/// numbered in order of first speech.
enum SpeakerDisplayName {
    static let notIdentified = "Speaker not identified"

    static func name(for speakerID: SpeakerID) -> String {
        "Speaker \(speakerID.index + 1)"
    }

    /// Truthful per-row accessibility text: names a speaker only for
    /// `.speaker`, and never lists ambiguous candidates.
    static func accessibilityDescription(for attribution: SpeakerAttribution) -> String {
        switch attribution {
        case .speaker(let speakerID): return name(for: speakerID)
        case .ambiguous: return "\(notIdentified), overlapping speakers"
        case .unknown: return notIdentified
        case .ineligible: return "\(notIdentified), no passage timing"
        }
    }
}

/// A visible group boundary above a transcript row.
enum SpeakerRowHeader: Equatable {
    case speaker(SpeakerID)
    /// Rows the alignment does not attribute (ambiguous, unknown, or
    /// ineligible). Breaks the previous speaker's group so those rows never
    /// read as that speaker's.
    case notIdentified

    var title: String {
        switch self {
        case .speaker(let speakerID): return SpeakerDisplayName.name(for: speakerID)
        case .notIdentified: return SpeakerDisplayName.notIdentified
        }
    }
}

/// Precomputed speaker decoration for one `TranscriptPlaybackNavigation`,
/// keyed by its items' existing IDs. Rows only look values up; nothing here
/// is written back to the transcript or persisted.
struct TranscriptSpeakerDecoration: Equatable {
    let attributionByItemID: [TranscriptPlaybackItem.ID: SpeakerAttribution]
    /// Rows that open a new visible group, and the group each opens.
    let headerByItemID: [TranscriptPlaybackItem.ID: SpeakerRowHeader]

    /// A header opens whenever a row's group differs from the previous
    /// row's: a speaker, or "not identified" for any non-speaker
    /// attribution. Rows before the first speaker get no header — no
    /// earlier group exists for them to be mistaken for.
    static func build(navigation: TranscriptPlaybackNavigation, alignments: [SpeakerItemAlignment]) -> TranscriptSpeakerDecoration {
        let navigationItemIDs = Set(navigation.items.map(\.id))
        var attributions: [TranscriptPlaybackItem.ID: SpeakerAttribution] = [:]
        for alignment in alignments where navigationItemIDs.contains(alignment.itemID) {
            attributions[alignment.itemID] = alignment.attribution
        }

        var headers: [TranscriptPlaybackItem.ID: SpeakerRowHeader] = [:]
        var previous: SpeakerRowHeader?
        for item in navigation.items {
            guard let attribution = attributions[item.id] else { continue }
            let group: SpeakerRowHeader
            if case .speaker(let speakerID) = attribution {
                group = .speaker(speakerID)
            } else {
                group = .notIdentified
            }
            if group != previous, !(group == .notIdentified && previous == nil) {
                headers[item.id] = group
            }
            previous = group
        }
        return TranscriptSpeakerDecoration(attributionByItemID: attributions, headerByItemID: headers)
    }
}

/// What the speaker-identification controls offer for one session.
struct SpeakerIdentificationAvailability: Equatable {
    var actionTitle: String
    var canIdentify: Bool
    /// Cancel is shown only while this session owns the one operation.
    var showsCancel: Bool
    /// Cancel works only before commit authorization (`.saving`).
    var canCancel: Bool
}

/// The status line beside the controls: text (if any) and whether an
/// indeterminate progress indicator accompanies it.
struct SpeakerIdentificationStatus: Equatable {
    var text: String?
    var showsProgress: Bool
    var isProblem: Bool = false
}

/// Pure value-in, value-out rules for the speaker-identification controls,
/// so action and multi-window busy semantics are testable without a UI.
/// Live state comes only from `SessionDiarizationService`; durable state
/// only from disk.
enum SpeakerIdentificationAvailabilityCalculator {
    static func availability(
        display: SpeakerDurableDisplay,
        ownership: SessionOwnershipDisplay,
        phase: SessionDiarizationService.OperationPhase
    ) -> SpeakerIdentificationAvailability {
        let actionTitle: String
        if case .available = display {
            actionTitle = "Identify Speakers Again"
        } else {
            actionTitle = "Identify Speakers"
        }

        let isRerunnable: Bool
        switch display {
        case .absent, .available, .outOfDate, .unreadable:
            isRerunnable = true
        case .loading, .sourceUnavailable, .storageUnavailable:
            isRerunnable = false
        }

        let canCancel: Bool
        switch phase {
        case .preparingSource, .diarizing, .validating:
            canCancel = ownership == .activeHere
        case .idle, .saving, .cancelling, .finished:
            canCancel = false
        }

        return SpeakerIdentificationAvailability(
            actionTitle: actionTitle,
            canIdentify: ownership == .none && isRerunnable,
            showsCancel: ownership == .activeHere,
            canCancel: canCancel
        )
    }

    static func status(
        display: SpeakerDurableDisplay,
        ownership: SessionOwnershipDisplay,
        phase: SessionDiarizationService.OperationPhase
    ) -> SpeakerIdentificationStatus {
        switch ownership {
        case .activeHere:
            return SpeakerIdentificationStatus(text: phaseText(phase), showsProgress: true)
        case .busyElsewhere:
            return SpeakerIdentificationStatus(text: "Speakers are being identified for another session.", showsProgress: false)
        case .none:
            switch display {
            case .loading:
                return SpeakerIdentificationStatus(text: nil, showsProgress: true)
            case .absent:
                return SpeakerIdentificationStatus(text: nil, showsProgress: false)
            case .available(let count):
                return SpeakerIdentificationStatus(text: count == 1 ? "1 speaker identified" : "\(count) speakers identified", showsProgress: false)
            case .outOfDate:
                return SpeakerIdentificationStatus(text: "Saved speaker labels are out of date.", showsProgress: false, isProblem: true)
            case .unreadable:
                return SpeakerIdentificationStatus(text: "Saved speaker labels can't be read.", showsProgress: false, isProblem: true)
            case .sourceUnavailable:
                return SpeakerIdentificationStatus(text: "Speaker identification isn't available for this session's audio.", showsProgress: false)
            case .storageUnavailable:
                return SpeakerIdentificationStatus(text: "Speaker identification isn't available for this session.", showsProgress: false)
            }
        }
    }

    /// Honest, indeterminate phase text — never a percentage. `nil` for the
    /// brief finishing moment before ownership is released.
    static func phaseText(_ phase: SessionDiarizationService.OperationPhase) -> String? {
        switch phase {
        case .preparingSource: return "Preparing audio…"
        case .diarizing: return "Identifying speakers…"
        case .validating: return "Checking results…"
        case .saving: return "Saving speaker labels…"
        case .cancelling: return "Cancelling…"
        case .idle, .finished: return nil
        }
    }
}

/// User-facing copy for operation results and refused admissions. Never
/// includes backend diagnostics, paths, or model details.
enum SpeakerIdentificationMessage {
    static func message(for outcome: SessionDiarizationService.DiarizationOperationOutcome?) -> String? {
        switch outcome {
        case .completed, nil:
            return nil
        case .cancelled:
            return "Speaker identification cancelled."
        case .staleSource:
            return "The recording changed while speakers were being identified. Try again."
        case .sourceUnavailable:
            return "This session's audio couldn't be read."
        case .failed(.backendFailed):
            return "Speaker identification couldn't finish."
        case .failed(.invalidBackendOutput):
            return "Speaker identification produced an unusable result."
        case .failed(.saveFailed):
            return "Speaker labels couldn't be saved."
        }
    }

    static func message(for admission: SessionDiarizationService.AdmissionResult) -> String? {
        switch admission {
        case .admitted:
            return nil
        case .busy:
            return "Speakers are already being identified for another session."
        case .shuttingDown:
            return "Speaker identification can't start while the app is quitting."
        }
    }
}
