import XCTest
@testable import LectureRecorder

/// Pure, fast tests for `SummaryGenerationRecoveryClassifier` — every
/// required semantic from the T5-F3A architecture contract, exercised
/// directly against hand-built fixtures with no filesystem I/O. Mirrors
/// `NotesGenerationRecoveryClassifierTests` in structure and coverage,
/// adapted for the Summary domain's batch/dual-fingerprint identity.
final class SummaryGenerationRecoveryClassifierTests: XCTestCase {
    // MARK: - Fixtures

    private func singleItemBatchGeneration(source: LectureSummarySourceSnapshot) throws -> LectureSummaryGenerationRecord {
        let plan = try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 10_000, maxItemsPerBatch: 1)
        )
        return LectureSummaryGenerationRecord.newGeneration(
            generationID: SummaryTestSupport.summaryGenerationID,
            sessionID: source.sessionID,
            sourceNotesGenerationID: source.sourceNotesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint,
            sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchPlan: plan,
            provenance: SummaryTestSupport.provenance,
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )
    }

    private func makeAnalysis(
        batchIndex: Int,
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) throws -> LectureSummaryAnalysis {
        let batch = generation.batchPlan.batches.first { $0.batchIndex == batchIndex }!
        let passages = try batch.sourceItemIDs.map { id -> LectureSummaryPassage in
            let item = source.sourceItems.first { $0.item.id == id }!.item
            return LectureSummaryPassage(
                text: "analysis text for batch \(batchIndex)",
                supportingNoteItemIDs: [id],
                sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(supportingItemIDs: [id], source: source),
                fidelity: item.fidelity,
                uncertaintyNote: item.fidelity == .transcriptSupported ? nil : "fake uncertainty"
            )
        }
        return LectureSummaryAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: batch.batchID,
            batchIndex: batchIndex,
            passages: passages,
            provenance: generation.provenance
        )
    }

    private func makeDocument(generation: LectureSummaryGenerationRecord, analyses: [LectureSummaryAnalysis]) -> LectureSummaryDocument {
        LectureSummaryDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: generation.provenance,
            sections: analyses.sorted { $0.batchIndex < $1.batchIndex }.map {
                LectureSummarySection(heading: "Batch \($0.batchIndex)", passages: $0.passages)
            }
        )
    }

    private func makeOperationState(
        lifecycle: SummaryGenerationOperationLifecycle,
        failureDescription: String? = nil,
        generation: LectureSummaryGenerationRecord
    ) -> SummaryGenerationOperationState {
        SummaryGenerationOperationState(
            sessionID: generation.sessionID,
            generationID: generation.generationID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            activeRunID: UUID(),
            runAttemptCount: 1,
            lifecycle: lifecycle,
            failureDescription: failureDescription
        )
    }

    // MARK: - Completed / ready for synthesis

    func testCompletedWhenValidDocumentAndExactCoverage() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = try (0..<generation.batchPlan.batches.count).map { try makeAnalysis(batchIndex: $0, generation: generation, source: source) }
        let document = makeDocument(generation: generation, analyses: analyses)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: document, operationState: nil
        )
        XCTAssertEqual(result, .completed(document: document))
    }

    func testReadyForSynthesisWhenFullCoverageNoDocument() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = try (0..<generation.batchPlan.batches.count).map { try makeAnalysis(batchIndex: $0, generation: generation, source: source) }

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: nil, operationState: nil
        )
        XCTAssertEqual(result, .readyForSynthesis(analyses: analyses))
    }

    func testEmptyPrefixResumableFromZeroWhenNothingCommittedYet() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: [], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .resumable(nextBatchIndex: 0, interruption: .notStarted))
    }

    func testResumableFromKWhenPrefixIncomplete() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = [try makeAnalysis(batchIndex: 0, generation: generation, source: source)]

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: nil, operationState: nil
        )
        XCTAssertEqual(result, .resumable(nextBatchIndex: 1, interruption: .notStarted))
    }

    // MARK: - Interruption reasons

    func testInterruptedWhenPersistedRunningWithIncompletePrefix() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = [try makeAnalysis(batchIndex: 0, generation: generation, source: source)]
        let state = makeOperationState(lifecycle: .running, generation: generation)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: nil, operationState: state
        )
        XCTAssertEqual(result, .resumable(nextBatchIndex: 1, interruption: .interruptedRunningState))
    }

    func testContinuableWhenCancelledAndIncompletePrefix() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = [try makeAnalysis(batchIndex: 0, generation: generation, source: source)]
        let state = makeOperationState(lifecycle: .cancelled, generation: generation)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: nil, operationState: state
        )
        XCTAssertEqual(result, .resumable(nextBatchIndex: 1, interruption: .cancelled))
    }

    func testRetryableWhenRecoverableFailureAndValidPrefixPreserved() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = [try makeAnalysis(batchIndex: 0, generation: generation, source: source)]
        let state = makeOperationState(lifecycle: .failed, failureDescription: "batch 1 boom", generation: generation)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: nil, operationState: state
        )
        // Artifact progress (the valid 0..<1 prefix) is preserved verbatim
        // regardless of the persisted failure.
        XCTAssertEqual(result, .resumable(nextBatchIndex: 1, interruption: .recoverableFailure(description: "batch 1 boom")))
    }

    // MARK: - Incompatible provenance

    /// A partial generation — including one whose last run failed
    /// recoverably — that the current build cannot resume is classified
    /// incompatible, never resumable/retryable.
    func testPartialGenerationWithUnresumableProvenanceIsIncompatible() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = [try makeAnalysis(batchIndex: 0, generation: generation, source: source)]
        let state = makeOperationState(lifecycle: .failed, failureDescription: "batch 1 boom", generation: generation)
        for operationState in [nil, state] {
            let result = SummaryGenerationRecoveryClassifier.classify(
                generation: generation, source: source, analyses: analyses, document: nil, operationState: operationState,
                canResume: { _ in false }
            )
            XCTAssertEqual(result, .incompatibleProvenance)
        }
        XCTAssertEqual(SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: [], document: nil, operationState: nil, canResume: { _ in false }
        ), .incompatibleProvenance)
    }

    func testFullCoverageWithoutDocumentAndUnresumableProvenanceIsIncompatible() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = try (0..<generation.batchPlan.batches.count).map { try makeAnalysis(batchIndex: $0, generation: generation, source: source) }
        XCTAssertEqual(SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: nil, operationState: nil, canResume: { _ in false }
        ), .incompatibleProvenance)
    }

    /// Completed (and damaged) generations are classified before
    /// compatibility is consulted: a completed historical Summary stays
    /// viewable whatever produced it.
    func testCompletedGenerationStaysCompletedWhateverItsProvenance() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = try (0..<generation.batchPlan.batches.count).map { try makeAnalysis(batchIndex: $0, generation: generation, source: source) }
        let document = makeDocument(generation: generation, analyses: analyses)
        XCTAssertEqual(SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: document, operationState: nil, canResume: { _ in false }
        ), .completed(document: document))
        let partialWithDocument = [analyses[0]]
        XCTAssertEqual(SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: partialWithDocument, document: document, operationState: nil, canResume: { _ in false }
        ), .damaged(reason: .documentWithoutCompleteCoverage))
    }

    /// The production rule: only exactly the current MLX provenance can be
    /// resumed; older recipes, other model revisions, and other selectable
    /// models cannot; non-MLX backends keep their own runtime checks.
    func testProductionSummaryResumeRuleRequiresTheExactCurrentMLXProvenance() {
        let current = MLXSummaryConfiguration.generationProvenance
        XCTAssertTrue(LectureSummaryGeneratorRouter.canResume(current))
        for recipe in ["mlx2-summary-v1", "mlx2-summary-v2", "mlx2-summary-v3", "mlx2-summary-v4", "mlx2-summary-v5"] {
            var old = current
            old.recipeVersion = recipe
            XCTAssertFalse(LectureSummaryGeneratorRouter.canResume(old), recipe)
        }
        var otherRevision = current
        otherRevision.generatorVersion = "0000000000000000000000000000000000000000"
        XCTAssertFalse(LectureSummaryGeneratorRouter.canResume(otherRevision))
        XCTAssertFalse(LectureSummaryGeneratorRouter.canResume(MLXSummaryConfiguration.generationProvenance(for: .qwen3_14b_4bit)))
        XCTAssertTrue(LectureSummaryGeneratorRouter.canResume(SummaryTestSupport.provenance))
        XCTAssertTrue(LectureSummaryGeneratorRouter.canResume(FoundationModelsSummaryConfiguration.generationProvenance))
    }

    // MARK: - Operation-state precedence

    func testStaleCompletedOperationStateIgnoredWhenPrefixIncomplete() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let state = makeOperationState(lifecycle: .completed, generation: generation)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: [], document: nil, operationState: state
        )
        XCTAssertEqual(result, .resumable(nextBatchIndex: 0, interruption: .notStarted))
    }

    func testCompletedIgnoresOperationStateClaimingRunning() throws {
        // Use the 2-batch default generation so a single analysis can still
        // form full coverage.
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let analyses = try generation.batchPlan.batches.map { try makeAnalysis(batchIndex: $0.batchIndex, generation: generation, source: source) }
        let document = makeDocument(generation: generation, analyses: analyses)
        let state = makeOperationState(lifecycle: .running, generation: generation)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: document, operationState: state
        )
        XCTAssertEqual(result, .completed(document: document))
    }

    // MARK: - Stale source

    func testStaleSourceWhenSessionMismatch() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        var mismatched = source
        mismatched.sessionID = UUID()

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: mismatched, analyses: [], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .staleSource)
    }

    func testStaleSourceWhenSourceNotesGenerationMismatch() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        var mismatched = source
        mismatched.sourceNotesGenerationID = UUID()

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: mismatched, analyses: [], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .staleSource)
    }

    func testStaleSourceWhenTranscriptFingerprintMismatch() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        var mismatched = source
        mismatched.transcriptFingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "c", count: 64))

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: mismatched, analyses: [], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .staleSource)
    }

    func testStaleSourceWhenNotesDocumentFingerprintMismatch() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        var mismatched = source
        mismatched.sourceNotesDocumentFingerprint = NotesDocumentFingerprint(algorithmVersion: 1, digestHex: String(repeating: "d", count: 64))

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: mismatched, analyses: [], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .staleSource)
    }

    // MARK: - Historical Notes fingerprints (topics compatibility)

    /// The Notes document fingerprint of `SummaryTestSupport`'s fixture — a
    /// document with no topics, which the pre-`topics` encoder wrote
    /// without a `topics` key. A regression that re-introduces
    /// `"topics": []` changes this digest.
    private static let historicalFixtureNotesFingerprint = "8fc2d0b43ce6422c61e6e59343be69c6281397f0d42f1942f548ad7173df7fec"

    func testNotesWithoutTopicsKeepTheirHistoricalFingerprint() throws {
        let evidence = SummaryTestSupport.notesEvidence()
        XCTAssertTrue(evidence.1.sections.allSatisfy(\.topics.isEmpty))
        XCTAssertFalse(String(decoding: try AtomicFileWriter.defaultEncoder.encode(evidence.1), as: UTF8.self).contains("topics"))
        XCTAssertEqual(try LectureSummarySourceBuilder.fingerprint(document: evidence.1).digestHex, Self.historicalFixtureNotesFingerprint)
    }

    /// A completed Summary that pinned the historical fingerprint of Notes
    /// saved before topics existed stays completed — never `.staleSource`.
    func testCompletedSummaryOfNotesSavedBeforeTopicsStaysCompleted() throws {
        let source = try SummaryTestSupport.source()
        var generation = try singleItemBatchGeneration(source: source)
        generation.sourceNotesDocumentFingerprint = NotesDocumentFingerprint(algorithmVersion: 1, digestHex: Self.historicalFixtureNotesFingerprint)
        let analyses = try (0..<generation.batchPlan.batches.count).map { try makeAnalysis(batchIndex: $0, generation: generation, source: source) }
        let document = makeDocument(generation: generation, analyses: analyses)

        XCTAssertEqual(SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: document, operationState: nil
        ), .completed(document: document))
    }

    /// A real change to the Notes still makes the Summary stale, and real
    /// non-empty topics are part of the Notes identity.
    func testChangedNotesOrRealTopicsStillMakeTheSummaryStale() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let evidence = SummaryTestSupport.notesEvidence()

        var changedItem = evidence.1
        changedItem.sections[0].items[0].body = "A different first concept"
        var withTopics = evidence.1
        withTopics.sections[0].topics = ["Voltage"]
        for changed in [changedItem, withTopics] {
            var moved = source
            moved.sourceNotesDocumentFingerprint = try LectureSummarySourceBuilder.fingerprint(document: changed)
            XCTAssertNotEqual(moved.sourceNotesDocumentFingerprint, source.sourceNotesDocumentFingerprint)
            XCTAssertEqual(SummaryGenerationRecoveryClassifier.classify(
                generation: generation, source: moved, analyses: [], document: nil, operationState: nil
            ), .staleSource)
        }
    }

    // MARK: - Plan partition by provenance (Summary v5)

    private func mlxGeneration(
        source: LectureSummarySourceSnapshot, recipe: String, partition: LectureSummaryPlanPartition
    ) throws -> LectureSummaryGenerationRecord {
        var provenance = MLXSummaryConfiguration.generationProvenance
        provenance.recipeVersion = recipe
        return LectureSummaryGenerationRecord.newGeneration(
            generationID: SummaryTestSupport.summaryGenerationID,
            sessionID: source.sessionID,
            sourceNotesGenerationID: source.sourceNotesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint,
            sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchPlan: try LectureSummaryPlanner.plan(
                source: source,
                budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 10_000, maxItemsPerBatch: 3),
                partition: partition
            ),
            provenance: provenance,
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )
    }

    /// A completed MLX v4 Summary keeps its contiguous plan valid; a v5
    /// Summary is valid with its Notes-section plan. Each is damaged only
    /// under the other's partition — historical plans are never
    /// reinterpreted.
    func testEachRecipeReplansWithItsOwnPartition() throws {
        let source = try SummaryTestSupport.source()
        let v4 = try mlxGeneration(source: source, recipe: "mlx2-summary-v4", partition: .contiguous)
        let v5 = try mlxGeneration(source: source, recipe: "mlx2-summary-v5", partition: .notesSections)
        XCTAssertEqual(v4.batchPlan.batches.count, 1, "fixture: the contiguous plan spans both Notes sections")
        XCTAssertEqual(v5.batchPlan.batches.count, 2)

        for valid in [v4, v5] {
            let analyses = try (0..<valid.batchPlan.batches.count).map { try makeAnalysis(batchIndex: $0, generation: valid, source: source) }
            let document = makeDocument(generation: valid, analyses: analyses)
            XCTAssertEqual(SummaryGenerationRecoveryClassifier.classify(
                generation: valid, source: source, analyses: analyses, document: document, operationState: nil
            ), .completed(document: document), valid.provenance.recipeVersion)
        }
        var v4WithSectionPlan = v4
        v4WithSectionPlan.batchPlan = v5.batchPlan
        var v5WithContiguousPlan = v5
        v5WithContiguousPlan.batchPlan = v4.batchPlan
        for mismatched in [v4WithSectionPlan, v5WithContiguousPlan] {
            guard case .damaged(.planDoesNotMatchSource) = SummaryGenerationRecoveryClassifier.classify(
                generation: mismatched, source: source, analyses: [], document: nil, operationState: nil
            ) else { return XCTFail("\(mismatched.provenance.recipeVersion) must replan with its own partition") }
        }
    }

    // MARK: - Damage

    func testDamagedWhenInvalidBatchPlanStructure() throws {
        let source = try SummaryTestSupport.source()
        let malformedPlan = LectureSummaryPlan(
            maxSerializedBytesPerBatch: 100,
            maxItemsPerBatch: 1,
            batches: [
                LectureSummaryBatch(
                    batchID: "batch_0000", batchIndex: 0,
                    firstSourceItemIndex: 5, lastSourceItemIndex: 2,
                    sourceItemIDs: [source.sourceItems[0].item.id],
                    serializedByteCount: 10, isOversizedSingleItem: false
                )
            ]
        )
        let generation = LectureSummaryGenerationRecord.newGeneration(
            generationID: SummaryTestSupport.summaryGenerationID,
            sessionID: source.sessionID,
            sourceNotesGenerationID: source.sourceNotesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint,
            sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchPlan: malformedPlan,
            provenance: SummaryTestSupport.provenance
        )

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: [], document: nil, operationState: nil
        )
        guard case .damaged(.invalidBatchPlan) = result else {
            return XCTFail("expected .damaged(.invalidBatchPlan), got \(result)")
        }
    }

    /// T5-F3A correction: proves the deterministic-replan comparison is
    /// actually reached and actually fails when the persisted plan's
    /// content diverges from what `LectureSummaryPlanner` would compute for
    /// this exact (source, budget) pair — as distinct from
    /// `.invalidBatchPlan`, which only catches purely-structural defects
    /// that never require a source at all.
    func testDamagedWhenPlanDoesNotMatchDeterministicReplan() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        XCTAssertEqual(generation.batchPlan.batches.count, 3)

        // Swap the source items assigned to batches 0 and 1. Each batch
        // remains individually well-formed (one item, correct index range,
        // correct batchID) so purely-structural `validateStructure()` still
        // passes — the mismatch only appears once the plan is recomputed
        // from the (identity-matching) source and compared for equality.
        var mutatedPlan = generation.batchPlan
        let firstItems = mutatedPlan.batches[0].sourceItemIDs
        mutatedPlan.batches[0].sourceItemIDs = mutatedPlan.batches[1].sourceItemIDs
        mutatedPlan.batches[1].sourceItemIDs = firstItems
        XCTAssertNoThrow(try mutatedPlan.validateStructure())

        var mutatedGeneration = generation
        mutatedGeneration.batchPlan = mutatedPlan

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: mutatedGeneration, source: source, analyses: [], document: nil, operationState: nil
        )
        guard case .damaged(.planDoesNotMatchSource) = result else {
            return XCTFail("expected .damaged(.planDoesNotMatchSource), got \(result)")
        }
    }

    func testDamagedWhenNonPrefixGapAcrossCommittedAnalyses() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        XCTAssertEqual(generation.batchPlan.batches.count, 3)
        // Batches 0 and 2 committed — batch 1 missing. Must never be
        // silently treated as resumable from batch 1 alone.
        let analyses = try [0, 2].map { try makeAnalysis(batchIndex: $0, generation: generation, source: source) }

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: nil, operationState: nil
        )
        XCTAssertEqual(result, .damaged(reason: .nonPrefixCoverage(presentIndices: [0, 2])))
    }

    func testDamagedWhenDuplicateAnalysis() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analysis = try makeAnalysis(batchIndex: 0, generation: generation, source: source)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: [analysis, analysis], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .damaged(reason: .duplicateAnalysis(batchIndex: 0)))
    }

    func testDamagedWhenAnalysisOutsidePlan() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        var analysis = try makeAnalysis(batchIndex: 0, generation: generation, source: source)
        analysis.batchIndex = 99
        analysis.batchID = LectureSummaryPlanner.batchID(99)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: [analysis], document: nil, operationState: nil
        )
        XCTAssertEqual(result, .damaged(reason: .analysisOutsidePlan(batchIndex: 99)))
    }

    func testDamagedWhenAnalysisFailsIndividualValidation() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        var analysis = try makeAnalysis(batchIndex: 0, generation: generation, source: source)
        // Corrupt the batch identity so the analysis no longer matches its
        // own claimed batch — an individually invalid analysis.
        analysis.batchID = "not-the-real-batch-id"

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: [analysis], document: nil, operationState: nil
        )
        guard case .damaged(.corruptOrInvalidAnalysis(let batchIndex, _)) = result, batchIndex == 0 else {
            return XCTFail("expected .damaged(.corruptOrInvalidAnalysis), got \(result)")
        }
    }

    func testDamagedWhenDocumentWithoutCompleteCoverage() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = [try makeAnalysis(batchIndex: 0, generation: generation, source: source)]
        let document = makeDocument(generation: generation, analyses: analyses)

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: document, operationState: nil
        )
        XCTAssertEqual(result, .damaged(reason: .documentWithoutCompleteCoverage))
    }

    func testDamagedWhenDocumentConflictsWithGeneration() throws {
        let source = try SummaryTestSupport.source()
        let generation = try singleItemBatchGeneration(source: source)
        let analyses = try (0..<generation.batchPlan.batches.count).map { try makeAnalysis(batchIndex: $0, generation: generation, source: source) }
        var document = makeDocument(generation: generation, analyses: analyses)
        document.provenance = LectureNotesGenerationProvenance(recipeVersion: "mismatched-recipe")

        let result = SummaryGenerationRecoveryClassifier.classify(
            generation: generation, source: source, analyses: analyses, document: document, operationState: nil
        )
        guard case .damaged(.invalidDocument) = result else {
            return XCTFail("expected .damaged(.invalidDocument), got \(result)")
        }
    }
}
