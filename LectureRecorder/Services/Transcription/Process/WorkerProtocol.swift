import Foundation

/// Generic, worker-agnostic request envelope. `Payload` carries whatever a
/// specific worker (the T2 fixture today, a real T3 whisper.cpp adapter
/// later) needs beyond these stable identity fields — this type itself
/// never gains Whisper-specific fields. No `Any`, `[String: Any]`, or
/// `AnyCodable`: `Payload` is a real, closed, `Codable` type chosen by the
/// caller.
nonisolated struct WorkerRequestEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    var schemaVersion: Int
    var requestID: UUID
    var attemptID: UUID
    var sessionID: UUID
    var chunkSequenceNumber: Int
    var sourceIdentity: String
    var payload: Payload
}

nonisolated enum WorkerOutcome: String, Codable, Sendable {
    case success
    case failure
}

nonisolated struct WorkerDeclaredFailure: Codable, Sendable, Equatable {
    var message: String
    /// Optional operation-specific closed code. Legacy/T2 fixture workers
    /// omit it; production adapters validate any code they require.
    var code: String? = nil
}

/// Generic response envelope. Exactly one of `output`/`failure` is
/// populated, matching `outcome` — `TranscriptionWorkerClient` validates
/// this shape explicitly rather than trusting whichever field happens to
/// be non-nil.
nonisolated struct WorkerResponseEnvelope<Output: Codable & Sendable>: Codable, Sendable {
    var schemaVersion: Int
    var requestID: UUID
    var attemptID: UUID
    var sessionID: UUID
    var chunkSequenceNumber: Int
    var sourceIdentity: String
    var workerIdentifier: String
    var workerVersion: String
    var outcome: WorkerOutcome
    var output: Output?
    var failure: WorkerDeclaredFailure?
}

/// The identity a response must match, built from the request that was
/// sent. Never round-tripped through the worker — computed independently
/// by the client from what it itself sent, so a worker cannot "confirm" a
/// forged identity merely by echoing back whatever it was told.
nonisolated struct WorkerRequestIdentity: Sendable, Equatable {
    var requestID: UUID
    var attemptID: UUID
    var sessionID: UUID
    var chunkSequenceNumber: Int
    var sourceIdentity: String
}

nonisolated enum WorkerProtocolConstants {
    static let currentSchemaVersion = 1
}

/// The production helper's only T3A operation. Its fixed operation marker
/// prevents this probe payload from becoming an open-ended command bag.
nonisolated struct WhisperCapabilityProbePayload: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operation
    }

    private enum Operation: String, Codable {
        case capabilityProbe
    }

    let schemaVersion: Int
    private let operation: Operation

    init() {
        schemaVersion = WhisperCapabilityProbeConstants.currentSchemaVersion
        operation = .capabilityProbe
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == WhisperCapabilityProbeConstants.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported capability-probe payload schema version \(version)."
            )
        }
        schemaVersion = version
        operation = try container.decode(Operation.self, forKey: .operation)
    }
}

/// Validated output from a native `whisper_version()` call. Decoding fails
/// closed for an unsupported output schema or an empty upstream version.
nonisolated struct WhisperCapabilityProbeOutput: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case upstreamVersion
    }

    let schemaVersion: Int
    let upstreamVersion: String

    init(upstreamVersion: String) {
        schemaVersion = WhisperCapabilityProbeConstants.currentSchemaVersion
        self.upstreamVersion = upstreamVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == WhisperCapabilityProbeConstants.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported capability-probe output schema version \(version)."
            )
        }
        let upstreamVersion = try container.decode(String.self, forKey: .upstreamVersion)
        guard !upstreamVersion.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .upstreamVersion,
                in: container,
                debugDescription: "whisper_version() returned an empty version."
            )
        }
        schemaVersion = version
        self.upstreamVersion = upstreamVersion
    }
}

nonisolated enum WhisperCapabilityProbeConstants {
    static let currentSchemaVersion = 1
    static let workerIdentifier = "LectureRecorderWhisperWorker"
    static let workerImplementationVersion = "1.0.0"
}

nonisolated struct WhisperInferencePayload: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let operation: String
    let sourcePath: String
    let source: TranscriptionSourceSnapshot

    init(sourcePath: String, source: TranscriptionSourceSnapshot) {
        schemaVersion = 1
        operation = "transcribe"
        self.sourcePath = sourcePath
        self.source = source
    }
}

nonisolated struct WhisperInferenceSegment: Codable, Sendable, Equatable {
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let text: String
}

nonisolated struct WhisperInferenceTiming: Codable, Sendable, Equatable {
    let modelInitializationMilliseconds: Int64
    let audioConversionMilliseconds: Int64
    let inferenceMilliseconds: Int64
}

nonisolated struct WhisperInferenceOutput: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let transcript: String
    let segments: [WhisperInferenceSegment]
    let decodedDurationMilliseconds: Int64
    let decodedSampleCount: Int
    let provenance: TranscriptionProvenance
    let timing: WhisperInferenceTiming
}
