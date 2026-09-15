import Foundation

// Deliberately independent of the app target's `WorkerProtocol.swift` — see
// that file's header comment for why this is duplicated rather than
// shared. Field names and JSON shape must match it exactly; this fixture's
// own end-to-end tests are what catch any accidental drift between the
// two independently-maintained copies.

struct FixturePayload: Codable, Sendable {}

struct FixtureOutput: Codable, Sendable {
    var text: String
}

struct FixtureDeclaredFailure: Codable, Sendable {
    var message: String
}

enum FixtureOutcome: String, Codable, Sendable {
    case success
    case failure
}

struct FixtureRequestEnvelope: Codable, Sendable {
    var schemaVersion: Int
    var requestID: UUID
    var attemptID: UUID
    var sessionID: UUID
    var chunkSequenceNumber: Int
    var sourceIdentity: String
    var payload: FixturePayload
}

struct FixtureResponseEnvelope: Codable, Sendable {
    var schemaVersion: Int
    var requestID: UUID
    var attemptID: UUID
    var sessionID: UUID
    var chunkSequenceNumber: Int
    var sourceIdentity: String
    var workerIdentifier: String
    var workerVersion: String
    var outcome: FixtureOutcome
    var output: FixtureOutput?
    var failure: FixtureDeclaredFailure?
}

enum FixtureProtocolConstants {
    static let currentSchemaVersion = 1
    static let unsupportedSchemaVersion = 999
    static let workerIdentifier = "LectureRecorderWorkerFixture"
    static let workerVersion = "1.0"
}
