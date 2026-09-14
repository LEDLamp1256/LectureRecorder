import Foundation

// Independent, narrow mirror of the app target's generic worker envelope.
// End-to-end hosted tests detect any accidental wire-format drift.
struct WhisperProbePayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operation
    }

    private enum Operation: String, Codable {
        case capabilityProbe
    }

    let schemaVersion: Int
    private let operation: Operation

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == WhisperWorkerConstants.capabilitySchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported capability-probe schema."
            )
        }
        schemaVersion = version
        operation = try container.decode(Operation.self, forKey: .operation)
    }
}

struct WhisperProbeOutput: Codable {
    let schemaVersion: Int
    let upstreamVersion: String
}

enum WhisperWorkerOutcome: String, Codable {
    case success
    case failure
}

struct WhisperWorkerFailure: Codable {
    let message: String
    let code: String?
}

struct WhisperWorkerRequestEnvelope: Codable {
    let schemaVersion: Int
    let requestID: UUID
    let attemptID: UUID
    let sessionID: UUID
    let chunkSequenceNumber: Int
    let sourceIdentity: String
    let payload: WhisperProbePayload
}

struct WhisperWorkerResponseEnvelope: Codable {
    let schemaVersion: Int
    let requestID: UUID
    let attemptID: UUID
    let sessionID: UUID
    let chunkSequenceNumber: Int
    let sourceIdentity: String
    let workerIdentifier: String
    let workerVersion: String
    let outcome: WhisperWorkerOutcome
    let output: WhisperProbeOutput?
    let failure: WhisperWorkerFailure?
}

enum WhisperWorkerConstants {
    static let envelopeSchemaVersion = 1
    static let capabilitySchemaVersion = 1
    static let workerIdentifier = "LectureRecorderWhisperWorker"
    static let implementationVersion = "1.0.0"
    static let maximumRequestBytes = 1 * 1024 * 1024
}

struct WorkerAudioFormat: Codable {
    let sampleRate: Double
    let channelCount: UInt32
    let bitsPerChannel: UInt32
    let formatIdentifier: String
}

struct WorkerSourceSnapshot: Codable {
    let sessionID: UUID
    let chunkSequenceNumber: Int
    let chunkFileName: String
    let frameCount: Int
    let startOffsetSeconds: Double
    let durationSeconds: Double
    let audioFormat: WorkerAudioFormat
}

struct WhisperInferencePayload: Codable {
    let schemaVersion: Int
    let operation: String
    let sourcePath: String
    let source: WorkerSourceSnapshot
}

struct WhisperInferenceRequestEnvelope: Codable {
    let schemaVersion: Int
    let requestID: UUID
    let attemptID: UUID
    let sessionID: UUID
    let chunkSequenceNumber: Int
    let sourceIdentity: String
    let payload: WhisperInferencePayload
}

struct WorkerPrinting: Codable { let printSpecial, printProgress, printRealtime, printTimestamps: Bool }
struct WorkerConfigurationProvenance: Codable {
    let identifier, samplingStrategy: String
    let threadCount: Int
    let language: String
    let automaticLanguageDetectionEnabled, translationEnabled, previousTextContextEnabled: Bool
    let initialPromptUsed, segmentTimestampsEnabled, tokenTimestampsEnabled: Bool
    let singleSegmentModeEnabled, vadEnabled, diarizationEnabled: Bool
    let printing: WorkerPrinting
    let computeBackend: String
}
struct WorkerIdentityProvenance: Codable { let identifier, version: String }
struct WorkerEngineProvenance: Codable { let identifier, version, sourceRevision: String }
struct WorkerModelProvenance: Codable { let identifier, filename: String; let byteCount: UInt64; let sha256: String }
struct WorkerProvenance: Codable {
    let worker: WorkerIdentityProvenance
    let engine: WorkerEngineProvenance
    let model: WorkerModelProvenance
    let configuration: WorkerConfigurationProvenance
}
struct WorkerInferenceSegment: Codable { let startMilliseconds, endMilliseconds: Int64; let text: String }
struct WorkerInferenceTiming: Codable {
    let modelInitializationMilliseconds, audioConversionMilliseconds, inferenceMilliseconds: Int64
}
struct WorkerInferenceOutput: Codable {
    let schemaVersion: Int
    let transcript: String
    let segments: [WorkerInferenceSegment]
    let decodedDurationMilliseconds: Int64
    let decodedSampleCount: Int
    let provenance: WorkerProvenance
    let timing: WorkerInferenceTiming
}
struct WhisperInferenceResponseEnvelope: Codable {
    let schemaVersion: Int
    let requestID, attemptID, sessionID: UUID
    let chunkSequenceNumber: Int
    let sourceIdentity, workerIdentifier, workerVersion: String
    let outcome: WhisperWorkerOutcome
    let output: WorkerInferenceOutput?
    let failure: WhisperWorkerFailure?
}
