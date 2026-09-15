import Foundation

/// The outcome of committing a generation record exactly once. Distinct
/// from `.created` is `.createdDurabilityUncertain`, preserved rather than
/// collapsed into `.created` — see
/// `NotesExclusiveArtifactFileSystem.createExclusive`'s own
/// `.createdDurabilityUncertain` case. The artifact is genuinely readable
/// either way; only whether its containing-directory entry is confirmed
/// flushed to stable storage differs. T5-A does not implement recovery
/// orchestration for this — it only ensures the evidence is never thrown
/// away, so a future T5-B can act on it.
nonisolated enum NotesGenerationCommitOutcome: Sendable, Equatable {
    case created
    case createdDurabilityUncertain
    /// A generation record already existed at this generation ID with
    /// byte-for-byte identical content — not treated as an error.
    case alreadyExistsIdentical
    /// A generation record already existed at this generation ID with
    /// *different* content — a genuine identity conflict, never silently
    /// resolved.
    case conflict
}

nonisolated enum NotesWindowAnalysisCommitOutcome: Sendable, Equatable {
    case committed
    case committedDurabilityUncertain
    case alreadyCommittedIdentical
    case conflict
}

nonisolated enum NotesDocumentCommitOutcome: Sendable, Equatable {
    case committed
    case committedDurabilityUncertain
    case alreadyCommittedIdentical
    case conflict
}

/// The result of one artifact load during bulk enumeration: either the
/// decoded value, or a diagnostic describing why it could not be loaded.
/// Mirrors `ArtifactLoadResult`'s "never abort the rest of the
/// enumeration" shape, independently, for the notes domain.
nonisolated enum NotesArtifactLoadResult<Value: Sendable>: Sendable {
    case success(windowIndex: Int, value: Value)
    case failure(windowIndex: Int, error: String)

    var windowIndex: Int {
        switch self {
        case .success(let windowIndex, _): return windowIndex
        case .failure(let windowIndex, _): return windowIndex
        }
    }
}

nonisolated enum LectureNotesStoreError: LocalizedError, Sendable {
    case corruptArtifact(url: URL, underlying: String)
    case unsupportedSchemaVersion(url: URL, version: Int)
    /// An artifact's own embedded identity (`sessionID`/`generationID`/
    /// `windowIndex`) does not agree with the `NotesArtifactPaths` it was
    /// committed to or loaded from. Never silently persisted or
    /// reinterpreted under the path it actually occupies.
    case identityMismatch(url: URL, reason: String)
    /// A generation record's own `windowPlan` failed structural
    /// validation (see `NotesWindowPlan.validateStructure`) — checked
    /// before ever accepting the record on write, and again on every
    /// load, since decoding successfully proves nothing about coherence.
    case invalidWindowPlan(url: URL, underlying: NotesWindowPlanValidationError)
    /// The path an artifact would occupy already exists but is a symlink
    /// or the wrong filesystem entry type — mirrors
    /// `CompletedSessionPathSafety`'s existing T4 standard, applied to the
    /// notes domain's own paths.
    case unsafePath(url: URL)

    var errorDescription: String? {
        switch self {
        case .corruptArtifact(let url, let underlying):
            return "Notes artifact at \(url.path) is corrupt: \(underlying)"
        case .unsupportedSchemaVersion(let url, let version):
            return "Notes artifact at \(url.path) has unsupported schema version \(version)."
        case .invalidWindowPlan(let url, let underlying):
            return "Notes generation at \(url.path) has an invalid window plan: \(underlying.errorDescription ?? "unknown reason")"
        case .identityMismatch(let url, let reason):
            return "Notes artifact at \(url.path) has a mismatched identity: \(reason)"
        case .unsafePath(let url):
            return "Path \(url.path) exists but is a symlink or an unexpected filesystem entry type."
        }
    }
}

/// The full persistence boundary for the notes domain. Never touches
/// `TranscriptionArtifactPaths`, transcription jobs/results, or
/// `SessionManifest` — every method here operates only within one
/// session's `notes/` subtree. A malformed or unsupported artifact is
/// always reported as a thrown error, never silently repaired or allowed
/// to corrupt sibling artifacts.
nonisolated protocol LectureNotesStoring: Sendable {
    func ensureDirectoriesExist(paths: NotesArtifactPaths) throws

    /// Lists every generation ID already persisted for a session, sorted
    /// deterministically (by UUID string) — never by raw filesystem
    /// enumeration order. Returns `[]` if no generation has ever been
    /// created.
    func listGenerationIDs(sessionPaths: SessionPaths) throws -> [UUID]

    func createGenerationIfAbsent(
        _ record: LectureNotesGenerationRecord,
        paths: NotesArtifactPaths
    ) throws -> NotesGenerationCommitOutcome

    /// `nil` if no generation record exists yet at these paths. Throws if
    /// one exists but is corrupt or has an unsupported schema version —
    /// loading a previously valid generation never requires any generator
    /// backend to be available.
    func loadGeneration(paths: NotesArtifactPaths) throws -> LectureNotesGenerationRecord?

    func commitWindowAnalysis(
        _ analysis: LectureNotesWindowAnalysis,
        paths: NotesArtifactPaths
    ) throws -> NotesWindowAnalysisCommitOutcome

    func loadWindowAnalysis(windowIndex: Int, paths: NotesArtifactPaths) throws -> LectureNotesWindowAnalysis?

    func loadAllWindowAnalyses(paths: NotesArtifactPaths) throws -> [NotesArtifactLoadResult<LectureNotesWindowAnalysis>]

    func commitDocument(
        _ document: LectureNotesDocument,
        paths: NotesArtifactPaths
    ) throws -> NotesDocumentCommitOutcome

    func loadDocument(paths: NotesArtifactPaths) throws -> LectureNotesDocument?
}
