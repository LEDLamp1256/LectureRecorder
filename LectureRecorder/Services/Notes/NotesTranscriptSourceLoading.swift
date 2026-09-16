import Foundation

nonisolated enum NotesTranscriptSourceLoadError: LocalizedError, Sendable {
    case sessionsRootUnavailable(String)
    case unsafeSessionsRoot
    case unsafeSessionDirectory
    case unsafeManifest
    case manifestUndecodable(String)
    case ineligible(String)
    case preflightBlocked(reasons: [String])
    case sourceBuildFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionsRootUnavailable(let reason):
            return "Unable to resolve sessions storage: \(reason)"
        case .unsafeSessionsRoot:
            return "Sessions root is missing, a symlink, or not a directory."
        case .unsafeSessionDirectory:
            return "Session directory is missing, a symlink, or not a directory."
        case .unsafeManifest:
            return "Session manifest is missing, a symlink, or not a regular file."
        case .manifestUndecodable(let reason):
            return "Session manifest could not be read: \(reason)"
        case .ineligible(let reason):
            return "Session is not eligible for notes generation: \(reason)"
        case .preflightBlocked(let reasons):
            return "Transcript artifacts failed integrity preflight: \(reasons.joined(separator: "; "))"
        case .sourceBuildFailed(let reason):
            return "Unable to build transcript source snapshot: \(reason)"
        }
    }
}

/// The smallest Notes-domain seam onto the existing, established completed-
/// session/transcription persistence path
/// (`SessionTranscriptionEligibility`, `SessionArtifactPreflight`,
/// `TranscriptionStoring`, `NotesTranscriptSourceBuilder`). Exists so the
/// notes-generation orchestration service never independently scans or
/// reinterprets transcription files itself (T5-B contract §3). Read-only:
/// never mutates transcription state, never touches canonical transcription
/// artifacts, never depends on or locks against `SessionManager` or any
/// recording/transcription operation.
nonisolated protocol NotesTranscriptSourceLoading: Sendable {
    /// Loads the current, authoritative `NotesTranscriptSourceSnapshot` for
    /// `sessionID` — always freshly derived from durable transcription
    /// state on disk, never cached across calls.
    func loadCurrentSnapshot(sessionID: UUID) async throws -> NotesTranscriptSourceSnapshot
}
