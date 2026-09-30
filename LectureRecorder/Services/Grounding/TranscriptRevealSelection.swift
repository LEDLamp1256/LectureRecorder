import Foundation

/// Where a resolved Notes source lives in the transcript, carrying only what
/// presentation needs to reveal it: the session, the transcript it was
/// resolved against, and its inclusive range of whole transcription chunks.
/// Derived from a `ResolvedTranscriptSource`; never persisted.
nonisolated struct TranscriptRevealTarget: Equatable, Sendable {
    let sessionID: UUID
    let transcriptFingerprint: TranscriptSourceFingerprint
    let firstSequenceNumber: Int
    let lastSequenceNumber: Int
}

extension TranscriptRevealTarget {
    init(_ resolved: ResolvedTranscriptSource) {
        self.init(
            sessionID: resolved.sessionID,
            transcriptFingerprint: resolved.transcriptFingerprint,
            firstSequenceNumber: resolved.firstSequenceNumber,
            lastSequenceNumber: resolved.lastSequenceNumber
        )
    }
}

/// The transcript rows a `TranscriptRevealTarget` covers. Chunk-granular: a
/// chunk shown as several timed-segment rows contributes every one of them,
/// so no single segment is ever presented as the Note's grounding.
nonisolated struct TranscriptRevealSelection: Equatable, Sendable {
    /// The first selected row, in transcript order.
    let scrollTargetID: TranscriptPlaybackItem.ID
    /// Every row of every referenced chunk, in transcript order; never empty.
    let selectedItemIDs: [TranscriptPlaybackItem.ID]
}

/// Maps a `TranscriptRevealTarget` onto `TranscriptPlaybackNavigation` rows by
/// chunk sequence number alone. Pure: never reads text or timing, never
/// guesses, never plays.
nonisolated enum TranscriptRevealSelectionBuilder {
    /// Returns `nil` — never a partial selection — when the sessions differ,
    /// the range is inverted, or any chunk in the range has no row.
    ///
    /// The range bounds are treated as untrusted: work is bounded by the
    /// navigation's item count, and coverage is proven by counting the
    /// distinct in-range chunks seen against the range width computed with
    /// checked arithmetic, never by iterating the range.
    static func select(_ target: TranscriptRevealTarget, in navigation: TranscriptPlaybackNavigation) -> TranscriptRevealSelection? {
        guard target.sessionID == navigation.sessionID else { return nil }
        let first = target.firstSequenceNumber
        let last = target.lastSequenceNumber
        guard first <= last else { return nil }

        var selectedItemIDs: [TranscriptPlaybackItem.ID] = []
        var coveredSequenceNumbers: Set<Int> = []
        for item in navigation.items where first <= item.chunkSequenceNumber && item.chunkSequenceNumber <= last {
            selectedItemIDs.append(item.id)
            coveredSequenceNumbers.insert(item.chunkSequenceNumber)
        }

        // Every covered number lies in `first...last`, so the range is fully
        // covered exactly when the counts match.
        let (span, spanOverflowed) = last.subtractingReportingOverflow(first)
        guard !spanOverflowed else { return nil }
        let (chunkCount, countOverflowed) = span.addingReportingOverflow(1)
        guard !countOverflowed, coveredSequenceNumbers.count == chunkCount,
              let scrollTargetID = selectedItemIDs.first else {
            return nil
        }
        return TranscriptRevealSelection(scrollTargetID: scrollTargetID, selectedItemIDs: selectedItemIDs)
    }
}
