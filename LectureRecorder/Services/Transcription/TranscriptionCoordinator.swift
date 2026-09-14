import Foundation

/// Every error `TranscriptionCoordinator`'s public operations can throw
/// that is not itself a durable `TranscriptionFailure` (those are recorded
/// on the job, not thrown).
nonisolated enum TranscriptionCoordinatorError: LocalizedError, Sendable, Equatable {
    /// This coordinator instance already has an active, unreleased attempt
    /// for this `(sessionID, sequenceNumber)` — refused rather than
    /// allowed to race, since the actor is reentrant across the `await`
    /// inside `Transcribing.transcribe`.
    case alreadyClaimedByThisCoordinator(sequenceNumber: Int)
    case jobNotFound(sequenceNumber: Int)
    case jobNotClaimable(sequenceNumber: Int, state: TranscriptionJobState)
    /// The job moved past the attempt this caller believed it still owned
    /// (e.g. reconciliation already reclassified it) before this call
    /// could complete/fail it.
    case attemptSuperseded(sequenceNumber: Int)
    case sourceMissing(sequenceNumber: Int)
    /// The result was exclusively committed (it is real and readable) but
    /// its containing-directory sync could not be confirmed. The job is
    /// deliberately left `.running`, not marked completed or failed —
    /// reconciliation resolves this later. See
    /// `ExclusiveCreateOutcome.createdDurabilityUncertain`.
    case commitDurabilityUncertain(sequenceNumber: Int)
    case retryNotEligible(sequenceNumber: Int)

    var errorDescription: String? {
        switch self {
        case .alreadyClaimedByThisCoordinator(let seq):
            return "Chunk #\(seq) already has an active attempt on this coordinator instance."
        case .jobNotFound(let seq):
            return "No transcription job exists for chunk #\(seq)."
        case .jobNotClaimable(let seq, let state):
            return "Chunk #\(seq)'s job is \(state.rawValue), not queued; it cannot be claimed."
        case .attemptSuperseded(let seq):
            return "Chunk #\(seq)'s attempt was superseded before this operation could complete."
        case .sourceMissing(let seq):
            return "Chunk #\(seq)'s source audio file is missing."
        case .commitDurabilityUncertain(let seq):
            return "Chunk #\(seq)'s result was committed but directory durability could not be confirmed; left running for reconciliation."
        case .retryNotEligible(let seq):
            return "Chunk #\(seq)'s job is not an eligible, retryable failure."
        }
    }
}

/// The outcome of one `enqueueEligibleChunks` call, reporting what
/// happened to every chunk in the manifest, by sequence number.
nonisolated struct EnqueueReport: Sendable, Equatable {
    var created: [Int] = []
    var alreadyExisted: [Int] = []
    var inconsistent: [Int] = []
}

/// The outcome of one `reconcileState` call: the full, reconciled set of
/// jobs plus every per-artifact inconsistency found along the way. Never
/// throws on an individual damaged artifact — see
/// `TranscriptionStoring.loadAllJobArtifacts`/`loadAllResultArtifacts`.
nonisolated struct ReconciliationReport: Sendable {
    var jobs: [TranscriptionJob]
    var inconsistencies: [TranscriptionInconsistency]
}

/// Orchestrates T1's transcription lifecycle for one already-`.completed`
/// session: idempotent enqueue, single-owning `processJob` lifecycle,
/// explicit retry, and partial-tolerant reconciliation. Consumes
/// `TranscriptionStoring`/`Transcribing` only — never touches
/// `AtomicFileWriter`, `ExclusiveArtifactFileSystem`, or `FileManager`
/// directly.
///
/// ## Single-owner assumption
/// T1 supports exactly one `TranscriptionCoordinator` instance actively
/// operating on a given session's transcription state at a time within one
/// running process. Two coordinator instances (or two processes)
/// concurrently processing the *same* session's chunks is unsupported —
/// there is no distributed lock. The persisted `attemptID` and the store's
/// exclusive-write/identity validations still reject a stale or superseded
/// completion even under that unsupported condition; they are not
/// sufficient to make concurrent multi-owner writing safe or correct.
///
/// ## Actor reentrancy
/// `Transcribing.transcribe` is `async`, so this actor is reentrant across
/// that `await` — declaring it an actor does not by itself serialize two
/// calls processing the same job. Two calls each awaiting a *different*
/// suspending call (e.g. `store.loadJob`) can both be in flight on this
/// actor at once, so a guard that only checks an in-memory set before its
/// *own* first suspension is not enough — the reservation into that set
/// must itself land before that first suspension, or a second call can
/// still observe the set as empty. `claimJob` reserves its
/// `activeAttempts` key synchronously, immediately after the "already
/// claimed" check and before the first `await` in its body
/// (`store.loadJob`), and releases that reservation on every failure path
/// via a single `do`/`catch` wrapping the rest of the function.
/// `processJob` then owns the reservation for the remainder of the
/// attempt and releases it unconditionally via `defer`. See `claimJob`
/// and `processJob`.
actor TranscriptionCoordinator {
    private let store: any TranscriptionStoring
    private let transcriber: any Transcribing
    private let now: @Sendable () -> Date
    private let makeAttemptID: @Sendable () -> UUID

    /// Attempts this coordinator instance is currently, actively working
    /// on. Never persisted — a fresh instance always starts empty, which
    /// is exactly what makes `reconcileState` able to correctly recognize
    /// abandoned `.running` work left by a crashed or restarted process.
    private var activeAttempts: Set<TranscriptionAttemptKey> = []

    init(
        store: any TranscriptionStoring,
        transcriber: any Transcribing,
        now: @escaping @Sendable () -> Date = Date.init,
        makeAttemptID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.store = store
        self.transcriber = transcriber
        self.now = now
        self.makeAttemptID = makeAttemptID
    }

    // MARK: - Enqueue

    /// Idempotently creates exactly one durable job for every chunk in
    /// `manifest.chunks`: `.queued` if its source `.caf` file is present,
    /// or `.failed(.sourceMissing, .retryable)` otherwise — a missing
    /// source is never silently skipped, and one missing chunk never
    /// prevents jobs for the other chunks from being created. An existing
    /// job (in any state) is never touched by a repeat call.
    @discardableResult
    func enqueueEligibleChunks(
        manifest: SessionManifest,
        sessionPaths: SessionPaths
    ) async throws -> EnqueueReport {
        let paths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: paths)

        var report = EnqueueReport()

        for chunk in manifest.chunks.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            let source = TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID,
                chunkSequenceNumber: chunk.sequenceNumber,
                chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount,
                startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds,
                audioFormat: manifest.audioFormat
            )

            let sourceExists = FileManager.default.fileExists(atPath: paths.chunkAudioURL(fileName: chunk.fileName).path)
            let candidate = sourceExists
                ? TranscriptionJob.newQueued(source: source, now: now())
                : TranscriptionJob.newSourceMissing(source: source, now: now())

            let outcome = try await store.createJobIfAbsent(candidate, paths: paths)
            switch outcome {
            case .created:
                report.created.append(chunk.sequenceNumber)
            case .alreadyExistsValid:
                report.alreadyExisted.append(chunk.sequenceNumber)
            case .alreadyExistsInconsistent:
                report.inconsistent.append(chunk.sequenceNumber)
            }
        }

        return report
    }

    // MARK: - Public processing lifecycle

    /// Owns one job's entire processing lifecycle end to end: claim
    /// (queued → running, with source revalidation and a fresh attempt
    /// ID), invoke the transcriber, observe cancellation, commit or
    /// reconcile the result, and transition to completed or failed —
    /// releasing this coordinator's in-memory attempt ownership
    /// unconditionally via `defer`. This is the only entry point ordinary
    /// callers should use; `claimJob`/`completeJob`/`failJob` remain
    /// separately callable for focused tests, but a caller cannot strand a
    /// claim on this instance merely by forgetting a follow-up call to
    /// `processJob` itself, since claiming and releasing both happen
    /// inside this one function.
    func processJob(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptionJob {
        let claimed = try await claimJob(sequenceNumber: sequenceNumber, paths: paths)
        let key = TranscriptionAttemptKey(sessionID: paths.sessionID, chunkSequenceNumber: sequenceNumber)

        guard let attemptID = claimed.currentAttemptID else {
            activeAttempts.remove(key)
            throw TranscriptionCoordinatorError.attemptSuperseded(sequenceNumber: sequenceNumber)
        }

        defer { activeAttempts.remove(key) }

        let audioURL = paths.chunkAudioURL(fileName: claimed.source.chunkFileName)

        do {
            let output = try await transcriber.transcribe(audioURL: audioURL, source: claimed.source)
            return try await completeJob(
                sequenceNumber: sequenceNumber,
                attemptID: attemptID,
                output: output,
                paths: paths
            )
        } catch is CancellationError {
            _ = try? await failJob(
                sequenceNumber: sequenceNumber,
                attemptID: attemptID,
                failure: TranscriptionFailure(
                    category: .cancellation,
                    message: "Processing was cancelled.",
                    retryDisposition: .retryable,
                    failureDate: now(),
                    attemptNumber: claimed.attemptCount
                ),
                paths: paths
            )
            throw CancellationError()
        } catch let engineFailure as TranscriptionEngineFailing {
            return try await failJob(
                sequenceNumber: sequenceNumber,
                attemptID: attemptID,
                failure: TranscriptionFailure(
                    category: engineFailure.category,
                    message: engineFailure.diagnosticMessage,
                    retryDisposition: engineFailure.retryDisposition,
                    failureDate: now(),
                    attemptNumber: claimed.attemptCount
                ),
                paths: paths
            )
        } catch TranscriptionCoordinatorError.commitDurabilityUncertain(let seq) {
            // The job was deliberately left .running by completeJob;
            // propagate as-is rather than reclassifying it here.
            throw TranscriptionCoordinatorError.commitDurabilityUncertain(sequenceNumber: seq)
        } catch {
            // An Error that does not conform to TranscriptionEngineFailing
            // is mapped conservatively: .unknown category, .permanent
            // disposition. Only `message` (diagnostic-only) is derived
            // from the arbitrary error; category/disposition never are.
            return try await failJob(
                sequenceNumber: sequenceNumber,
                attemptID: attemptID,
                failure: TranscriptionFailure(
                    category: .unknown,
                    message: String(describing: error),
                    retryDisposition: .permanent,
                    failureDate: now(),
                    attemptNumber: claimed.attemptCount
                ),
                paths: paths
            )
        }
    }

    /// Moves an eligible `.failed(.retryable)` job back to `.queued`.
    /// Never invoked implicitly by `enqueueEligibleChunks` or
    /// reconciliation — the only way a failed job becomes retryable again.
    @discardableResult
    func retryJob(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptionJob {
        guard let job = try await store.loadJob(sequenceNumber: sequenceNumber, paths: paths) else {
            throw TranscriptionCoordinatorError.jobNotFound(sequenceNumber: sequenceNumber)
        }
        guard job.state == .failed, job.lastFailure?.retryDisposition == .retryable else {
            throw TranscriptionCoordinatorError.retryNotEligible(sequenceNumber: sequenceNumber)
        }

        var queued = job
        queued.state = .queued
        queued.currentAttemptID = nil
        queued.updatedDate = now()
        try await store.replaceJob(queued, paths: paths)
        return queued
    }

    // MARK: - Internal lifecycle helpers (also directly testable)

    /// Transitions a `.queued` job to `.running` with a fresh attempt ID,
    /// after revalidating that its source `.caf` file is still present.
    ///
    /// Guards concurrent same-instance claims via `activeAttempts`. The
    /// key is both *checked* and *reserved* (inserted) synchronously,
    /// before the first `await` in this function (`store.loadJob`) — not
    /// just checked. Reserving first, rather than only checking first,
    /// closes the reentrancy window across that suspension: a second call
    /// arriving while this one is suspended inside `store.loadJob` (or any
    /// later `await` in this function) must see the key already present.
    /// Every exit after the reservation — `jobNotFound`, `jobNotClaimable`,
    /// `sourceMissing`, a `replaceJob` failure, or any other error — rolls
    /// the reservation back via the single `do`/`catch` below, so a failed
    /// claim never leaks ownership. Only a *successful* claim leaves the
    /// key reserved, handing ownership to `processJob`'s own `defer`.
    func claimJob(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptionJob {
        let key = TranscriptionAttemptKey(sessionID: paths.sessionID, chunkSequenceNumber: sequenceNumber)
        guard !activeAttempts.contains(key) else {
            throw TranscriptionCoordinatorError.alreadyClaimedByThisCoordinator(sequenceNumber: sequenceNumber)
        }
        activeAttempts.insert(key)

        do {
            guard let job = try await store.loadJob(sequenceNumber: sequenceNumber, paths: paths) else {
                throw TranscriptionCoordinatorError.jobNotFound(sequenceNumber: sequenceNumber)
            }
            guard job.state == .queued else {
                throw TranscriptionCoordinatorError.jobNotClaimable(sequenceNumber: sequenceNumber, state: job.state)
            }

            let audioURL = paths.chunkAudioURL(fileName: job.source.chunkFileName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                var missing = job
                missing.state = .failed
                missing.currentAttemptID = nil
                missing.lastFailure = TranscriptionFailure(
                    category: .sourceMissing,
                    message: "Source audio file \(job.source.chunkFileName) was not found before claiming.",
                    retryDisposition: .retryable,
                    failureDate: now(),
                    attemptNumber: job.attemptCount
                )
                missing.updatedDate = now()
                try await store.replaceJob(missing, paths: paths)
                throw TranscriptionCoordinatorError.sourceMissing(sequenceNumber: sequenceNumber)
            }

            var running = job
            running.state = .running
            running.currentAttemptID = makeAttemptID()
            running.attemptCount += 1
            running.updatedDate = now()
            try await store.replaceJob(running, paths: paths)
            return running
        } catch {
            activeAttempts.remove(key)
            throw error
        }
    }

    /// Commits `output` as an immutable result and transitions the job to
    /// `.completed`, only if `attemptID` still matches the durably-loaded
    /// job's `currentAttemptID`. On `.committed`, this commit's own
    /// containing-directory sync already succeeded, so the completed-job
    /// transition proceeds immediately. On `.alreadyCommittedIdentical`,
    /// the canonical result already existed and validates as identical —
    /// but that alone is not fresh evidence that an *earlier* durability
    /// uncertainty for this directory has since been resolved, so
    /// `store.confirmResultsDirectoryDurable` is required first; only on
    /// success does the completed-job transition proceed, and on failure
    /// or a thrown error the job is left exactly as loaded (`.running`,
    /// same `currentAttemptID`) with
    /// `TranscriptionCoordinatorError.commitDurabilityUncertain` thrown —
    /// the canonical result is never rewritten, replaced, or deleted, and
    /// the job is never marked failed or re-transcribed. On
    /// `.committedDurabilityUncertain`, the job is likewise deliberately
    /// left `.running` and `commitDurabilityUncertain` is thrown. On
    /// `.conflict`/`.integrityError`, the job is transitioned to `.failed`
    /// via `failJob` with the corresponding category and a `.permanent`
    /// disposition.
    @discardableResult
    func completeJob(
        sequenceNumber: Int,
        attemptID: UUID,
        output: TranscriptionEngineOutput,
        paths: TranscriptionArtifactPaths
    ) async throws -> TranscriptionJob {
        guard
            let job = try await store.loadJob(sequenceNumber: sequenceNumber, paths: paths),
            job.state == .running,
            job.currentAttemptID == attemptID
        else {
            throw TranscriptionCoordinatorError.attemptSuperseded(sequenceNumber: sequenceNumber)
        }

        let result = TranscriptResult(
            schemaVersion: TranscriptResult.schemaVersion(for: output),
            source: job.source,
            output: output,
            attemptID: attemptID,
            completedDate: now()
        )

        let outcome = try await store.commitResult(result, paths: paths)

        switch outcome {
        case .committed:
            return try await transitionToCompleted(job: job, sequenceNumber: sequenceNumber, paths: paths)
        case .alreadyCommittedIdentical:
            // Readable-and-identical is exactly what a result originally
            // committed as `.committedDurabilityUncertain` also satisfies
            // — so, just like `TranscriptionCoordinator.reconcileState`,
            // fresh directory-durability evidence is required before this
            // is treated as permission to complete the job, not the mere
            // existence of a matching result.
            let durabilityConfirmed = (try? await store.confirmResultsDirectoryDurable(paths: paths)) ?? false
            guard durabilityConfirmed else {
                throw TranscriptionCoordinatorError.commitDurabilityUncertain(sequenceNumber: sequenceNumber)
            }
            return try await transitionToCompleted(job: job, sequenceNumber: sequenceNumber, paths: paths)
        case .committedDurabilityUncertain:
            throw TranscriptionCoordinatorError.commitDurabilityUncertain(sequenceNumber: sequenceNumber)
        case .conflict:
            return try await failJob(
                sequenceNumber: sequenceNumber,
                attemptID: attemptID,
                failure: TranscriptionFailure(
                    category: .resultCommitConflict,
                    message: "A different result already exists for this chunk.",
                    retryDisposition: .permanent,
                    failureDate: now(),
                    attemptNumber: job.attemptCount
                ),
                paths: paths
            )
        case .integrityError(let message):
            return try await failJob(
                sequenceNumber: sequenceNumber,
                attemptID: attemptID,
                failure: TranscriptionFailure(
                    category: .resultCommitIntegrityError,
                    message: message,
                    retryDisposition: .permanent,
                    failureDate: now(),
                    attemptNumber: job.attemptCount
                ),
                paths: paths
            )
        }
    }

    /// Shared completed-job write for `completeJob`'s two success paths
    /// (`.committed` and, once durability is confirmed,
    /// `.alreadyCommittedIdentical`). `job` must already be the durably-
    /// loaded `.running` job this attempt owns; this function only
    /// performs the state transition and its durable write.
    private func transitionToCompleted(
        job: TranscriptionJob,
        sequenceNumber: Int,
        paths: TranscriptionArtifactPaths
    ) async throws -> TranscriptionJob {
        var completed = job
        completed.state = .completed
        completed.currentAttemptID = nil
        completed.updatedDate = now()
        do {
            try await store.replaceJob(completed, paths: paths)
        } catch {
            // The result is already durably committed at this point (or
            // was already durably committed and its directory durability
            // has just been freshly reconfirmed). A failure persisting
            // the job's own completed-state transition must not be
            // reclassified as a transcription failure by processJob's
            // generic catch-all — that would silently orphan an
            // already-successful result behind a job marked
            // `.failed(.unknown, .permanent)`. Leave the job exactly as
            // reconciliation expects to find it — `.running` with this
            // attempt still current — by surfacing the same
            // durability-uncertain signal used for the sibling
            // filesystem-level outcomes in `completeJob`.
            throw TranscriptionCoordinatorError.commitDurabilityUncertain(sequenceNumber: sequenceNumber)
        }
        return completed
    }

    /// Transitions a `.running` job to `.failed`, only if `attemptID`
    /// still matches the durably-loaded job's `currentAttemptID`.
    @discardableResult
    func failJob(
        sequenceNumber: Int,
        attemptID: UUID,
        failure: TranscriptionFailure,
        paths: TranscriptionArtifactPaths
    ) async throws -> TranscriptionJob {
        guard
            let job = try await store.loadJob(sequenceNumber: sequenceNumber, paths: paths),
            job.state == .running,
            job.currentAttemptID == attemptID
        else {
            throw TranscriptionCoordinatorError.attemptSuperseded(sequenceNumber: sequenceNumber)
        }

        var failed = job
        failed.state = .failed
        failed.currentAttemptID = nil
        failed.lastFailure = failure
        failed.updatedDate = now()
        try await store.replaceJob(failed, paths: paths)
        return failed
    }

    // MARK: - Reconciliation

    /// Partial-tolerant reconciliation: enumerates every discoverable job
    /// and result artifact independently, never aborting the whole pass
    /// because one file is corrupt or an unsupported schema version.
    /// Reclassifies `.running` jobs this instance does not itself own
    /// (`activeAttempts`) as either `.completed` (a matching, attempt-ID-
    /// consistent result already exists *and* fresh results-directory
    /// durability re-confirmation succeeds — see below), `.failed(.abandonedRunningAttempt,
    /// .retryable)` (no such result), or left exactly as `.running` (a
    /// matching result exists but durability re-confirmation still fails;
    /// reported as `.resultDurabilityUnconfirmed`, not completed and not
    /// failed). A `.running` job is never promoted to `.completed` merely
    /// because its result is readable and attempt-matching: that
    /// readability alone is exactly what a result committed with
    /// `.committedDurabilityUncertain` already satisfies, and promoting on
    /// that basis alone would present a session as Completed while a known
    /// publication-durability uncertainty remained unresolved. The
    /// re-confirmation call is made at most once per `reconcileState`
    /// invocation (all `.running` candidates in one session share the same
    /// `resultsDirectory`) and never mutates or re-transcribes anything —
    /// it only gates whether the job's own completed-state transition and
    /// write, below, is allowed to proceed.
    /// Never auto-completes a `.queued`/`.failed` job just because an old,
    /// superseded-attempt result file happens to exist for it — that is
    /// reported as `.resultWithNonTerminalJob` instead. Never deletes,
    /// overwrites, or otherwise repairs any artifact; every finding it
    /// cannot safely resolve is reported as a `TranscriptionInconsistency`,
    /// not fixed.
    func reconcileState(paths: TranscriptionArtifactPaths) async throws -> ReconciliationReport {
        var inconsistencies: [TranscriptionInconsistency] = []

        var jobsBySequence: [Int: TranscriptionJob] = [:]
        for loadResult in try await store.loadAllJobArtifacts(paths: paths) {
            switch loadResult {
            case .success(let seq, let job):
                jobsBySequence[seq] = job
            case .failure(_, let inconsistency):
                inconsistencies.append(inconsistency)
            }
        }

        var resultsBySequence: [Int: TranscriptResult] = [:]
        for loadResult in try await store.loadAllResultArtifacts(paths: paths) {
            switch loadResult {
            case .success(let seq, let value):
                resultsBySequence[seq] = value
            case .failure(_, let inconsistency):
                inconsistencies.append(inconsistency)
            }
        }

        var reconciledJobs: [TranscriptionJob] = []
        // Computed at most once per call: every `.running` candidate below
        // shares the same session `resultsDirectory`, so one fresh
        // re-confirmation is sufficient evidence for all of them. A thrown
        // error is treated the same as an unconfirmed sync (`false`) rather
        // than aborting this partial-tolerant pass.
        var resultsDirectoryDurabilityConfirmed: Bool?

        for sequenceNumber in jobsBySequence.keys.sorted() {
            let job = jobsBySequence[sequenceNumber]!
            let key = TranscriptionAttemptKey(sessionID: paths.sessionID, chunkSequenceNumber: sequenceNumber)
            let matchingResult = resultsBySequence[sequenceNumber]

            switch job.state {
            case .running where activeAttempts.contains(key):
                // Legitimately in-flight on this instance right now —
                // never reclassified by reconciliation.
                reconciledJobs.append(job)

            case .running:
                if let matchingResult, matchingResult.attemptID == job.currentAttemptID {
                    let durabilityConfirmed: Bool
                    if let cached = resultsDirectoryDurabilityConfirmed {
                        durabilityConfirmed = cached
                    } else {
                        durabilityConfirmed = (try? await store.confirmResultsDirectoryDurable(paths: paths)) ?? false
                        resultsDirectoryDurabilityConfirmed = durabilityConfirmed
                    }

                    guard durabilityConfirmed else {
                        // The result is real and attempt-matching, but
                        // fresh durability re-confirmation for its
                        // containing directory still fails. Leave the job
                        // exactly as-is — not completed, not failed. No
                        // inference is re-run and the immutable result is
                        // never touched; recovery-pending state is
                        // reported truthfully so a later reconciliation
                        // pass can retry once durability is restored.
                        inconsistencies.append(.resultDurabilityUnconfirmed(sequenceNumber: sequenceNumber))
                        reconciledJobs.append(job)
                        continue
                    }

                    var completed = job
                    completed.state = .completed
                    completed.currentAttemptID = nil
                    completed.updatedDate = now()
                    do {
                        try await store.replaceJob(completed, paths: paths)
                        reconciledJobs.append(completed)
                    } catch {
                        inconsistencies.append(.abandonedRunningAttemptWithoutResult(sequenceNumber: sequenceNumber))
                        reconciledJobs.append(job)
                    }
                } else {
                    if matchingResult != nil {
                        inconsistencies.append(.resultAttemptMismatch(sequenceNumber: sequenceNumber))
                    } else {
                        inconsistencies.append(.abandonedRunningAttemptWithoutResult(sequenceNumber: sequenceNumber))
                    }
                    var failed = job
                    failed.state = .failed
                    failed.currentAttemptID = nil
                    failed.lastFailure = TranscriptionFailure(
                        category: .abandonedRunningAttempt,
                        message: "Job was left running with no active owner during reconciliation.",
                        retryDisposition: .retryable,
                        failureDate: now(),
                        attemptNumber: job.attemptCount
                    )
                    failed.updatedDate = now()
                    do {
                        try await store.replaceJob(failed, paths: paths)
                        reconciledJobs.append(failed)
                    } catch {
                        reconciledJobs.append(job)
                    }
                }

            case .completed:
                reconciledJobs.append(job)
                if matchingResult == nil {
                    inconsistencies.append(.completedJobMissingResult(sequenceNumber: sequenceNumber))
                }

            case .queued, .failed:
                reconciledJobs.append(job)
                if matchingResult != nil {
                    inconsistencies.append(.resultWithNonTerminalJob(sequenceNumber: sequenceNumber, jobState: job.state))
                }
            }
        }

        for sequenceNumber in resultsBySequence.keys.sorted() where jobsBySequence[sequenceNumber] == nil {
            inconsistencies.append(.orphanedResult(sequenceNumber: sequenceNumber))
        }

        return ReconciliationReport(
            jobs: reconciledJobs.sorted { $0.source.chunkSequenceNumber < $1.source.chunkSequenceNumber },
            inconsistencies: inconsistencies
        )
    }

    // MARK: - Derived ordered view

    /// Pure, `nonisolated` — computed at read time from durable job/result
    /// state, never itself persisted. Sequence-ordered regardless of
    /// completion arrival order; a chunk with no job yet, or a completed
    /// job whose result is unexpectedly missing, is reported as `.missing`
    /// rather than silently omitted or shifting later text into its place.
    nonisolated func assembleOrderedTranscript(
        chunks: [ChunkMetadata],
        jobs: [TranscriptionJob],
        results: [TranscriptResult]
    ) -> [OrderedSegment] {
        var jobsBySequence: [Int: TranscriptionJob] = [:]
        for job in jobs {
            jobsBySequence[job.source.chunkSequenceNumber] = job
        }
        var resultsBySequence: [Int: TranscriptResult] = [:]
        for result in results {
            resultsBySequence[result.source.chunkSequenceNumber] = result
        }

        return chunks
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map { chunk in
                let sequenceNumber = chunk.sequenceNumber
                guard let job = jobsBySequence[sequenceNumber] else {
                    return OrderedSegment(sequenceNumber: sequenceNumber, state: .missing)
                }
                switch job.state {
                case .completed:
                    guard let result = resultsBySequence[sequenceNumber] else {
                        return OrderedSegment(sequenceNumber: sequenceNumber, state: .missing)
                    }
                    return OrderedSegment(sequenceNumber: sequenceNumber, state: .completed(text: result.output.text))
                case .failed:
                    guard let failure = job.lastFailure else {
                        return OrderedSegment(sequenceNumber: sequenceNumber, state: .missing)
                    }
                    return OrderedSegment(sequenceNumber: sequenceNumber, state: .failed(failure))
                case .queued, .running:
                    return OrderedSegment(sequenceNumber: sequenceNumber, state: .inProgress)
                }
            }
    }
}
