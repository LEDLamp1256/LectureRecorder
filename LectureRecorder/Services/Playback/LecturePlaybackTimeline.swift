import Foundation

/// Every reason a manifest cannot form a playback timeline, checked in the
/// order `LecturePlaybackTimeline.init(manifest:)` lists.
nonisolated enum LecturePlaybackTimelineError: LocalizedError, Sendable, Equatable {
    case invalidSampleRate
    case noChunks
    case nonContiguousChunkSequence
    case nonCanonicalChunkFileName(sequenceNumber: Int)
    case nonCompletedChunk(sequenceNumber: Int)
    case nonPositiveChunkFrameCount(sequenceNumber: Int)
    case frameCountOverflow

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            return "The session's audio sample rate is not a finite, positive value."
        case .noChunks:
            return "The session has no recorded audio chunks to play."
        case .nonContiguousChunkSequence:
            return "The session's chunk sequence numbers are not a contiguous, duplicate-free range starting at 0."
        case .nonCanonicalChunkFileName(let sequenceNumber):
            return "Chunk #\(sequenceNumber) has a non-canonical file name."
        case .nonCompletedChunk(let sequenceNumber):
            return "Chunk #\(sequenceNumber) is not marked completed."
        case .nonPositiveChunkFrameCount(let sequenceNumber):
            return "Chunk #\(sequenceNumber) has no audio frames."
        case .frameCountOverflow:
            return "The session's total frame count overflows."
        }
    }
}

/// One physical chunk's place on the logical session timeline. Frame
/// values are exact integers derived only from persisted
/// `ChunkMetadata.frameCount`.
nonisolated struct LecturePlaybackChunk: Equatable, Sendable {
    let sequenceNumber: Int
    /// Canonical `chunk_%06d.caf` name within the session's chunks directory.
    let fileName: String
    /// Session-relative frame of this chunk's first frame.
    let startFrame: Int64
    let frameCount: Int64

    /// Session-relative frame one past this chunk's last frame (exclusive).
    /// Cannot overflow: the timeline proved the checked running sum.
    var endFrame: Int64 { startFrame + frameCount }
}

/// Where one session-relative frame lives physically.
nonisolated enum LecturePlaybackLocation: Equatable, Sendable {
    /// A playable frame: `frameOffset` frames into `chunks[chunkIndex]`.
    case chunk(chunkIndex: Int, frameOffset: Int64)
    /// Exactly the session's total frame count — the logical end, which
    /// addresses no audio.
    case end
}

/// One completed session's audio as a single logical, frame-exact
/// timeline over its durable ~30-second chunks.
///
/// The authority is persisted integer `ChunkMetadata.frameCount` and the
/// session's `audioFormat.sampleRate`. Floating-point
/// `startOffsetSeconds`/`durationSeconds` are never summed or used to
/// place a chunk. Seconds are converted to frames once (nearest frame) and
/// every topology decision is made in integers, so a chunk boundary can
/// never be misattributed by floating-point drift.
///
/// Pure value: never touches the filesystem.
nonisolated struct LecturePlaybackTimeline: Equatable, Sendable {
    let sessionID: UUID
    let sampleRate: Double
    /// Index `i` holds sequence number `i`.
    let chunks: [LecturePlaybackChunk]
    let totalFrameCount: Int64

    var durationSeconds: Double { Double(totalFrameCount) / sampleRate }

    /// Builds the timeline, rejecting (in order): a non-finite or
    /// nonpositive sample rate; no chunks; a sequence that is not exactly
    /// `0..<count`; a non-canonical file name; a chunk not `.completed`; a
    /// nonpositive frame count; a total that overflows `Int64`.
    init(manifest: SessionManifest) throws {
        let sampleRate = manifest.audioFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw LecturePlaybackTimelineError.invalidSampleRate
        }
        guard !manifest.chunks.isEmpty else {
            throw LecturePlaybackTimelineError.noChunks
        }

        let ordered = manifest.chunks.sorted { $0.sequenceNumber < $1.sequenceNumber }
        guard ordered.map(\.sequenceNumber) == Array(0..<ordered.count) else {
            throw LecturePlaybackTimelineError.nonContiguousChunkSequence
        }

        var chunks: [LecturePlaybackChunk] = []
        chunks.reserveCapacity(ordered.count)
        var runningFrame: Int64 = 0
        for chunk in ordered {
            guard chunk.fileName == TranscriptionArtifactPaths.canonicalChunkFileName(for: chunk.sequenceNumber) else {
                throw LecturePlaybackTimelineError.nonCanonicalChunkFileName(sequenceNumber: chunk.sequenceNumber)
            }
            guard chunk.state == .completed else {
                throw LecturePlaybackTimelineError.nonCompletedChunk(sequenceNumber: chunk.sequenceNumber)
            }
            guard chunk.frameCount > 0 else {
                throw LecturePlaybackTimelineError.nonPositiveChunkFrameCount(sequenceNumber: chunk.sequenceNumber)
            }
            let frameCount = Int64(chunk.frameCount)
            let next = runningFrame.addingReportingOverflow(frameCount)
            guard !next.overflow else {
                throw LecturePlaybackTimelineError.frameCountOverflow
            }
            chunks.append(LecturePlaybackChunk(
                sequenceNumber: chunk.sequenceNumber,
                fileName: chunk.fileName,
                startFrame: runningFrame,
                frameCount: frameCount
            ))
            runningFrame = next.partialValue
        }

        self.sessionID = manifest.sessionID
        self.sampleRate = sampleRate
        self.chunks = chunks
        self.totalFrameCount = runningFrame
    }

    /// Converts session-relative seconds to a session frame, rounding to
    /// the nearest frame so a boundary offset derived as
    /// `Double(frames) / sampleRate` maps back to exactly `frames`.
    ///
    /// Clamps: negative seconds → 0; seconds at or beyond the end →
    /// `totalFrameCount` (the logical end). Rejects (returns `nil`) only a
    /// non-finite value, which names no position at all.
    func sessionFrame(forSessionTime seconds: Double) -> Int64? {
        guard seconds.isFinite else { return nil }
        guard seconds > 0 else { return 0 }
        let scaled = (seconds * sampleRate).rounded(.toNearestOrAwayFromZero)
        guard scaled < Double(totalFrameCount) else { return totalFrameCount }
        return Int64(scaled)
    }

    func sessionTime(forSessionFrame frame: Int64) -> Double {
        Double(frame) / sampleRate
    }

    /// Maps a session frame to its physical location. A frame on a chunk
    /// boundary belongs to the chunk that starts there. `totalFrameCount`
    /// is `.end`. Anything outside `0...totalFrameCount` is `nil` — never
    /// wrapped or clamped here; callers clamp explicitly.
    func location(forSessionFrame frame: Int64) -> LecturePlaybackLocation? {
        guard frame >= 0, frame <= totalFrameCount else { return nil }
        guard frame < totalFrameCount else { return .end }

        // Last chunk whose startFrame <= frame.
        var low = 0
        var high = chunks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if chunks[mid].startFrame <= frame {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return .chunk(chunkIndex: low, frameOffset: frame - chunks[low].startFrame)
    }
}
