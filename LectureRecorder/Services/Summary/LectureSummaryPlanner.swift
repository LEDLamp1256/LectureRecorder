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
        func encodedSize(_ items: [LectureSummarySourceItem], blamedOn id: UUID) throws -> Int {
            do {
                return try AtomicFileWriter.defaultEncoder.encode(items).count
            } catch {
                throw LectureSummaryPlanningError.itemEncodingFailed(id, error.localizedDescription)
            }
        }

        var batches: [LectureSummaryBatch] = []
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

        for (index, sourceItem) in source.sourceItems.enumerated() {
            let singleItemSize = try encodedSize([sourceItem], blamedOn: sourceItem.item.id)
            if singleItemSize > budget.maxSerializedBytesPerBatch {
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

            let exceedsItems = pendingIDs.count >= budget.maxItemsPerBatch
            let candidateItems = pendingItems + [sourceItem]
            let candidateSize = try encodedSize(candidateItems, blamedOn: sourceItem.item.id)
            let exceedsBytes = candidateSize > budget.maxSerializedBytesPerBatch
            if !pendingIDs.isEmpty && (exceedsItems || exceedsBytes) { flush() }
            if pendingStart == nil { pendingStart = index }
            pendingItems.append(sourceItem)
            pendingIDs.append(sourceItem.item.id)
            pendingBytes = try encodedSize(pendingItems, blamedOn: sourceItem.item.id)
        }
        flush()

        return LectureSummaryPlan(
            maxSerializedBytesPerBatch: budget.maxSerializedBytesPerBatch,
            maxItemsPerBatch: budget.maxItemsPerBatch,
            batches: batches
        )
    }

    static func batchID(_ index: Int) -> String {
        "batch_\(String(format: "%04d", index))"
    }
}
