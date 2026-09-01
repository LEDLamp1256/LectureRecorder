import Foundation

/// The durable, versioned record of a single recording session.
///
/// This is written to `Sessions/<session-uuid>/session.json` via
/// `AtomicFileWriter`, and is the single source of truth for session state
/// once the app is not running.
nonisolated struct SessionManifest: Codable, Equatable, Sendable {
    /// Bump this whenever the shape of `SessionManifest` changes in a way
    /// that isn't purely additive-and-optional. Older manifests can be
    /// migrated by switching on this value when read. Adding
    /// `failureDescription` did NOT require a bump: it is optional, and
    /// Codable synthesis treats a missing optional key as `nil`.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: UUID
    var creationDate: Date
    var endDate: Date?
    var status: SessionStatus
    var audioFormat: AudioFormatDescriptor
    var targetChunkDurationSeconds: Double
    var chunks: [ChunkMetadata]
    var endReason: SessionEndReason?
    var endedCleanly: Bool
    /// Human-readable description of what went wrong, populated only when
    /// `status == .failed`. Set by `SessionManager` when it persists a
    /// failure record so the reason is visible later without needing logs.
    var failureDescription: String?

    static func newSession(
        id: UUID,
        audioFormat: AudioFormatDescriptor,
        targetChunkDurationSeconds: Double
    ) -> SessionManifest {
        SessionManifest(
            schemaVersion: currentSchemaVersion,
            sessionID: id,
            creationDate: Date(),
            endDate: nil,
            status: .recording,
            audioFormat: audioFormat,
            targetChunkDurationSeconds: targetChunkDurationSeconds,
            chunks: [],
            endReason: nil,
            endedCleanly: false,
            failureDescription: nil
        )
    }
}

nonisolated enum SessionStatus: String, Codable, Equatable, Sendable {
    case recording
    case completed
    case failed
    case interrupted
}

nonisolated enum SessionEndReason: String, Codable, Equatable, Sendable {
    case userStopped
    case appTerminated
    case error
    case unknown
}

/// Metadata for a single ~30-second audio chunk within a session.
/// Not populated until the microphone-capture step lands; included now so
/// the manifest schema and its tests are stable up front.
nonisolated struct ChunkMetadata: Codable, Equatable, Sendable {
    var sequenceNumber: Int
    var fileName: String
    var startOffsetSeconds: Double
    var durationSeconds: Double
    var state: ChunkState
}

nonisolated enum ChunkState: String, Codable, Equatable, Sendable {
    case recording
    case completed
    case failed
}
