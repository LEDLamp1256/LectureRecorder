import Foundation

/// Commit-once Summary persistence. It deliberately has no "latest"
/// selection and never touches source Notes artifacts.
nonisolated struct LectureSummaryStore: LectureSummaryStoring {
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

    func ensureDirectoriesExist(paths: SummaryArtifactPaths) throws {
        try verifyAncestryIsSafe([paths.summariesDirectory, paths.generationsDirectory])
        try ensureSafeDirectory(paths.generationDirectory)
        try ensureSafeDirectory(paths.batchAnalysesDirectory)
    }

    func listGenerationIDs(sessionPaths: SessionPaths) throws -> [UUID] {
        let summaries = SummaryArtifactPaths.resolvedSummariesDirectory(sessionPaths: sessionPaths)
        try verifyAncestryIsSafe([summaries])
        let generations = SummaryArtifactPaths.generationsDirectory(sessionPaths: sessionPaths)
        switch CompletedSessionPathSafety.checkExistingDirectory(generations) {
        case .missing: return []
        case .unsafe: throw LectureSummaryStoreError.unsafePath(url: generations)
        case .safe: break
        }
        return try FileManager.default.contentsOfDirectory(at: generations, includingPropertiesForKeys: nil)
            .compactMap { url in
                guard let id = UUID(uuidString: url.lastPathComponent),
                      case .safe = CompletedSessionPathSafety.checkExistingDirectory(url) else { return nil }
                return id
            }
            .sorted { $0.uuidString < $1.uuidString }
    }

    func createGenerationIfAbsent(
        _ record: LectureSummaryGenerationRecord,
        paths: SummaryArtifactPaths
    ) throws -> SummaryGenerationCommitOutcome {
        try verifyGenerationIdentity(record, paths: paths, url: paths.generationRecordURL)
        try validatePlan(record.batchPlan, url: paths.generationRecordURL)
        try ensureDirectoriesExist(paths: paths)
        return try commit(record, at: paths.generationRecordURL, as: LectureSummaryGenerationRecord.self).generationOutcome
    }

    func loadGeneration(paths: SummaryArtifactPaths) throws -> LectureSummaryGenerationRecord? {
        try verifyAncestryIsSafe(paths.ancestryChain)
        guard let data = try readDataIfExists(at: paths.generationRecordURL) else { return nil }
        let record = try decode(LectureSummaryGenerationRecord.self, data: data, url: paths.generationRecordURL)
        guard record.schemaVersion == LectureSummaryGenerationRecord.currentSchemaVersion else {
            throw LectureSummaryStoreError.unsupportedSchemaVersion(url: paths.generationRecordURL, version: record.schemaVersion)
        }
        try verifyGenerationIdentity(record, paths: paths, url: paths.generationRecordURL)
        try validatePlan(record.batchPlan, url: paths.generationRecordURL)
        return record
    }

    func commitAnalysis(
        _ analysis: LectureSummaryAnalysis,
        paths: SummaryArtifactPaths
    ) throws -> SummaryAnalysisCommitOutcome {
        let url = paths.batchAnalysisURL(batchIndex: analysis.batchIndex)
        try verifyAnalysisIdentity(analysis, expectedBatchIndex: analysis.batchIndex, paths: paths, url: url)
        try ensureDirectoriesExist(paths: paths)
        try verifyAncestryIsSafe([paths.batchAnalysesDirectory])
        return try commit(analysis, at: url, as: LectureSummaryAnalysis.self).analysisOutcome
    }

    func loadAnalysis(batchIndex: Int, paths: SummaryArtifactPaths) throws -> LectureSummaryAnalysis? {
        try verifyAncestryIsSafe(paths.ancestryChain + [paths.batchAnalysesDirectory])
        let url = paths.batchAnalysisURL(batchIndex: batchIndex)
        guard let data = try readDataIfExists(at: url) else { return nil }
        let analysis = try decode(LectureSummaryAnalysis.self, data: data, url: url)
        guard analysis.schemaVersion == LectureSummaryAnalysis.currentSchemaVersion else {
            throw LectureSummaryStoreError.unsupportedSchemaVersion(url: url, version: analysis.schemaVersion)
        }
        try verifyAnalysisIdentity(analysis, expectedBatchIndex: batchIndex, paths: paths, url: url)
        return analysis
    }

    func loadAllAnalyses(paths: SummaryArtifactPaths) throws -> [SummaryArtifactLoadResult<LectureSummaryAnalysis>] {
        try verifyAncestryIsSafe(paths.ancestryChain)
        switch CompletedSessionPathSafety.checkExistingDirectory(paths.batchAnalysesDirectory) {
        case .missing:
            return []
        case .unsafe:
            throw LectureSummaryStoreError.unsafePath(url: paths.batchAnalysesDirectory)
        case .safe:
            break
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: paths.batchAnalysesDirectory,
            includingPropertiesForKeys: nil
        )
        var loaded: [(batchIndex: Int, fileName: String, result: SummaryArtifactLoadResult<LectureSummaryAnalysis>)] = []
        for url in contents {
            guard let batchIndex = SummaryArtifactPaths.batchIndex(
                fromBatchAnalysisFileName: url.lastPathComponent
            ) else { continue }
            do {
                guard let data = try readDataIfExists(at: url) else { continue }
                let analysis = try decode(LectureSummaryAnalysis.self, data: data, url: url)
                guard analysis.schemaVersion == LectureSummaryAnalysis.currentSchemaVersion else {
                    loaded.append((
                        batchIndex,
                        url.lastPathComponent,
                        .failure(batchIndex: batchIndex, error: "unsupported schema version \(analysis.schemaVersion)")
                    ))
                    continue
                }
                try verifyAnalysisIdentity(
                    analysis,
                    expectedBatchIndex: batchIndex,
                    paths: paths,
                    url: url
                )
                loaded.append((
                    batchIndex,
                    url.lastPathComponent,
                    .success(batchIndex: batchIndex, value: analysis)
                ))
            } catch {
                loaded.append((
                    batchIndex,
                    url.lastPathComponent,
                    .failure(batchIndex: batchIndex, error: error.localizedDescription)
                ))
            }
        }
        return loaded.sorted {
            if $0.batchIndex != $1.batchIndex { return $0.batchIndex < $1.batchIndex }
            return $0.fileName < $1.fileName
        }.map(\.result)
    }

    func commitDocument(
        _ document: LectureSummaryDocument,
        paths: SummaryArtifactPaths
    ) throws -> SummaryDocumentCommitOutcome {
        try verifyDocumentIdentity(document, paths: paths, url: paths.documentURL)
        try ensureDirectoriesExist(paths: paths)
        return try commit(document, at: paths.documentURL, as: LectureSummaryDocument.self).documentOutcome
    }

    func loadDocument(paths: SummaryArtifactPaths) throws -> LectureSummaryDocument? {
        try verifyAncestryIsSafe(paths.ancestryChain)
        guard let data = try readDataIfExists(at: paths.documentURL) else { return nil }
        let document = try decode(LectureSummaryDocument.self, data: data, url: paths.documentURL)
        guard document.schemaVersion == LectureSummaryDocument.currentSchemaVersion else {
            throw LectureSummaryStoreError.unsupportedSchemaVersion(url: paths.documentURL, version: document.schemaVersion)
        }
        try verifyDocumentIdentity(document, paths: paths, url: paths.documentURL)
        return document
    }

    private enum CommitResult { case created, durabilityUncertain, identical, conflict
        var generationOutcome: SummaryGenerationCommitOutcome {
            switch self { case .created: return .created; case .durabilityUncertain: return .createdDurabilityUncertain; case .identical: return .alreadyExistsIdentical; case .conflict: return .conflict }
        }
        var analysisOutcome: SummaryAnalysisCommitOutcome {
            switch self { case .created: return .committed; case .durabilityUncertain: return .committedDurabilityUncertain; case .identical: return .alreadyCommittedIdentical; case .conflict: return .conflict }
        }
        var documentOutcome: SummaryDocumentCommitOutcome {
            switch self { case .created: return .committed; case .durabilityUncertain: return .committedDurabilityUncertain; case .identical: return .alreadyCommittedIdentical; case .conflict: return .conflict }
        }
    }

    private func commit<T: Codable & Equatable>(_ value: T, at url: URL, as type: T.Type) throws -> CommitResult {
        try checkDestinationSafeToCommit(at: url)
        let data = try encoder.encode(value)
        switch try fileSystem.createExclusive(data: data, at: url) {
        case .created: return .created
        case .createdDurabilityUncertain: return .durabilityUncertain
        case .alreadyExists(let existingData):
            let existing = try decode(type, data: existingData, url: url)
            let normalized = try decode(type, data: data, url: url)
            return existing == normalized ? .identical : .conflict
        }
    }

    private func verifyGenerationIdentity(_ record: LectureSummaryGenerationRecord, paths: SummaryArtifactPaths, url: URL) throws {
        guard record.sessionID == paths.sessionID else { throw LectureSummaryStoreError.identityMismatch(url: url, reason: "sessionID does not match path") }
        guard record.generationID == paths.generationID else { throw LectureSummaryStoreError.identityMismatch(url: url, reason: "generationID does not match path") }
    }

    private func verifyAnalysisIdentity(_ analysis: LectureSummaryAnalysis, expectedBatchIndex: Int, paths: SummaryArtifactPaths, url: URL) throws {
        guard analysis.sessionID == paths.sessionID else { throw LectureSummaryStoreError.identityMismatch(url: url, reason: "sessionID does not match path") }
        guard analysis.generationID == paths.generationID else { throw LectureSummaryStoreError.identityMismatch(url: url, reason: "generationID does not match path") }
        guard analysis.batchIndex == expectedBatchIndex,
              analysis.batchID == LectureSummaryPlanner.batchID(expectedBatchIndex) else {
            throw LectureSummaryStoreError.identityMismatch(url: url, reason: "batch identity does not match path")
        }
    }

    private func verifyDocumentIdentity(_ document: LectureSummaryDocument, paths: SummaryArtifactPaths, url: URL) throws {
        guard document.sessionID == paths.sessionID else { throw LectureSummaryStoreError.identityMismatch(url: url, reason: "sessionID does not match path") }
        guard document.generationID == paths.generationID else { throw LectureSummaryStoreError.identityMismatch(url: url, reason: "generationID does not match path") }
    }

    private func validatePlan(_ plan: LectureSummaryPlan, url: URL) throws {
        do {
            try plan.validateStructure()
        } catch let error as LectureSummaryPlanValidationError {
            throw LectureSummaryStoreError.invalidPlan(url: url, underlying: error)
        }
    }

    private func verifyAncestryIsSafe(_ urls: [URL]) throws {
        for url in urls where CompletedSessionPathSafety.checkExistingDirectory(url) == .unsafe {
            throw LectureSummaryStoreError.unsafePath(url: url)
        }
    }

    private func ensureSafeDirectory(_ url: URL) throws {
        switch CompletedSessionPathSafety.checkExistingDirectory(url) {
        case .missing: try DefaultFileSystemLocator.ensureDirectoryExists(url)
        case .safe: break
        case .unsafe: throw LectureSummaryStoreError.unsafePath(url: url)
        }
    }

    private func checkDestinationSafeToCommit(at url: URL) throws {
        if CompletedSessionPathSafety.checkExistingRegularFile(url) == .unsafe {
            throw LectureSummaryStoreError.unsafePath(url: url)
        }
    }

    private func readDataIfExists(at url: URL) throws -> Data? {
        switch CompletedSessionPathSafety.checkExistingRegularFile(url) {
        case .missing: return nil
        case .unsafe: throw LectureSummaryStoreError.unsafePath(url: url)
        case .safe: return try Data(contentsOf: url)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, url: URL) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw LectureSummaryStoreError.corruptArtifact(url: url, underlying: error.localizedDescription) }
    }
}
