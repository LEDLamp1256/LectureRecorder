import XCTest
@testable import LectureRecorder

final class LectureSummaryModelsAndPlannerTests: XCTestCase {
    private let encoder = AtomicFileWriter.defaultEncoder
    private let decoder = AtomicFileWriter.defaultDecoder

    private func plannerPlan(
        maxBytes: Int = 100_000,
        maxItems: Int = 2
    ) throws -> LectureSummaryPlan {
        try LectureSummaryPlanner.plan(
            source: SummaryTestSupport.source(),
            budget: LectureSummaryBatchBudget(
                maxSerializedBytesPerBatch: maxBytes,
                maxItemsPerBatch: maxItems
            )
        )
    }

    func testDomainModelsCodableRoundTrip() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let passage = try SummaryTestSupport.passage(source: source)
        let batch = generation.batchPlan.batches[0]
        let analysis = LectureSummaryAnalysis(
            generationID: generation.generationID, sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: batch.batchID, batchIndex: batch.batchIndex,
            passages: [passage], provenance: generation.provenance
        )
        let document = LectureSummaryDocument(
            generationID: generation.generationID, sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: generation.provenance,
            createdDate: Date(timeIntervalSince1970: 1_700_000_020),
            sections: [LectureSummarySection(heading: "Core", passages: [passage])]
        )
        func roundTrip<T: Codable & Equatable>(_ value: T) throws {
            let decoded = try decoder.decode(T.self, from: encoder.encode(value))
            XCTAssertEqual(decoded, value)
        }
        try roundTrip(source)
        try roundTrip(generation)
        try roundTrip(analysis)
        try roundTrip(document)
    }

    func testPlannerIsDeterministicOrderedAndExactlyCovering() throws {
        let source = try SummaryTestSupport.source()
        let budget = try LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 100_000, maxItemsPerBatch: 2)
        let first = try LectureSummaryPlanner.plan(source: source, budget: budget)
        let second = try LectureSummaryPlanner.plan(source: source, budget: budget)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.batches.map(\.batchIndex), [0, 1])
        XCTAssertEqual(first.batches.flatMap(\.sourceItemIDs), SummaryTestSupport.itemIDs)
        XCTAssertEqual(first.batches.map(\.batchID), ["batch_0000", "batch_0001"])
    }

    func testPlannerHonorsByteAndItemLimits() throws {
        let source = try SummaryTestSupport.source()
        let oneItem = try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 100_000, maxItemsPerBatch: 1)
        )
        XCTAssertEqual(oneItem.batches.count, 3)
        XCTAssertTrue(oneItem.batches.allSatisfy { $0.sourceItemIDs.count == 1 })

        let firstSize = try AtomicFileWriter.defaultEncoder.encode([source.sourceItems[0]]).count
        let byteBound = try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: firstSize, maxItemsPerBatch: 10)
        )
        XCTAssertGreaterThan(byteBound.batches.count, 1)
        XCTAssertTrue(byteBound.batches.allSatisfy { $0.isOversizedSingleItem || $0.serializedByteCount <= firstSize })
    }

    func testOversizedSingleItemIsExplicit() throws {
        let source = try SummaryTestSupport.source()
        let plan = try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 1, maxItemsPerBatch: 10)
        )
        XCTAssertEqual(plan.batches.count, source.sourceItems.count)
        XCTAssertTrue(plan.batches.allSatisfy { $0.isOversizedSingleItem && $0.sourceItemIDs.count == 1 })
    }

    func testInvalidPlannerLimitsAreRejected() {
        XCTAssertThrowsError(try LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 0, maxItemsPerBatch: 1))
        XCTAssertThrowsError(try LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 1, maxItemsPerBatch: 0))
    }

    func testPlannerProducedNormalAndOversizedPlansPassStructuralValidation() throws {
        XCTAssertNoThrow(try plannerPlan().validateStructure())
        XCTAssertNoThrow(try plannerPlan(maxBytes: 1, maxItems: 2).validateStructure())
    }

    func testPlanValidationRejectsUnsupportedSchemaAndNonPositiveLimits() throws {
        var plan = try plannerPlan()
        plan.schemaVersion = 999
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual($0 as? LectureSummaryPlanValidationError, .unsupportedSchemaVersion(999))
        }
        plan = try plannerPlan()
        plan.maxSerializedBytesPerBatch = 0
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual($0 as? LectureSummaryPlanValidationError, .nonPositiveByteLimit(0))
        }
        plan = try plannerPlan()
        plan.maxItemsPerBatch = -1
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual($0 as? LectureSummaryPlanValidationError, .nonPositiveItemLimit(-1))
        }
    }

    func testPlanValidationRejectsEmptyDuplicateAndNonsequentialBatches() throws {
        XCTAssertThrowsError(try LectureSummaryPlan(
            maxSerializedBytesPerBatch: 10, maxItemsPerBatch: 1, batches: []
        ).validateStructure()) {
            XCTAssertEqual($0 as? LectureSummaryPlanValidationError, .emptyPlan)
        }
        var plan = try plannerPlan()
        plan.batches[1].batchIndex = 0
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual($0 as? LectureSummaryPlanValidationError, .duplicateBatchIndex(0))
        }
        plan = try plannerPlan()
        plan.batches[1].batchIndex = 2
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual($0 as? LectureSummaryPlanValidationError, .nonSequentialBatchIndices([0, 2]))
        }
    }

    func testPlanValidationRejectsIncorrectBatchIDAndEmptySourceItems() throws {
        var plan = try plannerPlan()
        plan.batches[0].batchID = "wrong"
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual(
                $0 as? LectureSummaryPlanValidationError,
                .batchIDMismatch(batchIndex: 0, expected: "batch_0000", actual: "wrong")
            )
        }
        plan = try plannerPlan()
        plan.batches[0].sourceItemIDs = []
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual($0 as? LectureSummaryPlanValidationError, .emptySourceItemIDs(batchIndex: 0))
        }
    }

    func testPlanValidationRejectsDuplicateSourceItemsAndItemLimitViolation() throws {
        var plan = try plannerPlan()
        let duplicate = plan.batches[0].sourceItemIDs[0]
        plan.batches[1].sourceItemIDs[0] = duplicate
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual($0 as? LectureSummaryPlanValidationError, .duplicateSourceItemID(duplicate))
        }
        plan = try plannerPlan()
        plan.maxItemsPerBatch = 1
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual(
                $0 as? LectureSummaryPlanValidationError,
                .itemCountExceedsLimit(batchIndex: 0, count: 2, limit: 1)
            )
        }
    }

    func testPlanValidationRejectsNegativeGapOverlapAndInconsistentRanges() throws {
        var plan = try plannerPlan()
        plan.batches[0].firstSourceItemIndex = -1
        XCTAssertThrowsError(try plan.validateStructure()) {
            guard case LectureSummaryPlanValidationError.negativeSourceIndexRange = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        plan = try plannerPlan()
        plan.batches[1].firstSourceItemIndex = 3
        plan.batches[1].lastSourceItemIndex = 3
        XCTAssertThrowsError(try plan.validateStructure()) {
            guard case LectureSummaryPlanValidationError.unexpectedFirstSourceItemIndex = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        plan = try plannerPlan()
        plan.batches[1].firstSourceItemIndex = 1
        plan.batches[1].lastSourceItemIndex = 1
        XCTAssertThrowsError(try plan.validateStructure()) {
            guard case LectureSummaryPlanValidationError.unexpectedFirstSourceItemIndex = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        plan = try plannerPlan()
        plan.batches[0].lastSourceItemIndex = 0
        XCTAssertThrowsError(try plan.validateStructure()) {
            guard case LectureSummaryPlanValidationError.lastSourceItemIndexMismatch = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
    }

    func testPlanValidationRejectsSourceRangeArithmeticOverflowWithoutTrapping() throws {
        var plan = try plannerPlan()
        plan.batches = [LectureSummaryBatch(
            batchID: "batch_0000",
            batchIndex: 0,
            firstSourceItemIndex: Int.max,
            lastSourceItemIndex: Int.max,
            sourceItemIDs: [UUID(), UUID()],
            serializedByteCount: 1,
            isOversizedSingleItem: false
        )]
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual($0 as? LectureSummaryPlanValidationError, .arithmeticOverflow(batchIndex: 0))
        }
    }

    func testPlanValidationRejectsNonPositiveAndInvalidByteBudgetClaims() throws {
        var plan = try plannerPlan()
        plan.batches[0].serializedByteCount = 0
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual(
                $0 as? LectureSummaryPlanValidationError,
                .nonPositiveSerializedByteCount(batchIndex: 0, count: 0)
            )
        }
        plan = try plannerPlan(maxItems: 1)
        plan.maxSerializedBytesPerBatch = plan.batches[0].serializedByteCount - 1
        XCTAssertThrowsError(try plan.validateStructure()) {
            guard case LectureSummaryPlanValidationError.overBudgetBatchNotMarkedOversized = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
    }

    func testPlanValidationRejectsIncorrectOversizedFlagsAndMultiItemOversizedBatch() throws {
        var plan = try plannerPlan(maxItems: 1)
        plan.batches[0].isOversizedSingleItem = true
        XCTAssertThrowsError(try plan.validateStructure()) {
            guard case LectureSummaryPlanValidationError.withinBudgetBatchMarkedOversized = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        plan = try plannerPlan()
        plan.batches[0].isOversizedSingleItem = true
        XCTAssertThrowsError(try plan.validateStructure()) {
            XCTAssertEqual(
                $0 as? LectureSummaryPlanValidationError,
                .oversizedBatchItemCountMismatch(batchIndex: 0, count: 2)
            )
        }
    }
}
