import Foundation

nonisolated struct SummaryArtifactPaths: Sendable, Equatable {
    nonisolated enum ValidationError: LocalizedError, Sendable, Equatable {
        case pathSessionMismatch
        case generationDirectoryEscapesSummariesDirectory

        var errorDescription: String? {
            switch self {
            case .pathSessionMismatch: return "The supplied session paths do not belong to the supplied session ID."
            case .generationDirectoryEscapesSummariesDirectory: return "The Summary generation directory escapes summaries/generations."
            }
        }
    }

    let sessionID: UUID
    let generationID: UUID
    let summariesDirectory: URL
    let generationsDirectory: URL
    let generationDirectory: URL
    let generationRecordURL: URL
    let batchAnalysesDirectory: URL
    let documentURL: URL
    /// Reserved canonical location only. T5-F1 does not define, read, or
    /// write Summary orchestration state.
    let operationStateURL: URL

    var ancestryChain: [URL] {
        [summariesDirectory, generationsDirectory, generationDirectory]
    }

    static func validated(
        sessionPaths: SessionPaths,
        sessionID: UUID,
        generationID: UUID
    ) throws -> SummaryArtifactPaths {
        guard sessionPaths.sessionDirectory.lastPathComponent == sessionID.uuidString else {
            throw ValidationError.pathSessionMismatch
        }
        let summaries = resolvedSummariesDirectory(sessionPaths: sessionPaths)
        let generations = summaries.appendingPathComponent("generations", isDirectory: true)
        let generation = generations.appendingPathComponent(generationID.uuidString, isDirectory: true)
        let prefix = generations.standardizedFileURL.path + "/"
        guard generation.standardizedFileURL.path.hasPrefix(prefix) else {
            throw ValidationError.generationDirectoryEscapesSummariesDirectory
        }
        return SummaryArtifactPaths(
            sessionID: sessionID,
            generationID: generationID,
            summariesDirectory: summaries,
            generationsDirectory: generations,
            generationDirectory: generation,
            generationRecordURL: generation.appendingPathComponent("generation.json"),
            batchAnalysesDirectory: generation.appendingPathComponent("batch_analyses", isDirectory: true),
            documentURL: generation.appendingPathComponent("document.json"),
            operationStateURL: generation.appendingPathComponent("operation-state.json")
        )
    }

    static func resolvedSummariesDirectory(sessionPaths: SessionPaths) -> URL {
        sessionPaths.sessionDirectory.appendingPathComponent("summaries", isDirectory: true)
    }

    static func generationsDirectory(sessionPaths: SessionPaths) -> URL {
        resolvedSummariesDirectory(sessionPaths: sessionPaths).appendingPathComponent("generations", isDirectory: true)
    }

    static func batchAnalysisFileName(for batchIndex: Int) -> String {
        "batch_\(String(format: "%04d", batchIndex)).analysis.json"
    }

    static func batchIndex(fromBatchAnalysisFileName name: String) -> Int? {
        let prefix = "batch_"
        let suffix = ".analysis.json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return Int(name[start..<end])
    }

    func batchAnalysisURL(batchIndex: Int) -> URL {
        batchAnalysesDirectory.appendingPathComponent(Self.batchAnalysisFileName(for: batchIndex))
    }
}
