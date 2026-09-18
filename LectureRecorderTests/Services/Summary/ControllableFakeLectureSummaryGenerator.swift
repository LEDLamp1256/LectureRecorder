import Foundation
@testable import LectureRecorder

/// Deterministic, controllable `LectureSummaryGenerating` fake — test-target
/// only. Records every call; lets a test script a failure for a specific
/// batch index or for synthesis, or arm a one-shot cooperative-polling gate
/// that suspends the call until the enclosing `Task` is cancelled, so
/// cancellation tests can deterministically get a generator call genuinely
/// in flight before cancelling — no sleeps or polling from the test itself.
/// Mirrors `ControllableFakeLectureNotesGenerator` exactly, adapted for the
/// Summary domain. Every value it produces is genuinely valid against
/// `LectureSummaryIntegrityValidator` — this fake exercises the real F1/F2
/// trust boundary, never bypasses it.
actor ControllableFakeLectureSummaryGenerator: LectureSummaryGenerating {
    nonisolated let provenance: LectureNotesGenerationProvenance

    private let maxItemsPerBatch: Int
    private let maxSerializedBytesPerBatch: Int

    private var gatedBatchIndices: Set<Int> = []
    private var gateSynthesis = false
    private var enteredBatchGates: Set<Int> = []
    private var enteredSynthesisGateFlag = false
    private var releaseSuccessfullyBatchIndices: Set<Int> = []
    private var releaseSynthesisSuccessfullyFlag = false
    private var failuresByBatchIndex: [Int: Error] = [:]
    private var synthesisFailure: Error?
    private var planFailure: Error?

    private(set) var analyzeCalls: [Int] = []
    private(set) var synthesizeCallCount = 0
    private(set) var makePlanCallCount = 0

    init(
        provenance: LectureNotesGenerationProvenance,
        maxItemsPerBatch: Int = 1,
        maxSerializedBytesPerBatch: Int = 10_000
    ) {
        self.provenance = provenance
        self.maxItemsPerBatch = maxItemsPerBatch
        self.maxSerializedBytesPerBatch = maxSerializedBytesPerBatch
    }

    func armGate(beforeBatchIndex batchIndex: Int) {
        gatedBatchIndices.insert(batchIndex)
    }

    func armSynthesisGate() {
        gateSynthesis = true
    }

    func hasEnteredGate(forBatchIndex batchIndex: Int) -> Bool {
        enteredBatchGates.contains(batchIndex)
    }

    var hasEnteredSynthesisGate: Bool { enteredSynthesisGateFlag }

    func setFailure(_ error: Error, forBatchIndex batchIndex: Int) {
        failuresByBatchIndex[batchIndex] = error
    }

    func setSynthesisFailure(_ error: Error) {
        synthesisFailure = error
    }

    func setPlanFailure(_ error: Error) {
        planFailure = error
    }

    func releaseGateSuccessfully(batchIndex: Int) {
        releaseSuccessfullyBatchIndices.insert(batchIndex)
    }

    func releaseSynthesisGateSuccessfully() {
        releaseSynthesisSuccessfullyFlag = true
    }

    func makePlan(for source: LectureSummarySourceSnapshot) async throws -> LectureSummaryPlan {
        makePlanCallCount += 1
        if let planFailure { throw planFailure }
        let budget = try LectureSummaryBatchBudget(
            maxSerializedBytesPerBatch: maxSerializedBytesPerBatch,
            maxItemsPerBatch: maxItemsPerBatch
        )
        return try LectureSummaryPlanner.plan(source: source, budget: budget)
    }

    func generateAnalysis(
        for batch: LectureSummaryBatch,
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) async throws -> LectureSummaryAnalysis {
        analyzeCalls.append(batch.batchIndex)

        if gatedBatchIndices.remove(batch.batchIndex) != nil {
            enteredBatchGates.insert(batch.batchIndex)
            while !Task.isCancelled && !releaseSuccessfullyBatchIndices.contains(batch.batchIndex) {
                await Task.yield()
            }
            if releaseSuccessfullyBatchIndices.remove(batch.batchIndex) == nil {
                try Task.checkCancellation()
            }
        }

        if let failure = failuresByBatchIndex[batch.batchIndex] {
            throw failure
        }

        let passages = try batch.sourceItemIDs.map { id -> LectureSummaryPassage in
            guard let sourceItem = source.sourceItems.first(where: { $0.item.id == id }) else {
                throw FakeSummaryGeneratorFailure(message: "unknown source item \(id)")
            }
            let fidelity = sourceItem.item.fidelity
            return LectureSummaryPassage(
                text: "analysis for \(id.uuidString)",
                supportingNoteItemIDs: [id],
                sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(supportingItemIDs: [id], source: source),
                fidelity: fidelity,
                uncertaintyNote: fidelity == .transcriptSupported ? nil : "fake uncertainty for \(id.uuidString)"
            )
        }
        return LectureSummaryAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: batch.batchID,
            batchIndex: batch.batchIndex,
            passages: passages,
            provenance: generation.provenance
        )
    }

    func generateDocument(
        from analyses: [LectureSummaryAnalysis],
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) async throws -> LectureSummaryDocument {
        synthesizeCallCount += 1

        if gateSynthesis {
            gateSynthesis = false
            enteredSynthesisGateFlag = true
            while !Task.isCancelled && !releaseSynthesisSuccessfullyFlag {
                await Task.yield()
            }
            if releaseSynthesisSuccessfullyFlag {
                releaseSynthesisSuccessfullyFlag = false
            } else {
                try Task.checkCancellation()
            }
        }

        if let synthesisFailure {
            throw synthesisFailure
        }

        let sections = analyses
            .sorted { $0.batchIndex < $1.batchIndex }
            .map { LectureSummarySection(heading: "Batch \($0.batchIndex)", passages: $0.passages) }
        return LectureSummaryDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: generation.provenance,
            sections: sections
        )
    }
}

/// A distinct, unclassified error type — used to prove
/// `LectureSummaryGenerationService` reports generator failures without
/// depending on any particular error shape. Conforms to `LocalizedError` so
/// `error.localizedDescription` (what the service actually surfaces) carries
/// `message` verbatim rather than a generic system-provided description.
struct FakeSummaryGeneratorFailure: Error, Equatable, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
