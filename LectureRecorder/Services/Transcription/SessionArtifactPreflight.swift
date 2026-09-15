import Foundation

/// The read-only outcome of `SessionArtifactPreflight.run`: every job/result
/// artifact this pass could safely load, plus every integrity problem found.
/// A nonempty `blockingReasons` means the caller must perform **zero**
/// mutating coordinator calls (no `reconcileState`, `retryJob`,
/// `enqueueEligibleChunks`, or `processJob`) for this operation.
nonisolated struct SessionArtifactPreflightReport: Sendable {
    var jobsBySequence: [Int: TranscriptionJob] = [:]
    var resultsBySequence: [Int: TranscriptResult] = [:]
    var blockingReasons: [String] = []
}

/// A read-only, non-mutating inspection pass that runs *before* the first
/// mutating `TranscriptionCoordinator` call (`reconcileState`, `retryJob`,
/// `enqueueEligibleChunks`, `processJob`). It never repairs, retries,
/// enqueues, replaces, or infers anything — it only proves whether it is
/// safe to let the existing coordinator's reconciliation/execution proceed
/// at all.
///
/// This does **not** reimplement `TranscriptionCoordinator.reconcileState`'s
/// durability-recovery algorithm. An ownerless `.running` job, or a
/// `.running` job with a matching-but-durability-unconfirmed result, is
/// deliberately treated as recoverable here (not a blocking finding) —
/// `reconcileState` still owns resolving those, exactly as before. Only
/// findings a "mutation phase" is not equipped to safely resolve on its own
/// are treated as blocking:
///
/// - an existing path component this session/operation would read is a
///   symlink or the wrong filesystem type (checked before any of those
///   paths are opened, so a symlink's target is never read or touched);
/// - a persisted job or result's full `TranscriptionSourceSnapshot` does not
///   exactly match the snapshot freshly derived from the current manifest
///   (a stale/foreign artifact must never be enqueued over, retried, or fed
///   to `processJob`, since the coordinator resolves the inference audio URL
///   from `job.source.chunkFileName`);
/// - a recognized job/result artifact's sequence number falls outside the
///   manifest's expected coverage, or is a duplicate;
/// - an orphaned result (no matching job) or a completed job missing its
///   result.
nonisolated enum SessionArtifactPreflight {
    static func run(
        manifest: SessionManifest,
        sessionPaths: SessionPaths,
        artifactPaths: TranscriptionArtifactPaths,
        store: any TranscriptionStoring
    ) async -> SessionArtifactPreflightReport {
        var reasons: [String] = []

        checkDirectoryIfPresent(sessionPaths.sessionDirectory, label: "Session directory", into: &reasons)
        checkFileIfPresent(sessionPaths.manifestURL, label: "session.json", into: &reasons)
        checkDirectoryIfPresent(sessionPaths.chunksDirectory, label: "Chunks directory", into: &reasons)
        checkDirectoryIfPresent(artifactPaths.transcriptionDirectory, label: "Transcription directory", into: &reasons)
        checkDirectoryIfPresent(artifactPaths.jobsDirectory, label: "Jobs directory", into: &reasons)
        checkDirectoryIfPresent(artifactPaths.resultsDirectory, label: "Results directory", into: &reasons)

        for chunk in manifest.chunks {
            checkFileIfPresent(
                artifactPaths.chunkAudioURL(fileName: chunk.fileName),
                label: "Chunk #\(chunk.sequenceNumber) source audio",
                into: &reasons
            )
            checkFileIfPresent(
                artifactPaths.jobURL(sequenceNumber: chunk.sequenceNumber),
                label: "Chunk #\(chunk.sequenceNumber) job artifact",
                into: &reasons
            )
            checkFileIfPresent(
                artifactPaths.resultURL(sequenceNumber: chunk.sequenceNumber),
                label: "Chunk #\(chunk.sequenceNumber) result artifact",
                into: &reasons
            )
        }

        // Beyond the expected-sequence canonical paths checked above, also
        // safety-check every *other* entry `store.loadAllJobArtifacts`/
        // `loadAllResultArtifacts` would otherwise enumerate and read next —
        // an unexpected recognized file (e.g. an out-of-range
        // `chunk_000099.job.json`) must be rejected before the store ever
        // opens it, not merely after its sequence is later found to be out
        // of coverage.
        checkAllDirectoryEntriesIfPresent(artifactPaths.jobsDirectory, label: "job artifact", into: &reasons)
        checkAllDirectoryEntriesIfPresent(artifactPaths.resultsDirectory, label: "result artifact", into: &reasons)

        // A symlink/wrong-type finding above means this pass must not read
        // through it — stop before any store call touches it.
        guard reasons.isEmpty else {
            return SessionArtifactPreflightReport(blockingReasons: reasons)
        }

        var jobsBySequence: [Int: TranscriptionJob] = [:]
        var resultsBySequence: [Int: TranscriptResult] = [:]
        let expectedSequences = Set(manifest.chunks.map(\.sequenceNumber))

        func expectedSource(for sequenceNumber: Int) -> TranscriptionSourceSnapshot? {
            guard let chunk = manifest.chunks.first(where: { $0.sequenceNumber == sequenceNumber }) else { return nil }
            return TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID,
                chunkSequenceNumber: chunk.sequenceNumber,
                chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount,
                startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds,
                audioFormat: manifest.audioFormat
            )
        }

        let jobLoads: [ArtifactLoadResult<TranscriptionJob>]
        do {
            jobLoads = try await store.loadAllJobArtifacts(paths: artifactPaths)
        } catch {
            reasons.append("Unable to enumerate transcription jobs: \(error.localizedDescription)")
            jobLoads = []
        }

        for entry in jobLoads {
            switch entry {
            case .failure(let sequenceNumber, let inconsistency):
                reasons.append("Chunk #\(sequenceNumber): \(inconsistency.t4DiagnosticDescription)")
            case .success(let sequenceNumber, let job):
                guard jobsBySequence[sequenceNumber] == nil else {
                    reasons.append("Chunk #\(sequenceNumber): duplicate job artifact detected")
                    continue
                }
                jobsBySequence[sequenceNumber] = job
                guard expectedSequences.contains(sequenceNumber), let expected = expectedSource(for: sequenceNumber) else {
                    reasons.append("Chunk #\(sequenceNumber): job artifact sequence is outside expected manifest coverage")
                    continue
                }
                if job.source != expected {
                    reasons.append("Chunk #\(sequenceNumber): job source snapshot does not match the current manifest")
                }
            }
        }

        let resultLoads: [ArtifactLoadResult<TranscriptResult>]
        do {
            resultLoads = try await store.loadAllResultArtifacts(paths: artifactPaths)
        } catch {
            reasons.append("Unable to enumerate transcription results: \(error.localizedDescription)")
            resultLoads = []
        }

        for entry in resultLoads {
            switch entry {
            case .failure(let sequenceNumber, let inconsistency):
                reasons.append("Chunk #\(sequenceNumber): \(inconsistency.t4DiagnosticDescription)")
            case .success(let sequenceNumber, let result):
                guard resultsBySequence[sequenceNumber] == nil else {
                    reasons.append("Chunk #\(sequenceNumber): duplicate result artifact detected")
                    continue
                }
                resultsBySequence[sequenceNumber] = result
                guard expectedSequences.contains(sequenceNumber), let expected = expectedSource(for: sequenceNumber) else {
                    reasons.append("Chunk #\(sequenceNumber): result artifact sequence is outside expected manifest coverage")
                    continue
                }
                if result.source != expected {
                    reasons.append("Chunk #\(sequenceNumber): result source snapshot does not match the current manifest")
                }
                if let job = jobsBySequence[sequenceNumber], job.source != result.source {
                    reasons.append("Chunk #\(sequenceNumber): job and result source snapshots disagree")
                }
            }
        }

        for sequenceNumber in resultsBySequence.keys where jobsBySequence[sequenceNumber] == nil {
            reasons.append("Chunk #\(sequenceNumber): result exists with no matching job")
        }
        for (sequenceNumber, job) in jobsBySequence where job.state == .completed && resultsBySequence[sequenceNumber] == nil {
            reasons.append("Chunk #\(sequenceNumber): completed job is missing its result")
        }

        // Job/result state-relationship validation: a result may only
        // coexist with a job that is `.running` (matching this exact
        // attempt) or `.completed` (already covered above). A `.queued` or
        // `.failed` job with any result at all is a genuine integrity
        // conflict a mutation phase must not paper over — `reconcileState`
        // must never be allowed to reinterpret an attempt-mismatched
        // running job as an ordinary abandoned attempt, and
        // `continueOrRetry` must never be allowed to retry a failed job
        // that already has an immutable result artifact sitting next to it.
        for (sequenceNumber, job) in jobsBySequence {
            guard let result = resultsBySequence[sequenceNumber] else { continue }
            switch job.state {
            case .running:
                if result.attemptID != job.currentAttemptID {
                    reasons.append("Chunk #\(sequenceNumber): result attempt does not match the job's current running attempt")
                }
            case .queued:
                reasons.append("Chunk #\(sequenceNumber): result exists for a job that is still queued")
            case .failed:
                reasons.append("Chunk #\(sequenceNumber): result exists for a failed job")
            case .completed:
                break // already validated above; a completed job never requires currentAttemptID.
            }
        }

        return SessionArtifactPreflightReport(
            jobsBySequence: jobsBySequence,
            resultsBySequence: resultsBySequence,
            blockingReasons: reasons
        )
    }

    private static func checkDirectoryIfPresent(_ url: URL, label: String, into reasons: inout [String]) {
        switch CompletedSessionPathSafety.checkExistingDirectory(url) {
        case .safe, .missing:
            break
        case .unsafe:
            reasons.append("\(label) is a symlink or not a directory.")
        }
    }

    private static func checkFileIfPresent(_ url: URL, label: String, into reasons: inout [String]) {
        switch CompletedSessionPathSafety.checkExistingRegularFile(url) {
        case .safe, .missing:
            break
        case .unsafe:
            reasons.append("\(label) is a symlink or not a regular file.")
        }
    }

    /// Read-only lists `directory` (a no-op if it does not exist yet —
    /// never created here) and rejects any entry that is a symlink or not
    /// a regular file, *before* `store.loadAllJobArtifacts`/
    /// `loadAllResultArtifacts` gets a chance to enumerate and read it.
    /// Never duplicates the store's own decoding/schema validation — this
    /// only proves it is safe to hand every entry to the store next.
    private static func checkAllDirectoryEntriesIfPresent(_ directory: URL, label: String, into reasons: inout [String]) {
        guard CompletedSessionPathSafety.checkExistingDirectory(directory) == .safe else {
            // Missing is fine (nothing enqueued yet); unsafe was already
            // reported by the directory-level check above.
            return
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            if CompletedSessionPathSafety.checkExistingRegularFile(entry) == .unsafe {
                reasons.append("\(label) \(entry.lastPathComponent) is a symlink or not a regular file.")
            }
        }
    }
}
