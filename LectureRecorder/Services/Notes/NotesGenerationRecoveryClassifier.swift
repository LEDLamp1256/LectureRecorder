import Foundation

/// Why a resumable generation stopped short of completion — purely
/// explanatory. It never changes what "resume from `nextWindowIndex`"
/// means, and it is only ever derived once the durable artifact prefix
/// itself is already known to be valid and incomplete (see
/// `NotesGenerationRecoveryClassifier.classify`).
nonisolated enum NotesGenerationInterruptionReason: Equatable, Sendable {
    /// No advisory operation-state record exists, or the one that does
    /// exist has a lifecycle that does not actually explain this
    /// incompleteness (e.g. it claims `.completed`) — canonical artifacts
    /// always win, so this is treated identically to "never started".
    case notStarted
    case cancelled
    case recoverableFailure(description: String?)
    /// A persisted `running` lifecycle. Since the classifier is only ever
    /// consulted while the orchestration service holds no in-memory active
    /// task for this generation (a genuinely active task's own admission
    /// check refuses a concurrent second call before classification could
    /// ever run again), a persisted `running` record found here can only
    /// mean a prior run was interrupted by a crash, force-quit, or app
    /// relaunch — never a currently-live operation.
    case interruptedRunningState
}

/// Every way committed canonical Notes artifacts can fail to form a valid,
/// resumable state for a generation. Never repaired automatically — a
/// non-prefix set of committed windows such as `{0, 1, 3}` is reported
/// here, never silently treated as resumable from window 2.
nonisolated enum NotesGenerationDamageReason: Equatable, Sendable {
    case invalidWindowPlan(NotesWindowPlanValidationError)
    case corruptOrInvalidAnalysis(windowIndex: Int, underlying: String)
    case duplicateAnalysis(windowIndex: Int)
    case analysisOutsidePlan(windowIndex: Int)
    case nonPrefixCoverage(presentIndices: [Int])
    case documentWithoutCompleteCoverage
    case invalidDocument(String)
    /// A generation's committed analyses no longer form the exact,
    /// individually-valid, complete coverage this generation's plan
    /// requires against a freshly reloaded source — detected by
    /// `LectureNotesGenerationService` immediately before synthesis,
    /// independently of the classifier's own earlier coverage check at
    /// resume time. Never conflated with `.staleSource`: this only fires
    /// once the source itself has already been proven to still match the
    /// generation.
    case coverageIntegrityViolation(String)
}

/// The actionable outcome of classifying one generation's current durable
/// state. Pure and deterministic: identical inputs always produce an
/// identical classification. Canonical artifact integrity is always
/// evaluated before advisory operation state is ever consulted (T5-B
/// contract §5).
nonisolated enum NotesGenerationRecoveryClassification: Equatable, Sendable {
    /// A valid final document exists with exact matching analysis coverage.
    case completed(document: LectureNotesDocument)
    /// Every planned window has a valid committed analysis; no document
    /// exists yet.
    case readyForSynthesis(analyses: [LectureNotesWindowAnalysis])
    /// Valid analyses form an exact `0..<nextWindowIndex` prefix (possibly
    /// empty, when `nextWindowIndex == 0`) of the generation's planned
    /// windows.
    case resumable(nextWindowIndex: Int, interruption: NotesGenerationInterruptionReason)
    /// The durable transcript source no longer matches this generation:
    /// different session/fingerprint, or the persisted plan no longer
    /// exactly covers the current source's coverage.
    case staleSource
    /// Canonical artifacts do not form a valid, resumable state.
    case damaged(reason: NotesGenerationDamageReason)
}

/// Deterministic, pure recovery/classification layer for one notes
/// generation, independently testable from `LectureNotesGenerationService`
/// (T5-B contract §5). Takes already-loaded values only; performs no
/// filesystem I/O and never throws — every failure mode this layer detects
/// is represented as a `NotesGenerationRecoveryClassification` case.
nonisolated enum NotesGenerationRecoveryClassifier {
    static func classify(
        generation: LectureNotesGenerationRecord,
        sourceSnapshot: NotesTranscriptSourceSnapshot,
        analyses: [LectureNotesWindowAnalysis],
        document: LectureNotesDocument?,
        operationState: NotesGenerationOperationState?
    ) -> NotesGenerationRecoveryClassification {
        do {
            try generation.windowPlan.validateStructure()
        } catch let error as NotesWindowPlanValidationError {
            return .damaged(reason: .invalidWindowPlan(error))
        } catch {
            return .damaged(reason: .invalidWindowPlan(.unsupportedSchemaVersion(generation.windowPlan.schemaVersion)))
        }

        do {
            try NotesIntegrityValidator.validateSourceMatchesGeneration(sourceSnapshot: sourceSnapshot, generation: generation)
        } catch {
            // `validateSourceMatchesGeneration` cannot fail here for a
            // structural plan reason (already ruled out above) — a session
            // ID mismatch, fingerprint mismatch, or coverage mismatch all
            // mean the durable transcript source has moved on since this
            // generation's plan was fixed.
            return .staleSource
        }

        let totalWindows = generation.windowPlan.windows.count
        let plannedByIndex = Dictionary(uniqueKeysWithValues: generation.windowPlan.windows.map { ($0.windowIndex, $0) })

        var seenIndices: Set<Int> = []
        for analysis in analyses.sorted(by: { $0.windowIndex < $1.windowIndex }) {
            guard seenIndices.insert(analysis.windowIndex).inserted else {
                return .damaged(reason: .duplicateAnalysis(windowIndex: analysis.windowIndex))
            }
        }

        for index in seenIndices.sorted() where plannedByIndex[index] == nil {
            return .damaged(reason: .analysisOutsidePlan(windowIndex: index))
        }

        let sortedIndices = seenIndices.sorted()
        guard sortedIndices == Array(0..<sortedIndices.count) else {
            return .damaged(reason: .nonPrefixCoverage(presentIndices: sortedIndices))
        }
        let prefixCount = sortedIndices.count

        for analysis in analyses.sorted(by: { $0.windowIndex < $1.windowIndex }) {
            guard let plannedWindow = plannedByIndex[analysis.windowIndex] else { continue }
            do {
                try NotesIntegrityValidator.validate(
                    analysis: analysis,
                    generation: generation,
                    plannedWindow: plannedWindow,
                    sourceSnapshot: sourceSnapshot
                )
            } catch {
                return .damaged(reason: .corruptOrInvalidAnalysis(windowIndex: analysis.windowIndex, underlying: error.localizedDescription))
            }
        }

        if prefixCount < totalWindows {
            guard document == nil else {
                return .damaged(reason: .documentWithoutCompleteCoverage)
            }
            return .resumable(nextWindowIndex: prefixCount, interruption: interruptionReason(from: operationState))
        }

        // `prefixCount == totalWindows`: full, individually-valid coverage.
        guard let document else {
            return .readyForSynthesis(analyses: analyses.sorted { $0.windowIndex < $1.windowIndex })
        }

        do {
            try NotesIntegrityValidator.validate(document: document, generation: generation, sourceSnapshot: sourceSnapshot)
        } catch {
            return .damaged(reason: .invalidDocument(error.localizedDescription))
        }

        return .completed(document: document)
    }

    private static func interruptionReason(from operationState: NotesGenerationOperationState?) -> NotesGenerationInterruptionReason {
        guard let operationState else { return .notStarted }
        switch operationState.lifecycle {
        case .running:
            return .interruptedRunningState
        case .cancelled:
            return .cancelled
        case .failed:
            return .recoverableFailure(description: operationState.failureDescription)
        case .completed:
            // Canonical artifacts already proved this generation is *not*
            // complete (we are in the `prefixCount < totalWindows` branch)
            // — a stale `.completed` claim is never allowed to override
            // that, so it is treated exactly like "never started".
            return .notStarted
        }
    }
}
