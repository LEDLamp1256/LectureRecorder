import Foundation

nonisolated enum NotesWindowBudgetError: LocalizedError, Sendable, Equatable {
    case nonPositiveByteLimit(Int)
    case nonPositiveUnitLimit(Int)

    var errorDescription: String? {
        switch self {
        case .nonPositiveByteLimit(let value):
            return "maxUTF8BytesPerWindow must be positive; got \(value)."
        case .nonPositiveUnitLimit(let value):
            return "maxUnitsPerWindow must be positive when provided; got \(value)."
        }
    }
}

/// A deterministic, backend-agnostic budget for grouping ordered transcript
/// source units into model-input windows. `maxUTF8BytesPerWindow` is a
/// simple, explicitly-approximate size estimator (UTF-8 byte count of a
/// unit's text — hence the name naming exactly that unit, not an opaque
/// "character" count) chosen because it is cheap and deterministic for
/// tests; a future backend-aware token estimator can replace
/// `NotesWindowPlanner`'s internal `unitSize` function without changing
/// this budget's shape or the planner's coverage contract.
nonisolated struct NotesWindowBudget: Sendable, Equatable {
    var maxUTF8BytesPerWindow: Int
    var maxUnitsPerWindow: Int?

    init(maxUTF8BytesPerWindow: Int, maxUnitsPerWindow: Int? = nil) throws {
        guard maxUTF8BytesPerWindow > 0 else {
            throw NotesWindowBudgetError.nonPositiveByteLimit(maxUTF8BytesPerWindow)
        }
        if let maxUnitsPerWindow {
            guard maxUnitsPerWindow > 0 else {
                throw NotesWindowBudgetError.nonPositiveUnitLimit(maxUnitsPerWindow)
            }
        }
        self.maxUTF8BytesPerWindow = maxUTF8BytesPerWindow
        self.maxUnitsPerWindow = maxUnitsPerWindow
    }
}

/// One planned, contiguous, model-neutral input window: an inclusive range
/// of transcript source unit sequence numbers this window owns. No real
/// model or backend is invoked to produce this — it is pure arithmetic
/// over already-durable transcript source units.
nonisolated struct NotesInputWindow: Codable, Equatable, Sendable {
    var windowIndex: Int
    var firstSequenceNumber: Int
    var lastSequenceNumber: Int
    var unitCount: Int
    /// `true` when a single source unit alone exceeded the budget and was
    /// therefore planned as its own window rather than being silently
    /// split or allowed to exceed the budget in a multi-unit window.
    var isOversizedSingleUnit: Bool
}

nonisolated enum NotesWindowPlanner {
    /// Partitions `units` into ordered, contiguous, non-overlapping,
    /// gap-free windows under `budget`. Guarantees: every unit belongs to
    /// exactly one window; windows are ordered ascending by
    /// `windowIndex`/sequence range; identical `units`/`budget` always
    /// produce an identical plan; an oversized single unit is always
    /// planned explicitly (`isOversizedSingleUnit == true`) rather than
    /// exceeding the budget invisibly or being split.
    static func plan(units: [NotesTranscriptSourceUnit], budget: NotesWindowBudget) -> [NotesInputWindow] {
        guard !units.isEmpty else { return [] }
        let sortedUnits = units.sorted { $0.sequenceNumber < $1.sequenceNumber }

        var windows: [NotesInputWindow] = []
        var windowIndex = 0
        var pendingFirst: Int?
        var pendingLast: Int?
        var pendingUnitCount = 0
        var pendingSize = 0

        func flushPendingWindow() {
            guard let first = pendingFirst, let last = pendingLast else { return }
            windows.append(NotesInputWindow(
                windowIndex: windowIndex,
                firstSequenceNumber: first,
                lastSequenceNumber: last,
                unitCount: pendingUnitCount,
                isOversizedSingleUnit: false
            ))
            windowIndex += 1
            pendingFirst = nil
            pendingLast = nil
            pendingUnitCount = 0
            pendingSize = 0
        }

        for unit in sortedUnits {
            let size = unitSize(for: unit)

            if size > budget.maxUTF8BytesPerWindow {
                flushPendingWindow()
                windows.append(NotesInputWindow(
                    windowIndex: windowIndex,
                    firstSequenceNumber: unit.sequenceNumber,
                    lastSequenceNumber: unit.sequenceNumber,
                    unitCount: 1,
                    isOversizedSingleUnit: true
                ))
                windowIndex += 1
                continue
            }

            let unitCountWouldExceed = budget.maxUnitsPerWindow.map { pendingUnitCount >= $0 } ?? false
            let sizeWouldExceed = pendingSize + size > budget.maxUTF8BytesPerWindow
            if pendingUnitCount > 0 && (unitCountWouldExceed || sizeWouldExceed) {
                flushPendingWindow()
            }

            if pendingFirst == nil {
                pendingFirst = unit.sequenceNumber
            }
            pendingLast = unit.sequenceNumber
            pendingUnitCount += 1
            pendingSize += size
        }
        flushPendingWindow()

        return windows
    }

    private static func unitSize(for unit: NotesTranscriptSourceUnit) -> Int {
        unit.text.utf8.count
    }
}
