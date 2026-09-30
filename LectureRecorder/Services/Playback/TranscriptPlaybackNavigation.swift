import Foundation

/// One transcript passage the user can jump to, placed on the T6-B session
/// timeline in exact integer frames. Read-only presentation data: never
/// persisted.
nonisolated struct TranscriptPlaybackItem: Equatable, Sendable, Identifiable {
    /// How precisely `startSessionFrame` locates this passage.
    enum Target: Hashable, Sendable {
        /// A durable Whisper timing segment (`index` into that chunk's
        /// `output.segments`).
        case timedSegment(index: Int)
        /// No usable timing for this chunk: the passage is the whole chunk
        /// text and the target is the chunk's exact first frame.
        case chunkStart
    }

    struct ID: Hashable, Sendable {
        let chunkSequenceNumber: Int
        let target: Target
    }

    let chunkSequenceNumber: Int
    let target: Target
    let text: String
    /// Session-relative frame this passage starts at; always inside its
    /// chunk (`chunk.startFrame..<chunk.endFrame`).
    let startSessionFrame: Int64
    /// Session-relative frame one past this passage (exclusive); never past
    /// its chunk's end.
    let endSessionFrame: Int64

    var id: ID { ID(chunkSequenceNumber: chunkSequenceNumber, target: target) }
}

/// A completed session's transcript as ordered navigation targets: chunk
/// sequence, then segment order within each chunk.
nonisolated struct TranscriptPlaybackNavigation: Equatable, Sendable {
    let sessionID: UUID
    let sampleRate: Double
    let items: [TranscriptPlaybackItem]

    func startTime(of item: TranscriptPlaybackItem) -> Double {
        Double(item.startSessionFrame) / sampleRate
    }
}

/// Builds `TranscriptPlaybackNavigation` from a T6-B timeline and a
/// session's canonical transcript results. Pure: never touches the
/// filesystem.
///
/// Chunk placement comes only from the timeline's exact integer
/// `startFrame`; persisted `startOffsetSeconds` values are never read. A
/// segment's chunk-relative seconds are converted once to frames at the
/// session sample rate (nearest frame, as `LecturePlaybackTimeline` does)
/// and added to that chunk's start frame.
///
/// A chunk's segments are used only when every one of them is ordered,
/// non-overlapping, finite, has start >= 0 and end >= start, and the
/// segments' text concatenates to the saved chunk text. In addition, bounded
/// by the chunk's physical duration (`frameCount / sampleRate`):
/// - a start must address a playable frame of the chunk — below the
///   physical duration and converting to a frame `< frameCount`. A start
///   at or past the chunk end is never clamped;
/// - an end may overshoot the physical duration by at most Whisper's 250 ms
///   allowance, and its frame is clamped to the chunk's exclusive end.
/// If any segment fails — or for historical results with `segments == nil`
/// — the whole chunk becomes one `.chunkStart` item carrying the durable
/// chunk text; good and bad timing are never mixed. No finer timing is ever
/// inferred.
nonisolated enum TranscriptPlaybackNavigationBuilder {
    /// Matches `WhisperProcessTranscriber.validate`'s end-of-audio allowance.
    static let segmentEndToleranceSeconds = 0.25

    /// Returns `nil` when the results do not cover the timeline exactly once
    /// per chunk for this session (the caller then shows no navigation).
    static func build(timeline: LecturePlaybackTimeline, results: [TranscriptResult]) -> TranscriptPlaybackNavigation? {
        var resultsBySequence: [Int: TranscriptResult] = [:]
        for result in results {
            guard result.source.sessionID == timeline.sessionID,
                  resultsBySequence.updateValue(result, forKey: result.source.chunkSequenceNumber) == nil else {
                return nil
            }
        }
        guard resultsBySequence.count == timeline.chunks.count else { return nil }

        var items: [TranscriptPlaybackItem] = []
        for chunk in timeline.chunks {
            guard let result = resultsBySequence[chunk.sequenceNumber],
                  Int64(result.source.frameCount) == chunk.frameCount else {
                return nil
            }
            if let timed = timedItems(chunk: chunk, output: result.output, sampleRate: timeline.sampleRate) {
                items.append(contentsOf: timed)
            } else {
                items.append(TranscriptPlaybackItem(
                    chunkSequenceNumber: chunk.sequenceNumber,
                    target: .chunkStart,
                    text: result.output.text,
                    startSessionFrame: chunk.startFrame,
                    endSessionFrame: chunk.endFrame
                ))
            }
        }
        return TranscriptPlaybackNavigation(sessionID: timeline.sessionID, sampleRate: timeline.sampleRate, items: items)
    }

    /// `nil` when this chunk has no usable timing segments.
    static func timedItems(
        chunk: LecturePlaybackChunk,
        output: TranscriptionEngineOutput,
        sampleRate: Double
    ) -> [TranscriptPlaybackItem]? {
        guard let segments = output.segments, !segments.isEmpty,
              segments.map(\.text).joined() == output.text else {
            return nil
        }

        let physicalDurationSeconds = Double(chunk.frameCount) / sampleRate
        let maximumEndSeconds = physicalDurationSeconds + segmentEndToleranceSeconds
        var priorEndSeconds = 0.0
        var items: [TranscriptPlaybackItem] = []
        items.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            guard segment.startSeconds.isFinite, segment.endSeconds.isFinite,
                  segment.startSeconds >= priorEndSeconds,
                  segment.endSeconds >= segment.startSeconds,
                  segment.startSeconds < physicalDurationSeconds,
                  segment.endSeconds <= maximumEndSeconds else {
                return nil
            }
            priorEndSeconds = segment.endSeconds

            // The start must itself address a playable frame; a start that
            // rounds onto the chunk end is unusable, never clamped. Only the
            // end is clamped, to the chunk's exclusive end.
            let scaledStart = (segment.startSeconds * sampleRate).rounded(.toNearestOrAwayFromZero)
            guard scaledStart < Double(chunk.frameCount) else { return nil }
            let startOffset = Int64(scaledStart)
            let endOffset = max(startOffset, chunkRelativeFrame(forSeconds: segment.endSeconds, sampleRate: sampleRate, limit: chunk.frameCount))
            let start = chunk.startFrame.addingReportingOverflow(startOffset)
            let end = chunk.startFrame.addingReportingOverflow(endOffset)
            guard !start.overflow, !end.overflow else { return nil }

            items.append(TranscriptPlaybackItem(
                chunkSequenceNumber: chunk.sequenceNumber,
                target: .timedSegment(index: index),
                text: segment.text,
                startSessionFrame: start.partialValue,
                endSessionFrame: end.partialValue
            ))
        }
        return items
    }

    /// Nearest frame for nonnegative, finite `seconds`, clamped to `limit`.
    static func chunkRelativeFrame(forSeconds seconds: Double, sampleRate: Double, limit: Int64) -> Int64 {
        let scaled = (seconds * sampleRate).rounded(.toNearestOrAwayFromZero)
        guard scaled < Double(limit) else { return limit }
        return max(Int64(scaled), 0)
    }
}
