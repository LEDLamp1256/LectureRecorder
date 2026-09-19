import Foundation
@testable import LectureRecorder

/// Deterministic, call-counting double used by
/// `LectureSummaryGeneratorRouterTests` to prove routing/no-fallback
/// behavior — mirrors `RecordingLectureNotesGenerator`'s role for the Notes
/// router tests.
final class RecordingLectureSummaryGenerator: LectureSummaryGenerating, NewLectureNotesGenerationAvailabilityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _makePlanCallCount = 0
    private var _generateAnalysisCallCount = 0
    private var _generateDocumentCallCount = 0

    let provenance: LectureNotesGenerationProvenance
    var availabilityResult: LectureNotesGenerationAvailability = .available
    var makePlanFailure: Error?
    var generateAnalysisFailure: Error?
    var generateDocumentFailure: Error?

    init(provenance: LectureNotesGenerationProvenance) {
        self.provenance = provenance
    }

    var makePlanCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _makePlanCallCount
    }

    var generateAnalysisCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _generateAnalysisCallCount
    }

    var generateDocumentCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _generateDocumentCallCount
    }

    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability {
        lock.lock(); defer { lock.unlock() }
        return availabilityResult
    }

    func makePlan(for source: LectureSummarySourceSnapshot) async throws -> LectureSummaryPlan {
        lock.lock()
        _makePlanCallCount += 1
        let failure = makePlanFailure
        lock.unlock()
        if let failure { throw failure }
        return try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 10_000, maxItemsPerBatch: 12)
        )
    }

    func generateAnalysis(
        for batch: LectureSummaryBatch,
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) async throws -> LectureSummaryAnalysis {
        lock.lock()
        _generateAnalysisCallCount += 1
        let failure = generateAnalysisFailure
        lock.unlock()
        if let failure { throw failure }
        return LectureSummaryAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: batch.batchID,
            batchIndex: batch.batchIndex,
            passages: [],
            provenance: generation.provenance
        )
    }

    func generateDocument(
        from analyses: [LectureSummaryAnalysis],
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) async throws -> LectureSummaryDocument {
        lock.lock()
        _generateDocumentCallCount += 1
        let failure = generateDocumentFailure
        lock.unlock()
        if let failure { throw failure }
        return LectureSummaryDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: generation.provenance,
            sections: []
        )
    }
}
