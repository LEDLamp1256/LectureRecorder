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
    /// Codable synthesis treats a missing optional key as `nil`. Adding
    /// `ChunkMetadata.frameCount` also did NOT require a bump: every
    /// manifest Phase 1 ever persisted has an empty `chunks` array (real
    /// chunk metadata didn't exist until Phase 2A), so there is no
    /// existing on-disk `ChunkMetadata` payload for the new required
    /// field to break decoding on. Adding
    /// `observedCaptureCopyFailureCount` also did NOT require a bump:
    /// it is optional, so a manifest written before this field existed
    /// simply decodes it as `nil`.
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
    /// Buffer copies observed failing during the most recently completed
    /// capture cycle for this session (see `CaptureStopOutcome`). `nil`
    /// means no capture cycle has yet produced this evidence for this
    /// manifest (including every manifest written before this field
    /// existed) — distinct from `0`, which means a cycle ran and observed
    /// zero copy failures. Not present in any manifest written before
    /// this field existed; decodes to `nil` for those. Not proof that no
    /// other audio was lost — see `CaptureStopOutcome`'s own
    /// documentation.
    var observedCaptureCopyFailureCount: Int? = nil

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
            failureDescription: nil,
            observedCaptureCopyFailureCount: nil
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

/// Metadata for a single ~30-second audio chunk within a session,
/// produced by `AudioChunkWriter` at finalization time.
nonisolated struct ChunkMetadata: Codable, Equatable, Sendable {
    var sequenceNumber: Int
    var fileName: String
    var startOffsetSeconds: Double
    var durationSeconds: Double
    /// The exact frame count written to this chunk, as counted by
    /// `AudioChunkWriter`. This is the source-of-truth integer value —
    /// `durationSeconds` is derived from it for display/readability only
    /// and must never be used to reconstruct an exact frame count
    /// (floating-point division/rounding makes that lossy).
    var frameCount: Int
    var state: ChunkState
}

nonisolated enum ChunkState: String, Codable, Equatable, Sendable {
    case recording
    case completed
    case failed
}
