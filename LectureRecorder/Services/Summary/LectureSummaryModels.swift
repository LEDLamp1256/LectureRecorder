import Foundation

/// A stable SHA-256 identity for the semantic contents of a committed
/// `LectureNotesDocument`. See `LectureSummarySourceBuilder` for the exact
/// deterministic encoding used to compute it.
nonisolated struct NotesDocumentFingerprint: Codable, Equatable, Hashable, Sendable {
    static let currentAlgorithmVersion = 1

    var algorithmVersion: Int
    var digestHex: String
}

/// One contiguous batch in a frozen Summary plan. `sourceItemIDs` are kept
/// explicitly so a later backend never has to reinterpret ordinal ranges.
nonisolated struct LectureSummaryBatch: Codable, Equatable, Sendable {
    var batchID: String
    var batchIndex: Int
    var firstSourceItemIndex: Int
    var lastSourceItemIndex: Int
    var sourceItemIDs: [UUID]
    var serializedByteCount: Int
    var isOversizedSingleItem: Bool
}

nonisolated struct LectureSummaryPlan: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var maxSerializedBytesPerBatch: Int
    var maxItemsPerBatch: Int
    var batches: [LectureSummaryBatch]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        maxSerializedBytesPerBatch: Int,
        maxItemsPerBatch: Int,
        batches: [LectureSummaryBatch]
    ) {
        self.schemaVersion = schemaVersion
        self.maxSerializedBytesPerBatch = maxSerializedBytesPerBatch
        self.maxItemsPerBatch = maxItemsPerBatch
        self.batches = batches
    }
}

/// Every source-independent structural rejection for a persisted Summary
/// plan. Decoding proves only JSON shape; it does not make integer arithmetic,
/// batch topology, frozen limits, or oversized-item claims trustworthy.
nonisolated enum LectureSummaryPlanValidationError: LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case nonPositiveByteLimit(Int)
    case nonPositiveItemLimit(Int)
    case emptyPlan
    case duplicateBatchIndex(Int)
    case nonSequentialBatchIndices([Int])
    case batchIDMismatch(batchIndex: Int, expected: String, actual: String)
    case emptySourceItemIDs(batchIndex: Int)
    case duplicateSourceItemID(UUID)
    case itemCountExceedsLimit(batchIndex: Int, count: Int, limit: Int)
    case negativeSourceIndexRange(batchIndex: Int, first: Int, last: Int)
    case unexpectedFirstSourceItemIndex(batchIndex: Int, expected: Int, actual: Int)
    case lastSourceItemIndexMismatch(batchIndex: Int, expected: Int, actual: Int)
    case arithmeticOverflow(batchIndex: Int)
    case nonPositiveSerializedByteCount(batchIndex: Int, count: Int)
    case overBudgetBatchNotMarkedOversized(batchIndex: Int, count: Int, limit: Int)
    case oversizedBatchItemCountMismatch(batchIndex: Int, count: Int)
    case withinBudgetBatchMarkedOversized(batchIndex: Int, count: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Summary plan schema version \(version) is not supported."
        case .nonPositiveByteLimit(let value):
            return "Summary plan byte limit must be positive; got \(value)."
        case .nonPositiveItemLimit(let value):
            return "Summary plan item limit must be positive; got \(value)."
        case .emptyPlan:
            return "Summary plan contains no batches."
        case .duplicateBatchIndex(let index):
            return "Summary plan contains duplicate batch index \(index)."
        case .nonSequentialBatchIndices(let indices):
            return "Summary plan batch indices are not exactly 0..<count: \(indices)."
        case .batchIDMismatch(let index, let expected, let actual):
            return "Summary batch #\(index) has ID \(actual), expected \(expected)."
        case .emptySourceItemIDs(let index):
            return "Summary batch #\(index) has no source item IDs."
        case .duplicateSourceItemID(let id):
            return "Summary plan assigns source item \(id.uuidString) more than once."
        case .itemCountExceedsLimit(let index, let count, let limit):
            return "Summary batch #\(index) has \(count) items, exceeding limit \(limit)."
        case .negativeSourceIndexRange(let index, let first, let last):
            return "Summary batch #\(index) has a negative source range \(first)...\(last)."
        case .unexpectedFirstSourceItemIndex(let index, let expected, let actual):
            return "Summary batch #\(index) starts at source index \(actual), expected \(expected)."
        case .lastSourceItemIndexMismatch(let index, let expected, let actual):
            return "Summary batch #\(index) ends at source index \(actual), expected \(expected)."
        case .arithmeticOverflow(let index):
            return "Summary batch #\(index) has source-index arithmetic that overflows Int."
        case .nonPositiveSerializedByteCount(let index, let count):
            return "Summary batch #\(index) has non-positive serialized byte count \(count)."
        case .overBudgetBatchNotMarkedOversized(let index, let count, let limit):
            return "Summary batch #\(index) has \(count) serialized bytes above limit \(limit) but is not marked oversized."
        case .oversizedBatchItemCountMismatch(let index, let count):
            return "Oversized Summary batch #\(index) contains \(count) items instead of exactly one."
        case .withinBudgetBatchMarkedOversized(let index, let count, let limit):
            return "Summary batch #\(index) is marked oversized at \(count) bytes but limit \(limit) is not exceeded."
        }
    }
}

extension LectureSummaryPlan {
    /// Validates only structure available in the persisted plan itself. Exact
    /// byte counts and exact source coverage remain source-aware checks in
    /// `LectureSummaryIntegrityValidator` through deterministic recomputation.
    func validateStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LectureSummaryPlanValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard maxSerializedBytesPerBatch > 0 else {
            throw LectureSummaryPlanValidationError.nonPositiveByteLimit(maxSerializedBytesPerBatch)
        }
        guard maxItemsPerBatch > 0 else {
            throw LectureSummaryPlanValidationError.nonPositiveItemLimit(maxItemsPerBatch)
        }
        guard !batches.isEmpty else { throw LectureSummaryPlanValidationError.emptyPlan }

        var seenBatchIndices: Set<Int> = []
        for batch in batches {
            guard seenBatchIndices.insert(batch.batchIndex).inserted else {
                throw LectureSummaryPlanValidationError.duplicateBatchIndex(batch.batchIndex)
            }
        }
        let sortedIndices = batches.map(\.batchIndex).sorted()
        guard sortedIndices == Array(0..<batches.count) else {
            throw LectureSummaryPlanValidationError.nonSequentialBatchIndices(sortedIndices)
        }

        var seenSourceItemIDs: Set<UUID> = []
        var expectedFirstSourceIndex = 0
        let orderedBatches = batches.sorted { $0.batchIndex < $1.batchIndex }
        for batch in orderedBatches {
            let expectedBatchID = LectureSummaryPlanner.batchID(batch.batchIndex)
            guard batch.batchID == expectedBatchID else {
                throw LectureSummaryPlanValidationError.batchIDMismatch(
                    batchIndex: batch.batchIndex,
                    expected: expectedBatchID,
                    actual: batch.batchID
                )
            }
            guard !batch.sourceItemIDs.isEmpty else {
                throw LectureSummaryPlanValidationError.emptySourceItemIDs(batchIndex: batch.batchIndex)
            }
            for id in batch.sourceItemIDs {
                guard seenSourceItemIDs.insert(id).inserted else {
                    throw LectureSummaryPlanValidationError.duplicateSourceItemID(id)
                }
            }
            guard batch.sourceItemIDs.count <= maxItemsPerBatch else {
                throw LectureSummaryPlanValidationError.itemCountExceedsLimit(
                    batchIndex: batch.batchIndex,
                    count: batch.sourceItemIDs.count,
                    limit: maxItemsPerBatch
                )
            }
            guard batch.firstSourceItemIndex >= 0, batch.lastSourceItemIndex >= 0 else {
                throw LectureSummaryPlanValidationError.negativeSourceIndexRange(
                    batchIndex: batch.batchIndex,
                    first: batch.firstSourceItemIndex,
                    last: batch.lastSourceItemIndex
                )
            }

            let (expectedLast, lastOverflowed) = batch.firstSourceItemIndex.addingReportingOverflow(
                batch.sourceItemIDs.count - 1
            )
            guard !lastOverflowed else {
                throw LectureSummaryPlanValidationError.arithmeticOverflow(batchIndex: batch.batchIndex)
            }
            guard batch.firstSourceItemIndex == expectedFirstSourceIndex else {
                throw LectureSummaryPlanValidationError.unexpectedFirstSourceItemIndex(
                    batchIndex: batch.batchIndex,
                    expected: expectedFirstSourceIndex,
                    actual: batch.firstSourceItemIndex
                )
            }
            guard batch.lastSourceItemIndex == expectedLast else {
                throw LectureSummaryPlanValidationError.lastSourceItemIndexMismatch(
                    batchIndex: batch.batchIndex,
                    expected: expectedLast,
                    actual: batch.lastSourceItemIndex
                )
            }
            let (nextExpected, nextOverflowed) = expectedLast.addingReportingOverflow(1)
            guard !nextOverflowed || batch.batchIndex == orderedBatches.count - 1 else {
                throw LectureSummaryPlanValidationError.arithmeticOverflow(batchIndex: batch.batchIndex)
            }
            if !nextOverflowed { expectedFirstSourceIndex = nextExpected }

            guard batch.serializedByteCount > 0 else {
                throw LectureSummaryPlanValidationError.nonPositiveSerializedByteCount(
                    batchIndex: batch.batchIndex,
                    count: batch.serializedByteCount
                )
            }
            if batch.isOversizedSingleItem {
                guard batch.sourceItemIDs.count == 1 else {
                    throw LectureSummaryPlanValidationError.oversizedBatchItemCountMismatch(
                        batchIndex: batch.batchIndex,
                        count: batch.sourceItemIDs.count
                    )
                }
                guard batch.serializedByteCount > maxSerializedBytesPerBatch else {
                    throw LectureSummaryPlanValidationError.withinBudgetBatchMarkedOversized(
                        batchIndex: batch.batchIndex,
                        count: batch.serializedByteCount,
                        limit: maxSerializedBytesPerBatch
                    )
                }
            } else {
                guard batch.serializedByteCount <= maxSerializedBytesPerBatch else {
                    throw LectureSummaryPlanValidationError.overBudgetBatchNotMarkedOversized(
                        batchIndex: batch.batchIndex,
                        count: batch.serializedByteCount,
                        limit: maxSerializedBytesPerBatch
                    )
                }
            }
        }
    }
}

/// Immutable identity and plan for one dedicated Summary generation.
nonisolated struct LectureSummaryGenerationRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generationID: UUID
    var sessionID: UUID
    var sourceNotesGenerationID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    var sourceNotesDocumentFingerprint: NotesDocumentFingerprint
    var batchPlan: LectureSummaryPlan
    var provenance: LectureNotesGenerationProvenance
    var createdDate: Date

    static func newGeneration(
        generationID: UUID = UUID(),
        sessionID: UUID,
        sourceNotesGenerationID: UUID,
        transcriptFingerprint: TranscriptSourceFingerprint,
        sourceNotesDocumentFingerprint: NotesDocumentFingerprint,
        batchPlan: LectureSummaryPlan,
        provenance: LectureNotesGenerationProvenance,
        now: Date = Date()
    ) -> LectureSummaryGenerationRecord {
        LectureSummaryGenerationRecord(
            schemaVersion: currentSchemaVersion,
            generationID: generationID,
            sessionID: sessionID,
            sourceNotesGenerationID: sourceNotesGenerationID,
            transcriptFingerprint: transcriptFingerprint,
            sourceNotesDocumentFingerprint: sourceNotesDocumentFingerprint,
            batchPlan: batchPlan,
            provenance: provenance,
            createdDate: now
        )
    }
}

/// Provider-neutral, post-mapping grounded prose. A backend may return local
/// indices, but only original Note item IDs and their exact derived transcript
/// references cross this domain boundary.
nonisolated struct LectureSummaryPassage: Codable, Equatable, Sendable {
    var id: UUID
    var text: String
    var supportingNoteItemIDs: [UUID]
    var sourceReferences: [NotesSourceReference]
    var fidelity: LectureNoteContentFidelity
    var uncertaintyNote: String?

    init(
        id: UUID = UUID(),
        text: String,
        supportingNoteItemIDs: [UUID],
        sourceReferences: [NotesSourceReference],
        fidelity: LectureNoteContentFidelity,
        uncertaintyNote: String? = nil
    ) {
        self.id = id
        self.text = text
        self.supportingNoteItemIDs = supportingNoteItemIDs
        self.sourceReferences = sourceReferences
        self.fidelity = fidelity
        self.uncertaintyNote = uncertaintyNote
    }
}

nonisolated struct LectureSummaryAnalysis: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generationID: UUID
    var sessionID: UUID
    var sourceNotesGenerationID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    var sourceNotesDocumentFingerprint: NotesDocumentFingerprint
    var batchID: String
    var batchIndex: Int
    var passages: [LectureSummaryPassage]
    var provenance: LectureNotesGenerationProvenance

    init(
        generationID: UUID,
        sessionID: UUID,
        sourceNotesGenerationID: UUID,
        transcriptFingerprint: TranscriptSourceFingerprint,
        sourceNotesDocumentFingerprint: NotesDocumentFingerprint,
        batchID: String,
        batchIndex: Int,
        passages: [LectureSummaryPassage],
        provenance: LectureNotesGenerationProvenance
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generationID = generationID
        self.sessionID = sessionID
        self.sourceNotesGenerationID = sourceNotesGenerationID
        self.transcriptFingerprint = transcriptFingerprint
        self.sourceNotesDocumentFingerprint = sourceNotesDocumentFingerprint
        self.batchID = batchID
        self.batchIndex = batchIndex
        self.passages = passages
        self.provenance = provenance
    }
}

nonisolated struct LectureSummarySection: Codable, Equatable, Sendable {
    var id: UUID
    var heading: String
    var passages: [LectureSummaryPassage]

    init(id: UUID = UUID(), heading: String, passages: [LectureSummaryPassage]) {
        self.id = id
        self.heading = heading
        self.passages = passages
    }
}

nonisolated struct LectureSummaryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generationID: UUID
    var sessionID: UUID
    var sourceNotesGenerationID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    var sourceNotesDocumentFingerprint: NotesDocumentFingerprint
    var provenance: LectureNotesGenerationProvenance
    var createdDate: Date
    var sections: [LectureSummarySection]

    init(
        generationID: UUID,
        sessionID: UUID,
        sourceNotesGenerationID: UUID,
        transcriptFingerprint: TranscriptSourceFingerprint,
        sourceNotesDocumentFingerprint: NotesDocumentFingerprint,
        provenance: LectureNotesGenerationProvenance,
        createdDate: Date = Date(),
        sections: [LectureSummarySection]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generationID = generationID
        self.sessionID = sessionID
        self.sourceNotesGenerationID = sourceNotesGenerationID
        self.transcriptFingerprint = transcriptFingerprint
        self.sourceNotesDocumentFingerprint = sourceNotesDocumentFingerprint
        self.provenance = provenance
        self.createdDate = createdDate
        self.sections = sections
    }
}
