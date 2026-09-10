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
