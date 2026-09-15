import Foundation

/// Every deterministic integrity rejection `NotesIntegrityValidator` can
/// throw. Model-derived artifacts (even today's deterministic fakes) are
/// treated as untrusted input — every case here is a rejection, never a
/// silent repair.
nonisolated enum NotesIntegrityError: LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case sessionIdentityMismatch
    case generationIdentityMismatch
    case transcriptFingerprintMismatch
    case provenanceMismatch
    case invalidSourceReference(NotesSourceReferenceError)
    case invalidWindowPlan(NotesWindowPlanValidationError)
    case sourceReferenceOutsideOwnedWindow(windowIndex: Int)
    case duplicateWindowIndex(Int)
    case windowOwnedRangeDoesNotMatchPlannedWindow(windowIndex: Int)
    /// `analysis.windowIndex` has no corresponding entry in
    /// `generation.windowPlan` at all — the persisted plan is the sole
    /// authority for which windows exist; a window absent from it is never
    /// accepted regardless of what a caller supplies.
    case windowNotInPlan(windowIndex: Int)
    /// A caller-supplied `plannedWindow` does not exactly equal the entry
    /// actually persisted in `generation.windowPlan` at that window index
    /// — an analysis can never be validated "as valid" merely because a
    /// caller happened to supply a matching-looking window of its own.
    case plannedWindowDisagreesWithPersistedPlan(windowIndex: Int)
    case itemMissingSourceReferences
    case missingWindowAnalysis(windowIndices: [Int])
    case unexpectedWindowAnalysis(windowIndices: [Int])

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Notes artifact schema version \(version) is not supported."
        case .sessionIdentityMismatch:
            return "Notes artifact session ID does not match the expected generation's session."
        case .generationIdentityMismatch:
            return "Notes artifact generation ID does not match the expected generation."
        case .transcriptFingerprintMismatch:
            return "Notes artifact transcript fingerprint does not match the expected generation's source."
        case .provenanceMismatch:
            return "Notes document provenance does not match its own generation's provenance."
        case .invalidSourceReference(let underlying):
            return underlying.errorDescription
        case .invalidWindowPlan(let underlying):
            return underlying.errorDescription
        case .sourceReferenceOutsideOwnedWindow(let windowIndex):
            return "A source reference in window #\(windowIndex) falls outside that window's owned range."
        case .duplicateWindowIndex(let windowIndex):
            return "Window index #\(windowIndex) appears more than once for the same generation."
        case .windowOwnedRangeDoesNotMatchPlannedWindow(let windowIndex):
            return "Window #\(windowIndex)'s analysis claims an owned range that does not match its planned window."
        case .windowNotInPlan(let windowIndex):
            return "Window #\(windowIndex) is not present in the generation's persisted window plan."
        case .plannedWindowDisagreesWithPersistedPlan(let windowIndex):
            return "The supplied planned window for #\(windowIndex) does not match the generation's persisted plan entry."
        case .itemMissingSourceReferences:
            return "A note item has no source references and cannot be considered grounded."
        case .missingWindowAnalysis(let windowIndices):
            return "Generation is missing analysis for planned window(s): \(windowIndices)."
        case .unexpectedWindowAnalysis(let windowIndices):
            return "Generation has analysis for window(s) not in its planned coverage: \(windowIndices)."
        }
    }
}

nonisolated enum NotesIntegrityValidator {
    /// Validates one source reference against `snapshot`, wrapping
    /// `NotesSourceReferenceError` into `NotesIntegrityError` so every
    /// rejection in the notes domain surfaces through a single error type.
    static func validate(
        reference: NotesSourceReference,
        against snapshot: NotesTranscriptSourceSnapshot
    ) throws {
        do {
            try reference.validate(against: snapshot)
        } catch let error as NotesSourceReferenceError {
            throw NotesIntegrityError.invalidSourceReference(error)
        }
    }

    /// Rejects a note item that carries no source references at all — an
    /// item with nothing grounding it cannot be considered a valid
    /// grounded note item, regardless of how its `sourceReferences` (if
    /// any existed) would otherwise validate.
    private static func validateHasSourceReferences(_ item: LectureNoteItem) throws {
        guard !item.sourceReferences.isEmpty else {
            throw NotesIntegrityError.itemMissingSourceReferences
        }
    }

    /// The central cross-check between a transcript source snapshot and
    /// the generation it is being used to validate: `sourceSnapshot` must
    /// actually belong to `generation`'s own session and be the exact
    /// transcript content `generation` was created against. A transcript
    /// that changed for the same session (a new fingerprint) therefore
    /// makes an old generation's further work stale/invalid the moment
    /// this check runs — never silently validated against whatever
    /// snapshot happens to be passed in.
    ///
    /// Also validates that `generation.windowPlan` is itself structurally
    /// valid *and exactly covers* `sourceSnapshot` (see
    /// `NotesWindowPlan.validateCoversExactly`). This is deliberately part
    /// of the same central check, not left to `validateCoverage` alone: a
    /// structurally valid but truncated or shifted plan must be rejected
    /// by individual window-analysis validation and by final-document
    /// validation too, not only when the full multi-window coverage path
    /// happens to run. No caller of any `validate`/`validateCoverage`
    /// overload below relies on `validateCoverage` having run first as an
    /// implicit precondition.
    static func validateSourceMatchesGeneration(
        sourceSnapshot: NotesTranscriptSourceSnapshot,
        generation: LectureNotesGenerationRecord
    ) throws {
        guard sourceSnapshot.sessionID == generation.sessionID else {
            throw NotesIntegrityError.sessionIdentityMismatch
        }
        guard sourceSnapshot.fingerprint == generation.transcriptFingerprint else {
            throw NotesIntegrityError.transcriptFingerprintMismatch
        }
        do {
            try generation.windowPlan.validateCoversExactly(sourceSnapshot)
        } catch let error as NotesWindowPlanValidationError {
            throw NotesIntegrityError.invalidWindowPlan(error)
        }
    }

    /// Looks up the window `generation.windowPlan` actually persists for
    /// `windowIndex`, wrapping `NotesWindowPlanValidationError` (from
    /// validating the plan's own structure first, so a malformed plan
    /// never allows an ambiguous or unsafe lookup) and throwing
    /// `.windowNotInPlan` if no such window exists.
    private static func persistedWindow(
        forWindowIndex windowIndex: Int,
        in generation: LectureNotesGenerationRecord
    ) throws -> NotesInputWindow {
        do {
            try generation.windowPlan.validateStructure()
        } catch let error as NotesWindowPlanValidationError {
            throw NotesIntegrityError.invalidWindowPlan(error)
        }
        guard let window = generation.windowPlan.windows.first(where: { $0.windowIndex == windowIndex }) else {
            throw NotesIntegrityError.windowNotInPlan(windowIndex: windowIndex)
        }
        return window
    }

    /// Validates one window analysis: schema support, that `sourceSnapshot`
    /// actually matches `generation` (see `validateSourceMatchesGeneration`),
    /// identity against `generation` (session/generation/fingerprint), that
    /// `plannedWindow` is not merely caller-asserted but exactly equals the
    /// entry `generation`'s own persisted `windowPlan` has for
    /// `analysis.windowIndex` (a window absent from the plan, or a
    /// supplied window that disagrees with the persisted one, is rejected
    /// either way), that its claimed `ownedRange` matches that window, and
    /// that every item has at least one source reference which both
    /// validates against `sourceSnapshot` and stays within the window's
    /// own owned range.
    static func validate(
        analysis: LectureNotesWindowAnalysis,
        generation: LectureNotesGenerationRecord,
        plannedWindow: NotesInputWindow,
        sourceSnapshot: NotesTranscriptSourceSnapshot
    ) throws {
        guard analysis.schemaVersion == LectureNotesWindowAnalysis.currentSchemaVersion else {
            throw NotesIntegrityError.unsupportedSchemaVersion(analysis.schemaVersion)
        }
        try validateSourceMatchesGeneration(sourceSnapshot: sourceSnapshot, generation: generation)
        guard analysis.sessionID == generation.sessionID else {
            throw NotesIntegrityError.sessionIdentityMismatch
        }
        guard analysis.generationID == generation.generationID else {
            throw NotesIntegrityError.generationIdentityMismatch
        }
        guard analysis.transcriptFingerprint == generation.transcriptFingerprint else {
            throw NotesIntegrityError.transcriptFingerprintMismatch
        }

        let persisted = try persistedWindow(forWindowIndex: analysis.windowIndex, in: generation)
        guard persisted == plannedWindow else {
            throw NotesIntegrityError.plannedWindowDisagreesWithPersistedPlan(windowIndex: analysis.windowIndex)
        }

        guard
            analysis.ownedRange.firstSequenceNumber == plannedWindow.firstSequenceNumber,
            analysis.ownedRange.lastSequenceNumber == plannedWindow.lastSequenceNumber
        else {
            throw NotesIntegrityError.windowOwnedRangeDoesNotMatchPlannedWindow(windowIndex: analysis.windowIndex)
        }

        try validate(reference: analysis.ownedRange, against: sourceSnapshot)

        for item in analysis.items {
            try validateHasSourceReferences(item)
            for reference in item.sourceReferences {
                try validate(reference: reference, against: sourceSnapshot)
                guard
                    reference.firstSequenceNumber >= analysis.ownedRange.firstSequenceNumber,
                    reference.lastSequenceNumber <= analysis.ownedRange.lastSequenceNumber
                else {
                    throw NotesIntegrityError.sourceReferenceOutsideOwnedWindow(windowIndex: analysis.windowIndex)
                }
            }
        }
    }

    /// Rejects duplicate window indices among a set of loaded window
    /// analyses before they are treated as one generation's complete,
    /// consistent evidence set.
    static func validateNoDuplicateWindowIndices(_ analyses: [LectureNotesWindowAnalysis]) throws {
        var seen: Set<Int> = []
        for analysis in analyses {
            guard seen.insert(analysis.windowIndex).inserted else {
                throw NotesIntegrityError.duplicateWindowIndex(analysis.windowIndex)
            }
        }
    }

    /// Validates that `analyses` is exactly the complete, consistent
    /// evidence set for `generation`'s persisted `windowPlan` — the sole
    /// authoritative expected coverage for that generation (see
    /// `NotesWindowPlan`) — before synthesis is allowed to proceed:
    ///
    /// - `sourceSnapshot` actually matches `generation`;
    /// - `generation.windowPlan` itself is structurally valid and exactly
    ///   covers `sourceSnapshot` (see `NotesWindowPlan.validateCoversExactly`);
    /// - no duplicate window index among `analyses`;
    /// - every planned window has exactly one corresponding analysis
    ///   (nothing missing);
    /// - no analysis exists for a window outside the plan (nothing extra);
    /// - each analysis individually validates against its corresponding
    ///   planned window (see the per-analysis `validate` overload above).
    ///
    /// Builds no dictionary from unvalidated data in a way that could trap:
    /// the plan's own structure (unique, sequential indices) is proven
    /// before any keyed lookup is attempted.
    static func validateCoverage(
        analyses: [LectureNotesWindowAnalysis],
        generation: LectureNotesGenerationRecord,
        sourceSnapshot: NotesTranscriptSourceSnapshot
    ) throws {
        // `validateSourceMatchesGeneration` already proves
        // `generation.windowPlan` is structurally valid and exactly
        // covers `sourceSnapshot` — not duplicated here.
        try validateSourceMatchesGeneration(sourceSnapshot: sourceSnapshot, generation: generation)
        try validateNoDuplicateWindowIndices(analyses)

        var plannedByIndex: [Int: NotesInputWindow] = [:]
        for window in generation.windowPlan.windows {
            plannedByIndex[window.windowIndex] = window
        }
        var analysesByIndex: [Int: LectureNotesWindowAnalysis] = [:]
        for analysis in analyses {
            analysesByIndex[analysis.windowIndex] = analysis
        }

        let plannedIndices = Set(plannedByIndex.keys)
        let analysisIndices = Set(analysesByIndex.keys)

        let missing = plannedIndices.subtracting(analysisIndices).sorted()
        guard missing.isEmpty else {
            throw NotesIntegrityError.missingWindowAnalysis(windowIndices: missing)
        }

        let extra = analysisIndices.subtracting(plannedIndices).sorted()
        guard extra.isEmpty else {
            throw NotesIntegrityError.unexpectedWindowAnalysis(windowIndices: extra)
        }

        for windowIndex in plannedIndices.sorted() {
            guard let plannedWindow = plannedByIndex[windowIndex], let analysis = analysesByIndex[windowIndex] else {
                // Unreachable given the missing/extra checks above, but
                // never force-unwrapped — a lookup miss here throws a
                // typed error rather than trapping.
                throw NotesIntegrityError.windowNotInPlan(windowIndex: windowIndex)
            }
            try validate(analysis: analysis, generation: generation, plannedWindow: plannedWindow, sourceSnapshot: sourceSnapshot)
        }
    }

    /// Validates the final synthesized document: schema support, that
    /// `sourceSnapshot` actually matches `generation`, identity against
    /// `generation` (session/generation/fingerprint/provenance), and that
    /// every item has at least one source reference which validates
    /// against `sourceSnapshot`. A document whose provenance does not
    /// match its own generation record is rejected here, never silently
    /// reattributed.
    static func validate(
        document: LectureNotesDocument,
        generation: LectureNotesGenerationRecord,
        sourceSnapshot: NotesTranscriptSourceSnapshot
    ) throws {
        guard document.schemaVersion == LectureNotesDocument.currentSchemaVersion else {
            throw NotesIntegrityError.unsupportedSchemaVersion(document.schemaVersion)
        }
        try validateSourceMatchesGeneration(sourceSnapshot: sourceSnapshot, generation: generation)
        guard document.sessionID == generation.sessionID else {
            throw NotesIntegrityError.sessionIdentityMismatch
        }
        guard document.generationID == generation.generationID else {
            throw NotesIntegrityError.generationIdentityMismatch
        }
        guard document.transcriptFingerprint == generation.transcriptFingerprint else {
            throw NotesIntegrityError.transcriptFingerprintMismatch
        }
        guard document.provenance == generation.provenance else {
            throw NotesIntegrityError.provenanceMismatch
        }

        for section in document.sections {
            for item in section.items {
                try validateHasSourceReferences(item)
                for reference in item.sourceReferences {
                    try validate(reference: reference, against: sourceSnapshot)
                }
            }
        }
    }
}
