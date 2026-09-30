import XCTest
@testable import LectureRecorder

final class MLXLectureSummaryGeneratorTests: XCTestCase {

    private func makeGenerator(driver: FakeMLXSessionDriver, maxItemsPerBatch: Int = 12) -> MLXLectureSummaryGenerator {
        MLXLectureSummaryGenerator(sessionDriver: driver, maxItemsPerBatch: maxItemsPerBatch)
    }

    private func mlxGeneration(
        source: LectureSummarySourceSnapshot,
        maxItemsPerBatch: Int = 2,
        provenance: LectureNotesGenerationProvenance = MLXSummaryConfiguration.generationProvenance
    ) throws -> LectureSummaryGenerationRecord {
        let plan = try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 10_000, maxItemsPerBatch: maxItemsPerBatch),
            partition: .forProvenance(provenance)
        )
        return LectureSummaryGenerationRecord.newGeneration(
            generationID: SummaryTestSupport.summaryGenerationID,
            sessionID: SummaryTestSupport.sessionID,
            sourceNotesGenerationID: SummaryTestSupport.notesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint,
            sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchPlan: plan,
            provenance: provenance,
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

    func testGeneratorProvenanceFollowsSelectedModel() {
        let driver = FakeMLXSessionDriver()
        XCTAssertEqual(makeGenerator(driver: driver).provenance, MLXSummaryConfiguration.generationProvenance)
        XCTAssertEqual(
            MLXLectureSummaryGenerator(sessionDriver: driver, modelDescriptor: .qwen3_14b_4bit).provenance,
            MLXSummaryConfiguration.generationProvenance(for: .qwen3_14b_4bit)
        )
    }

    func testModelMismatchedProvenanceIsRejectedWithoutDispatch() async throws {
        let source = try SummaryTestSupport.source()
        let generation8B = try mlxGeneration(source: source)
        let generation14B = try mlxGeneration(
            source: source, provenance: MLXSummaryConfiguration.generationProvenance(for: .qwen3_14b_4bit)
        )
        let driver = FakeMLXSessionDriver()
        let cases: [(MLXLectureSummaryGenerator, LectureSummaryGenerationRecord)] = [
            (makeGenerator(driver: driver), generation14B),
            (MLXLectureSummaryGenerator(sessionDriver: driver, modelDescriptor: .qwen3_14b_4bit), generation8B),
        ]

        for (generator, generation) in cases {
            do {
                _ = try await generator.generateAnalysis(
                    for: generation.batchPlan.batches[0], generation: generation, source: source
                )
                XCTFail("expected incompatibleProvenance")
            } catch let error as MLXLectureSummaryBackendError {
                XCTAssertEqual(error, .incompatibleProvenance)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(driver.respondCallCount, 0)
    }

    /// The exact model revision is part of Summary compatibility: a
    /// generation recorded with another revision of the same model is
    /// rejected before any model call, so artifacts from different revisions
    /// are never mixed; the exact configured revision is accepted.
    func testMismatchedModelRevisionIsRejectedBeforeInference() async throws {
        let source = try SummaryTestSupport.source()
        var otherRevision = MLXSummaryConfiguration.generationProvenance
        otherRevision.generatorVersion = "0000000000000000000000000000000000000000"
        let generation = try mlxGeneration(source: source, provenance: otherRevision)
        let driver = FakeMLXSessionDriver()
        do {
            _ = try await makeGenerator(driver: driver).generateAnalysis(for: generation.batchPlan.batches[0], generation: generation, source: source)
            XCTFail("expected incompatibleProvenance")
        } catch let error as MLXLectureSummaryBackendError {
            XCTAssertEqual(error, .incompatibleProvenance)
        }
        do {
            _ = try await makeGenerator(driver: driver).generateDocument(from: [], generation: generation, source: source)
            XCTFail("expected incompatibleProvenance")
        } catch let error as MLXLectureSummaryBackendError {
            XCTAssertEqual(error, .incompatibleProvenance)
        }
        XCTAssertEqual(driver.respondCallCount, 0)
        XCTAssertEqual(driver.tokenCountCallCount, 0)
        XCTAssertEqual(MLXSummaryConfiguration.generationProvenance.generatorVersion, "545dc4251c05440727734bcd94334791f6ab0192")
    }

    /// v7 accepts a printable `$` that v6 rejected; v1–v6 generations are
    /// never resumed under v7 — rejected before inference in both paths.
    func testSummaryRecipeIsV7AndOlderGenerationsAreRejectedBeforeInference() async throws {
        XCTAssertEqual(MLXSummaryConfiguration.recipeVersion, "mlx2-summary-v7")
        XCTAssertEqual(MLXSummaryConfiguration.generationProvenance.recipeVersion, "mlx2-summary-v7")
        for oldRecipe in ["mlx2-summary-v1", "mlx2-summary-v2", "mlx2-summary-v3", "mlx2-summary-v4", "mlx2-summary-v5", "mlx2-summary-v6"] {
            try await assertOldSummaryRecipeIsRejectedBeforeInference(oldRecipe)
        }
    }

    private func assertOldSummaryRecipeIsRejectedBeforeInference(_ oldRecipe: String) async throws {
        let source = try SummaryTestSupport.source()
        var v1 = MLXSummaryConfiguration.generationProvenance
        v1.recipeVersion = oldRecipe
        let generation = try mlxGeneration(source: source, provenance: v1)
        let driver = FakeMLXSessionDriver()
        do {
            _ = try await makeGenerator(driver: driver).generateAnalysis(for: generation.batchPlan.batches[0], generation: generation, source: source)
            XCTFail("expected incompatibleProvenance")
        } catch let error as MLXLectureSummaryBackendError {
            XCTAssertEqual(error, .incompatibleProvenance)
        }
        do {
            _ = try await makeGenerator(driver: driver).generateDocument(from: [], generation: generation, source: source)
            XCTFail("expected incompatibleProvenance")
        } catch let error as MLXLectureSummaryBackendError {
            XCTAssertEqual(error, .incompatibleProvenance)
        }
        XCTAssertEqual(driver.respondCallCount, 0)
        XCTAssertEqual(driver.tokenCountCallCount, 0)
    }

    /// A completed historical v1 Summary with model-authored reconstructed
    /// and uncertain passages still commits, loads, and validates unchanged.
    func testCompletedV1SummaryDocumentRemainsReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXSummaryV1Readable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SummaryTestSupport.source()
        var v1 = MLXSummaryConfiguration.generationProvenance
        v1.recipeVersion = "mlx2-summary-v1"
        let generation = try mlxGeneration(source: source, provenance: v1)
        let passages = [
            try SummaryTestSupport.passage(support: [SummaryTestSupport.itemIDs[0]], source: source),
            try SummaryTestSupport.passage(
                id: UUID(), support: [SummaryTestSupport.itemIDs[1]], fidelity: .reconstructed,
                uncertaintyNote: "Normalized notation.", source: source
            ),
            try SummaryTestSupport.passage(
                id: UUID(), support: [SummaryTestSupport.itemIDs[2]], fidelity: .uncertain,
                uncertaintyNote: "Qualified by the lecturer.", source: source
            ),
        ]
        let document = LectureSummaryDocument(
            generationID: generation.generationID, sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: v1,
            createdDate: Date(timeIntervalSince1970: 1_700_000_020),
            sections: [LectureSummarySection(heading: "Core", passages: passages)]
        )
        let paths = try SummaryArtifactPaths.validated(
            sessionPaths: DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: SummaryTestSupport.sessionID),
            sessionID: SummaryTestSupport.sessionID,
            generationID: generation.generationID
        )
        let store = LectureSummaryStore()
        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .created)
        XCTAssertEqual(try store.commitDocument(document, paths: paths), .committed)
        let loaded = try store.loadDocument(paths: paths)
        XCTAssertEqual(loaded, document)
        XCTAssertEqual(loaded?.sections[0].passages.map(\.fidelity), [.transcriptSupported, .reconstructed, .uncertain])
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(document: document, generation: generation, source: source))
    }

    /// A completed historical Summary is read without the generation-time
    /// text check: a v2 document whose passage holds the control characters
    /// seen in the v10 acceptance still commits, loads, and validates.
    func testCompletedV2SummaryWithControlCharactersRemainsReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXSummaryV2Readable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SummaryTestSupport.source()
        var v2 = MLXSummaryConfiguration.generationProvenance
        v2.recipeVersion = "mlx2-summary-v2"
        let generation = try mlxGeneration(source: source, provenance: v2)
        var passage = try SummaryTestSupport.passage(support: [SummaryTestSupport.itemIDs[0]], source: source)
        passage.text = "The quotient $ \u{0C}rac{f(x)}{\u{09}ext{delta } x} $ gives the slope."
        let document = LectureSummaryDocument(
            generationID: generation.generationID, sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: v2,
            createdDate: Date(timeIntervalSince1970: 1_700_000_020),
            sections: [LectureSummarySection(heading: "Core", passages: [passage])]
        )
        let paths = try SummaryArtifactPaths.validated(
            sessionPaths: DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: SummaryTestSupport.sessionID),
            sessionID: SummaryTestSupport.sessionID,
            generationID: generation.generationID
        )
        let store = LectureSummaryStore()
        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .created)
        XCTAssertEqual(try store.commitDocument(document, paths: paths), .committed)
        XCTAssertEqual(try store.loadDocument(paths: paths), document)
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(document: document, generation: generation, source: source))
    }

    /// A completed v3 Summary (made under the 8-passage batch cap) still
    /// commits, loads, and validates unchanged under v4.
    func testCompletedV3SummaryDocumentRemainsReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXSummaryV3Readable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SummaryTestSupport.source()
        var v3 = MLXSummaryConfiguration.generationProvenance
        v3.recipeVersion = "mlx2-summary-v3"
        let generation = try mlxGeneration(source: source, provenance: v3)
        let passage = try SummaryTestSupport.passage(support: [SummaryTestSupport.itemIDs[0]], source: source)
        let document = LectureSummaryDocument(
            generationID: generation.generationID, sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: v3,
            createdDate: Date(timeIntervalSince1970: 1_700_000_020),
            sections: [LectureSummarySection(heading: "Core", passages: [passage])]
        )
        let paths = try SummaryArtifactPaths.validated(
            sessionPaths: DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: SummaryTestSupport.sessionID),
            sessionID: SummaryTestSupport.sessionID,
            generationID: generation.generationID
        )
        let store = LectureSummaryStore()
        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .created)
        XCTAssertEqual(try store.commitDocument(document, paths: paths), .committed)
        XCTAssertEqual(try store.loadDocument(paths: paths), document)
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(document: document, generation: generation, source: source))
    }

    // MARK: - Batch coverage (v4)

    private func passagesCap(_ schema: String) throws -> (passages: Int?, supportMaximum: Int?, supportCount: Int?) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let passages = try XCTUnwrap((object["properties"] as? [String: Any])?["passages"] as? [String: Any])
        let support = try XCTUnwrap(((passages["items"] as? [String: Any])?["properties"] as? [String: Any])?["supportIndices"] as? [String: Any])
        return (passages["maxItems"] as? Int, (support["items"] as? [String: Any])?["maximum"] as? Int, support["maxItems"] as? Int)
    }

    /// A batch may return one passage per source item, bounded by the
    /// support-index cap; reduction and final sections still consolidate
    /// into at most 8.
    func testBatchPassageCapAllowsEveryItemWhileConsolidatingStagesKeepEight() throws {
        XCTAssertEqual([1, 3, 8, 11, 12, 13, 40].map { MLXLectureSummaryGenerator.batchPassageLimit(inputCount: $0) }, [1, 3, 8, 11, 12, 12, 12])
        XCTAssertEqual(MLXLectureSummaryGenerator.maximumConsolidatedPassages, 8)
        let batch = try passagesCap(MLXLectureSummaryGenerator.passagesJSONSchema(inputCount: 12, maximumPassages: 12))
        XCTAssertEqual(batch.passages, 12)
        XCTAssertEqual(batch.supportMaximum, 12, "support indices stay local to the batch")
        XCTAssertEqual(batch.supportCount, 12, "one passage may cite the whole batch")
        XCTAssertEqual(MLXSummaryResponseReserves.conservativeDefault.batchAnalysis, 3_072)
    }

    /// The v3 failure pattern — one passage per item, in order — now covers
    /// a full 12-item batch: the batch request's own schema admits all 12
    /// passages, and items 8–11 (1-based 9–12) reach the analysis.
    func testFullBatchOfOnePassagePerItemReachesTheLateItems() async throws {
        let (source, itemIDs) = try SummaryTestSupport.distinguishableSource(count: 12)
        let generation = try mlxGeneration(source: source, maxItemsPerBatch: 12)
        XCTAssertEqual(generation.batchPlan.batches.count, 1)
        let driver = FakeMLXSessionDriver()
        let passages = (1...12).map { #"{"text":"Explains item \#($0 - 1).","supportIndices":[\#($0)]}"# }
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":["# + passages.joined(separator: ",") + "]}")))

        let analysis = try await makeGenerator(driver: driver).generateAnalysis(
            for: generation.batchPlan.batches[0], generation: generation, source: source
        )

        let request = try XCTUnwrap(driver.respondArguments.first)
        XCTAssertEqual(request.instructions, MLXLectureSummaryGenerator.batchInstructions)
        XCTAssertEqual(try passagesCap(request.jsonSchema).passages, 12, "v3 capped this request at 8")
        XCTAssertEqual(request.maxOutputTokens, 3_072)
        XCTAssertEqual(analysis.passages.count, 12)
        XCTAssertEqual(analysis.passages.map(\.supportingNoteItemIDs), itemIDs.map { [$0] }, "passage i cites item i, including 8–11")
        XCTAssertTrue(analysis.passages.allSatisfy { $0.fidelity == .transcriptSupported && $0.uncertaintyNote == nil })
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: generation, source: source))
    }

    /// Consolidation still works: a few passages may each cite several
    /// related items, late items included, with fidelity and references
    /// derived from that support.
    func testConsolidatedPassagesCanCiteLateItems() async throws {
        let (source, itemIDs) = try SummaryTestSupport.distinguishableSource(count: 12)
        let generation = try mlxGeneration(source: source, maxItemsPerBatch: 12)
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"Items 0 and 5.","supportIndices":[6,1]},{"text":"Items 8 to 11.","supportIndices":[9,10,11,12]}]}"#)))

        let analysis = try await makeGenerator(driver: driver).generateAnalysis(
            for: generation.batchPlan.batches[0], generation: generation, source: source
        )

        XCTAssertEqual(analysis.passages.map(\.supportingNoteItemIDs), [[itemIDs[0], itemIDs[5]], Array(itemIDs[8...11])])
        XCTAssertEqual(analysis.passages[1].sourceReferences,
                       (8...11).map { NotesSourceReference(sessionID: SummaryTestSupport.sessionID, sequenceNumber: $0) })
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: generation, source: source))
    }

    /// Support indices stay bounded by the batch: an index past the last
    /// item still fails closed, as before.
    func testSupportBeyondTheBatchIsStillRejected() async throws {
        let (source, _) = try SummaryTestSupport.distinguishableSource(count: 12)
        let generation = try mlxGeneration(source: source, maxItemsPerBatch: 12)
        let driver = FakeMLXSessionDriver()
        for _ in 0..<2 {
            driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"Out of range.","supportIndices":[13]}]}"#)))
        }
        do {
            _ = try await makeGenerator(driver: driver).generateAnalysis(
                for: generation.batchPlan.batches[0], generation: generation, source: source
            )
            XCTFail("an out-of-batch support index must fail")
        } catch is MLXLectureSummaryBackendError {}
    }

    func testBatchInstructionsAskForTheWholeBatchWithoutRequiringOnePassagePerItem() {
        let instructions = MLXLectureSummaryGenerator.batchInstructions
        for phrase in [
            "Consider every numbered item, from the first to the last; items late in the list matter as much as early ones.",
            "Combine closely related items into one passage whose supportIndices cite all of them",
            "leave out only items that are genuinely secondary or redundant",
        ] {
            XCTAssertTrue(instructions.contains(phrase), phrase)
        }
        XCTAssertFalse(instructions.contains("one passage per"), "no one-passage-per-item requirement")
        XCTAssertFalse(instructions.contains("every item must"), "coverage is not required")
    }

    // MARK: - Notes-section structure (v5)

    private func sectionIndex(of id: UUID, in source: LectureSummarySourceSnapshot) -> String {
        source.sourceItems.first { $0.item.id == id }!.sectionHeading
    }

    /// Batches never cross a Notes section; a section over 12 items splits
    /// into the fewest batches, as evenly as possible; indices stay global
    /// and contiguous, so the plan meets every persisted-plan invariant.
    func testNotesSectionPlanNeverCrossesSectionsAndSplitsLargeSectionsEvenly() throws {
        let (source, _) = try SummaryTestSupport.distinguishableSource(sectionSizes: [3, 14, 1, 12, 13, 25])
        let budget = try LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 100_000, maxItemsPerBatch: 12)
        let plan = try LectureSummaryPlanner.plan(source: source, budget: budget, partition: .notesSections)

        XCTAssertEqual(plan.batches.map(\.sourceItemIDs.count), [3, 7, 7, 1, 12, 7, 6, 9, 8, 8], "sizes within a section differ by at most one")
        for batch in plan.batches {
            XCTAssertEqual(Set(batch.sourceItemIDs.map { sectionIndex(of: $0, in: source) }).count, 1, "batch \(batch.batchIndex) stays in one Notes section")
        }
        XCTAssertEqual(plan.batches.map(\.batchIndex), Array(0..<10))
        XCTAssertEqual(plan.batches.map(\.firstSourceItemIndex), [0, 3, 10, 17, 18, 30, 37, 43, 52, 60])
        XCTAssertEqual(plan.maxItemsPerBatch, 12)
        XCTAssertNoThrow(try plan.validateStructure())
        XCTAssertNotEqual(plan, try LectureSummaryPlanner.plan(source: source, budget: budget), "the contiguous plan crosses sections")
    }

    /// Only MLX v5 and v6 plans are partitioned by Notes section: the
    /// existing entry point and every older or non-MLX provenance keep the
    /// contiguous plan they were made with.
    func testOnlyV5AndLaterProvenancePartitionsByNotesSection() throws {
        let (source, _) = try SummaryTestSupport.distinguishableSource(sectionSizes: [3, 14, 1])
        let budget = try LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 100_000, maxItemsPerBatch: 12)
        XCTAssertEqual(try LectureSummaryPlanner.plan(source: source, budget: budget),
                       try LectureSummaryPlanner.plan(source: source, budget: budget, partition: .contiguous))
        XCTAssertEqual(MLXSummaryConfiguration.generationProvenance.recipeVersion, "mlx2-summary-v7")
        XCTAssertEqual(LectureSummaryPlanPartition.forProvenance(MLXSummaryConfiguration.generationProvenance), .notesSections)
        for historical in ["mlx2-summary-v5", "mlx2-summary-v6"] {
            var provenance = MLXSummaryConfiguration.generationProvenance
            provenance.recipeVersion = historical
            XCTAssertEqual(LectureSummaryPlanPartition.forProvenance(provenance), .notesSections, "completed \(historical) plans still replan by Notes section")
        }
        for recipe in ["mlx2-summary-v1", "mlx2-summary-v2", "mlx2-summary-v3", "mlx2-summary-v4"] {
            var old = MLXSummaryConfiguration.generationProvenance
            old.recipeVersion = recipe
            XCTAssertEqual(LectureSummaryPlanPartition.forProvenance(old), .contiguous, recipe)
        }
        XCTAssertEqual(LectureSummaryPlanPartition.forProvenance(FoundationModelsSummaryConfiguration.generationProvenance), .contiguous)
        XCTAssertEqual(LectureSummaryPlanPartition.forProvenance(SummaryTestSupport.provenance), .contiguous)
    }

    func testMakePlanPartitionsByNotesSection() async throws {
        let (source, _) = try SummaryTestSupport.distinguishableSource(sectionSizes: [5, 14])
        let plan = try await MLXLectureSummaryGenerator(sessionDriver: FakeMLXSessionDriver()).makePlan(for: source)
        XCTAssertEqual(plan.batches.map(\.sourceItemIDs.count), [5, 7, 7])
        XCTAssertEqual(plan, try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: plan.maxSerializedBytesPerBatch, maxItemsPerBatch: 12),
            partition: .notesSections
        ))
    }

    /// The v4 failure shape: flattened, consecutive passages that a model
    /// planner cut into 12/12/12/1 groups. Under v5 no planner runs — each
    /// Notes section's own passages form its Summary section, in Notes
    /// order, under its Notes title, with no passage from another section.
    func testFlattenedPassagesFollowTheNotesSectionsNotConsecutiveGroups() async throws {
        let (source, itemIDs) = try SummaryTestSupport.distinguishableSource(sectionSizes: [12, 12, 12, 1])
        let generation = try mlxGeneration(source: source, maxItemsPerBatch: 12)
        XCTAssertEqual(generation.batchPlan.batches.map(\.sourceItemIDs.count), [12, 12, 12, 1])
        // Each batch: one passage per item — 37 flattened carriers.
        let analyses = try generation.batchPlan.batches.map { batch in
            LectureSummaryAnalysis(
                generationID: generation.generationID, sessionID: generation.sessionID,
                sourceNotesGenerationID: generation.sourceNotesGenerationID,
                transcriptFingerprint: generation.transcriptFingerprint,
                sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
                batchID: batch.batchID, batchIndex: batch.batchIndex,
                passages: try batch.sourceItemIDs.map { id in
                    LectureSummaryPassage(
                        text: "About \(source.sourceItems.first { $0.item.id == id }!.item.body).",
                        supportingNoteItemIDs: [id],
                        sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(supportingItemIDs: [id], source: source),
                        fidelity: .transcriptSupported
                    )
                },
                provenance: generation.provenance
            )
        }
        let driver = FakeMLXSessionDriver()
        for count in [12, 12, 12, 1] {
            let all = (1...count).map(String.init).joined(separator: ",")
            driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"Section prose.","supportIndices":[\#(all)]}]}"#)))
        }

        let document = try await makeGenerator(driver: driver).generateDocument(from: analyses, generation: generation, source: source)

        XCTAssertEqual(document.sections.map(\.heading), ["Section 0", "Section 1", "Section 2", "Section 3"])
        XCTAssertEqual(document.sections.map { $0.passages[0].supportingNoteItemIDs },
                       [Array(itemIDs[0..<12]), Array(itemIDs[12..<24]), Array(itemIDs[24..<36]), [itemIDs[36]]])
        XCTAssertEqual(driver.respondArguments.map(\.instructions), Array(repeating: MLXLectureSummaryGenerator.finalSectionInstructions, count: 4),
                       "one final-section call per Notes section and no planning call")
        for (index, call) in driver.respondArguments.enumerated() {
            let batch = generation.batchPlan.batches[index]
            XCTAssertTrue(call.prompt.contains("Section \(index)"))
            for other in 0..<37 where !(batch.firstSourceItemIndex...batch.lastSourceItemIndex).contains(other) {
                XCTAssertFalse(call.prompt.contains("About item \(other)."), "section \(index) never sees item \(other)")
            }
        }
    }

    /// A Notes section with more passages than one final-section request
    /// takes is reduced within that section only; other sections' passages
    /// never enter its reduction or final call.
    func testReductionStaysInsideItsNotesSection() async throws {
        let (source, itemIDs) = try SummaryTestSupport.distinguishableSource(sectionSizes: [2, 14])
        let generation = try mlxGeneration(source: source, maxItemsPerBatch: 12)
        XCTAssertEqual(generation.batchPlan.batches.map(\.sourceItemIDs.count), [2, 7, 7])
        let analyses = try generation.batchPlan.batches.map { batch in
            LectureSummaryAnalysis(
                generationID: generation.generationID, sessionID: generation.sessionID,
                sourceNotesGenerationID: generation.sourceNotesGenerationID,
                transcriptFingerprint: generation.transcriptFingerprint,
                sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
                batchID: batch.batchID, batchIndex: batch.batchIndex,
                passages: try batch.sourceItemIDs.map { id in
                    LectureSummaryPassage(
                        text: "About \(source.sourceItems.first { $0.item.id == id }!.item.body).",
                        supportingNoteItemIDs: [id],
                        sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(supportingItemIDs: [id], source: source),
                        fidelity: .transcriptSupported
                    )
                },
                provenance: generation.provenance
            )
        }
        let driver = FakeMLXSessionDriver()
        // Section 0: 2 carriers fit directly.
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"Section 0 prose.","supportIndices":[1,2]}]}"#)))
        // Section 1: 14 carriers exceed 12 → reduced as groups of 12 and 2.
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"Reduced A.","supportIndices":[1,2,3,4,5,6]},{"text":"Reduced B.","supportIndices":[7,8,9,10,11,12]}]}"#)))
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"Reduced C.","supportIndices":[1,2]}]}"#)))
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"Section 1 prose.","supportIndices":[1,2,3]}]}"#)))

        let document = try await makeGenerator(driver: driver).generateDocument(from: analyses, generation: generation, source: source)

        let calls = driver.respondArguments
        XCTAssertEqual(calls.map(\.instructions), [
            MLXLectureSummaryGenerator.finalSectionInstructions,
            MLXLectureSummaryGenerator.reductionInstructions,
            MLXLectureSummaryGenerator.reductionInstructions,
            MLXLectureSummaryGenerator.finalSectionInstructions,
        ])
        for call in calls.dropFirst() {
            XCTAssertFalse(call.prompt.contains("About item 0.") || call.prompt.contains("About item 1."), "section 0 never enters section 1's reduction")
        }
        XCTAssertEqual(document.sections.map(\.heading), ["Section 0", "Section 1"])
        XCTAssertEqual(document.sections[0].passages[0].supportingNoteItemIDs, Array(itemIDs[0..<2]))
        XCTAssertEqual(document.sections[1].passages[0].supportingNoteItemIDs, Array(itemIDs[2..<16]), "support flows through reduction")
    }

    /// Analyses whose batch would span two Notes sections are refused:
    /// structure comes from the Notes sections by construction.
    func testBatchSpanningNotesSectionsIsRefused() throws {
        let (source, _) = try SummaryTestSupport.distinguishableSource(sectionSizes: [2, 2])
        let flat = try LectureSummaryPlanner.plan(
            source: source, budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 100_000, maxItemsPerBatch: 12)
        )
        let analysis = LectureSummaryAnalysis(
            generationID: UUID(), sessionID: source.sessionID, sourceNotesGenerationID: source.sourceNotesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint, sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchID: flat.batches[0].batchID, batchIndex: 0,
            passages: [LectureSummaryPassage(text: "t", supportingNoteItemIDs: [source.sourceItems[0].item.id], sourceReferences: [], fidelity: .transcriptSupported)],
            provenance: MLXSummaryConfiguration.generationProvenance
        )
        XCTAssertThrowsError(try MLXLectureSummaryGenerator.notesSectionGroups([analysis], plan: flat, source: source)) {
            XCTAssertEqual($0 as? MLXLectureSummaryBackendError, .malformedResponse("batch spans more than one Notes section"))
        }
    }

    // MARK: - Generated text integrity (v3)

    func testGeneratedTextAcceptsOneParagraphOfProseAndUnicodeMathematics() {
        for text in [
            "Ohm's law, V = IR, relates voltage and current.",
            "The electric field is related to potential through the gradient, E = −∇V.",
            "dφ = −E · dx; ΔW = F·Δx; x² ≤ 10 Ω; f′(x) = 2x — “quoted”, ‘single’ … α β γ ε₀ ρ ∫ ∑ √ ∞ ≈ ≠ → ×",
        ] {
            XCTAssertNoThrow(try MLXLectureSummaryGenerator.requireIntactGeneratedText(text), text)
        }
    }

    /// A passage is one plain paragraph. Line breaks, tabs, every other C0
    /// control, DEL, every C1 control, and backslashes are rejected, never
    /// repaired.
    func testGeneratedTextRejectsEveryControlAndBackslashWithoutRepair() {
        let rejected: [UInt32] = Array(0x00...0x1F) + [0x5C, 0x7F] + Array(0x80...0x9F)
        for scalar in rejected {
            let text = "Before" + String(Character(Unicode.Scalar(scalar)!)) + "after."
            XCTAssertThrowsError(try MLXLectureSummaryGenerator.requireIntactGeneratedText(text)) {
                XCTAssertEqual($0 as? MLXLectureSummaryBackendError, .invalidGeneratedText(String(format: "U+%04X", scalar)))
            }
        }
        XCTAssertEqual(
            MLXLectureSummaryBackendError.invalidGeneratedText("U+005C").errorDescription,
            "The local MLX model produced Summary text with an unsupported generated character: U+005C."
        )
    }

    /// v7: a printable `$` — alone or as delimiters — is accepted as is.
    func testGeneratedTextAcceptsPrintableDollarSigns() {
        for text in [
            "The kit costs $5.",
            "$x$ is the unknown.",
            "Energy is $ E = mc² $ in plain text.",
            "$$ Δx → 0 $$",
        ] {
            XCTAssertNoThrow(try MLXLectureSummaryGenerator.requireIntactGeneratedText(text), text)
        }
    }

    /// v6 rejected this passage on its `$`; v7 maps it with the text
    /// exactly as generated — no repair, stripping, or retry.
    func testPassageWithOnlyPrintableDollarsMapsUnchanged() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let text = "Energy is $ E = mc² $, and the kit costs $5."
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"\#(text)","supportIndices":[1]}]}"#)))

        let analysis = try await makeGenerator(driver: driver).generateAnalysis(
            for: generation.batchPlan.batches[0], generation: generation, source: source
        )

        XCTAssertEqual(analysis.passages.map(\.text), [text])
        XCTAssertEqual(driver.respondCallCount, 1)
    }

    /// The v5 acceptance defect: the model wrote `$ E = -\nabla V $`; JSON
    /// decoded `\n` as a line feed, leaving `$ E = -⏎abla V $`. Every
    /// decoded `\n…` command (`\nabla`, `\neq`, `\ne`, `\nu`, `\newline`)
    /// carries that line feed, so each fails closed on the first response —
    /// nothing is repaired, retried, or returned.
    func testLatexCommandsDecodedToLineFeedsFailClosedWithoutRepair() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        // The exact persisted v5 text: a real line feed where `\n` was. It
        // fails on that line feed, not on its now-accepted `$`.
        let decodedV5 = "$ E = -" + "\u{0A}" + "abla V $"
        XCTAssertThrowsError(try MLXLectureSummaryGenerator.requireIntactGeneratedText(decodedV5)) {
            XCTAssertEqual($0 as? MLXLectureSummaryBackendError, .invalidGeneratedText("U+000A"))
        }
        XCTAssertThrowsError(try MLXLectureSummaryGenerator.requireIntactGeneratedText("E = -" + "\u{0A}" + "abla V")) {
            XCTAssertEqual($0 as? MLXLectureSummaryBackendError, .invalidGeneratedText("U+000A"))
        }
        let cases: [(json: String, expected: String)] = [
            (#"$ E = -\nabla V $"#, "U+000A"),
            (#"E = -\nabla V"#, "U+000A"),
            (#"x \neq 0"#, "U+000A"),
            (#"a \ne b"#, "U+000A"),
            (#"frequency \nu"#, "U+000A"),
            (#"first \newline second"#, "U+000A"),
        ]
        for (json, expected) in cases {
            let driver = FakeMLXSessionDriver()
            driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"\#(json)","supportIndices":[1]}]}"#)))
            driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"Clean.","supportIndices":[1]}]}"#)))
            do {
                let analysis = try await makeGenerator(driver: driver).generateAnalysis(
                    for: generation.batchPlan.batches[0], generation: generation, source: source
                )
                XCTFail("accepted \(json) as \(analysis.passages.map(\.text))")
            } catch let error as MLXLectureSummaryBackendError {
                XCTAssertEqual(error, .invalidGeneratedText(expected), json)
            }
            XCTAssertEqual(driver.respondCallCount, 1, "\(json): fails closed without a retry")
        }
    }

    /// A completed v5 Summary whose passage holds the v5 defect's legacy
    /// text still commits, loads, and validates: the v6 paragraph rule
    /// applies at generation only.
    func testCompletedV5SummaryWithLegacyLineFeedAndDollarsRemainsReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXSummaryV5Readable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SummaryTestSupport.source()
        var v5 = MLXSummaryConfiguration.generationProvenance
        v5.recipeVersion = "mlx2-summary-v5"
        let generation = try mlxGeneration(source: source, provenance: v5)
        var passage = try SummaryTestSupport.passage(support: [SummaryTestSupport.itemIDs[0]], source: source)
        passage.text = "The field follows $ E = -\nabla V $ from the potential."
        let document = LectureSummaryDocument(
            generationID: generation.generationID, sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: v5,
            createdDate: Date(timeIntervalSince1970: 1_700_000_020),
            sections: [LectureSummarySection(heading: "Concepts", passages: [passage])]
        )
        let paths = try SummaryArtifactPaths.validated(
            sessionPaths: DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: SummaryTestSupport.sessionID),
            sessionID: SummaryTestSupport.sessionID,
            generationID: generation.generationID
        )
        let store = LectureSummaryStore()
        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .created)
        XCTAssertEqual(try store.commitDocument(document, paths: paths), .committed)
        XCTAssertEqual(try store.loadDocument(paths: paths), document)
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(document: document, generation: generation, source: source))
    }

    /// The v10 acceptance defect: single-backslash LaTeX inside a JSON
    /// string decodes `\f` and `\t` to U+000C and U+0009. Since v7 its `$`
    /// delimiter is accepted, so the decoded control fails it. The batch path
    /// fails closed on the first response — no identical greedy retry.
    func testLatexEscapesDecodedToControlCharactersFailBatchAnalysisWithoutRetry() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"The quotient $ \frac{f(x + \text{delta } x) - f(x)}{\text{delta } x} $ gives the slope.","supportIndices":[1]}]}"#)))
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"Clean.","supportIndices":[1]}]}"#)))
        do {
            _ = try await makeGenerator(driver: driver).generateAnalysis(for: generation.batchPlan.batches[0], generation: generation, source: source)
            XCTFail("expected invalidGeneratedText")
        } catch let error as MLXLectureSummaryBackendError {
            XCTAssertEqual(error, .invalidGeneratedText("U+000C"))
        }
        XCTAssertEqual(driver.respondCallCount, 1, "deterministic greedy output is never retried")
    }

    /// Trimming never hides a mis-decoded escape at either end of the text.
    func testControlCharacterAtTheStartOfAPassageIsNotTrimmedAway() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"\frac{a}{b} is the quotient.","supportIndices":[1]}]}"#)))
        do {
            _ = try await makeGenerator(driver: driver).generateAnalysis(for: generation.batchPlan.batches[0], generation: generation, source: source)
            XCTFail("expected invalidGeneratedText")
        } catch let error as MLXLectureSummaryBackendError {
            XCTAssertEqual(error, .invalidGeneratedText("U+000C"))
        }
        XCTAssertEqual(driver.respondCallCount, 1)
    }

    func testLatexEscapesDecodedToControlCharactersFailFinalCompositionWithoutRetry() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source, maxItemsPerBatch: 3)
        let analyses = try validAnalyses(generation: generation, source: source)
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: #"{"passages":[{"text":"As $ \text{delta } x $ shrinks, $ n \times x^{n-1} $ follows.","supportIndices":[1]}]}"#)))
        do {
            _ = try await makeGenerator(driver: driver).generateDocument(from: analyses, generation: generation, source: source)
            XCTFail("expected invalidGeneratedText")
        } catch let error as MLXLectureSummaryBackendError {
            XCTAssertEqual(error, .invalidGeneratedText("U+0009"))
        }
        XCTAssertEqual(driver.respondCallCount, 1, "one final-section call, not retried; no structure call exists")
    }

    func testSummaryInstructionsForbidBackslashLatex() {
        let contract = "Write each passage as a single paragraph with no line breaks. Write mathematics as plain text or Unicode symbols (for example Δx, ×, ≤, x², f′(x)); never use backslashes, LaTeX commands, or $ delimiters."
        for instructions in [
            MLXLectureSummaryGenerator.batchInstructions,
            MLXLectureSummaryGenerator.reductionInstructions,
            MLXLectureSummaryGenerator.finalSectionInstructions,
        ] {
            XCTAssertTrue(instructions.contains(contract))
            XCTAssertTrue(instructions.hasSuffix("Respond with JSON matching the given schema only."))
        }
    }

    // MARK: - Batch analysis

    private func analysis(
        support: [Int], batchIndex: Int = 0, generator: MLXLectureSummaryGenerator? = nil, extraJSON: String = ""
    ) async throws -> (LectureSummaryAnalysis, FakeMLXSessionDriver) {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source, maxItemsPerBatch: 3)
        let driver = FakeMLXSessionDriver()
        let indices = support.map(String.init).joined(separator: ",")
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"passages":[{"text":"Explains the material.","supportIndices":[\(indices)]\(extraJSON)}]}
        """)))
        let analysis = try await makeGenerator(driver: driver).generateAnalysis(
            for: generation.batchPlan.batches[batchIndex], generation: generation, source: source
        )
        return (analysis, driver)
    }

    func testGenerateAnalysisSucceedsWithGroundedJSON() async throws {
        let (analysis, driver) = try await analysis(support: [1, 2])
        XCTAssertEqual(analysis.passages.count, 1)
        XCTAssertEqual(
            Set(analysis.passages[0].supportingNoteItemIDs),
            Set([SummaryTestSupport.itemIDs[0], SummaryTestSupport.itemIDs[1]])
        )
        XCTAssertEqual(driver.respondCallCount, 1)
    }

    /// Fixture items 1/2 (Notes section "Concepts", batch 0) are
    /// transcriptSupported/reconstructed; item 3 ("Conclusion", batch 1) is
    /// uncertain. Every passage's fidelity is the most cautious of its
    /// cited support.
    func testAnalysisFidelityIsDerivedFromCitedSupport() async throws {
        let cases: [([Int], Int, LectureNoteContentFidelity, String?)] = [
            ([1], 0, .transcriptSupported, nil),
            ([2], 0, .reconstructed, "Normalized from spoken notation."),
            ([1, 2], 0, .reconstructed, "Normalized from spoken notation."),
            ([1], 1, .uncertain, "The lecturer qualified this conclusion."),
        ]
        for (support, batchIndex, fidelity, note) in cases {
            let passage = try await analysis(support: support, batchIndex: batchIndex).0.passages[0]
            XCTAssertEqual(passage.fidelity, fidelity, "support \(support)")
            XCTAssertEqual(passage.uncertaintyNote, note, "support \(support)")
        }
    }

    /// A model that still emits the old fidelity fields cannot choose the
    /// passage's fidelity: they are ignored, and there is no violation to
    /// retry.
    func testModelAuthoredFidelityIsIgnored() async throws {
        let overconfident = #","fidelity":"transcriptSupported","uncertaintyExplanation":"""#
        let (supported, driver) = try await analysis(support: [2], extraJSON: overconfident)
        XCTAssertEqual(supported.passages[0].fidelity, .reconstructed)
        XCTAssertEqual(driver.respondCallCount, 1)

        let overcautious = #","fidelity":"uncertain","uncertaintyExplanation":"Model doubt.""#
        let plain = try await analysis(support: [1], extraJSON: overcautious).0.passages[0]
        XCTAssertEqual(plain.fidelity, .transcriptSupported)
        XCTAssertNil(plain.uncertaintyNote)
    }

    func testPassageSchemaAndInstructionsNoLongerAskForFidelity() {
        let schema = MLXLectureSummaryGenerator.passagesJSONSchema(inputCount: 3, maximumPassages: 3)
        XCTAssertFalse(schema.contains("fidelity"))
        XCTAssertFalse(schema.contains("uncertaintyExplanation"))
        XCTAssertTrue(schema.contains(#""required": ["text", "supportIndices"]"#))
        for instructions in [
            MLXLectureSummaryGenerator.batchInstructions,
            MLXLectureSummaryGenerator.reductionInstructions,
            MLXLectureSummaryGenerator.finalSectionInstructions,
        ] {
            XCTAssertFalse(instructions.contains("uncertaintyExplanation"))
            XCTAssertFalse(instructions.contains("\"reconstructed\""))
            XCTAssertFalse(instructions.contains("\"transcriptSupported\""))
        }
    }

    func testDerivedFidelityAndNoteHelpers() {
        func carrier(_ fidelity: LectureNoteContentFidelity, _ note: String? = nil) -> MLXSummaryCarrier {
            MLXSummaryCarrier(text: "t", supportingNoteItemIDs: [UUID()], sourceReferences: [], fidelity: fidelity, uncertaintyNote: note)
        }
        XCTAssertEqual(MLXLectureSummaryGenerator.derivedFidelity(of: [carrier(.transcriptSupported), carrier(.transcriptSupported)]), .transcriptSupported)
        XCTAssertEqual(MLXLectureSummaryGenerator.derivedFidelity(of: [carrier(.reconstructed), carrier(.transcriptSupported)]), .reconstructed)
        XCTAssertEqual(MLXLectureSummaryGenerator.derivedFidelity(of: [carrier(.reconstructed), carrier(.uncertain)]), .uncertain)

        let mixed = [carrier(.uncertain, "A."), carrier(.reconstructed, "R."), carrier(.uncertain, "A."), carrier(.uncertain, " B. ")]
        XCTAssertEqual(MLXLectureSummaryGenerator.derivedUncertaintyNote(fidelity: .uncertain, selected: mixed), "A. B.")
        XCTAssertEqual(
            MLXLectureSummaryGenerator.derivedUncertaintyNote(fidelity: .reconstructed, selected: [carrier(.reconstructed)]),
            MLXLectureSummaryGenerator.fallbackUncertaintyNote
        )
        XCTAssertNil(MLXLectureSummaryGenerator.derivedUncertaintyNote(fidelity: .transcriptSupported, selected: mixed))
    }

    func testGenerateAnalysisRecoversOnRetryAfterMalformedFirstAttempt() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let batch = generation.batchPlan.batches[0]
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: "not json")))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"passages":[{"text":"Recovered on retry.","supportIndices":[1]}]}
        """)))
        let generator = makeGenerator(driver: driver)

        let analysis = try await generator.generateAnalysis(for: batch, generation: generation, source: source)
        XCTAssertEqual(analysis.passages.count, 1)
        XCTAssertEqual(driver.respondCallCount, 2)
        XCTAssertEqual(driver.respondSamplings, [nil, nil], "Summary batch analysis stays greedy, including its retry")
    }

    // MARK: - Document synthesis (no reduction needed)

    /// One valid analysis per planned batch: a single passage citing the
    /// whole batch at its most cautious source fidelity.
    private func validAnalyses(
        generation: LectureSummaryGenerationRecord, source: LectureSummarySourceSnapshot
    ) throws -> [LectureSummaryAnalysis] {
        try generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }.map { batch in
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
            return LectureSummaryAnalysis(
                generationID: generation.generationID, sessionID: generation.sessionID,
                sourceNotesGenerationID: generation.sourceNotesGenerationID,
                transcriptFingerprint: generation.transcriptFingerprint,
                sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
                batchID: batch.batchID, batchIndex: batch.batchIndex,
                passages: [passage], provenance: generation.provenance
            )
        }
    }

    /// The fixture's two Notes sections ("Concepts": items 1–2;
    /// "Conclusion": item 3) become the Summary's two sections, in order,
    /// under their Notes titles — one final-section call each, no structure
    /// call — with fidelity derived from each section's own carriers.
    func testGenerateDocumentWritesOneSectionPerNotesSectionUnderItsNotesTitle() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try mlxGeneration(source: source)
        let analyses = try validAnalyses(generation: generation, source: source)
        let driver = FakeMLXSessionDriver()
        for _ in 0..<2 {
            driver.enqueueRespond(.success(.stub(jsonText: """
            {"passages":[{"text":"Final synthesized section text.","supportIndices":[1],"fidelity":"transcriptSupported","uncertaintyExplanation":""}]}
            """)))
        }

        let document = try await makeGenerator(driver: driver).generateDocument(from: analyses, generation: generation, source: source)

        XCTAssertEqual(document.sections.map(\.heading), ["Concepts", "Conclusion"])
        XCTAssertEqual(document.sections.map(\.passages.count), [1, 1])
        XCTAssertEqual(document.sections[0].passages[0].supportingNoteItemIDs, Array(SummaryTestSupport.itemIDs[0...1]))
        XCTAssertEqual(document.sections[1].passages[0].supportingNoteItemIDs, [SummaryTestSupport.itemIDs[2]])
        // The model's claimed fidelity is ignored; each passage takes the
        // most cautious fidelity of its own section's carriers.
        XCTAssertEqual(document.sections.map { $0.passages[0].fidelity }, [.reconstructed, .uncertain])
        let finalCalls = driver.respondArguments
        XCTAssertEqual(finalCalls.map(\.instructions), Array(repeating: MLXLectureSummaryGenerator.finalSectionInstructions, count: 2))
        XCTAssertTrue(finalCalls[0].prompt.contains("Concepts") && !finalCalls[0].prompt.contains("Passage for batch 1"))
        XCTAssertTrue(finalCalls[1].prompt.contains("Conclusion") && !finalCalls[1].prompt.contains("Passage for batch 0"))
        XCTAssertEqual(driver.respondSamplings, [nil, nil], "Summary stays greedy: Notes v10 sampling never reaches it")
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
