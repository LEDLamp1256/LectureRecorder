import Foundation

/// A finding reconciliation (or a single load) can report about one
/// artifact, without aborting processing of every other artifact in the
/// session. The original ten categories required by the approved plan,
/// plus one reconciliation-only addition: `resultDurabilityUnconfirmed`,
/// covering a `.running` job whose matching, attempt-consistent result is
/// readable but whose containing results directory could not be freshly
/// re-confirmed as durably synchronized — the job is deliberately left
/// `.running`, neither completed nor failed. See
/// `TranscriptionCoordinator.reconcileState`.
/// `jobResultIdentityMismatch` is used both for a single artifact whose
/// decoded identity doesn't match the path/context it was loaded from, and
/// for a job/result pair whose identities disagree with each other.
nonisolated enum TranscriptionInconsistency: Sendable, Equatable {
    case corruptJob(sequenceNumber: Int, message: String)
    case unsupportedJobSchema(sequenceNumber: Int, version: Int)
    case corruptResult(sequenceNumber: Int, message: String)
    case unsupportedResultSchema(sequenceNumber: Int, version: Int)
    case orphanedResult(sequenceNumber: Int)
    case completedJobMissingResult(sequenceNumber: Int)
    case jobResultIdentityMismatch(sequenceNumber: Int)
    case resultAttemptMismatch(sequenceNumber: Int)
    case resultWithNonTerminalJob(sequenceNumber: Int, jobState: TranscriptionJobState)
    case abandonedRunningAttemptWithoutResult(sequenceNumber: Int)
    case resultDurabilityUnconfirmed(sequenceNumber: Int)
}

/// The outcome of an exclusive, check-then-create-without-replace job
/// enqueue (see `TranscriptionStoring.createJobIfAbsent`).
nonisolated enum JobCreationOutcome: Sendable, Equatable {
    /// No job file previously existed; `job` was durably created.
    case created(TranscriptionJob)
    /// A job file already existed and decoded to a value matching the
    /// intended identity — treated as an idempotent no-op. The *existing*
    /// job (not the one passed in) is returned, since it — not the
    /// caller's freshly-constructed value — is the durable truth.
    case alreadyExistsValid(TranscriptionJob)
    /// A job file already existed but was malformed, an unsupported
    /// schema version, or identity-mismatched. Left completely untouched.
    case alreadyExistsInconsistent(TranscriptionInconsistency)
}

/// The outcome of an exclusive result commit (see
/// `TranscriptionStoring.commitResult`).
nonisolated enum ResultCommitOutcome: Sendable, Equatable {
    /// No result file previously existed; the result was durably
    /// committed, including a successful containing-directory sync.
    case committed
    /// A result file already existed and decoded to a value identical to
    /// the one being committed — idempotent success, not a conflict.
    case alreadyCommittedIdentical
    /// The result was exclusively renamed into place (it is real and
    /// readable right now) but the containing-directory sync failed. The
    /// caller must **not** treat this as `.committed` — see
    /// `TranscriptionCoordinator`'s handling, which leaves the owning job
    /// `.running` for reconciliation to resolve later rather than marking
    /// it `.completed` on unconfirmed durability.
    case committedDurabilityUncertain
    /// A result file already existed and decoded successfully, but its
    /// content differs from the one being committed. Never overwritten.
    case conflict(existing: TranscriptResult)
    /// A result file already existed but could not be decoded, or its
    /// identity did not match the result being committed. Never
    /// overwritten.
    case integrityError(String)
}

/// A single artifact's load outcome inside a bulk, partial-tolerant
/// enumeration (`loadAllJobArtifacts`/`loadAllResultArtifacts`): either the
/// decoded, identity- and schema-validated value, or a specific
/// `TranscriptionInconsistency` — never a thrown error that would abort
/// the rest of the enumeration.
nonisolated enum ArtifactLoadResult<Value: Sendable>: Sendable {
    case success(sequenceNumber: Int, value: Value)
    case failure(sequenceNumber: Int, inconsistency: TranscriptionInconsistency)
}

/// Errors from a *single-target* store operation (`loadJob`, `loadResult`,
/// `createJobIfAbsent`, `replaceJob`, `commitResult`) — as opposed to the
/// per-artifact `TranscriptionInconsistency` findings the bulk
/// `loadAll*Artifacts` operations report without throwing.
nonisolated enum TranscriptionStoreError: LocalizedError, Sendable {
    case identityMismatch(sequenceNumber: Int)
    case unsupportedSchemaVersion(sequenceNumber: Int, version: Int)
    case corrupt(sequenceNumber: Int, underlying: String)

    var errorDescription: String? {
        switch self {
        case .identityMismatch(let seq):
            return "Decoded artifact identity does not match expected sequence number \(seq)."
        case .unsupportedSchemaVersion(let seq, let version):
            return "Artifact for sequence \(seq) has unsupported schema version \(version)."
        case .corrupt(let seq, let underlying):
            return "Artifact for sequence \(seq) is corrupt: \(underlying)"
        }
    }
}

/// The full persistence boundary for T1's transcription state. Owns every
/// piece of I/O, path resolution, exclusivity, and schema/identity
/// validation described in the approved plan — `TranscriptionCoordinator`
/// consumes this protocol and never touches `AtomicFileWriter`,
/// `ExclusiveArtifactFileSystem`, or `FileManager` directly.
nonisolated protocol TranscriptionStoring: Sendable {
    func ensureDirectoriesExist(paths: TranscriptionArtifactPaths) async throws

    /// Loads and validates the job for `sequenceNumber`, or returns `nil`
    /// if no job file exists yet. Throws `TranscriptionStoreError` on a
    /// malformed, unsupported-schema, or identity-mismatched file — this
    /// single-target load is not required to be partial-tolerant (only
    /// bulk reconciliation is).
    func loadJob(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptionJob?

    /// Exclusively creates a job record if none exists yet for
    /// `job.source.chunkSequenceNumber`. Never replaces or overwrites an
    /// existing job file, valid or not.
    func createJobIfAbsent(_ job: TranscriptionJob, paths: TranscriptionArtifactPaths) async throws -> JobCreationOutcome

    /// Replaces an existing job record (a lifecycle-state transition).
    /// Callers must only ever call this for a job that
    /// `createJobIfAbsent`/`loadJob` has already confirmed exists.
    func replaceJob(_ job: TranscriptionJob, paths: TranscriptionArtifactPaths) async throws

    /// Loads and validates the result for `sequenceNumber`, or returns
    /// `nil` if none exists yet. Throws on malformed/unsupported-schema/
    /// identity-mismatched content.
    func loadResult(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptResult?

    /// Exclusively commits a result artifact. See `ResultCommitOutcome`
    /// for the full set of distinguishable outcomes; never overwrites an
    /// existing canonical result.
    func commitResult(_ result: TranscriptResult, paths: TranscriptionArtifactPaths) async throws -> ResultCommitOutcome

    /// Re-confirms, right now, that `paths.resultsDirectory` is itself
    /// durably synchronized — independent of any specific result file
    /// inside it. Used by reconciliation to obtain fresh durability
    /// evidence before promoting a `.running` job to `.completed` on the
    /// strength of an already-readable, attempt-matching result, rather
    /// than trusting stale evidence from whatever the original commit
    /// attempt observed. Returns `false` (never throws) for an ordinary
    /// sync failure; only a genuine I/O error establishing the directory
    /// itself (e.g. it cannot be created) is thrown.
    func confirmResultsDirectoryDurable(paths: TranscriptionArtifactPaths) async throws -> Bool

    /// Enumerates and independently validates every job artifact under
    /// `paths.jobsDirectory`. A malformed/unsupported-schema/identity-
    /// mismatched individual file is reported as a `.failure` entry, never
    /// thrown — one damaged file never prevents the rest from loading.
    func loadAllJobArtifacts(paths: TranscriptionArtifactPaths) async throws -> [ArtifactLoadResult<TranscriptionJob>]

    /// Same partial-tolerant contract as `loadAllJobArtifacts`, for
    /// results under `paths.resultsDirectory`.
    func loadAllResultArtifacts(paths: TranscriptionArtifactPaths) async throws -> [ArtifactLoadResult<TranscriptResult>]
}
