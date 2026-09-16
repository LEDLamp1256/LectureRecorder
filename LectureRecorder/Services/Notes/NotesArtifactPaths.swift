import Foundation

/// Validated, notes-owned on-disk locations for one generation's
/// artifacts. Deliberately independent of `TranscriptionArtifactPaths` —
/// notes persistence lives entirely under its own `notes/` subtree beneath
/// a session directory and never touches `chunks/` or `transcription/`.
/// The only way to construct one is `validated(sessionPaths:sessionID:
/// generationID:)`.
nonisolated struct NotesArtifactPaths: Sendable, Equatable {
    nonisolated enum ValidationError: LocalizedError, Sendable, Equatable {
        /// `sessionPaths.sessionDirectory`'s last path component does not
        /// match `sessionID` — proves the supplied paths do not actually
        /// belong to this session.
        case pathSessionMismatch
        /// The resolved generation directory does not remain beneath the
        /// session's `notes/generations/` directory after
        /// standardization. `generationID` is always a `UUID`, so this is
        /// defense-in-depth rather than an expected failure mode.
        case generationDirectoryEscapesNotesDirectory

        var errorDescription: String? {
            switch self {
            case .pathSessionMismatch:
                return "The supplied session paths do not belong to the supplied session ID."
            case .generationDirectoryEscapesNotesDirectory:
                return "The resolved generation directory does not remain beneath the session's notes directory."
            }
        }
    }

    let sessionID: UUID
    let generationID: UUID
    let notesDirectory: URL
    let generationsDirectory: URL
    let generationDirectory: URL
    let generationRecordURL: URL
    let windowAnalysesDirectory: URL
    let documentURL: URL
    /// The advisory, mutable notes-generation operation-state record for
    /// this generation (see `NotesGenerationOperationState`) — the one
    /// artifact in this subtree that is overwritten in place rather than
    /// committed once. Lives directly under `generationDirectory`, so it
    /// shares that directory's ancestry-safety checks with every canonical
    /// artifact here.
    let operationStateURL: URL

    /// The full root-to-leaf ancestor chain notes persistence owns for
    /// this generation, in order — every level a path-safety check must
    /// walk before trusting anything beneath it. Deliberately excludes
    /// `sessionDirectory` itself (T4's own concern, not notes').
    var ancestryChain: [URL] {
        [notesDirectory, generationsDirectory, generationDirectory]
    }

    static func validated(
        sessionPaths: SessionPaths,
        sessionID: UUID,
        generationID: UUID
    ) throws -> NotesArtifactPaths {
        guard sessionPaths.sessionDirectory.lastPathComponent == sessionID.uuidString else {
            throw ValidationError.pathSessionMismatch
        }

        let notesDirectory = Self.resolvedNotesDirectory(sessionPaths: sessionPaths)
        let generationsDirectory = notesDirectory.appendingPathComponent("generations", isDirectory: true)
        let generationDirectory = generationsDirectory
            .appendingPathComponent(generationID.uuidString, isDirectory: true)

        let standardizedGenerationsDirectory = generationsDirectory.standardizedFileURL
        let standardizedGenerationDirectory = generationDirectory.standardizedFileURL
        let generationsPrefix = standardizedGenerationsDirectory.path.hasSuffix("/")
            ? standardizedGenerationsDirectory.path
            : standardizedGenerationsDirectory.path + "/"
        guard standardizedGenerationDirectory.path.hasPrefix(generationsPrefix) else {
            throw ValidationError.generationDirectoryEscapesNotesDirectory
        }

        return NotesArtifactPaths(
            sessionID: sessionID,
            generationID: generationID,
            notesDirectory: notesDirectory,
            generationsDirectory: generationsDirectory,
            generationDirectory: generationDirectory,
            generationRecordURL: generationDirectory.appendingPathComponent("generation.json"),
            windowAnalysesDirectory: generationDirectory.appendingPathComponent("window_analyses", isDirectory: true),
            documentURL: generationDirectory.appendingPathComponent("document.json"),
            operationStateURL: generationDirectory.appendingPathComponent("operation-state.json")
        )
    }

    /// The `notes/` directory for a session, without requiring any
    /// specific generation ID. Pure; never touches the filesystem. Named
    /// distinctly from the `notesDirectory` instance property to avoid any
    /// ambiguity between the two.
    static func resolvedNotesDirectory(sessionPaths: SessionPaths) -> URL {
        sessionPaths.sessionDirectory.appendingPathComponent("notes", isDirectory: true)
    }

    /// The `notes/generations/` directory for a session, without
    /// requiring any specific generation ID — used for read-only
    /// generation enumeration. Pure; never touches the filesystem.
    static func generationsDirectory(sessionPaths: SessionPaths) -> URL {
        resolvedNotesDirectory(sessionPaths: sessionPaths).appendingPathComponent("generations", isDirectory: true)
    }

    static func windowAnalysisFileName(for windowIndex: Int) -> String {
        "window_\(String(format: "%04d", windowIndex)).analysis.json"
    }

    /// Parses a window-analysis file name back into its window index, or
    /// `nil` if `name` is not a recognized window-analysis file name.
    /// Shared by every enumeration path so on-disk enumeration order never
    /// determines logical window order.
    static func windowIndex(fromWindowAnalysisFileName name: String) -> Int? {
        let prefix = "window_"
        let suffix = ".analysis.json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return Int(name[start..<end])
    }

    func windowAnalysisURL(windowIndex: Int) -> URL {
        windowAnalysesDirectory.appendingPathComponent(Self.windowAnalysisFileName(for: windowIndex))
    }
}
