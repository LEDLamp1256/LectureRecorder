import Foundation

/// The plain transcript rows a `TranscriptRevealTarget` covers when no
/// `TranscriptPlaybackNavigation` is available. Plain rows are one per chunk,
/// so this is exactly as precise as the chunk-granular Notes source — never
/// finer.
nonisolated struct TranscriptFallbackRevealSelection: Equatable, Sendable {
    /// The first selected row, in displayed transcript order.
    let scrollTargetSequenceNumber: Int
    /// Every referenced chunk's row, in displayed transcript order; never empty.
    let selectedSequenceNumbers: [Int]
}

/// Maps a `TranscriptRevealTarget` onto plain `OrderedSegment` rows by
/// sequence number alone. Pure: never reads text or timing, never guesses,
/// never plays. The caller checks the target's session against the
/// transcript's; segments carry no session of their own.
nonisolated enum TranscriptFallbackRevealSelectionBuilder {
    /// Returns `nil` — never a partial selection — when the range is
    /// inverted, any chunk in the range has no row, or any in-range row is
    /// not `.completed`. Failed, in-progress, and missing rows are status,
    /// not transcript text, so they never count as supporting evidence.
    ///
    /// The range bounds are treated as untrusted: work is bounded by the
    /// segment count, and coverage is proven by counting the distinct
    /// in-range chunks seen against the range width computed with checked
    /// arithmetic, never by iterating the range.
    static func select(_ target: TranscriptRevealTarget, in segments: [OrderedSegment]) -> TranscriptFallbackRevealSelection? {
        let first = target.firstSequenceNumber
        let last = target.lastSequenceNumber
        guard first <= last else { return nil }

        var selectedSequenceNumbers: [Int] = []
        var coveredSequenceNumbers: Set<Int> = []
        for segment in segments where first <= segment.sequenceNumber && segment.sequenceNumber <= last {
            guard case .completed = segment.state else { return nil }
            selectedSequenceNumbers.append(segment.sequenceNumber)
            coveredSequenceNumbers.insert(segment.sequenceNumber)
        }

        // Every covered number lies in `first...last`, so the range is fully
        // covered exactly when the counts match.
        let (span, spanOverflowed) = last.subtractingReportingOverflow(first)
        guard !spanOverflowed else { return nil }
        let (chunkCount, countOverflowed) = span.addingReportingOverflow(1)
        guard !countOverflowed, coveredSequenceNumbers.count == chunkCount,
              let scrollTargetSequenceNumber = selectedSequenceNumbers.first else {
            return nil
        }
        return TranscriptFallbackRevealSelection(
            scrollTargetSequenceNumber: scrollTargetSequenceNumber,
            selectedSequenceNumbers: selectedSequenceNumbers
        )
    }
}
