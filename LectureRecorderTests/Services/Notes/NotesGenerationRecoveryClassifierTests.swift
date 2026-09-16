import XCTest
@testable import LectureRecorder

/// Pure, fast tests for `NotesGenerationRecoveryClassifier` — every required
/// semantic from T5-B contract §5, exercised directly against hand-built
/// fixtures with no filesystem I/O.
final class NotesGenerationRecoveryClassifierTests: XCTestCase {
    private let sessionID = UUID()
    private let generationID = UUID()
    private let fingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "a", count: 64))

    private func makeUnit(_ sequenceNumber: Int) -> NotesTranscriptSourceUnit {
        NotesTranscriptSourceUnit(
            sequenceNumber: sequenceNumber,
            chunkFileName: "chunk_\(sequenceNumber).caf",
            text: "unit \(sequenceNumber)",
            startOffsetSeconds: Double(sequenceNumber) * 30,
            durationSeconds: 30
        )
    }

    private func makeSnapshot(unitCount: Int, fingerprint: TranscriptSourceFingerprint? = nil, sessionID: UUID? = nil) -> NotesTranscriptSourceSnapshot {
        NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID ?? self.sessionID,
            units: (0..<unitCount).map(makeUnit),
            fingerprint: fingerprint ?? self.fingerprint
        )
    }

    private func makeWindows(count: Int) -> [NotesInputWindow] {
        (0..<count).map { index in
            NotesInputWindow(windowIndex: index, firstSequenceNumber: index, lastSequenceNumber: index, unitCount: 1, isOversizedSingleUnit: false)
        }
    }

    private func makeGeneration(windowCount: Int, fingerprint: TranscriptSourceFingerprint? = nil, sessionID: UUID? = nil) -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord.newGeneration(
            generationID: generationID,
            sessionID: sessionID ?? self.sessionID,
            transcriptFingerprint: fingerprint ?? self.fingerprint,
            windowPlan: NotesWindowPlan(windows: makeWindows(count: windowCount)),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeAnalysis(windowIndex: Int, generation: LectureNotesGenerationRecord) -> LectureNotesWindowAnalysis {
        LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: windowIndex,
            ownedRange: NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: windowIndex),
            items: [
                LectureNoteItem(
                    kind: .explanation,
                    body: "body \(windowIndex)",
                    fidelity: .transcriptSupported,
                    sourceReferences: [NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: windowIndex)]
                )
            ]
        )
    }

    private func makeDocument(generation: LectureNotesGenerationRecord, analyses: [LectureNotesWindowAnalysis]) -> LectureNotesDocument {
        LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            createdDate: Date(timeIntervalSince1970: 1_700_000_000),
            overview: "overview",
            sections: analyses.map { LectureNoteSection(heading: "Window \($0.windowIndex)", items: $0.items) }
        )
    }

    private func makeOperationState(lifecycle: NotesGenerationOperationLifecycle, failureDescription: String? = nil, generation: LectureNotesGenerationRecord) -> NotesGenerationOperationState {
        NotesGenerationOperationState(
            sessionID: generation.sessionID,
            generationID: generation.generationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            activeRunID: UUID(),
            runAttemptCount: 1,
            lifecycle: lifecycle,
            failureDescription: failureDescription
        )
    }

    // MARK: - Completed / ready for synthesis

    func testCompletedWhenValidDocumentAndExactCoverage() {
        let generation = makeGeneration(windowCount: 2)
        let snapshot = makeSnapshot(unitCount: 2)
        let analyses = (0..<2).map { makeAnalysis(windowIndex: $0, generation: generation) }
        let document = makeDocument(generation: generation, analyses: analyses)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: document, operationState: nil
        )
        XCTAssertEqual(result, .completed(document: document))
    }

    func testReadyForSynthesisWhenFullCoverageNoDocument() {
        let generation = makeGeneration(windowCount: 2)
        let snapshot = makeSnapshot(unitCount: 2)
        let analyses = (0..<2).map { makeAnalysis(windowIndex: $0, generation: generation) }

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: nil, operationState: nil
        )
        XCTAssertEqual(result, .readyForSynthesis(analyses: analyses))
    }

    func testEmptyPrefixResumableFromZeroWhenNothingCommittedYet() {
        let generation = makeGeneration(windowCount: 3)
        let snapshot = makeSnapshot(unitCount: 3)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: [], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .resumable(nextWindowIndex: 0, interruption: .notStarted))
    }

    func testResumableFromKWhenPrefixIncomplete() {
        let generation = makeGeneration(windowCount: 3)
        let snapshot = makeSnapshot(unitCount: 3)
        let analyses = (0..<2).map { makeAnalysis(windowIndex: $0, generation: generation) }

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: nil, operationState: nil
        )
        XCTAssertEqual(result, .resumable(nextWindowIndex: 2, interruption: .notStarted))
    }

    // MARK: - Interruption reasons

    func testInterruptedWhenPersistedRunningWithIncompletePrefix() {
        let generation = makeGeneration(windowCount: 3)
        let snapshot = makeSnapshot(unitCount: 3)
        let analyses = (0..<1).map { makeAnalysis(windowIndex: $0, generation: generation) }
        let state = makeOperationState(lifecycle: .running, generation: generation)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: nil, operationState: state
        )
        XCTAssertEqual(result, .resumable(nextWindowIndex: 1, interruption: .interruptedRunningState))
    }

    func testContinuableWhenCancelledAndIncompletePrefix() {
        let generation = makeGeneration(windowCount: 3)
        let snapshot = makeSnapshot(unitCount: 3)
        let analyses = (0..<1).map { makeAnalysis(windowIndex: $0, generation: generation) }
        let state = makeOperationState(lifecycle: .cancelled, generation: generation)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: nil, operationState: state
        )
        XCTAssertEqual(result, .resumable(nextWindowIndex: 1, interruption: .cancelled))
    }

    func testRetryableWhenRecoverableFailureAndValidPrefixPreserved() {
        let generation = makeGeneration(windowCount: 3)
        let snapshot = makeSnapshot(unitCount: 3)
        let analyses = (0..<2).map { makeAnalysis(windowIndex: $0, generation: generation) }
        let state = makeOperationState(lifecycle: .failed, failureDescription: "window 2 boom", generation: generation)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: nil, operationState: state
        )
        // Artifact progress (the valid 0..<2 prefix) is preserved verbatim
        // regardless of the persisted failure — contract §14.
        XCTAssertEqual(result, .resumable(nextWindowIndex: 2, interruption: .recoverableFailure(description: "window 2 boom")))
    }

    // MARK: - Operation-state precedence (contract §14)

    func testStaleCompletedOperationStateIgnoredWhenPrefixIncomplete() {
        let generation = makeGeneration(windowCount: 3)
        let snapshot = makeSnapshot(unitCount: 3)
        let analyses = (0..<1).map { makeAnalysis(windowIndex: $0, generation: generation) }
        let state = makeOperationState(lifecycle: .completed, generation: generation)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: nil, operationState: state
        )
        XCTAssertEqual(result, .resumable(nextWindowIndex: 1, interruption: .notStarted))
    }

    func testCompletedIgnoresOperationStateClaimingRunning() {
        let generation = makeGeneration(windowCount: 1)
        let snapshot = makeSnapshot(unitCount: 1)
        let analyses = [makeAnalysis(windowIndex: 0, generation: generation)]
        let document = makeDocument(generation: generation, analyses: analyses)
        let state = makeOperationState(lifecycle: .running, generation: generation)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: document, operationState: state
        )
        XCTAssertEqual(result, .completed(document: document))
    }

    // MARK: - Stale source

    func testStaleSourceWhenSessionMismatch() {
        let generation = makeGeneration(windowCount: 1)
        let snapshot = makeSnapshot(unitCount: 1, sessionID: UUID())

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: [], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .staleSource)
    }

    func testStaleSourceWhenFingerprintMismatch() {
        let generation = makeGeneration(windowCount: 1)
        let differentFingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "b", count: 64))
        let snapshot = makeSnapshot(unitCount: 1, fingerprint: differentFingerprint)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: [], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .staleSource)
    }

    func testStaleSourceWhenPlanNoLongerCoversGrownSource() {
        let generation = makeGeneration(windowCount: 1) // plan covers only sequence 0
        let snapshot = makeSnapshot(unitCount: 2) // source now has sequences 0 and 1

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: [], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .staleSource)
    }

    // MARK: - Damage

    func testDamagedWhenInvalidWindowPlanStructure() {
        let malformedPlan = NotesWindowPlan(windows: [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 5, lastSequenceNumber: 2, unitCount: 1, isOversizedSingleUnit: false)
        ])
        let generation = LectureNotesGenerationRecord.newGeneration(
            generationID: generationID, sessionID: sessionID, transcriptFingerprint: fingerprint,
            windowPlan: malformedPlan, provenance: LectureNotesGenerationProvenance(recipeVersion: "v1")
        )
        let snapshot = makeSnapshot(unitCount: 1)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: [], document: nil, operationState: nil
        )
        guard case .damaged(.invalidWindowPlan) = result else {
            return XCTFail("expected .damaged(.invalidWindowPlan), got \(result)")
        }
    }

    func testDamagedWhenNonPrefixGapAcrossCommittedAnalyses() {
        let generation = makeGeneration(windowCount: 4)
        let snapshot = makeSnapshot(unitCount: 4)
        // Windows 0, 1, and 3 committed — window 2 missing. Must never be
        // silently treated as resumable from window 2 alone.
        let analyses = [0, 1, 3].map { makeAnalysis(windowIndex: $0, generation: generation) }

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: nil, operationState: nil
        )
        XCTAssertEqual(result, .damaged(reason: .nonPrefixCoverage(presentIndices: [0, 1, 3])))
    }

    func testDamagedWhenDuplicateAnalysis() {
        let generation = makeGeneration(windowCount: 2)
        let snapshot = makeSnapshot(unitCount: 2)
        let analyses = [makeAnalysis(windowIndex: 0, generation: generation), makeAnalysis(windowIndex: 0, generation: generation)]

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: nil, operationState: nil
        )
        XCTAssertEqual(result, .damaged(reason: .duplicateAnalysis(windowIndex: 0)))
    }

    func testDamagedWhenAnalysisOutsidePlan() {
        let generation = makeGeneration(windowCount: 1)
        let snapshot = makeSnapshot(unitCount: 1)
        let analyses = [makeAnalysis(windowIndex: 5, generation: generation)]

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: nil, operationState: nil
        )
        XCTAssertEqual(result, .damaged(reason: .analysisOutsidePlan(windowIndex: 5)))
    }

    func testDamagedWhenAnalysisFailsIndividualValidation() {
        let generation = makeGeneration(windowCount: 1)
        let snapshot = makeSnapshot(unitCount: 1)
        // Owned range does not match the planned window (0...0) — an
        // individually corrupt/invalid analysis.
        var mutated = makeAnalysis(windowIndex: 0, generation: generation)
        mutated.ownedRange = NotesSourceReference(
            sessionID: generation.sessionID, firstSequenceNumber: 0, lastSequenceNumber: 5
        )

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: [mutated], document: nil, operationState: nil
        )
        guard case .damaged(.corruptOrInvalidAnalysis(let windowIndex, _)) = result, windowIndex == 0 else {
            return XCTFail("expected .damaged(.corruptOrInvalidAnalysis), got \(result)")
        }
    }

    func testDamagedWhenDocumentWithoutCompleteCoverage() {
        let generation = makeGeneration(windowCount: 2)
        let snapshot = makeSnapshot(unitCount: 2)
        let analyses = [makeAnalysis(windowIndex: 0, generation: generation)]
        let document = makeDocument(generation: generation, analyses: analyses)

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: document, operationState: nil
        )
        XCTAssertEqual(result, .damaged(reason: .documentWithoutCompleteCoverage))
    }

    func testDamagedWhenDocumentConflictsWithGeneration() {
        let generation = makeGeneration(windowCount: 1)
        let snapshot = makeSnapshot(unitCount: 1)
        let analyses = [makeAnalysis(windowIndex: 0, generation: generation)]
        var document = makeDocument(generation: generation, analyses: analyses)
        document.provenance = LectureNotesGenerationProvenance(recipeVersion: "mismatched-recipe")

        let result = NotesGenerationRecoveryClassifier.classify(
            generation: generation, sourceSnapshot: snapshot, analyses: analyses, document: document, operationState: nil
        )
        guard case .damaged(.invalidDocument) = result else {
            return XCTFail("expected .damaged(.invalidDocument), got \(result)")
        }
    }
}
