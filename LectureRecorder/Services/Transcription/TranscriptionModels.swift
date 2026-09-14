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

nonisolated enum TranscriptionSamplingStrategy: String, Codable, Equatable, Sendable {
    case greedy
}

nonisolated enum TranscriptionComputeBackend: String, Codable, Equatable, Sendable {
    case cpuAccelerate = "cpu-plus-accelerate"
}

nonisolated struct TranscriptionPrintingConfiguration: Codable, Equatable, Sendable {
    var printSpecial: Bool
    var printProgress: Bool
    var printRealtime: Bool
    var printTimestamps: Bool
}

nonisolated struct TranscriptionInferenceConfigurationProvenance: Codable, Equatable, Sendable {
    var identifier: String
    var samplingStrategy: TranscriptionSamplingStrategy
    var threadCount: Int
    var language: String
    var automaticLanguageDetectionEnabled: Bool
    var translationEnabled: Bool
    var previousTextContextEnabled: Bool
    var initialPromptUsed: Bool
    var segmentTimestampsEnabled: Bool
    var tokenTimestampsEnabled: Bool
    var singleSegmentModeEnabled: Bool
    var vadEnabled: Bool
    var diarizationEnabled: Bool
    var printing: TranscriptionPrintingConfiguration
    var computeBackend: TranscriptionComputeBackend
}

nonisolated struct TranscriptionWorkerProvenance: Codable, Equatable, Sendable {
    var identifier: String
    var version: String
}

nonisolated struct TranscriptionEngineProvenance: Codable, Equatable, Sendable {
    var identifier: String
    var version: String
    var sourceRevision: String
}

nonisolated struct TranscriptionModelProvenance: Codable, Equatable, Sendable {
    var identifier: String
    var filename: String
    var byteCount: UInt64
    var sha256: String
}

nonisolated enum TranscriptionProvenanceValidationError: LocalizedError, Sendable, Equatable {
    case empty(field: String)
    case oversized(field: String, maximumUTF8Bytes: Int)
    case invalidSourceRevision
    case invalidModelDigest
    case invalidModelByteCount
    case invalidThreadCount

    var errorDescription: String? {
        switch self {
        case .empty(let field): return "Transcription provenance field \(field) is empty."
        case .oversized(let field, let maximum): return "Transcription provenance field \(field) exceeds \(maximum) UTF-8 bytes."
        case .invalidSourceRevision: return "Transcription engine source revision must be 40 lowercase hexadecimal characters."
        case .invalidModelDigest: return "Transcription model SHA-256 must be 64 lowercase hexadecimal characters."
        case .invalidModelByteCount: return "Transcription model byte count must be greater than zero."
        case .invalidThreadCount: return "Transcription thread count must be between 1 and 64."
        }
    }
}

/// Structured, bounded provenance for schema-v2 transcript results. Schema-v1
/// results have no provenance; absence there means "not recorded", never a
/// fabricated approximation of these fields.
nonisolated struct TranscriptionProvenance: Codable, Equatable, Sendable {
    var worker: TranscriptionWorkerProvenance
    var engine: TranscriptionEngineProvenance
    var model: TranscriptionModelProvenance
    var configuration: TranscriptionInferenceConfigurationProvenance

    func validate() throws {
        try Self.requireBounded(worker.identifier, field: "worker.identifier", maximum: 128)
        try Self.requireBounded(worker.version, field: "worker.version", maximum: 64)
        try Self.requireBounded(engine.identifier, field: "engine.identifier", maximum: 128)
        try Self.requireBounded(engine.version, field: "engine.version", maximum: 64)
        try Self.requireBounded(model.identifier, field: "model.identifier", maximum: 128)
        try Self.requireBounded(model.filename, field: "model.filename", maximum: 255)
        try Self.requireBounded(configuration.identifier, field: "configuration.identifier", maximum: 128)
        try Self.requireBounded(configuration.language, field: "configuration.language", maximum: 32)

        guard Self.isLowercaseHex(engine.sourceRevision, exactCount: 40) else {
            throw TranscriptionProvenanceValidationError.invalidSourceRevision
        }
        guard Self.isLowercaseHex(model.sha256, exactCount: 64) else {
            throw TranscriptionProvenanceValidationError.invalidModelDigest
        }
        guard model.byteCount > 0 else {
            throw TranscriptionProvenanceValidationError.invalidModelByteCount
        }
        guard (1...64).contains(configuration.threadCount) else {
            throw TranscriptionProvenanceValidationError.invalidThreadCount
        }
    }

    private static func requireBounded(_ value: String, field: String, maximum: Int) throws {
        guard !value.isEmpty else { throw TranscriptionProvenanceValidationError.empty(field: field) }
        guard value.utf8.count <= maximum else {
            throw TranscriptionProvenanceValidationError.oversized(field: field, maximumUTF8Bytes: maximum)
        }
    }

    private static func isLowercaseHex(_ value: String, exactCount: Int) -> Bool {
        value.utf8.count == exactCount && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
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
    var provenance: TranscriptionProvenance? = nil
}

nonisolated enum TranscriptResultSchemaError: LocalizedError, Sendable, Equatable {
    case provenanceNotPermittedInV1
    case provenanceRequiredInV2
    case legacyIdentityContradictsProvenance(field: String)
    case invalidV2Language
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .provenanceNotPermittedInV1: return "Schema-v1 transcript results cannot contain provenance."
        case .provenanceRequiredInV2: return "Schema-v2 transcript results require complete structured provenance."
        case .legacyIdentityContradictsProvenance(let field):
            return "Schema-v2 transcript field \(field) contradicts authoritative provenance."
        case .invalidV2Language:
            return "Schema-v2 transcript language must use the fixed canonical English identifier 'en'."
        case .unsupportedVersion(let version): return "Unsupported transcript-result schema version \(version)."
        }
    }
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
    static let legacySchemaVersion = 1
    static let currentSchemaVersion = 2

    static func schemaVersion(for output: TranscriptionEngineOutput) -> Int {
        output.provenance == nil ? legacySchemaVersion : currentSchemaVersion
    }

    var schemaVersion: Int
    var source: TranscriptionSourceSnapshot
    var output: TranscriptionEngineOutput
    var attemptID: UUID
    var completedDate: Date

    init(
        schemaVersion: Int,
        source: TranscriptionSourceSnapshot,
        output: TranscriptionEngineOutput,
        attemptID: UUID,
        completedDate: Date
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.output = output
        self.attemptID = attemptID
        self.completedDate = completedDate
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, source, output, attemptID, completedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        source = try container.decode(TranscriptionSourceSnapshot.self, forKey: .source)
        output = try container.decode(TranscriptionEngineOutput.self, forKey: .output)
        attemptID = try container.decode(UUID.self, forKey: .attemptID)
        completedDate = try container.decode(Date.self, forKey: .completedDate)
        try Self.validateVersionedOutput(schemaVersion: schemaVersion, output: output)
    }

    func encode(to encoder: Encoder) throws {
        try Self.validateVersionedOutput(schemaVersion: schemaVersion, output: output)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(source, forKey: .source)
        try container.encode(output, forKey: .output)
        try container.encode(attemptID, forKey: .attemptID)
        try container.encode(completedDate, forKey: .completedDate)
    }

    func validateSchema() throws {
        try Self.validateVersionedOutput(schemaVersion: schemaVersion, output: output)
    }

    static func validateVersionedOutput(
        schemaVersion: Int,
        output: TranscriptionEngineOutput
    ) throws {
        switch schemaVersion {
        case legacySchemaVersion:
            guard output.provenance == nil else {
                throw TranscriptResultSchemaError.provenanceNotPermittedInV1
            }
        case currentSchemaVersion:
            guard let provenance = output.provenance else {
                throw TranscriptResultSchemaError.provenanceRequiredInV2
            }
            try provenance.validate()
            guard output.engineIdentifier == provenance.engine.identifier else {
                throw TranscriptResultSchemaError.legacyIdentityContradictsProvenance(field: "engineIdentifier")
            }
            guard output.engineVersion == provenance.engine.version else {
                throw TranscriptResultSchemaError.legacyIdentityContradictsProvenance(field: "engineVersion")
            }
            guard output.modelIdentifier == provenance.model.identifier else {
                throw TranscriptResultSchemaError.legacyIdentityContradictsProvenance(field: "modelIdentifier")
            }
            guard provenance.configuration.language == "en", output.language == "en" else {
                throw TranscriptResultSchemaError.invalidV2Language
            }
        default:
            throw TranscriptResultSchemaError.unsupportedVersion(schemaVersion)
        }
    }
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
