import Foundation

/// Production `LectureNotesStoring`, backed by `NotesExclusiveArtifactFileSystem`
/// for commit-once artifacts (generation record, each window analysis, the
/// final document) and plain `Data(contentsOf:)` reads — no artifact this
/// store manages is ever rewritten in place. Every commit verifies the
/// artifact's own embedded identity against the paths it is being written
/// to *before* writing; every load re-verifies identity against the paths
/// it was read from. Every directory in the notes-owned ancestry chain
/// (`notesDirectory` → `generationsDirectory` → `generationDirectory` →
/// `windowAnalysesDirectory` where applicable) and every leaf artifact
/// file is checked via `CompletedSessionPathSafety` (the same standard T4
/// already applies to session/chunk paths) before being trusted, on both
/// read and write paths — a safe-looking leaf beneath a symlinked
/// ancestor is never reached.
nonisolated struct LectureNotesStore: LectureNotesStoring {
    private let fileSystem: any NotesExclusiveArtifactFileSystem
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileSystem: any NotesExclusiveArtifactFileSystem = DarwinNotesExclusiveArtifactFileSystem(),
        encoder: JSONEncoder = AtomicFileWriter.defaultEncoder,
        decoder: JSONDecoder = AtomicFileWriter.defaultDecoder
    ) {
        self.fileSystem = fileSystem
        self.encoder = encoder
        self.decoder = decoder
    }

    func ensureDirectoriesExist(paths: NotesArtifactPaths) throws {
        try verifyAncestryIsSafe([paths.notesDirectory, paths.generationsDirectory])
        try ensureSafeDirectory(paths.generationDirectory)
        try ensureSafeDirectory(paths.windowAnalysesDirectory)
    }

    func listGenerationIDs(sessionPaths: SessionPaths) throws -> [UUID] {
        let notesDirectory = NotesArtifactPaths.resolvedNotesDirectory(sessionPaths: sessionPaths)
        try verifyAncestryIsSafe([notesDirectory])

        let generationsDirectory = NotesArtifactPaths.generationsDirectory(sessionPaths: sessionPaths)
        switch CompletedSessionPathSafety.checkExistingDirectory(generationsDirectory) {
        case .missing:
            return []
        case .unsafe:
            throw LectureNotesStoreError.unsafePath(url: generationsDirectory)
        case .safe:
            break
        }
        let contents = try FileManager.default.contentsOfDirectory(at: generationsDirectory, includingPropertiesForKeys: nil)
        return contents
            .compactMap { entry -> UUID? in
                // A UUID-named entry that is a symlink or the wrong
                // filesystem type is never surfaced as a valid generation
                // — excluded here, not merely deferred to a later check,
                // since a caller enumerating this list has no other
                // opportunity to learn it was unsafe.
                guard let uuid = UUID(uuidString: entry.lastPathComponent) else { return nil }
                guard case .safe = CompletedSessionPathSafety.checkExistingDirectory(entry) else { return nil }
                return uuid
            }
            .sorted { $0.uuidString < $1.uuidString }
    }

    func createGenerationIfAbsent(
        _ record: LectureNotesGenerationRecord,
        paths: NotesArtifactPaths
    ) throws -> NotesGenerationCommitOutcome {
        try verifyGenerationIdentity(record, paths: paths, url: paths.generationRecordURL)
        do {
            try record.windowPlan.validateStructure()
        } catch let error as NotesWindowPlanValidationError {
            throw LectureNotesStoreError.invalidWindowPlan(url: paths.generationRecordURL, underlying: error)
        }
        try ensureDirectoriesExist(paths: paths)
        try checkDestinationSafeToCommit(at: paths.generationRecordURL)
        let data = try encoder.encode(record)
        let outcome = try fileSystem.createExclusive(data: data, at: paths.generationRecordURL)
        switch outcome {
        case .created:
            return .created
        case .createdDurabilityUncertain:
            return .createdDurabilityUncertain
        case .alreadyExists(let existingData):
            let existing = try decode(LectureNotesGenerationRecord.self, data: existingData, url: paths.generationRecordURL)
            // Compare against `record` re-decoded from the exact bytes just
            // encoded, not the raw in-memory value: `createdDate` loses
            // sub-millisecond precision across the JSON round-trip, so a
            // literal identity check against the pre-encoding original
            // would misreport a genuinely identical re-commit as a conflict.
            let normalizedCandidate = try decode(LectureNotesGenerationRecord.self, data: data, url: paths.generationRecordURL)
            return existing == normalizedCandidate ? .alreadyExistsIdentical : .conflict
        }
    }

    func loadGeneration(paths: NotesArtifactPaths) throws -> LectureNotesGenerationRecord? {
        try verifyAncestryIsSafe(paths.ancestryChain)
        guard let data = try readDataIfExists(at: paths.generationRecordURL) else { return nil }
        let record = try decode(LectureNotesGenerationRecord.self, data: data, url: paths.generationRecordURL)
        guard record.schemaVersion == LectureNotesGenerationRecord.currentSchemaVersion else {
            throw LectureNotesStoreError.unsupportedSchemaVersion(url: paths.generationRecordURL, version: record.schemaVersion)
        }
        try verifyGenerationIdentity(record, paths: paths, url: paths.generationRecordURL)
        do {
            try record.windowPlan.validateStructure()
        } catch let error as NotesWindowPlanValidationError {
            throw LectureNotesStoreError.invalidWindowPlan(url: paths.generationRecordURL, underlying: error)
        }
        return record
    }

    func commitWindowAnalysis(
        _ analysis: LectureNotesWindowAnalysis,
        paths: NotesArtifactPaths
    ) throws -> NotesWindowAnalysisCommitOutcome {
        let url = paths.windowAnalysisURL(windowIndex: analysis.windowIndex)
        try verifyWindowAnalysisIdentity(analysis, expectedWindowIndex: analysis.windowIndex, paths: paths, url: url)
        try ensureDirectoriesExist(paths: paths)
        try verifyAncestryIsSafe([paths.windowAnalysesDirectory])
        try checkDestinationSafeToCommit(at: url)
        let data = try encoder.encode(analysis)
        let outcome = try fileSystem.createExclusive(data: data, at: url)
        switch outcome {
        case .created:
            return .committed
        case .createdDurabilityUncertain:
            return .committedDurabilityUncertain
        case .alreadyExists(let existingData):
            let existing = try decode(LectureNotesWindowAnalysis.self, data: existingData, url: url)
            let normalizedCandidate = try decode(LectureNotesWindowAnalysis.self, data: data, url: url)
            return existing == normalizedCandidate ? .alreadyCommittedIdentical : .conflict
        }
    }

    func loadWindowAnalysis(windowIndex: Int, paths: NotesArtifactPaths) throws -> LectureNotesWindowAnalysis? {
        try verifyAncestryIsSafe(paths.ancestryChain + [paths.windowAnalysesDirectory])
        let url = paths.windowAnalysisURL(windowIndex: windowIndex)
        guard let data = try readDataIfExists(at: url) else { return nil }
        let analysis = try decode(LectureNotesWindowAnalysis.self, data: data, url: url)
        guard analysis.schemaVersion == LectureNotesWindowAnalysis.currentSchemaVersion else {
            throw LectureNotesStoreError.unsupportedSchemaVersion(url: url, version: analysis.schemaVersion)
        }
        try verifyWindowAnalysisIdentity(analysis, expectedWindowIndex: windowIndex, paths: paths, url: url)
        return analysis
    }

    func loadAllWindowAnalyses(paths: NotesArtifactPaths) throws -> [NotesArtifactLoadResult<LectureNotesWindowAnalysis>] {
        try verifyAncestryIsSafe(paths.ancestryChain)
        switch CompletedSessionPathSafety.checkExistingDirectory(paths.windowAnalysesDirectory) {
        case .missing:
            return []
        case .unsafe:
            throw LectureNotesStoreError.unsafePath(url: paths.windowAnalysesDirectory)
        case .safe:
            break
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: paths.windowAnalysesDirectory,
            includingPropertiesForKeys: nil
        )

        var results: [NotesArtifactLoadResult<LectureNotesWindowAnalysis>] = []
        for url in contents {
            guard let windowIndex = NotesArtifactPaths.windowIndex(fromWindowAnalysisFileName: url.lastPathComponent) else {
                continue
            }
            do {
                guard let data = try readDataIfExists(at: url) else { continue }
                let analysis = try decode(LectureNotesWindowAnalysis.self, data: data, url: url)
                guard analysis.schemaVersion == LectureNotesWindowAnalysis.currentSchemaVersion else {
                    results.append(.failure(
                        windowIndex: windowIndex,
                        error: "unsupported schema version \(analysis.schemaVersion)"
                    ))
                    continue
                }
                try verifyWindowAnalysisIdentity(analysis, expectedWindowIndex: windowIndex, paths: paths, url: url)
                results.append(.success(windowIndex: windowIndex, value: analysis))
            } catch {
                results.append(.failure(windowIndex: windowIndex, error: error.localizedDescription))
            }
        }

        return results.sorted { $0.windowIndex < $1.windowIndex }
    }

    func commitDocument(
        _ document: LectureNotesDocument,
        paths: NotesArtifactPaths
    ) throws -> NotesDocumentCommitOutcome {
        try verifyDocumentIdentity(document, paths: paths, url: paths.documentURL)
        try ensureDirectoriesExist(paths: paths)
        try checkDestinationSafeToCommit(at: paths.documentURL)
        let data = try encoder.encode(document)
        let outcome = try fileSystem.createExclusive(data: data, at: paths.documentURL)
        switch outcome {
        case .created:
            return .committed
        case .createdDurabilityUncertain:
            return .committedDurabilityUncertain
        case .alreadyExists(let existingData):
            let existing = try decode(LectureNotesDocument.self, data: existingData, url: paths.documentURL)
            let normalizedCandidate = try decode(LectureNotesDocument.self, data: data, url: paths.documentURL)
            return existing == normalizedCandidate ? .alreadyCommittedIdentical : .conflict
        }
    }

    func loadDocument(paths: NotesArtifactPaths) throws -> LectureNotesDocument? {
        try verifyAncestryIsSafe(paths.ancestryChain)
        guard let data = try readDataIfExists(at: paths.documentURL) else { return nil }
        let document = try decode(LectureNotesDocument.self, data: data, url: paths.documentURL)
        guard document.schemaVersion == LectureNotesDocument.currentSchemaVersion else {
            throw LectureNotesStoreError.unsupportedSchemaVersion(url: paths.documentURL, version: document.schemaVersion)
        }
        try verifyDocumentIdentity(document, paths: paths, url: paths.documentURL)
        return document
    }

    // MARK: - Identity verification

    private func verifyGenerationIdentity(
        _ record: LectureNotesGenerationRecord,
        paths: NotesArtifactPaths,
        url: URL
    ) throws {
        guard record.sessionID == paths.sessionID else {
            throw LectureNotesStoreError.identityMismatch(url: url, reason: "sessionID does not match the artifact's own path")
        }
        guard record.generationID == paths.generationID else {
            throw LectureNotesStoreError.identityMismatch(url: url, reason: "generationID does not match the artifact's own path")
        }
    }

    private func verifyWindowAnalysisIdentity(
        _ analysis: LectureNotesWindowAnalysis,
        expectedWindowIndex: Int,
        paths: NotesArtifactPaths,
        url: URL
    ) throws {
        guard analysis.sessionID == paths.sessionID else {
            throw LectureNotesStoreError.identityMismatch(url: url, reason: "sessionID does not match the artifact's own path")
        }
        guard analysis.generationID == paths.generationID else {
            throw LectureNotesStoreError.identityMismatch(url: url, reason: "generationID does not match the artifact's own path")
        }
        guard analysis.windowIndex == expectedWindowIndex else {
            throw LectureNotesStoreError.identityMismatch(url: url, reason: "windowIndex does not match the artifact's own path")
        }
    }

    private func verifyDocumentIdentity(
        _ document: LectureNotesDocument,
        paths: NotesArtifactPaths,
        url: URL
    ) throws {
        guard document.sessionID == paths.sessionID else {
            throw LectureNotesStoreError.identityMismatch(url: url, reason: "sessionID does not match the artifact's own path")
        }
        guard document.generationID == paths.generationID else {
            throw LectureNotesStoreError.identityMismatch(url: url, reason: "generationID does not match the artifact's own path")
        }
    }

    // MARK: - Path-safety-aware I/O helpers

    /// Walks every URL in `ancestors` (expected root-to-leaf order) and
    /// rejects the first one that already exists but is a symlink or the
    /// wrong filesystem entry type. An ancestor that genuinely does not
    /// exist yet (`.missing`) is not an error here — it is safe to create
    /// on the way down; only an *existing but unsafe* ancestor blocks
    /// everything beneath it, so a safe-looking leaf can never be reached
    /// by traversing through a symlinked ancestor.
    private func verifyAncestryIsSafe(_ ancestors: [URL]) throws {
        for ancestor in ancestors {
            switch CompletedSessionPathSafety.checkExistingDirectory(ancestor) {
            case .missing, .safe:
                continue
            case .unsafe:
                throw LectureNotesStoreError.unsafePath(url: ancestor)
            }
        }
    }

    private func ensureSafeDirectory(_ url: URL) throws {
        switch CompletedSessionPathSafety.checkExistingDirectory(url) {
        case .missing:
            try DefaultFileSystemLocator.ensureDirectoryExists(url)
        case .unsafe:
            throw LectureNotesStoreError.unsafePath(url: url)
        case .safe:
            break
        }
    }

    /// Rejects committing to a destination that already exists but is a
    /// symlink or the wrong filesystem entry type — checked before ever
    /// invoking the exclusive-create primitive, so a symlinked destination
    /// is never dereferenced (whether by a `renamex_np` collision fallback
    /// reading through it, or by anything else). A destination that
    /// genuinely does not exist yet is always safe to attempt.
    private func checkDestinationSafeToCommit(at url: URL) throws {
        if case .unsafe = CompletedSessionPathSafety.checkExistingRegularFile(url) {
            throw LectureNotesStoreError.unsafePath(url: url)
        }
    }

    private func readDataIfExists(at url: URL) throws -> Data? {
        switch CompletedSessionPathSafety.checkExistingRegularFile(url) {
        case .missing:
            return nil
        case .unsafe:
            throw LectureNotesStoreError.unsafePath(url: url)
        case .safe:
            return try Data(contentsOf: url)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, url: URL) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LectureNotesStoreError.corruptArtifact(url: url, underlying: error.localizedDescription)
        }
    }
}
