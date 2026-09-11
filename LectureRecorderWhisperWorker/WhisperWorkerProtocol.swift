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
