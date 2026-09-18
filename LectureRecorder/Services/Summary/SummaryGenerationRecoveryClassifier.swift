import Foundation

/// Why a resumable Summary generation stopped short of completion — purely
/// explanatory. It never changes what "resume from `nextBatchIndex`" means,
/// and it is only ever derived once the durable artifact prefix itself is
/// already known to be valid and incomplete (see
/// `SummaryGenerationRecoveryClassifier.classify`). Mirrors
/// `NotesGenerationInterruptionReason` exactly, adapted for the Summary
/// domain's batch vocabulary.
nonisolated enum SummaryGenerationInterruptionReason: Equatable, Sendable {
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

/// Every way committed canonical Summary artifacts can fail to form a valid,
/// resumable state for a generation. Never repaired automatically — a
/// non-prefix set of committed batches such as `{0, 1, 3}` is reported here,
/// never silently treated as resumable from batch 2.
nonisolated enum SummaryGenerationDamageReason: Equatable, Sendable {
    case invalidBatchPlan(LectureSummaryPlanValidationError)
    case corruptOrInvalidAnalysis(batchIndex: Int, underlying: String)
    case duplicateAnalysis(batchIndex: Int)
    case analysisOutsidePlan(batchIndex: Int)
    case nonPrefixCoverage(presentIndices: [Int])
    case documentWithoutCompleteCoverage
    case invalidDocument(String)
    /// The generation's own persisted `batchPlan` no longer matches the
    /// deterministic plan `LectureSummaryPlanner` computes for a source that
    /// otherwise proved identity-identical (matching session, source Notes
    /// generation, transcript fingerprint, and Notes document fingerprint).
    /// Because the source Notes document is itself commit-once and
    /// immutable per generation ID, matching fingerprints already guarantee
    /// byte-identical flattened source items — so unlike Notes' analogous
    /// window-plan-coverage check (which legitimately drifts as the live
    /// transcript grows), a mismatch here can only mean the persisted plan
    /// itself was corrupted or a planner/schema change silently altered its
    /// meaning. Never conflated with `.staleSource`, which is reserved for
    /// a genuine identity/fingerprint disagreement.
    case planDoesNotMatchSource(String)
}

/// The actionable outcome of classifying one Summary generation's current
/// durable state. Pure and deterministic: identical inputs always produce an
/// identical classification. Canonical artifact integrity is always
/// evaluated before advisory operation state is ever consulted — mirrors
/// `NotesGenerationRecoveryClassifier`'s own contract exactly.
nonisolated enum SummaryGenerationRecoveryClassification: Equatable, Sendable {
    /// A valid final document exists with exact matching analysis coverage.
    case completed(document: LectureSummaryDocument)
    /// Every planned batch has a valid committed analysis; no document
    /// exists yet.
    case readyForSynthesis(analyses: [LectureSummaryAnalysis])
    /// Valid analyses form an exact `0..<nextBatchIndex` prefix (possibly
    /// empty, when `nextBatchIndex == 0`) of the generation's planned
    /// batches.
    case resumable(nextBatchIndex: Int, interruption: SummaryGenerationInterruptionReason)
    /// The durable source this generation was built from no longer matches:
    /// different session, different source Notes generation, or a changed
    /// transcript/Notes-document fingerprint. Also reached when the
    /// referenced source Notes generation itself is no longer available or
    /// valid (deleted, incomplete, or failing Notes integrity validation) —
    /// see `LectureSummaryGenerationService`'s own source-reload handling.
    case staleSource
    /// Canonical artifacts do not form a valid, resumable state.
    case damaged(reason: SummaryGenerationDamageReason)
}

/// Deterministic, pure recovery/classification layer for one Summary
/// generation, independently testable from `LectureSummaryGenerationService`.
/// Takes already-loaded values only; performs no filesystem I/O and never
/// throws — every failure mode this layer detects is represented as a
/// `SummaryGenerationRecoveryClassification` case. Mirrors
/// `NotesGenerationRecoveryClassifier` exactly in architectural role,
/// adapted for the Summary domain's batch-plan/dual-fingerprint identity.
nonisolated enum SummaryGenerationRecoveryClassifier {
    static func classify(
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot,
        analyses: [LectureSummaryAnalysis],
        document: LectureSummaryDocument?,
        operationState: SummaryGenerationOperationState?
    ) -> SummaryGenerationRecoveryClassification {
        do {
            try generation.batchPlan.validateStructure()
        } catch let error as LectureSummaryPlanValidationError {
            return .damaged(reason: .invalidBatchPlan(error))
        } catch {
            return .damaged(reason: .invalidBatchPlan(.unsupportedSchemaVersion(generation.batchPlan.schemaVersion)))
        }

        // Identity/staleness first, independent of the heavier structural
        // replan check below: a genuine identity/fingerprint disagreement
        // always means the source has moved on, never that the record is
        // corrupt.
        guard
            generation.sessionID == source.sessionID,
            generation.sourceNotesGenerationID == source.sourceNotesGenerationID,
            generation.transcriptFingerprint == source.transcriptFingerprint,
            generation.sourceNotesDocumentFingerprint == source.sourceNotesDocumentFingerprint
        else {
            return .staleSource
        }

        // Identity already matches — a persisted plan that still disagrees
        // with the deterministic replan of this (proven byte-identical)
        // source is corruption, not staleness. See
        // `SummaryGenerationDamageReason.planDoesNotMatchSource`.
        do {
            try LectureSummaryIntegrityValidator.validate(generation: generation, source: source)
        } catch {
            return .damaged(reason: .planDoesNotMatchSource(error.localizedDescription))
        }

        let totalBatches = generation.batchPlan.batches.count
        let plannedByIndex = Dictionary(uniqueKeysWithValues: generation.batchPlan.batches.map { ($0.batchIndex, $0) })

        var seenIndices: Set<Int> = []
        for analysis in analyses.sorted(by: { $0.batchIndex < $1.batchIndex }) {
            guard seenIndices.insert(analysis.batchIndex).inserted else {
                return .damaged(reason: .duplicateAnalysis(batchIndex: analysis.batchIndex))
            }
        }

        for index in seenIndices.sorted() where plannedByIndex[index] == nil {
            return .damaged(reason: .analysisOutsidePlan(batchIndex: index))
        }

        let sortedIndices = seenIndices.sorted()
        guard sortedIndices == Array(0..<sortedIndices.count) else {
            return .damaged(reason: .nonPrefixCoverage(presentIndices: sortedIndices))
        }
        let prefixCount = sortedIndices.count

        for analysis in analyses.sorted(by: { $0.batchIndex < $1.batchIndex }) {
            do {
                try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: generation, source: source)
            } catch {
                return .damaged(reason: .corruptOrInvalidAnalysis(batchIndex: analysis.batchIndex, underlying: error.localizedDescription))
            }
        }

        if prefixCount < totalBatches {
            guard document == nil else {
                return .damaged(reason: .documentWithoutCompleteCoverage)
            }
            return .resumable(nextBatchIndex: prefixCount, interruption: interruptionReason(from: operationState))
        }

        // `prefixCount == totalBatches`: full, individually-valid coverage.
        guard let document else {
            return .readyForSynthesis(analyses: analyses.sorted { $0.batchIndex < $1.batchIndex })
        }

        do {
            try LectureSummaryIntegrityValidator.validate(document: document, generation: generation, source: source)
        } catch {
            return .damaged(reason: .invalidDocument(error.localizedDescription))
        }

        return .completed(document: document)
    }

    private static func interruptionReason(from operationState: SummaryGenerationOperationState?) -> SummaryGenerationInterruptionReason {
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
            // complete (we are in the `prefixCount < totalBatches` branch)
            // — a stale `.completed` claim is never allowed to override
            // that, so it is treated exactly like "never started".
            return .notStarted
        }
    }
}
