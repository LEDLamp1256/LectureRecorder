import Foundation

/// Durable lifecycle state of one transcription job. See
/// `TranscriptionCoordinator` for the complete, exhaustive set of allowed
/// transitions between these states — nothing outside that type is
/// permitted to move a job between states.
nonisolated enum TranscriptionJobState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case completed
    case failed
}

/// Whether a failed job's condition is worth retrying. This is a property
/// of the *failure*, not a separate job-lifecycle stage — a job is equally
/// "failed" either way; only whether an explicit retry is worth attempting
/// differs.
nonisolated enum RetryDisposition: String, Codable, Equatable, Sendable {
    case retryable
    case permanent
}

/// A stable, closed classification for why a transcription attempt failed.
/// Never derived from an arbitrary Swift `Error` type's name — only these
/// known categories are ever persisted, so the durable contract never
/// depends on implementation details of whatever `Error` a transcriber
/// happened to throw.
nonisolated enum TranscriptionFailureCategory: String, Codable, Equatable, Sendable {
    /// The transcriber conformed to `TranscriptionEngineFailing` and
    /// reported a failure through that protocol.
    case engineThrew
    /// The processing `Task` was cancelled while `Transcribing.transcribe`
    /// was in flight.
    case cancellation
    /// A `.running` job was found, on reconciliation, with no coordinator
    /// instance actively holding its attempt — never set directly by a
    /// live attempt.
    case abandonedRunningAttempt
    /// The chunk's source `.caf` file was missing at enqueue time or at
    /// the start of a processing attempt.
    case sourceMissing
    /// A result commit found an existing, decodable, but *different*
    /// canonical result already in place.
    case resultCommitConflict
    /// A result commit found an existing canonical result that was
    /// malformed or whose identity did not match the job it was found
    /// under.
    case resultCommitIntegrityError
    /// The transcriber threw an `Error` that did not conform to
    /// `TranscriptionEngineFailing`. Mapped conservatively — see
    /// `TranscriptionCoordinator`'s catch-all handling.
    case unknown
}

/// A truthful, structured failure record. Replaces any free-form
/// "last error string" contract: `category`/`retryDisposition` are always
/// one of the closed enums above, never inferred from an arbitrary
/// `Error`'s type name. `message` is diagnostic-only and is never used to
/// drive behavior.
nonisolated struct TranscriptionFailure: Codable, Equatable, Sendable {
    var category: TranscriptionFailureCategory
    var message: String
    var retryDisposition: RetryDisposition
    var failureDate: Date
    var attemptNumber: Int
}

/// The immutable, per-chunk recording facts a transcription job/result is
/// scoped to — built directly from a `.completed` session's own
/// `SessionManifest`/`ChunkMetadata`/`AudioFormatDescriptor`, never
/// independently reconstructed. Detects metadata/path mismatch (the wrong
/// chunk being associated with a job, or a stale reference to a moved or
/// renamed session). Does **not** detect byte-level tampering or silent
/// corruption of the `.caf` file's actual audio content — a content
/// fingerprint (e.g. a hash) is deliberately deferred; if that is ever
/// needed, it can be added as a new optional field without breaking this
/// schema.
nonisolated struct TranscriptionSourceSnapshot: Codable, Equatable, Sendable {
    var sessionID: UUID
    var chunkSequenceNumber: Int
    var chunkFileName: String
    var frameCount: Int
    var startOffsetSeconds: Double
    var durationSeconds: Double
    var audioFormat: AudioFormatDescriptor
}

/// One reserved, additive timing segment within a transcript. Not produced
/// or consumed by anything in T1's fake transcriber; reserved purely so a
/// future real engine's segment-level output has somewhere to go without a
/// schema break.
nonisolated struct TranscriptionTimingSegment: Codable, Equatable, Sendable {
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}

/// The structured output of one transcription attempt, as reported by a
/// `Transcribing` conformer. `engineIdentifier`/`modelIdentifier` are
/// always taken verbatim from the transcriber — neither
/// `TranscriptionStore` nor `TranscriptionCoordinator` ever invents or
/// guesses engine identity.
nonisolated struct TranscriptionEngineOutput: Codable, Equatable, Sendable {
    var text: String
    var engineIdentifier: String
    var modelIdentifier: String?
    var language: String?
    var segments: [TranscriptionTimingSegment]?
    var engineVersion: String?
}

/// A durable, mutable-by-replacement job record for one chunk's
/// transcription. Identity is `(source.sessionID, source.chunkSequenceNumber)`
/// — there is no independent job UUID, matching how the rest of this
/// codebase identifies a chunk. `currentAttemptID` is set only while
/// `state == .running`; it is cleared on every terminal transition.
///
/// Persisted at `Sessions/<uuid>/transcription/jobs/chunk_%06d.job.json`.
nonisolated struct TranscriptionJob: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var source: TranscriptionSourceSnapshot
    var state: TranscriptionJobState
    var currentAttemptID: UUID?
    var attemptCount: Int
    var lastFailure: TranscriptionFailure?
    var createdDate: Date
    var updatedDate: Date

    static func newQueued(source: TranscriptionSourceSnapshot, now: Date) -> TranscriptionJob {
        TranscriptionJob(
            schemaVersion: currentSchemaVersion,
            source: source,
            state: .queued,
            currentAttemptID: nil,
            attemptCount: 0,
            lastFailure: nil,
            createdDate: now,
            updatedDate: now
        )
    }

    static func newSourceMissing(source: TranscriptionSourceSnapshot, now: Date) -> TranscriptionJob {
        TranscriptionJob(
            schemaVersion: currentSchemaVersion,
            source: source,
            state: .failed,
            currentAttemptID: nil,
            attemptCount: 0,
            lastFailure: TranscriptionFailure(
                category: .sourceMissing,
                message: "Source audio file \(source.chunkFileName) was not found at enqueue time.",
                retryDisposition: .retryable,
                failureDate: now,
                attemptNumber: 0
            ),
            createdDate: now,
            updatedDate: now
        )
    }
}

/// An immutable result artifact, committed exactly once per successful
/// attempt via an exclusive-create primitive (see
/// `ExclusiveArtifactFileSystem`). Once written, a `TranscriptResult` file
/// is never rewritten — the only lifecycle events are creation, or a
/// `.conflict`/`.alreadyCommittedIdentical` outcome on a repeat commit
/// attempt for the same identity.
///
/// Persisted at `Sessions/<uuid>/transcription/results/chunk_%06d.transcript.json`.
nonisolated struct TranscriptResult: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var source: TranscriptionSourceSnapshot
    var output: TranscriptionEngineOutput
    var attemptID: UUID
    var completedDate: Date
}

/// In-memory-only key identifying one attempt slot a `TranscriptionCoordinator`
/// instance may be actively working on. Never persisted.
nonisolated struct TranscriptionAttemptKey: Hashable, Sendable {
    var sessionID: UUID
    var chunkSequenceNumber: Int
}

/// One position in a derived, sequence-ordered view of a session's
/// transcription progress. Never persisted — always computed at read time
/// from durable job/result state by
/// `TranscriptionCoordinator.assembleOrderedTranscript`.
nonisolated struct OrderedSegment: Equatable, Sendable {
    nonisolated enum State: Equatable, Sendable {
        case completed(text: String)
        case failed(TranscriptionFailure)
        case inProgress
        case missing
    }

    var sequenceNumber: Int
    var state: State
}
