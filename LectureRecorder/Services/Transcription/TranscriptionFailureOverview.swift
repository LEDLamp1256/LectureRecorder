import Foundation

/// One failed transcription part, reduced to the structured facts the UI
/// may present. Deliberately carries no `TranscriptionFailure.message`, no
/// path, and no engine/worker text — only the closed category/disposition
/// enums and what each explicit action would do with this part.
nonisolated struct TranscriptionFailedPart: Equatable, Sendable {
    /// Zero-based chunk sequence number (as persisted).
    let sequenceNumber: Int
    /// `nil` only for a failed job with no recorded failure, which no
    /// current coordinator path produces.
    let category: TranscriptionFailureCategory?
    let retryDisposition: RetryDisposition?

    /// Whether Continue's automatic policy would requeue this part —
    /// exactly `TranscriptionCoordinator.retryJob`'s own eligibility rule.
    var isAutomaticallyRetryable: Bool { retryDisposition == .retryable }

    /// Whether the explicit "Try Failed Parts Again" action would requeue
    /// this part — `TranscriptionCoordinator.retryPermanentlyFailedJob`'s
    /// eligibility rule. An overview is only ever built from an unblocked
    /// preflight, which already rejects any failed job with a result.
    var isEligibleForManualRetry: Bool { retryDisposition == .permanent }
}

/// A read-only summary of an incomplete session's failed parts and whether
/// Continue still has any automatic work to do. Built from the same
/// unblocked `SessionArtifactPreflight` snapshot `peekStatus` uses; never
/// itself persisted.
nonisolated struct TranscriptionFailureOverview: Equatable, Sendable {
    /// Every `.failed` job, in sequence order.
    let failedParts: [TranscriptionFailedPart]
    /// `true` when Continue would find anything to do under its unchanged
    /// automatic policy: a queued or running job, a retryable failure, or a
    /// manifest chunk with no job yet.
    let hasAutomaticWork: Bool

    var hasManualRetryEligibleParts: Bool {
        failedParts.contains { $0.isEligibleForManualRetry }
    }

    /// Pure: derives the overview from already-loaded durable state. A
    /// failed job with any result next to it is never offered for either
    /// retry (callers only reach here after preflight rejected that state
    /// as blocking; this is kept as defense in depth).
    static func make(
        manifest: SessionManifest,
        jobs: [TranscriptionJob],
        results: [TranscriptResult]
    ) -> TranscriptionFailureOverview {
        var jobsBySequence: [Int: TranscriptionJob] = [:]
        for job in jobs {
            jobsBySequence[job.source.chunkSequenceNumber] = job
        }
        let resultSequences = Set(results.map(\.source.chunkSequenceNumber))

        var failedParts: [TranscriptionFailedPart] = []
        var hasAutomaticWork = false

        for chunk in manifest.chunks.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            guard let job = jobsBySequence[chunk.sequenceNumber] else {
                hasAutomaticWork = true
                continue
            }
            switch job.state {
            case .queued, .running:
                hasAutomaticWork = true
            case .completed:
                break
            case .failed:
                let hasResult = resultSequences.contains(chunk.sequenceNumber)
                let disposition = hasResult ? nil : job.lastFailure?.retryDisposition
                if disposition == .retryable { hasAutomaticWork = true }
                failedParts.append(TranscriptionFailedPart(
                    sequenceNumber: chunk.sequenceNumber,
                    category: job.lastFailure?.category,
                    retryDisposition: disposition
                ))
            }
        }

        return TranscriptionFailureOverview(failedParts: failedParts, hasAutomaticWork: hasAutomaticWork)
    }
}
