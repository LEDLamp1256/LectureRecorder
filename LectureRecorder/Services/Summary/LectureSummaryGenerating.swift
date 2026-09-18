import Foundation

/// Provider-neutral generation boundary for dedicated lecture Summaries.
/// Persistence, recovery, operation state, and presentation remain outside
/// this protocol and are owned by the later orchestration layer.
nonisolated protocol LectureSummaryGenerating: Sendable {
    var provenance: LectureNotesGenerationProvenance { get }

    func makePlan(for source: LectureSummarySourceSnapshot) async throws -> LectureSummaryPlan

    func generateAnalysis(
        for batch: LectureSummaryBatch,
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) async throws -> LectureSummaryAnalysis

    func generateDocument(
        from analyses: [LectureSummaryAnalysis],
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) async throws -> LectureSummaryDocument
}
