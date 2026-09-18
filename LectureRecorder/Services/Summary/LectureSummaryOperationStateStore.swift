import Foundation

/// Production `LectureSummaryOperationStateStoring`, backed by
/// `AtomicFileWriter`'s plain atomic-replace primitive — unlike
/// `LectureSummaryStore`'s canonical artifacts, this record is expected to be
/// overwritten repeatedly, so it is never routed through
/// `NotesExclusiveArtifactFileSystem`'s commit-once semantics. Every save
/// verifies the record's own embedded identity against the paths it is
/// being written to *before* writing; every load re-verifies identity
/// against the paths it was read from. The full Summary-owned ancestry chain
/// is checked via `CompletedSessionPathSafety` before any read or write, on
/// both paths — a safe-looking leaf beneath a symlinked ancestor is never
/// reached. Mirrors `LectureNotesOperationStateStore` exactly, adapted for
/// the Summary domain's own paths/error type.
nonisolated struct LectureSummaryOperationStateStore: LectureSummaryOperationStateStoring {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        encoder: JSONEncoder = AtomicFileWriter.defaultEncoder,
        decoder: JSONDecoder = AtomicFileWriter.defaultDecoder
    ) {
        self.encoder = encoder
        self.decoder = decoder
    }

    func loadOperationState(paths: SummaryArtifactPaths) throws -> SummaryGenerationOperationState? {
        try verifyAncestryIsSafe(paths.ancestryChain)
        guard let data = try readDataIfExists(at: paths.operationStateURL) else { return nil }

        let state: SummaryGenerationOperationState
        do {
            state = try decoder.decode(SummaryGenerationOperationState.self, from: data)
        } catch {
            throw SummaryOperationStateStoreError.corruptArtifact(url: paths.operationStateURL, underlying: error.localizedDescription)
        }
        guard state.schemaVersion == SummaryGenerationOperationState.currentSchemaVersion else {
            throw SummaryOperationStateStoreError.unsupportedSchemaVersion(url: paths.operationStateURL, version: state.schemaVersion)
        }
        try verifyIdentity(state, paths: paths)
        return state
    }

    func saveOperationState(_ state: SummaryGenerationOperationState, paths: SummaryArtifactPaths) throws {
        try verifyIdentity(state, paths: paths)
        try verifyAncestryIsSafe(paths.ancestryChain)
        if case .unsafe = CompletedSessionPathSafety.checkExistingRegularFile(paths.operationStateURL) {
            throw SummaryOperationStateStoreError.unsafePath(url: paths.operationStateURL)
        }
        // `AtomicFileWriter.writeJSON` creates `generationDirectory` (the
        // file's containing directory) if it does not exist yet — already
        // proven not-unsafe by the ancestry check above.
        try AtomicFileWriter.writeJSON(state, to: paths.operationStateURL, encoder: encoder)
    }

    private func verifyIdentity(_ state: SummaryGenerationOperationState, paths: SummaryArtifactPaths) throws {
        guard state.sessionID == paths.sessionID else {
            throw SummaryOperationStateStoreError.identityMismatch(
                url: paths.operationStateURL,
                reason: "sessionID does not match the artifact's own path"
            )
        }
        guard state.generationID == paths.generationID else {
            throw SummaryOperationStateStoreError.identityMismatch(
                url: paths.operationStateURL,
                reason: "generationID does not match the artifact's own path"
            )
        }
    }

    private func verifyAncestryIsSafe(_ ancestors: [URL]) throws {
        for ancestor in ancestors {
            switch CompletedSessionPathSafety.checkExistingDirectory(ancestor) {
            case .missing, .safe:
                continue
            case .unsafe:
                throw SummaryOperationStateStoreError.unsafePath(url: ancestor)
            }
        }
    }

    private func readDataIfExists(at url: URL) throws -> Data? {
        switch CompletedSessionPathSafety.checkExistingRegularFile(url) {
        case .missing:
            return nil
        case .unsafe:
            throw SummaryOperationStateStoreError.unsafePath(url: url)
        case .safe:
            return try Data(contentsOf: url)
        }
    }
}
