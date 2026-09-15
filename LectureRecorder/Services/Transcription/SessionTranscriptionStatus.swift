import Foundation

/// The truthful, durable-state classification T4 presents for one
/// completed session's transcription progress. Always derived at read
/// time from durable jobs/results/inconsistencies — never itself
/// persisted. See `SessionTranscriptionClassifier.classify`.
nonisolated enum SessionTranscriptionStatus: Sendable, Equatable {
    /// No transcription jobs exist yet for this session.
    case notTranscribed
    /// The session has no recorded chunks. Deliberately distinct from
    /// `.completed` — a session with zero expected chunks must never be
    /// presented as vacuously "Transcription Completed".
    case zeroChunkSession
    /// Some chunks are queued/running/completed but coverage is not yet
    /// complete, and no chunk is stuck in an ownerless `.running` state.
    case incomplete(completed: Int, total: Int)
    /// At least one job is `.running` with no active owner (a prior
    /// process was interrupted mid-attempt). Explicit recovery
    /// (Transcribe/Continue/Retry) will reconcile it.
    case interrupted(retryableSequenceNumbers: [Int])
    /// A `.running` job has a matching, attempt-consistent result on
    /// disk, but results-directory durability could not be freshly
    /// reconfirmed. Not completed and not failed — a later recovery
    /// attempt may resolve it once durability is restored.
    case recoveryPending
    /// Every expected chunk has a completed job with a matching canonical
    /// result whose source snapshot matches the manifest. See
    /// `SessionTranscriptionClassifier.isCompletionValid` for the exact
    /// rule.
    case completed
    /// A genuine integrity problem exists (corrupt/unsupported artifact,
    /// orphaned result, attempt mismatch, conflicting canonical result,
    /// etc.) that recovery cannot safely resolve automatically. Artifacts
    /// are preserved untouched; a human/architecture decision may be
    /// needed.
    case blocked(reasons: [String])
}

nonisolated enum SessionTranscriptionClassifier {
    /// The exact completion rule (Section 21 of the T4 contract): a
    /// session may be presented as complete only when every expected
    /// chunk has a `.completed` job whose canonical result exists and
    /// whose own source snapshot, and the result's, both match the
    /// snapshot freshly derived from the manifest. A session with zero
    /// expected chunks is never complete. Does not require
    /// `currentAttemptID` absence, no `lastFailure`, or today's inference
    /// configuration to match the historical result.
    static func isCompletionValid(
        manifest: SessionManifest,
        jobs: [TranscriptionJob],
        results: [TranscriptResult]
    ) -> Bool {
        guard !manifest.chunks.isEmpty else { return false }

        var jobsBySequence: [Int: TranscriptionJob] = [:]
        for job in jobs {
            jobsBySequence[job.source.chunkSequenceNumber] = job
        }
        var resultsBySequence: [Int: TranscriptResult] = [:]
        for result in results {
            resultsBySequence[result.source.chunkSequenceNumber] = result
        }

        // Exact expected coverage: a recognized job/result at a sequence
        // number outside the manifest's expected range must never be
        // silently ignored — it blocks completion rather than being
        // dropped by the per-chunk loop below.
        let expectedSequences = Set(manifest.chunks.map(\.sequenceNumber))
        guard Set(jobsBySequence.keys).isSubset(of: expectedSequences) else { return false }
        guard Set(resultsBySequence.keys).isSubset(of: expectedSequences) else { return false }

        for chunk in manifest.chunks {
            guard let job = jobsBySequence[chunk.sequenceNumber], job.state == .completed else {
                return false
            }
            guard let result = resultsBySequence[chunk.sequenceNumber] else {
                return false
            }
            let expectedSource = TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID,
                chunkSequenceNumber: chunk.sequenceNumber,
                chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount,
                startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds,
                audioFormat: manifest.audioFormat
            )
            guard job.source == expectedSource, result.source == expectedSource else {
                return false
            }
        }
        return true
    }

    /// Classifies durable state into exactly one of the required
    /// conceptual states (Section 18). Callers typically invoke this
    /// against raw, not-yet-reconciled disk state (to decide whether an
    /// `.interrupted`/`.recoveryPending` recovery pass is needed) and
    /// again after `reconcileState` has run (to derive the terminal
    /// status to publish). Pure — never touches disk, never mutates
    /// anything.
    static func classify(
        manifest: SessionManifest,
        jobs: [TranscriptionJob],
        results: [TranscriptResult],
        inconsistencies: [TranscriptionInconsistency]
    ) -> SessionTranscriptionStatus {
        if manifest.chunks.isEmpty {
            return .zeroChunkSession
        }

        let blocking = blockingReasons(from: inconsistencies)
        if !blocking.isEmpty {
            return .blocked(reasons: blocking)
        }

        if isCompletionValid(manifest: manifest, jobs: jobs, results: results) {
            return .completed
        }

        if inconsistencies.contains(where: {
            if case .resultDurabilityUnconfirmed = $0 { return true }
            return false
        }) {
            return .recoveryPending
        }

        var jobsBySequence: [Int: TranscriptionJob] = [:]
        for job in jobs {
            jobsBySequence[job.source.chunkSequenceNumber] = job
        }

        guard !jobsBySequence.isEmpty else {
            return .notTranscribed
        }

        if jobsBySequence.values.contains(where: { $0.state == .running }) {
            let retryable = jobsBySequence.values
                .filter { $0.state == .failed && $0.lastFailure?.retryDisposition == .retryable }
                .map(\.source.chunkSequenceNumber)
                .sorted()
            return .interrupted(retryableSequenceNumbers: retryable)
        }

        let completedCount = jobsBySequence.values.filter { $0.state == .completed }.count
        return .incomplete(completed: completedCount, total: manifest.chunks.count)
    }

    /// `TranscriptionInconsistency` cases that represent a genuine
    /// integrity blocker recovery cannot resolve on its own.
    /// `.resultDurabilityUnconfirmed` and `.abandonedRunningAttemptWithoutResult`
    /// are deliberately excluded — both describe conditions
    /// `reconcileState`/an explicit recovery action can and does resolve
    /// (surfaced instead as `.recoveryPending` / `.interrupted`).
    private static func blockingReasons(from inconsistencies: [TranscriptionInconsistency]) -> [String] {
        inconsistencies.compactMap { inconsistency -> String? in
            switch inconsistency {
            case .resultDurabilityUnconfirmed, .abandonedRunningAttemptWithoutResult:
                return nil
            default:
                return inconsistency.t4DiagnosticDescription
            }
        }
    }
}

nonisolated extension TranscriptionInconsistency {
    /// A human-readable diagnostic string, shared by the classifier's
    /// blocking-reason derivation and `SessionArtifactPreflight`'s own
    /// findings, so the two never develop diverging descriptions for the
    /// same underlying inconsistency.
    var t4DiagnosticDescription: String {
        switch self {
        case .corruptJob(let sequenceNumber, let message):
            return "Chunk #\(sequenceNumber): corrupt job artifact (\(message))"
        case .unsupportedJobSchema(let sequenceNumber, let version):
            return "Chunk #\(sequenceNumber): unsupported job schema version \(version)"
        case .corruptResult(let sequenceNumber, let message):
            return "Chunk #\(sequenceNumber): corrupt result artifact (\(message))"
        case .unsupportedResultSchema(let sequenceNumber, let version):
            return "Chunk #\(sequenceNumber): unsupported result schema version \(version)"
        case .orphanedResult(let sequenceNumber):
            return "Chunk #\(sequenceNumber): result exists with no matching job"
        case .completedJobMissingResult(let sequenceNumber):
            return "Chunk #\(sequenceNumber): completed job is missing its result"
        case .jobResultIdentityMismatch(let sequenceNumber):
            return "Chunk #\(sequenceNumber): job/result identity mismatch"
        case .resultAttemptMismatch(let sequenceNumber):
            return "Chunk #\(sequenceNumber): result does not match the job's current attempt"
        case .resultWithNonTerminalJob(let sequenceNumber, let jobState):
            return "Chunk #\(sequenceNumber): result exists but job is \(jobState.rawValue)"
        case .abandonedRunningAttemptWithoutResult(let sequenceNumber):
            return "Chunk #\(sequenceNumber): job was left running with no active owner"
        case .resultDurabilityUnconfirmed(let sequenceNumber):
            return "Chunk #\(sequenceNumber): result durability could not be reconfirmed"
        }
    }
}
