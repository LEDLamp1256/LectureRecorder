import Foundation

nonisolated enum SummaryGenerationCommitOutcome: Sendable, Equatable {
    case created
    case createdDurabilityUncertain
    case alreadyExistsIdentical
    case conflict
}

nonisolated enum SummaryAnalysisCommitOutcome: Sendable, Equatable {
    case committed
    case committedDurabilityUncertain
    case alreadyCommittedIdentical
    case conflict
}

nonisolated enum SummaryDocumentCommitOutcome: Sendable, Equatable {
    case committed
    case committedDurabilityUncertain
    case alreadyCommittedIdentical
    case conflict
}

nonisolated enum SummaryArtifactLoadResult<Value: Sendable>: Sendable {
    case success(batchIndex: Int, value: Value)
    case failure(batchIndex: Int, error: String)

    var batchIndex: Int {
        switch self {
        case .success(let batchIndex, _): return batchIndex
        case .failure(let batchIndex, _): return batchIndex
        }
    }
}

nonisolated enum LectureSummaryStoreError: LocalizedError, Sendable {
    case corruptArtifact(url: URL, underlying: String)
    case unsupportedSchemaVersion(url: URL, version: Int)
    case identityMismatch(url: URL, reason: String)
    case invalidPlan(url: URL, underlying: LectureSummaryPlanValidationError)
    case unsafePath(url: URL)

    var errorDescription: String? {
        switch self {
        case .corruptArtifact(let url, let reason): return "Summary artifact at \(url.path) is corrupt: \(reason)"
        case .unsupportedSchemaVersion(let url, let version): return "Summary artifact at \(url.path) has unsupported schema version \(version)."
        case .identityMismatch(let url, let reason): return "Summary artifact at \(url.path) has a mismatched identity: \(reason)"
        case .invalidPlan(let url, let underlying):
            return "Summary generation at \(url.path) has an invalid frozen batch plan: \(underlying.errorDescription ?? "unknown reason")"
        case .unsafePath(let url): return "Path \(url.path) is a symlink or unexpected filesystem entry type."
        }
    }
}

nonisolated protocol LectureSummaryStoring: Sendable {
    func ensureDirectoriesExist(paths: SummaryArtifactPaths) throws
    func listGenerationIDs(sessionPaths: SessionPaths) throws -> [UUID]
    func createGenerationIfAbsent(_ record: LectureSummaryGenerationRecord, paths: SummaryArtifactPaths) throws -> SummaryGenerationCommitOutcome
    func loadGeneration(paths: SummaryArtifactPaths) throws -> LectureSummaryGenerationRecord?
    func commitAnalysis(_ analysis: LectureSummaryAnalysis, paths: SummaryArtifactPaths) throws -> SummaryAnalysisCommitOutcome
    func loadAnalysis(batchIndex: Int, paths: SummaryArtifactPaths) throws -> LectureSummaryAnalysis?
    func loadAllAnalyses(paths: SummaryArtifactPaths) throws -> [SummaryArtifactLoadResult<LectureSummaryAnalysis>]
    func commitDocument(_ document: LectureSummaryDocument, paths: SummaryArtifactPaths) throws -> SummaryDocumentCommitOutcome
    func loadDocument(paths: SummaryArtifactPaths) throws -> LectureSummaryDocument?
}
