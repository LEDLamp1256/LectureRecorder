import XCTest
@testable import LectureRecorder

final class MLXLectureSummaryGeneratorTests: XCTestCase {

    private func makeGenerator(driver: FakeMLXSessionDriver, maxItemsPerBatch: Int = 12) -> MLXLectureSummaryGenerator {
        MLXLectureSummaryGenerator(sessionDriver: driver, maxItemsPerBatch: maxItemsPerBatch)
    }

    private func mlxGeneration(source: LectureSummarySourceSnapshot, maxItemsPerBatch: Int = 2) throws -> LectureSummaryGenerationRecord {
        let plan = try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 10_000, maxItemsPerBatch: maxItemsPerBatch)
        )
        return LectureSummaryGenerationRecord.newGeneration(
            generationID: SummaryTestSupport.summaryGenerationID,
            sessionID: SummaryTestSupport.sessionID,
            sourceNotesGenerationID: SummaryTestSupport.notesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint,
            sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchPlan: plan,
            provenance: MLXSummaryConfiguration.generationProvenance,
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )
    }

    // MARK: - Availability

    func testAvailabilityDelegatesToDriver() {
        let driver = FakeMLXSessionDriver()
        driver.setAvailability(.unavailable(description: "model not provisioned"))
        let generator = makeGenerator(driver: driver)
        XCTAssertEqual(generator.availabilityForNewGeneration(), .unavailable(description: "model not provisioned"))
    }

    // MARK: - Provenance

    func testGenerateAnalysisRejectsIncompatibleProvenance() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let driver = FakeMLXSessionDriver()
        let generator = makeGenerator(driver: driver)
        let batch = generation.batchPlan.batches[0]

        do {
            _ = try await generator.generateAnalysis(for: batch, generation: generation, source: source)
            XCTFail("expected incompatibleProvenance")
        } catch let error as MLXLectureSummaryBackendError {
            XCTAssertEqual(error, .incompatibleProvenance)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 0, "must never dispatch a request for incompatible provenance")
    }

    // MARK: - Batch analysis

    func testGenerateAnalysisSucceedsWithGroundedJSON() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let batch = generation.batchPlan.batches[0]
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"passages":[{"text":"Explains the first concept and its formula.","supportIndices":[1,2],"fidelity":"reconstructed","uncertaintyExplanation":"Normalized notation."}]}
        """)))
        let generator = makeGenerator(driver: driver)

        let analysis = try await generator.generateAnalysis(for: batch, generation: generation, source: source)
        XCTAssertEqual(analysis.passages.count, 1)
        XCTAssertEqual(analysis.passages[0].fidelity, .reconstructed)
        XCTAssertEqual(
            Set(analysis.passages[0].supportingNoteItemIDs),
            Set([SummaryTestSupport.itemIDs[0], SummaryTestSupport.itemIDs[1]])
        )
        XCTAssertEqual(driver.respondCallCount, 1)
    }

    func testGenerateAnalysisFailsClosedOnFidelityViolation() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let batch = generation.batchPlan.batches[0]
        let driver = FakeMLXSessionDriver()
        // Local index 2 (itemIDs[1]) is .reconstructed in the frozen source
        // — claiming transcriptSupported over it is a fidelity violation on
        // both retry attempts.
        for _ in 0..<2 {
            driver.enqueueRespond(.success(.stub(jsonText: """
            {"passages":[{"text":"Overconfident claim.","supportIndices":[2],"fidelity":"transcriptSupported","uncertaintyExplanation":""}]}
            """)))
        }
        let generator = makeGenerator(driver: driver)

        do {
            _ = try await generator.generateAnalysis(for: batch, generation: generation, source: source)
            XCTFail("expected fidelityViolation")
        } catch let error as MLXLectureSummaryBackendError {
            XCTAssertEqual(error, .fidelityViolation)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 2, "a retryable structural failure is retried once before failing")
    }

    func testGenerateAnalysisRecoversOnRetryAfterMalformedFirstAttempt() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let batch = generation.batchPlan.batches[0]
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: "not json")))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"passages":[{"text":"Recovered on retry.","supportIndices":[1],"fidelity":"transcriptSupported","uncertaintyExplanation":""}]}
        """)))
        let generator = makeGenerator(driver: driver)

        let analysis = try await generator.generateAnalysis(for: batch, generation: generation, source: source)
        XCTAssertEqual(analysis.passages.count, 1)
        XCTAssertEqual(driver.respondCallCount, 2)
    }

    // MARK: - Document synthesis (no reduction needed)

    func testGenerateDocumentSucceedsWithoutReduction() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let orderedBatches = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }

        var analyses: [LectureSummaryAnalysis] = []
        for batch in orderedBatches {
            let itemIDs = batch.sourceItemIDs
            let requiredFidelity = source.sourceItems
                .filter { itemIDs.contains($0.item.id) }
                .map(\.item.fidelity)
                .max { fidelityRank($0) < fidelityRank($1) } ?? .transcriptSupported
            let passage = LectureSummaryPassage(
                text: "Passage for batch \(batch.batchIndex).",
                supportingNoteItemIDs: itemIDs,
                sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(supportingItemIDs: itemIDs, source: source),
                fidelity: requiredFidelity,
                uncertaintyNote: requiredFidelity == .transcriptSupported ? nil : "matches frozen source fidelity"
            )
            analyses.append(LectureSummaryAnalysis(
                generationID: generation.generationID, sessionID: generation.sessionID,
                sourceNotesGenerationID: generation.sourceNotesGenerationID,
                transcriptFingerprint: generation.transcriptFingerprint,
                sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
                batchID: batch.batchID, batchIndex: batch.batchIndex,
                passages: [passage], provenance: generation.provenance
            ))
        }

        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"sections":[{"title":"Overview","supportIndices":[1,2]}]}
        """)))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"passages":[{"text":"Final synthesized section text.","supportIndices":[1,2],"fidelity":"uncertain","uncertaintyExplanation":"Mixed confidence sources."}]}
        """)))
        let generator = makeGenerator(driver: driver)

        let document = try await generator.generateDocument(from: analyses, generation: generation, source: source)
        XCTAssertEqual(document.sections.count, 1)
        XCTAssertEqual(document.sections[0].heading, "Overview")
        XCTAssertEqual(document.sections[0].passages.count, 1)
        XCTAssertEqual(document.sections[0].passages[0].fidelity, .uncertain)
        XCTAssertEqual(driver.respondCallCount, 2)
    }

    func testGenerateDocumentRejectsMismatchedAnalysisCoverage() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let driver = FakeMLXSessionDriver()
        let generator = makeGenerator(driver: driver)

        do {
            _ = try await generator.generateDocument(from: [], generation: generation, source: source)
            XCTFail("expected malformedResponse for missing batch coverage")
        } catch let error as MLXLectureSummaryBackendError {
            guard case .malformedResponse = error else { return XCTFail("expected malformedResponse, got \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 0)
    }

    // MARK: - Plan

    func testMakePlanReturnsProviderNeutralPlanCoveringEverySourceItem() async throws {
        let source = try SummaryTestSupport.source()
        let driver = FakeMLXSessionDriver()
        let generator = MLXLectureSummaryGenerator(sessionDriver: driver, maxItemsPerBatch: 12)

        let plan = try await generator.makePlan(for: source)
        XCTAssertFalse(plan.batches.isEmpty)
        XCTAssertEqual(plan.batches.flatMap(\.sourceItemIDs).count, source.sourceItems.count)
    }

    private func fidelityRank(_ fidelity: LectureNoteContentFidelity) -> Int {
        switch fidelity {
        case .transcriptSupported: return 0
        case .reconstructed: return 1
        case .uncertain: return 2
        }
    }
}
