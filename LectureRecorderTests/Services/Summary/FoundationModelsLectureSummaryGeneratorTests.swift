import FoundationModels
import XCTest
@testable import LectureRecorder

/// Thread-safe sink for `FoundationModelsSummaryDiagnosticEvent`s recorded
/// during a test. Collection order matches attempt order since the backend
/// awaits each attempt sequentially before starting the next.
private final class DiagnosticEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [FoundationModelsSummaryDiagnosticEvent] = []

    var events: [FoundationModelsSummaryDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: FoundationModelsSummaryDiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        storedEvents.append(event)
    }
}

/// Thread-safe sink for `FoundationModelsSummarySynthesisEvent`s recorded
/// during a test.
private final class SynthesisEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [FoundationModelsSummarySynthesisEvent] = []

    var events: [FoundationModelsSummarySynthesisEvent] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: FoundationModelsSummarySynthesisEvent) {
        lock.lock(); defer { lock.unlock() }
        storedEvents.append(event)
    }
}

final class FoundationModelsLectureSummaryGeneratorTests: XCTestCase {
    private var noReserve: FoundationModelsSummaryResponseReserves {
        FoundationModelsSummaryResponseReserves(
            batchAnalysis: 0, reduction: 0, finalStructure: 0, finalSection: 0, safety: 0
        )
    }

    private func passageDTO(
        _ text: String = "Grounded summary.",
        support: [Int] = [1],
        fidelity: String = "transcriptSupported",
        uncertainty: String = ""
    ) -> AppleSummaryPassageDTO {
        AppleSummaryPassageDTO(
            text: text,
            supportIndices: support,
            fidelity: fidelity,
            uncertaintyExplanation: uncertainty
        )
    }

    private func generator(
        _ driver: FakeFoundationModelsSessionDriver,
        maxItems: Int = 12,
        levels: Int = 8,
        diagnosticRecorder: (@Sendable (FoundationModelsSummaryDiagnosticEvent) -> Void)? = nil,
        preflightRecorder: (@Sendable (FoundationModelsSummaryPreflightEvent) -> Void)? = nil,
        synthesisRecorder: (@Sendable (FoundationModelsSummarySynthesisEvent) -> Void)? = nil
    ) -> FoundationModelsLectureSummaryGenerator {
        FoundationModelsLectureSummaryGenerator(
            sessionDriver: driver,
            responseReserves: noReserve,
            maxInputBytesPerCall: 100_000,
            maxItemsPerBatch: maxItems,
            maxReductionLevels: levels,
            diagnosticRecorder: diagnosticRecorder,
            preflightRecorder: preflightRecorder,
            synthesisRecorder: synthesisRecorder
        )
    }

    private func assertSupportIndexBounds(
        _ request: FakeFoundationModelsSchemaRequest,
        collectionProperty: String,
        upperBound: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.schemaDescription.utf8)) as? [String: Any],
            file: file, line: line
        )
        let properties = try XCTUnwrap(object["properties"] as? [String: Any], file: file, line: line)
        let collection = try XCTUnwrap(properties[collectionProperty] as? [String: Any], file: file, line: line)
        let itemReference = try XCTUnwrap(collection["items"] as? [String: Any], file: file, line: line)
        let item: [String: Any]
        if let reference = itemReference["$ref"] as? String {
            let name = String(reference.split(separator: "/").last ?? "")
            let definitions = try XCTUnwrap(object["$defs"] as? [String: Any], file: file, line: line)
            item = try XCTUnwrap(definitions[name] as? [String: Any], file: file, line: line)
        } else {
            item = itemReference
        }
        let itemProperties = try XCTUnwrap(item["properties"] as? [String: Any], file: file, line: line)
        let support = try XCTUnwrap(itemProperties["supportIndices"] as? [String: Any], file: file, line: line)
        let supportItem = try XCTUnwrap(support["items"] as? [String: Any], file: file, line: line)
        XCTAssertEqual((supportItem["minimum"] as? NSNumber)?.intValue, 1, file: file, line: line)
        XCTAssertEqual((supportItem["maximum"] as? NSNumber)?.intValue, upperBound, file: file, line: line)
        XCTAssertEqual((support["minItems"] as? NSNumber)?.intValue, 1, file: file, line: line)
        XCTAssertEqual((support["maxItems"] as? NSNumber)?.intValue, 12, file: file, line: line)
    }

    private func assertExactSchemaWasPreflighted(
        _ request: FakeFoundationModelsSchemaRequest,
        driver: FakeFoundationModelsSessionDriver,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            driver.capturedSchemaPreflights.contains(request),
            "dispatch must use the exact instructions, prompt, and request-specific schema that were preflighted",
            file: file,
            line: line
        )
    }

    /// Reads the legal generated fidelity values (`AppleSummaryFidelity`'s
    /// `anyOf` enum choices) out of a raw request-specific passage schema's
    /// JSON description, in the order the schema declares them.
    private func allowedFidelityValues(
        fromSchemaDescription description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String] {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(description.utf8)) as? [String: Any],
            file: file, line: line
        )
        let defs = try XCTUnwrap(object["$defs"] as? [String: Any], file: file, line: line)
        let fidelityDef = try XCTUnwrap(defs["AppleSummaryFidelity"] as? [String: Any], file: file, line: line)
        let anyOf = try XCTUnwrap(fidelityDef["anyOf"] as? [[String: Any]], file: file, line: line)
        return anyOf.compactMap { ($0["enum"] as? [String])?.first }
    }

    /// Whether the passage schema's `uncertaintyExplanation` string property
    /// carries a nonblank-content pattern constraint.
    private func uncertaintyExplanationRequiresNonblankPattern(
        inSchemaDescription description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Bool {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(description.utf8)) as? [String: Any],
            file: file, line: line
        )
        let defs = try XCTUnwrap(object["$defs"] as? [String: Any], file: file, line: line)
        let passageDef = try XCTUnwrap(defs["AppleSummaryPassage"] as? [String: Any], file: file, line: line)
        let properties = try XCTUnwrap(passageDef["properties"] as? [String: Any], file: file, line: line)
        let uncertaintyExplanation = try XCTUnwrap(properties["uncertaintyExplanation"] as? [String: Any], file: file, line: line)
        return uncertaintyExplanation["pattern"] != nil
    }

    private func generation(
        source: LectureSummarySourceSnapshot,
        plan: LectureSummaryPlan
    ) -> LectureSummaryGenerationRecord {
        LectureSummaryGenerationRecord.newGeneration(
            generationID: SummaryTestSupport.summaryGenerationID,
            sessionID: source.sessionID,
            sourceNotesGenerationID: source.sourceNotesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint,
            sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchPlan: plan,
            provenance: FoundationModelsSummaryConfiguration.generationProvenance,
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func planAndGeneration(
        _ generator: FoundationModelsLectureSummaryGenerator,
        source: LectureSummarySourceSnapshot
    ) async throws -> (LectureSummaryPlan, LectureSummaryGenerationRecord) {
        let plan = try await generator.makePlan(for: source)
        return (plan, generation(source: source, plan: plan))
    }

    private func analysis(
        batch: LectureSummaryBatch,
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot,
        support: [UUID],
        text: String,
        fidelity: LectureNoteContentFidelity,
        uncertainty: String? = nil
    ) throws -> LectureSummaryAnalysis {
        LectureSummaryAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: batch.batchID,
            batchIndex: batch.batchIndex,
            passages: [LectureSummaryPassage(
                text: text,
                supportingNoteItemIDs: support,
                sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(
                    supportingItemIDs: support, source: source
                ),
                fidelity: fidelity,
                uncertaintyNote: uncertainty
            )],
            provenance: generation.provenance
        )
    }

    private func completeAnalyses(
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) throws -> [LectureSummaryAnalysis] {
        try generation.batchPlan.batches.map { batch in
            let id = batch.sourceItemIDs[0]
            let item = source.sourceItems.first { $0.item.id == id }!.item
            return try analysis(
                batch: batch, generation: generation, source: source,
                support: [id], text: item.body, fidelity: item.fidelity,
                uncertainty: item.uncertaintyNote
            )
        }
    }

    // MARK: Planning and prompt boundaries

    func testTokenAwarePlanSplitsAtExactBoundaryAndPreservesCoverageOrder() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(200)
        driver.setTokenCountHandler { _, prompt in prompt.split(separator: "\n").count * 100 }
        let backend = generator(driver)
        let source = try SummaryTestSupport.source()

        let plan = try await backend.makePlan(for: source)

        XCTAssertEqual(plan.maxItemsPerBatch, 2)
        XCTAssertEqual(plan.batches.map { $0.sourceItemIDs.count }, [2, 1])
        XCTAssertEqual(plan.batches.flatMap(\.sourceItemIDs), source.sourceItems.map(\.item.id))
        XCTAssertNoThrow(try plan.validateStructure())
    }

    func testOversizedIndividualSourceItemFailsWithoutModelDispatch() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(99)
        driver.setTokenCountHandler { _, _ in 100 }
        let backend = generator(driver)

        do {
            _ = try await backend.makePlan(for: SummaryTestSupport.source())
            XCTFail("expected oversized source item failure")
        } catch {
            XCTAssertEqual(error as? FoundationModelsSummaryBackendError, .sourceItemTooLarge(0))
        }
        XCTAssertEqual(driver.callCount, 0)
    }

    func testBatchPromptUsesStableOneBasedLocalNumbersAndNoPersistentIDs() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 2)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        driver.enqueue(AppleSummaryPassagesDTO(passages: [passageDTO(support: [1])]))

        _ = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)

        let prompt = try XCTUnwrap(driver.capturedPrompts.first?.prompt)
        XCTAssertTrue(prompt.contains("[1] section="))
        XCTAssertTrue(prompt.contains("[2] section="))
        XCTAssertFalse(prompt.contains(source.sourceItems[0].item.id.uuidString))
        XCTAssertFalse(prompt.contains(source.sourceItems[0].item.sourceReferences[0].sessionID.uuidString))
    }

    // MARK: Local support mapping and fidelity

    func testValidSupportMapsToOriginalIDsAndDeterministicTranscriptReferences() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 2)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Combined explanation", support: [2, 1], fidelity: "reconstructed", uncertainty: "Formula notation was normalized.")
        ]))

        let result = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)

        XCTAssertEqual(result.passages[0].supportingNoteItemIDs, Array(SummaryTestSupport.itemIDs.prefix(2)))
        XCTAssertEqual(
            result.passages[0].sourceReferences,
            try LectureSummaryIntegrityValidator.derivedSourceReferences(
                supportingItemIDs: Array(SummaryTestSupport.itemIDs.prefix(2)), source: source
            )
        )
        let request = try XCTUnwrap(driver.capturedSchemaResponses.last)
        try assertSupportIndexBounds(request, collectionProperty: "passages", upperBound: 2)
        assertExactSchemaWasPreflighted(request, driver: driver)
    }

    func testInvalidDuplicateAndMissingSupportAreRejected() throws {
        XCTAssertThrowsError(try FoundationModelsLectureSummaryGenerator.validatedIndices([0], inputCount: 2)) {
            XCTAssertEqual($0 as? FoundationModelsSummaryBackendError, .invalidLocalSupportIndex(0))
        }
        XCTAssertThrowsError(try FoundationModelsLectureSummaryGenerator.validatedIndices([-1], inputCount: 2)) {
            XCTAssertEqual($0 as? FoundationModelsSummaryBackendError, .invalidLocalSupportIndex(-1))
        }
        XCTAssertThrowsError(try FoundationModelsLectureSummaryGenerator.validatedIndices([3], inputCount: 2)) {
            XCTAssertEqual($0 as? FoundationModelsSummaryBackendError, .invalidLocalSupportIndex(3))
        }
        XCTAssertThrowsError(try FoundationModelsLectureSummaryGenerator.validatedIndices([1, 1], inputCount: 2)) {
            XCTAssertEqual($0 as? FoundationModelsSummaryBackendError, .duplicateLocalSupportIndex(1))
        }
        XCTAssertThrowsError(try FoundationModelsLectureSummaryGenerator.validatedIndices([], inputCount: 2)) {
            XCTAssertEqual($0 as? FoundationModelsSummaryBackendError, .missingSupport)
        }
    }

    func testEmptyContentFidelityUpgradeAndMissingExplanationAreRejected() throws {
        let source = try SummaryTestSupport.source()
        let reconstructed = FoundationModelsLectureSummaryGenerator.carrier(from: source.sourceItems[1])
        XCTAssertThrowsError(try FoundationModelsLectureSummaryGenerator.mapPassage(
            passageDTO(" ", fidelity: "reconstructed", uncertainty: "x"), inputs: [reconstructed], source: source
        )) { XCTAssertEqual($0 as? FoundationModelsSummaryBackendError, .emptyGeneratedContent) }
        XCTAssertThrowsError(try FoundationModelsLectureSummaryGenerator.mapPassage(
            passageDTO(fidelity: "transcriptSupported"), inputs: [reconstructed], source: source
        )) { XCTAssertEqual($0 as? FoundationModelsSummaryBackendError, .fidelityViolation) }
        XCTAssertThrowsError(try FoundationModelsLectureSummaryGenerator.mapPassage(
            passageDTO(fidelity: "reconstructed", uncertainty: " "), inputs: [reconstructed], source: source
        )) { XCTAssertEqual($0 as? FoundationModelsSummaryBackendError, .uncertaintyExplanationRequired) }
    }

    func testMoreCautiousFidelityIsAccepted() throws {
        let source = try SummaryTestSupport.source()
        let supported = FoundationModelsLectureSummaryGenerator.carrier(from: source.sourceItems[0])
        let result = try FoundationModelsLectureSummaryGenerator.mapPassage(
            passageDTO(fidelity: "uncertain", uncertainty: "The synthesis is intentionally cautious."),
            inputs: [supported], source: source
        )
        XCTAssertEqual(result.fidelity, .uncertain)
    }

    // MARK: Generated-output fidelity-violation diagnostics

    func testFidelityViolationDiagnosticAttributesBatchAnalysisStageAndAttempt() async throws {
        let collector = DiagnosticEventCollector()
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 2, diagnosticRecorder: collector.record)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        // Local index 2 is itemIDs[1] (reconstructed); generating
        // "transcriptSupported" for it is more confident than its support.
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Overconfident", support: [2], fidelity: "transcriptSupported")
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Corrected", support: [2], fidelity: "reconstructed", uncertainty: "Matches the reconstructed source fidelity.")
        ]))
        // `makePlan` above already probed candidate batch sizes with its own
        // (always-unrestricted) preflights; only a delta from here isolates
        // this specific generateAnalysis request's own preflight activity.
        let batchPreflightCountBeforeRequest = driver.capturedSchemaPreflights.filter {
            $0.instructions == FoundationModelsLectureSummaryGenerator.batchInstructions
        }.count

        let analysis = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)

        XCTAssertEqual(analysis.passages.count, 1, "production behavior is unchanged: retry still recovers")
        XCTAssertEqual(collector.events.count, 1)
        let event = try XCTUnwrap(collector.events.first)
        XCTAssertEqual(event.stage, .batchAnalysis)
        XCTAssertEqual(event.attempt, 1)
        XCTAssertEqual(event.error, .fidelityViolation)
        XCTAssertEqual(event.generatedFidelity, .transcriptSupported)
        XCTAssertEqual(event.requiredFloorFidelity, .reconstructed)
        XCTAssertEqual(event.supportIndices, [2])

        // The batch's own request-level floor (reconstructed, from itemIDs[1]
        // — the weakest fidelity among ALL batch items, not just the support
        // a passage selects) must restrict the schema, and require nonblank
        // uncertainty explanation, even though itemIDs[0] alone is
        // transcriptSupported.
        let batchPreflights = driver.capturedSchemaPreflights.filter {
            $0.instructions == FoundationModelsLectureSummaryGenerator.batchInstructions
        }
        let batchDispatches = driver.capturedSchemaResponses.filter {
            $0.instructions == FoundationModelsLectureSummaryGenerator.batchInstructions
        }
        XCTAssertEqual(batchPreflights.count - batchPreflightCountBeforeRequest, 1, "preflight happens once per logical request")
        XCTAssertEqual(batchDispatches.count, 2, "both attempts dispatch")
        XCTAssertEqual(batchDispatches[0], batchDispatches[1], "attempt 2 reuses the exact same instructions/prompt/schema as attempt 1")
        XCTAssertEqual(batchDispatches[0], batchPreflights.last, "the request's own preflight — the most recent one — matches what was dispatched")
        let allowed = try allowedFidelityValues(fromSchemaDescription: batchDispatches[0].schemaDescription)
        XCTAssertEqual(allowed, ["reconstructed", "uncertain"])
        XCTAssertFalse(
            try uncertaintyExplanationRequiresNonblankPattern(inSchemaDescription: batchDispatches[0].schemaDescription),
            "a real-model compatibility probe confirmed the regex pattern guide is rejected by the Apple Foundation Models runtime; nonblank enforcement is Swift's responsibility only"
        )
    }

    func testUncertaintyExplanationRequiredDiagnosticCapturesFidelityAndSupportContext() async throws {
        let collector = DiagnosticEventCollector()
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 2, diagnosticRecorder: collector.record)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        // Fidelity itself is legal (reconstructed >= floor reconstructed) but
        // the explanation is blank, so this fails on uncertaintyExplanationRequired
        // rather than fidelityViolation — the diagnostic must still capture context.
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Missing explanation", support: [2], fidelity: "reconstructed", uncertainty: " ")
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Corrected", support: [2], fidelity: "reconstructed", uncertainty: "Explains the reconstruction.")
        ]))

        let analysis = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)

        XCTAssertEqual(analysis.passages.count, 1, "production behavior is unchanged: retry still recovers")
        XCTAssertEqual(collector.events.count, 1)
        let event = try XCTUnwrap(collector.events.first)
        XCTAssertEqual(event.stage, .batchAnalysis)
        XCTAssertEqual(event.attempt, 1)
        XCTAssertEqual(event.error, .uncertaintyExplanationRequired)
        XCTAssertEqual(event.generatedFidelity, .reconstructed)
        XCTAssertEqual(event.requiredFloorFidelity, .reconstructed)
        XCTAssertEqual(event.supportIndices, [2])
    }

    func testFidelityViolationDiagnosticAttributesReductionStage() async throws {
        let collector = DiagnosticEventCollector()
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(2)
        driver.setTokenCountHandler { instructions, prompt in
            let count = prompt.split(separator: "\n").count
            if instructions == FoundationModelsLectureSummaryGenerator.batchInstructions { return 1 }
            if instructions == FoundationModelsLectureSummaryGenerator.reductionInstructions { return count <= 2 ? 1 : 99 }
            if instructions == FoundationModelsLectureSummaryGenerator.finalStructureInstructions { return count <= 2 ? 1 : 99 }
            return 1
        }
        let backend = generator(driver, maxItems: 1, diagnosticRecorder: collector.record)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        // Reduction group [1, 2] = itemIDs[0] (transcriptSupported) + itemIDs[1]
        // (reconstructed); the floor for that group is reconstructed.
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Overconfident reduction", support: [1, 2], fidelity: "transcriptSupported")
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Reduced first pair", support: [1, 2], fidelity: "reconstructed", uncertainty: "Includes reconstructed formula support.")
        ]))
        driver.enqueue(AppleSummaryStructureDTO(sections: [
            AppleSummarySectionPlanDTO(title: "Selected", supportIndices: [1])
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Final selected explanation", support: [1], fidelity: "reconstructed", uncertainty: "Includes normalized formula evidence.")
        ]))

        let document = try await backend.generateDocument(from: analyses, generation: record, source: source)

        XCTAssertEqual(document.sections.count, 1, "production behavior is unchanged: retry still recovers")
        XCTAssertEqual(collector.events.count, 1)
        let event = try XCTUnwrap(collector.events.first)
        XCTAssertEqual(event.stage, .reduction)
        XCTAssertEqual(event.attempt, 1)
        XCTAssertEqual(event.error, .fidelityViolation)
        XCTAssertEqual(event.generatedFidelity, .transcriptSupported)
        XCTAssertEqual(event.requiredFloorFidelity, .reconstructed)
        XCTAssertEqual(event.supportIndices, [1, 2])

        // The reduction request's own floor (reconstructed, from all of its
        // input carriers) must restrict its schema and require nonblank
        // uncertainty explanation, mirroring batch analysis and final section.
        // `makeReductionGroups` above also probes candidate group sizes with
        // its own (always-unrestricted) preflights before `reduce` itself
        // ever runs; `reduce`'s own preflight is the most recent one.
        let reductionPreflights = driver.capturedSchemaPreflights.filter {
            $0.instructions == FoundationModelsLectureSummaryGenerator.reductionInstructions
        }
        let reductionDispatches = driver.capturedSchemaResponses.filter {
            $0.instructions == FoundationModelsLectureSummaryGenerator.reductionInstructions
        }
        XCTAssertEqual(reductionDispatches.count, 2, "both attempts dispatch")
        XCTAssertEqual(reductionDispatches[0], reductionDispatches[1], "attempt 2 reuses the exact same instructions/prompt/schema as attempt 1")
        XCTAssertEqual(reductionDispatches[0], reductionPreflights.last, "reduce's own preflight — the most recent one — matches what was dispatched")
        let allowed = try allowedFidelityValues(fromSchemaDescription: reductionDispatches[0].schemaDescription)
        XCTAssertEqual(allowed, ["reconstructed", "uncertain"])
        XCTAssertFalse(
            try uncertaintyExplanationRequiresNonblankPattern(inSchemaDescription: reductionDispatches[0].schemaDescription),
            "a real-model compatibility probe confirmed the regex pattern guide is rejected by the Apple Foundation Models runtime; nonblank enforcement is Swift's responsibility only"
        )
    }

    func testFidelityViolationRetryExhaustionPreservesDistinctContextPerAttempt() async throws {
        let collector = DiagnosticEventCollector()
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 2, diagnosticRecorder: collector.record)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Attempt one", support: [2], fidelity: "transcriptSupported")
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Attempt two", support: [1, 2], fidelity: "transcriptSupported")
        ]))

        do {
            _ = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)
            XCTFail("expected retry exhaustion")
        } catch {
            XCTAssertEqual(error as? FoundationModelsSummaryBackendError, .fidelityViolation, "the public typed error is unchanged by diagnostics")
        }
        XCTAssertEqual(driver.callCount, 2)

        XCTAssertEqual(collector.events.count, 2)
        XCTAssertEqual(collector.events[0].stage, .batchAnalysis)
        XCTAssertEqual(collector.events[0].attempt, 1)
        XCTAssertEqual(collector.events[0].supportIndices, [2])
        XCTAssertEqual(collector.events[1].stage, .batchAnalysis)
        XCTAssertEqual(collector.events[1].attempt, 2)
        XCTAssertEqual(collector.events[1].supportIndices, [1, 2], "attempt 2's context must not be attempt 1's stale support indices")
    }

    func testDiagnosticRecorderReceivesNoEventsOnSuccessfulGeneration() async throws {
        let collector = DiagnosticEventCollector()
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 2, diagnosticRecorder: collector.record)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Grounded", support: [1])
        ]))

        let analysis = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)

        XCTAssertEqual(analysis.passages.count, 1)
        XCTAssertTrue(collector.events.isEmpty)
    }

    func testPreflightRecorderReceivesRealTokenCountAndContextBudgetOnBatchAnalysis() async throws {
        var recorded: [FoundationModelsSummaryPreflightEvent] = []
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 2, preflightRecorder: { recorded.append($0) })
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        recorded.removeAll() // isolate the call under test from makePlan's own preflights
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Grounded", support: [1])
        ]))

        _ = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)

        XCTAssertEqual(recorded.count, 1)
        let event = try XCTUnwrap(recorded.first)
        XCTAssertEqual(event.stage, .batchAnalysis)
        XCTAssertEqual(event.estimatedInputTokens, 1, "must be the real preflight count the fake driver reports, never an invented estimate")
        XCTAssertEqual(event.contextLimit, driver.contextTokenBudget)
        XCTAssertTrue(event.fitsDirectly)
    }

    // MARK: Content-free error classification

    func testDiagnosticCategoryIsCaseNameOnlyNeverAssociatedPayload() {
        let secret = "SECRET_LECTURE_CONTENT_MARKER"
        let cases: [(FoundationModelsSummaryBackendError, String)] = [
            (.unavailable(secret), "unavailable"),
            (.incompatibleProvenance, "incompatibleProvenance"),
            (.contextBudgetExceeded(secret), "contextBudgetExceeded"),
            (.tokenPreflightUnavailable(secret), "tokenPreflightUnavailable"),
            (.sourceItemTooLarge(999), "sourceItemTooLarge"),
            (.malformedGeneratedStructure(secret), "malformedGeneratedStructure"),
            (.invalidLocalSupportIndex(999), "invalidLocalSupportIndex"),
            (.duplicateLocalSupportIndex(999), "duplicateLocalSupportIndex"),
            (.missingSupport, "missingSupport"),
            (.emptyGeneratedContent, "emptyGeneratedContent"),
            (.fidelityViolation, "fidelityViolation"),
            (.uncertaintyExplanationRequired, "uncertaintyExplanationRequired"),
            (.reductionCoverageLost, "reductionCoverageLost"),
            (.nonProgressingReduction, "nonProgressingReduction"),
            (.unsupportedLanguage(secret), "unsupportedLanguage"),
            (.guardrailFailure(secret), "guardrailFailure"),
            (.frameworkFailure(secret), "frameworkFailure"),
            (.finalIntegrityValidationFailed(secret), "finalIntegrityValidationFailed")
        ]
        for (error, expectedCategory) in cases {
            XCTAssertEqual(error.diagnosticCategory, expectedCategory)
            XCTAssertFalse(error.diagnosticCategory.contains(secret), "\(expectedCategory) leaked its associated payload")
        }
    }

    // MARK: Synthesis-phase boundary events

    func testFinalStructureAndFinalSectionSynthesisEventsReportAccurateCounts() async throws {
        let collector = SynthesisEventCollector()
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(10)
        driver.setTokenCountHandler { _, _ in 1 }
        let backend = generator(driver, maxItems: 1, synthesisRecorder: collector.record)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        driver.enqueue(AppleSummaryStructureDTO(sections: [
            AppleSummarySectionPlanDTO(title: "Second evidence", supportIndices: [2]),
            AppleSummarySectionPlanDTO(title: "First evidence", supportIndices: [1])
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Formula section", fidelity: "reconstructed", uncertainty: "Formula was normalized.")
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [passageDTO("Concept section")]))

        let document = try await backend.generateDocument(from: analyses, generation: record, source: source)

        XCTAssertEqual(document.sections.count, 2, "setup sanity check")
        let events = collector.events
        XCTAssertEqual(
            events.count, 6,
            "one started/completed pair for final structure, plus one started/completed pair per final section (2 sections)"
        )

        guard case .finalStructureStarted(let structureInputCount) = events[0].boundary else {
            return XCTFail("expected finalStructureStarted first, got \(events[0].boundary)")
        }
        XCTAssertEqual(structureInputCount, 3, "all three source carriers enter the final-structure request")
        XCTAssertEqual(events[0].sessionID, record.sessionID)
        XCTAssertEqual(events[0].generationID, record.generationID)

        guard case .finalStructureCompleted(let sectionCount) = events[1].boundary else {
            return XCTFail("expected finalStructureCompleted second, got \(events[1].boundary)")
        }
        XCTAssertEqual(sectionCount, 2)
        XCTAssertNotNil(events[1].elapsedSeconds, "a completed event must report elapsed time")

        guard case .finalSectionStarted(let sectionIndex0, let totalSections0, let sectionInputCount0) = events[2].boundary else {
            return XCTFail("expected finalSectionStarted third, got \(events[2].boundary)")
        }
        XCTAssertEqual(sectionIndex0, 0)
        XCTAssertEqual(totalSections0, 2)
        XCTAssertEqual(sectionInputCount0, 1, "the first planned section selects exactly one carrier (index 2)")

        guard case .finalSectionCompleted(let completedIndex0, let passageCount0) = events[3].boundary else {
            return XCTFail("expected finalSectionCompleted fourth, got \(events[3].boundary)")
        }
        XCTAssertEqual(completedIndex0, 0)
        XCTAssertEqual(passageCount0, 1)
        XCTAssertNotNil(events[3].elapsedSeconds)

        guard case .finalSectionStarted(let sectionIndex1, let totalSections1, let sectionInputCount1) = events[4].boundary else {
            return XCTFail("expected finalSectionStarted fifth, got \(events[4].boundary)")
        }
        XCTAssertEqual(sectionIndex1, 1)
        XCTAssertEqual(totalSections1, 2)
        XCTAssertEqual(sectionInputCount1, 1, "the second planned section selects exactly one carrier (index 1)")

        guard case .finalSectionCompleted(let completedIndex1, let passageCount1) = events[5].boundary else {
            return XCTFail("expected finalSectionCompleted sixth, got \(events[5].boundary)")
        }
        XCTAssertEqual(completedIndex1, 1)
        XCTAssertEqual(passageCount1, 1)
        XCTAssertNotNil(events[5].elapsedSeconds)
    }

    func testReductionGroupSynthesisEventsOmitSingletonPassthroughGroups() async throws {
        let collector = SynthesisEventCollector()
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(2)
        driver.setTokenCountHandler { instructions, prompt in
            let count = prompt.split(separator: "\n").count
            if instructions == FoundationModelsLectureSummaryGenerator.batchInstructions { return 1 }
            if instructions == FoundationModelsLectureSummaryGenerator.reductionInstructions { return count <= 2 ? 1 : 99 }
            if instructions == FoundationModelsLectureSummaryGenerator.finalStructureInstructions { return count <= 2 ? 1 : 99 }
            return 1
        }
        let backend = generator(driver, maxItems: 1, synthesisRecorder: collector.record)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        // Three source carriers pack into groups of at most 2 under this
        // budget: one real two-carrier reduction group, plus one
        // single-carrier group carried forward unchanged (a passthrough,
        // never a model call).
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Reduced pair", support: [1, 2], fidelity: "reconstructed", uncertainty: "Includes reconstructed formula support.")
        ]))
        driver.enqueue(AppleSummaryStructureDTO(sections: [
            AppleSummarySectionPlanDTO(title: "Selected", supportIndices: [1, 2])
        ]))
        // The final section's own input carriers are the reduced carrier
        // (reconstructed) plus the untouched third source carrier
        // (uncertain) — its fidelity floor is therefore `uncertain`.
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Final section", support: [1, 2], fidelity: "uncertain", uncertainty: "Includes reconstructed formula support and an uncertain conclusion.")
        ]))

        _ = try await backend.generateDocument(from: analyses, generation: record, source: source)

        let reductionEvents = collector.events.filter {
            switch $0.boundary {
            case .reductionGroupStarted, .reductionGroupCompleted: return true
            default: return false
            }
        }
        XCTAssertEqual(reductionEvents.count, 2, "exactly one group actually calls the model — no event for the passthrough singleton group")
        guard case .reductionGroupStarted(let level, let groupIndex, let totalGroups, let inputCarrierCount) = reductionEvents[0].boundary else {
            return XCTFail("expected reductionGroupStarted first")
        }
        XCTAssertEqual(level, 0)
        XCTAssertEqual(groupIndex, 0, "the two-carrier group is packed first")
        XCTAssertEqual(totalGroups, 2)
        XCTAssertEqual(inputCarrierCount, 2)
        guard case .reductionGroupCompleted(_, _, let outputCarrierCount) = reductionEvents[1].boundary else {
            return XCTFail("expected reductionGroupCompleted second")
        }
        XCTAssertEqual(outputCarrierCount, 1)
        XCTAssertNotNil(reductionEvents[1].elapsedSeconds)
    }

    // MARK: Generated-output retry boundary

    func testGeneratedOutputAttemptFailedDiagnosticReportsAccurateWillRetry() async throws {
        let collector = DiagnosticEventCollector()
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 2, diagnosticRecorder: collector.record)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        // Both scripted attempts fail with the same retryable category
        // (`.uncertaintyExplanationRequired`), so attempt 1 retries and
        // attempt 2 — the last allowed attempt — exhausts retries and
        // throws.
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Attempt 1", support: [1], fidelity: "uncertain", uncertainty: " ")
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Attempt 2", support: [1], fidelity: "uncertain", uncertainty: " ")
        ]))

        do {
            _ = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)
            XCTFail("expected retry exhaustion to throw")
        } catch let error as FoundationModelsSummaryBackendError {
            XCTAssertEqual(error, .uncertaintyExplanationRequired)
        }

        XCTAssertEqual(collector.events.count, 2)
        XCTAssertEqual(collector.events[0].attempt, 1)
        XCTAssertTrue(collector.events[0].willRetry, "a retryable category with attempts remaining must report willRetry == true")
        XCTAssertEqual(collector.events[1].attempt, 2)
        XCTAssertFalse(collector.events[1].willRetry, "the final attempt must never claim it will retry, matching the actual thrown outcome")
    }

    func testMissingUncertaintyExplanationRetriesExactRequestAndUsesOnlyValidResponseEvidence() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 2)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        let preflightCountBeforeRequest = driver.capturedSchemaPreflights.count
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO(
                "Discarded malformed attempt",
                support: [2],
                fidelity: "uncertain",
                uncertainty: " "
            )
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO(
                "Valid second attempt",
                support: [1],
                fidelity: "reconstructed",
                uncertainty: "The explanation generalizes the transcript wording."
            )
        ]))

        let analysis = try await backend.generateAnalysis(
            for: plan.batches[0], generation: record, source: source
        )

        XCTAssertEqual(driver.callCount, 2)
        XCTAssertEqual(driver.capturedSchemaPreflights.count, preflightCountBeforeRequest + 1)
        XCTAssertEqual(driver.capturedSchemaResponses[0], driver.capturedSchemaResponses[1])
        XCTAssertEqual(analysis.passages.count, 1)
        XCTAssertEqual(analysis.passages[0].text, "Valid second attempt")
        XCTAssertEqual(analysis.passages[0].supportingNoteItemIDs, [SummaryTestSupport.itemIDs[0]])
        XCTAssertEqual(
            analysis.passages[0].uncertaintyNote,
            "The explanation generalizes the transcript wording."
        )
    }

    func testInvalidSupportRetriesAndSucceedsWithoutAcceptingMalformedEvidence() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        driver.enqueue(AppleSummaryPassagesDTO(passages: [passageDTO(
            "Illegal support",
            support: [2]
        )]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [passageDTO(
            "Grounded support",
            support: [1]
        )]))

        let analysis = try await backend.generateAnalysis(
            for: plan.batches[0], generation: record, source: source
        )

        XCTAssertEqual(driver.callCount, 2)
        XCTAssertEqual(analysis.passages.map(\.text), ["Grounded support"])
        XCTAssertEqual(analysis.passages[0].supportingNoteItemIDs, [SummaryTestSupport.itemIDs[0]])
    }

    func testRetryExhaustionReturnsFinalTypedValidationError() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        driver.enqueue(AppleSummaryPassagesDTO(passages: [passageDTO(
            "Illegal support",
            support: [2]
        )]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [passageDTO(
            "Still malformed",
            fidelity: "uncertain",
            uncertainty: " "
        )]))

        do {
            _ = try await backend.generateAnalysis(
                for: plan.batches[0], generation: record, source: source
            )
            XCTFail("expected retry exhaustion")
        } catch {
            XCTAssertEqual(
                error as? FoundationModelsSummaryBackendError,
                .uncertaintyExplanationRequired
            )
        }
        XCTAssertEqual(driver.callCount, 2)
    }

    func testCancellationDoesNotRetryGeneratedRequest() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        driver.armGate(beforeCallNumber: 1)

        let task = Task {
            try await backend.generateAnalysis(
                for: plan.batches[0], generation: record, source: source
            )
        }
        while !driver.hasEnteredGate { await Task.yield() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(driver.callCount, 1)
    }

    // MARK: Reduction and final synthesis

    func testReductionUnionsOriginalEvidenceAndFinalStructureMayBeSelective() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(2)
        driver.setTokenCountHandler { instructions, prompt in
            let count = prompt.split(separator: "\n").count
            if instructions == FoundationModelsLectureSummaryGenerator.batchInstructions { return 1 }
            if instructions == FoundationModelsLectureSummaryGenerator.reductionInstructions { return count <= 2 ? 1 : 99 }
            if instructions == FoundationModelsLectureSummaryGenerator.finalStructureInstructions { return count <= 2 ? 1 : 99 }
            return 1
        }
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Reduced first pair", support: [1, 2], fidelity: "reconstructed", uncertainty: "Includes reconstructed formula support.")
        ]))
        driver.enqueue(AppleSummaryStructureDTO(sections: [
            AppleSummarySectionPlanDTO(title: "Selected", supportIndices: [1])
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Final selected explanation", support: [1], fidelity: "reconstructed", uncertainty: "Includes normalized formula evidence.")
        ]))

        let document = try await backend.generateDocument(from: analyses, generation: record, source: source)

        XCTAssertEqual(document.sections.count, 1)
        XCTAssertEqual(document.sections[0].passages[0].supportingNoteItemIDs, Array(SummaryTestSupport.itemIDs.prefix(2)))
        XCTAssertFalse(document.sections[0].passages[0].supportingNoteItemIDs.contains(SummaryTestSupport.itemIDs[2]))
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(document: document, generation: record, source: source))
        XCTAssertEqual(driver.callCount, 3, "the one-carrier reduction group must pass through without a model call")
        let request = try XCTUnwrap(driver.capturedSchemaResponses.first {
            $0.instructions == FoundationModelsLectureSummaryGenerator.reductionInstructions
        })
        try assertSupportIndexBounds(request, collectionProperty: "passages", upperBound: 2)
        assertExactSchemaWasPreflighted(request, driver: driver)
    }

    func testMultiLevelReductionRetainsOnlyOriginalEvidenceAndPropagatesConservativeFidelity() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(1)
        driver.setTokenCountHandler { instructions, prompt in
            if instructions == FoundationModelsLectureSummaryGenerator.batchInstructions { return 1 }
            if instructions == FoundationModelsLectureSummaryGenerator.reductionInstructions { return 1 }
            if instructions == FoundationModelsLectureSummaryGenerator.finalStructureInstructions {
                return prompt.split(separator: "\n").count == 1 ? 1 : 99
            }
            return 1
        }
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Reduced A", support: [1, 2], fidelity: "reconstructed", uncertainty: "Formula reconstruction remains."),
            passageDTO("Reduced B", support: [3], fidelity: "uncertain", uncertainty: "Original conclusion is uncertain.")
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Reduced all", support: [1, 2], fidelity: "uncertain", uncertainty: "Uncertain evidence remains.")
        ]))
        driver.enqueue(AppleSummaryStructureDTO(sections: [AppleSummarySectionPlanDTO(title: "All", supportIndices: [1])]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Final", support: [1], fidelity: "uncertain", uncertainty: "Uncertain evidence remains.")
        ]))

        let document = try await backend.generateDocument(from: analyses, generation: record, source: source)

        XCTAssertEqual(document.sections[0].passages[0].supportingNoteItemIDs, SummaryTestSupport.itemIDs)
        XCTAssertEqual(document.sections[0].passages[0].fidelity, .uncertain)
    }

    func testReductionRejectsLostCoverageAndNonProgress() async throws {
        for (responses, expected) in [
            ([passageDTO("Only first", support: [1])], FoundationModelsSummaryBackendError.reductionCoverageLost),
            ([passageDTO("First", support: [1]), passageDTO("Second", support: [2], fidelity: "reconstructed", uncertainty: "Reconstructed.")], .nonProgressingReduction)
        ] {
            let driver = FakeFoundationModelsSessionDriver()
            driver.setContextTokenBudget(1)
            driver.setTokenCountHandler { instructions, prompt in
                if instructions == FoundationModelsLectureSummaryGenerator.batchInstructions { return 1 }
                if instructions == FoundationModelsLectureSummaryGenerator.reductionInstructions { return prompt.split(separator: "\n").count <= 2 ? 1 : 99 }
                return 99
            }
            let backend = generator(driver, maxItems: 1)
            let source = try SummaryTestSupport.source()
            let (_, record) = try await planAndGeneration(backend, source: source)
            let analyses = try completeAnalyses(generation: record, source: source)
            driver.enqueue(AppleSummaryPassagesDTO(passages: responses))
            driver.enqueue(AppleSummaryPassagesDTO(passages: responses))
            do {
                _ = try await backend.generateDocument(from: analyses, generation: record, source: source)
                XCTFail("expected reduction failure")
            } catch {
                XCTAssertEqual(error as? FoundationModelsSummaryBackendError, expected)
            }
            XCTAssertEqual(driver.callCount, 2)
        }
    }

    func testFinalSectionOrderAndMappingAreDeterministic() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(10)
        driver.setTokenCountHandler { _, _ in 1 }
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        driver.enqueue(AppleSummaryStructureDTO(sections: [
            AppleSummarySectionPlanDTO(title: "Second evidence", supportIndices: [2]),
            AppleSummarySectionPlanDTO(title: "First evidence", supportIndices: [1])
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Formula section", fidelity: "reconstructed", uncertainty: "Formula was normalized.")
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [passageDTO("Concept section")]))

        let document = try await backend.generateDocument(from: analyses, generation: record, source: source)

        XCTAssertEqual(document.sections.map(\.heading), ["Second evidence", "First evidence"])
        XCTAssertEqual(document.sections[0].passages[0].supportingNoteItemIDs, [SummaryTestSupport.itemIDs[1]])
        XCTAssertEqual(document.sections[1].passages[0].supportingNoteItemIDs, [SummaryTestSupport.itemIDs[0]])
        let request = try XCTUnwrap(driver.capturedSchemaResponses.first {
            $0.instructions == FoundationModelsLectureSummaryGenerator.finalStructureInstructions
        })
        try assertSupportIndexBounds(request, collectionProperty: "sections", upperBound: 3)
        assertExactSchemaWasPreflighted(request, driver: driver)
    }

    func testFinalStructureFitDoesNotRequireCompleteInputToFitFinalSectionRequest() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(10)
        driver.setTokenCountHandler { instructions, prompt in
            if instructions == FoundationModelsLectureSummaryGenerator.batchInstructions { return 1 }
            if instructions == FoundationModelsLectureSummaryGenerator.finalStructureInstructions { return 5 }
            if instructions == FoundationModelsLectureSummaryGenerator.finalSectionInstructions {
                let carrierCount = prompt.components(separatedBy: "fidelity=").count - 1
                return carrierCount == 1 ? 5 : 11
            }
            return 1
        }
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        driver.enqueue(AppleSummaryStructureDTO(sections: [
            AppleSummarySectionPlanDTO(title: "Focused concept", supportIndices: [1])
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [passageDTO("Focused explanation")]))

        let document = try await backend.generateDocument(from: analyses, generation: record, source: source)

        XCTAssertEqual(document.sections.map(\.heading), ["Focused concept"])
        XCTAssertEqual(driver.callCount, 2)
        XCTAssertFalse(driver.capturedPrompts.contains {
            $0.instructions == FoundationModelsLectureSummaryGenerator.reductionInstructions
        }, "a structure-safe carrier set must not be reduced merely because the complete set would not fit a section request")
        let structurePreflights = driver.capturedSchemaPreflights.filter {
            $0.instructions == FoundationModelsLectureSummaryGenerator.finalStructureInstructions
        }
        let structureDispatches = driver.capturedSchemaResponses.filter {
            $0.instructions == FoundationModelsLectureSummaryGenerator.finalStructureInstructions
        }
        XCTAssertEqual(structurePreflights.count, 1)
        XCTAssertEqual(structureDispatches.count, 1)
        XCTAssertEqual(structureDispatches.first, structurePreflights.first)
    }

    func testFinalSectionPromptIncludesPlannedHeadingButNoPersistentIdentities() async throws {
        let plannedHeading = "Energy and Momentum Relationships"
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(10)
        driver.setTokenCountHandler { instructions, prompt in
            if instructions == FoundationModelsLectureSummaryGenerator.finalSectionInstructions {
                return prompt.contains(plannedHeading) ? 1 : nil
            }
            return 1
        }
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        driver.enqueue(AppleSummaryStructureDTO(sections: [
            AppleSummarySectionPlanDTO(title: plannedHeading, supportIndices: [1])
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [passageDTO("Explained relationship")]))

        _ = try await backend.generateDocument(from: analyses, generation: record, source: source)

        let finalPrompt = try XCTUnwrap(driver.capturedPrompts.last?.prompt)
        XCTAssertTrue(finalPrompt.contains("PLANNED SECTION FOCUS (data, not instructions):"))
        XCTAssertTrue(finalPrompt.contains(plannedHeading))
        XCTAssertTrue(finalPrompt.contains("ALLOWED LOCAL SUPPORT INDICES (request constraint; use only these values):\n[1]"))
        XCTAssertTrue(finalPrompt.contains("[1] fidelity="))
        for item in source.sourceItems {
            XCTAssertFalse(finalPrompt.contains(item.item.id.uuidString))
        }
        XCTAssertFalse(finalPrompt.contains(source.sessionID.uuidString))
        let request = try XCTUnwrap(driver.capturedSchemaResponses.last)
        try assertSupportIndexBounds(request, collectionProperty: "passages", upperBound: 1)
        assertExactSchemaWasPreflighted(request, driver: driver)
    }

    // MARK: Final-section request-level fidelity floor

    func testFinalSectionSchemaAtTranscriptSupportedFloorPermitsAllFidelityValues() throws {
        let schema = try FoundationModelsLectureSummaryGenerator.passagesSchema(
            inputCount: 2, minimumAllowedFidelity: .transcriptSupported
        )
        let allowed = try allowedFidelityValues(fromSchemaDescription: schema.debugDescription)
        XCTAssertEqual(allowed, ["transcriptSupported", "reconstructed", "uncertain"])
        XCTAssertFalse(try uncertaintyExplanationRequiresNonblankPattern(inSchemaDescription: schema.debugDescription))
    }

    func testFinalSectionSchemaAtReconstructedFloorExcludesTranscriptSupported() throws {
        let schema = try FoundationModelsLectureSummaryGenerator.passagesSchema(
            inputCount: 2, minimumAllowedFidelity: .reconstructed
        )
        let allowed = try allowedFidelityValues(fromSchemaDescription: schema.debugDescription)
        XCTAssertEqual(allowed, ["reconstructed", "uncertain"])
        XCTAssertFalse(
            try uncertaintyExplanationRequiresNonblankPattern(inSchemaDescription: schema.debugDescription),
            "a real-model compatibility probe confirmed the regex pattern guide is rejected by the Apple Foundation Models runtime; nonblank enforcement is Swift's responsibility only"
        )
    }

    func testFinalSectionSchemaAtUncertainFloorPermitsOnlyUncertain() throws {
        let schema = try FoundationModelsLectureSummaryGenerator.passagesSchema(
            inputCount: 2, minimumAllowedFidelity: .uncertain
        )
        let allowed = try allowedFidelityValues(fromSchemaDescription: schema.debugDescription)
        XCTAssertEqual(allowed, ["uncertain"])
        XCTAssertFalse(
            try uncertaintyExplanationRequiresNonblankPattern(inSchemaDescription: schema.debugDescription),
            "a real-model compatibility probe confirmed the regex pattern guide is rejected by the Apple Foundation Models runtime; nonblank enforcement is Swift's responsibility only"
        )
    }

    func testFinalSectionDispatchedSchemaMatchesPreflightAtRestrictedFloor() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(10)
        driver.setTokenCountHandler { _, _ in 1 }
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        // Local index 2 is itemIDs[1] (reconstructed); this section's only
        // carrier is reconstructed, so its request-level floor is reconstructed.
        driver.enqueue(AppleSummaryStructureDTO(sections: [
            AppleSummarySectionPlanDTO(title: "Reconstructed only", supportIndices: [2])
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Reconstructed explanation", fidelity: "reconstructed", uncertainty: "Explains the reconstruction.")
        ]))

        let document = try await backend.generateDocument(from: analyses, generation: record, source: source)

        XCTAssertEqual(document.sections[0].passages[0].fidelity, .reconstructed)
        let request = try XCTUnwrap(driver.capturedSchemaResponses.first {
            $0.instructions == FoundationModelsLectureSummaryGenerator.finalSectionInstructions
        })
        assertExactSchemaWasPreflighted(request, driver: driver)
        let allowed = try allowedFidelityValues(fromSchemaDescription: request.schemaDescription)
        XCTAssertEqual(allowed, ["reconstructed", "uncertain"])
        XCTAssertFalse(
            try uncertaintyExplanationRequiresNonblankPattern(inSchemaDescription: request.schemaDescription),
            "a real-model compatibility probe confirmed the regex pattern guide is rejected by the Apple Foundation Models runtime; nonblank enforcement is Swift's responsibility only"
        )
    }

    func testFinalSectionRetryPreservesSingleSchemaAcrossTwoAttemptsAndSwiftBackstopRejectsIllegalFidelity() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(10)
        driver.setTokenCountHandler { _, _ in 1 }
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        let analyses = try completeAnalyses(generation: record, source: source)
        driver.enqueue(AppleSummaryStructureDTO(sections: [
            AppleSummarySectionPlanDTO(title: "Reconstructed only", supportIndices: [2])
        ]))
        // A real model could not legally emit this under the restricted
        // schema, but the fake driver does not enforce schema legality —
        // this proves Swift's own selected-support validation in
        // `mapPassage` remains the authoritative backstop regardless.
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Overconfident", fidelity: "transcriptSupported")
        ]))
        driver.enqueue(AppleSummaryPassagesDTO(passages: [
            passageDTO("Corrected", fidelity: "reconstructed", uncertainty: "Explains the reconstruction.")
        ]))

        let document = try await backend.generateDocument(from: analyses, generation: record, source: source)

        XCTAssertEqual(document.sections[0].passages[0].fidelity, .reconstructed)
        let finalSectionPreflights = driver.capturedSchemaPreflights.filter {
            $0.instructions == FoundationModelsLectureSummaryGenerator.finalSectionInstructions
        }
        let finalSectionDispatches = driver.capturedSchemaResponses.filter {
            $0.instructions == FoundationModelsLectureSummaryGenerator.finalSectionInstructions
        }
        XCTAssertEqual(finalSectionPreflights.count, 1, "preflight happens once per logical request")
        XCTAssertEqual(finalSectionDispatches.count, 2, "both attempts dispatch")
        XCTAssertEqual(finalSectionDispatches[0], finalSectionDispatches[1], "attempt 2 reuses the exact same instructions/prompt/schema as attempt 1")
        XCTAssertEqual(finalSectionDispatches[0], finalSectionPreflights[0])
        let allowed = try allowedFidelityValues(fromSchemaDescription: finalSectionDispatches[0].schemaDescription)
        XCTAssertEqual(allowed, ["reconstructed", "uncertain"], "the restricted schema was in effect for both attempts")
    }

    func testFinalSectionInstructionsStateFidelityAndUncertaintyRule() {
        let text = FoundationModelsLectureSummaryGenerator.finalSectionInstructions
        XCTAssertTrue(text.contains("reconstructed evidence forbids transcriptSupported"))
        XCTAssertTrue(text.contains("uncertain evidence requires uncertain output"))
        XCTAssertTrue(text.contains("nonblank explanation"))
    }

    func testSummaryProvenanceAdvancedForRegexGuideRemoval() {
        // generatedContractVersion (schema5) is unchanged here: the guide
        // removal that produced schema5 is a separate, prior event from the
        // fm-epoch bump asserted below — neither touches the other.
        XCTAssertEqual(FoundationModelsSummaryConfiguration.generatedContractVersion, 5)
    }

    /// The shared Foundation Models driver's token-estimation fix (Notes
    /// context-budget reliability work) changed
    /// `RealFoundationModelsSessionDriver.estimatedTokenCount` to measure
    /// the real assembled `Transcript` instead of summing independently-
    /// tokenized parts — a driver/runtime execution-compatibility change,
    /// not a schema or prompt change, so only `foundationModelsCompatibilityEpoch`
    /// (fm1 → fm2) advances; `generatedContractVersion` (schema5) and every
    /// `*PromptVersion` stay exactly as they were.
    func testSummaryProvenanceAdvancedForSharedDriverTokenEstimationFix() {
        XCTAssertEqual(FoundationModelsSummaryConfiguration.foundationModelsCompatibilityEpoch, 2)
        XCTAssertEqual(FoundationModelsSummaryConfiguration.generatedContractVersion, 5)
        XCTAssertEqual(
            FoundationModelsSummaryConfiguration.recipeVersion,
            "t5f2-summary-p2-b1-r1-structure1-section2-schema5-fm2"
        )
    }

    // MARK: Availability, provenance, and framework failures

    func testUnavailableAndIncompatibleProvenanceFailBeforeModelDispatch() async throws {
        let source = try SummaryTestSupport.source()
        let unavailableDriver = FakeFoundationModelsSessionDriver()
        unavailableDriver.setAvailability(.unavailable(description: "not ready"))
        do { _ = try await generator(unavailableDriver).makePlan(for: source); XCTFail("expected unavailable") }
        catch { XCTAssertEqual(error as? FoundationModelsSummaryBackendError, .unavailable("not ready")) }

        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 1)
        let plan = try await backend.makePlan(for: source)
        var record = generation(source: source, plan: plan)
        record.provenance.recipeVersion = "future"
        do { _ = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source); XCTFail("expected provenance rejection") }
        catch { XCTAssertEqual(error as? FoundationModelsSummaryBackendError, .incompatibleProvenance) }
        XCTAssertEqual(driver.callCount, 0)
    }

    func testUnsupportedLanguageFrameworkErrorIsMapped() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        driver.enqueueFailure(LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(
            .init(debugDescription: "unsupported locale")
        ))
        do {
            _ = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)
            XCTFail("expected mapped language error")
        } catch {
            guard case .unsupportedLanguage = error as? FoundationModelsSummaryBackendError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(driver.callCount, 1)
    }

    func testUnsupportedGuideFrameworkErrorPreservesConcreteCaseAndContext() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (plan, record) = try await planAndGeneration(backend, source: source)
        driver.enqueueFailure(LanguageModelSession.GenerationError.unsupportedGuide(
            .init(debugDescription: "the fidelity guide is not supported")
        ))
        do {
            _ = try await backend.generateAnalysis(for: plan.batches[0], generation: record, source: source)
            XCTFail("expected mapped framework error")
        } catch {
            guard case .frameworkFailure(let message) = error as? FoundationModelsSummaryBackendError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("unsupportedGuide"), "must not degrade to a generic 'error -N' message")
            XCTAssertTrue(message.contains("the fidelity guide is not supported"))
        }
    }

    func testInvalidInputAnalysisIsRejectedByIntegrityValidation() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setTokenCountOverride(1)
        let backend = generator(driver, maxItems: 1)
        let source = try SummaryTestSupport.source()
        let (_, record) = try await planAndGeneration(backend, source: source)
        var analyses = try completeAnalyses(generation: record, source: source)
        analyses[0].passages[0].sourceReferences = []
        do {
            _ = try await backend.generateDocument(from: analyses, generation: record, source: source)
            XCTFail("expected integrity rejection")
        } catch {
            guard case .finalIntegrityValidationFailed = error as? FoundationModelsSummaryBackendError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(driver.callCount, 0)
    }

    func testUnavailableTokenPreflightFailsClosedWithoutModelDispatch() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let backend = generator(driver)

        do {
            _ = try await backend.makePlan(for: SummaryTestSupport.source())
            XCTFail("expected token-preflight-unavailable failure")
        } catch {
            XCTAssertEqual(
                error as? FoundationModelsSummaryBackendError,
                .tokenPreflightUnavailable(FoundationModelsSummaryCallStage.batchAnalysis.rawValue)
            )
        }
        XCTAssertEqual(driver.callCount, 0)
    }
}
