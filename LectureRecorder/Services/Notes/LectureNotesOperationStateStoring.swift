import Foundation

nonisolated enum NotesOperationStateStoreError: LocalizedError, Sendable {
    case corruptArtifact(url: URL, underlying: String)
    case unsupportedSchemaVersion(url: URL, version: Int)
    /// The record's own embedded `sessionID`/`generationID` does not agree
    /// with the `NotesArtifactPaths` it was saved to or loaded from. Never
    /// silently persisted or reinterpreted under the path it actually
    /// occupies.
    case identityMismatch(url: URL, reason: String)
    /// The path this record would occupy (or one of its ancestor
    /// directories) already exists but is a symlink or the wrong
    /// filesystem entry type — mirrors `CompletedSessionPathSafety`'s
    /// existing T4 standard, applied to this notes-owned mutable artifact.
    case unsafePath(url: URL)

    var errorDescription: String? {
        switch self {
        case .corruptArtifact(let url, let underlying):
            return "Notes operation state at \(url.path) is corrupt: \(underlying)"
        case .unsupportedSchemaVersion(let url, let version):
            return "Notes operation state at \(url.path) has unsupported schema version \(version)."
        case .identityMismatch(let url, let reason):
            return "Notes operation state at \(url.path) has a mismatched identity: \(reason)"
        case .unsafePath(let url):
            return "Path \(url.path) exists but is a symlink or an unexpected filesystem entry type."
        }
    }
}

/// Persistence boundary for the advisory, mutable notes-generation
/// operation-state record — deliberately separate from
/// `LectureNotesStoring`'s commit-once canonical artifacts, since this
/// record (unlike those) is expected to be overwritten repeatedly across a
/// generation's lifetime. Persisted with a plain atomic replace, never an
/// exclusive create. A malformed or identity-mismatched record is always
/// reported as a thrown error, never silently repaired.
nonisolated protocol LectureNotesOperationStateStoring: Sendable {
    /// `nil` if no operation-state record has ever been saved for this
    /// generation yet — not an error; a brand-new generation has none.
    func loadOperationState(paths: NotesArtifactPaths) throws -> NotesGenerationOperationState?

    func saveOperationState(_ state: NotesGenerationOperationState, paths: NotesArtifactPaths) throws
}
