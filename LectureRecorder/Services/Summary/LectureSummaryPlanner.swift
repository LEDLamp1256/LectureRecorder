import Foundation

nonisolated enum LectureSummaryPlanningError: LocalizedError, Sendable, Equatable {
    case nonPositiveByteLimit(Int)
    case nonPositiveItemLimit(Int)
    case itemEncodingFailed(UUID, String)

    var errorDescription: String? {
        switch self {
        case .nonPositiveByteLimit(let value): return "maxSerializedBytesPerBatch must be positive; got \(value)."
        case .nonPositiveItemLimit(let value): return "maxItemsPerBatch must be positive; got \(value)."
        case .itemEncodingFailed(let id, let reason): return "Source Note item \(id.uuidString) could not be sized: \(reason)"
        }
    }
}

nonisolated struct LectureSummaryBatchBudget: Equatable, Sendable {
    var maxSerializedBytesPerBatch: Int
    var maxItemsPerBatch: Int

    init(maxSerializedBytesPerBatch: Int, maxItemsPerBatch: Int) throws {
        guard maxSerializedBytesPerBatch > 0 else {
            throw LectureSummaryPlanningError.nonPositiveByteLimit(maxSerializedBytesPerBatch)
        }
        guard maxItemsPerBatch > 0 else {
            throw LectureSummaryPlanningError.nonPositiveItemLimit(maxItemsPerBatch)
        }
        self.maxSerializedBytesPerBatch = maxSerializedBytesPerBatch
        self.maxItemsPerBatch = maxItemsPerBatch
    }
}

/// How a plan partitions the source. Chosen from a generation's persisted
/// provenance — never stored in the plan — so every plan made before
/// `notesSections` existed is re-derived exactly as it always was.
nonisolated enum LectureSummaryPlanPartition: Equatable, Sendable {
    /// Contiguous batches across the whole source, filled up to the item
    /// limit (every Apple plan and MLX Summary v1–v4).
    case contiguous
    /// Contiguous batches that never cross a Notes section: each section is
    /// split into the fewest batches within the item limit, as evenly as
    /// possible (MLX Summary v5 and later).
    case notesSections

    static func forProvenance(_ provenance: LectureNotesGenerationProvenance) -> LectureSummaryPlanPartition {
        provenance.backendIdentifier == MLXSummaryConfiguration.backendIdentifier
            && MLXSummaryConfiguration.notesSectionPartitionedRecipeVersions.contains(provenance.recipeVersion)
            ? .notesSections : .contiguous
    }
}

nonisolated enum LectureSummaryPlanner {
    /// Partitions canonical source items into deterministic contiguous batches.
    /// Byte cost is the exact size of the batch's source-item array under the
    /// canonical deterministic JSON encoder, including array delimiters and
    /// separators. Oversized items remain explicit,
    /// single-item batches for controlled rejection by a future backend.
    static func plan(
        source: LectureSummarySourceSnapshot,
        budget: LectureSummaryBatchBudget
    ) throws -> LectureSummaryPlan {
        try plan(source: source, budget: budget, partition: .contiguous)
    }

    /// `plan(source:budget:)` under `partition`. With `.notesSections`, each
    /// maximal run of consecutive items sharing a Notes section is split
    /// into the fewest chunks within the item limit, whose sizes differ by
    /// at most one (18 items → 9 + 9, never 12 + 6; 25 → 9 + 8 + 8), and
    /// each chunk is planned on its own (the byte limit can still split it
    /// further). Batch indices and source indices stay global, and the
    /// persisted limits are `budget`'s, so the result meets every
    /// `LectureSummaryPlan.validateStructure()` invariant.
    static func plan(
        source: LectureSummarySourceSnapshot,
        budget: LectureSummaryBatchBudget,
        partition: LectureSummaryPlanPartition
    ) throws -> LectureSummaryPlan {
        var batches: [LectureSummaryBatch] = []
        switch partition {
        case .contiguous:
            try appendBatches(
                for: source.sourceItems[...], itemLimit: budget.maxItemsPerBatch,
                byteLimit: budget.maxSerializedBytesPerBatch, to: &batches
            )
        case .notesSections:
            var start = source.sourceItems.startIndex
            while start < source.sourceItems.endIndex {
                let sectionID = source.sourceItems[start].sectionID
                var end = start
                while end < source.sourceItems.endIndex, source.sourceItems[end].sectionID == sectionID { end += 1 }
                let count = end - start
                let batchCount = (count + budget.maxItemsPerBatch - 1) / budget.maxItemsPerBatch
                var chunkStart = start
                for chunk in 0..<batchCount {
                    let size = count / batchCount + (chunk < count % batchCount ? 1 : 0)
                    try appendBatches(
                        for: source.sourceItems[chunkStart..<(chunkStart + size)], itemLimit: size,
                        byteLimit: budget.maxSerializedBytesPerBatch, to: &batches
                    )
                    chunkStart += size
                }
                start = end
            }
        }
        return LectureSummaryPlan(
            maxSerializedBytesPerBatch: budget.maxSerializedBytesPerBatch,
            maxItemsPerBatch: budget.maxItemsPerBatch,
            batches: batches
        )
    }

    /// The contiguous greedy partition of `items` (whose `sourceIndex`
    /// values are global), appended after `batches`.
    private static func appendBatches(
        for items: ArraySlice<LectureSummarySourceItem>,
        itemLimit: Int,
        byteLimit: Int,
        to batches: inout [LectureSummaryBatch]
    ) throws {
        func encodedSize(_ items: [LectureSummarySourceItem], blamedOn id: UUID) throws -> Int {
            do {
                return try AtomicFileWriter.defaultEncoder.encode(items).count
            } catch {
                throw LectureSummaryPlanningError.itemEncodingFailed(id, error.localizedDescription)
            }
        }

        var pendingStart: Int?
        var pendingItems: [LectureSummarySourceItem] = []
        var pendingIDs: [UUID] = []
        var pendingBytes = 0

        func flush() {
            guard let start = pendingStart, !pendingIDs.isEmpty else { return }
            let index = batches.count
            batches.append(LectureSummaryBatch(
                batchID: batchID(index),
                batchIndex: index,
                firstSourceItemIndex: start,
                lastSourceItemIndex: start + pendingIDs.count - 1,
                sourceItemIDs: pendingIDs,
                serializedByteCount: pendingBytes,
                isOversizedSingleItem: false
            ))
            pendingStart = nil
            pendingItems = []
            pendingIDs = []
            pendingBytes = 0
        }

        // Slice indices are positions in the whole source, so a section's
        // batches carry global source indices.
        for index in items.indices {
            let sourceItem = items[index]
            let singleItemSize = try encodedSize([sourceItem], blamedOn: sourceItem.item.id)
            if singleItemSize > byteLimit {
                flush()
                let batchIndex = batches.count
                batches.append(LectureSummaryBatch(
                    batchID: batchID(batchIndex),
                    batchIndex: batchIndex,
                    firstSourceItemIndex: index,
                    lastSourceItemIndex: index,
                    sourceItemIDs: [sourceItem.item.id],
                    serializedByteCount: singleItemSize,
                    isOversizedSingleItem: true
                ))
                continue
            }

            let exceedsItems = pendingIDs.count >= itemLimit
            let candidateItems = pendingItems + [sourceItem]
            let candidateSize = try encodedSize(candidateItems, blamedOn: sourceItem.item.id)
            let exceedsBytes = candidateSize > byteLimit
            if !pendingIDs.isEmpty && (exceedsItems || exceedsBytes) { flush() }
            if pendingStart == nil { pendingStart = index }
            pendingItems.append(sourceItem)
            pendingIDs.append(sourceItem.item.id)
            pendingBytes = try encodedSize(pendingItems, blamedOn: sourceItem.item.id)
        }
        flush()
    }

    static func batchID(_ index: Int) -> String {
        "batch_\(String(format: "%04d", index))"
    }
}
