//
//  ChunkBoundaryPlanner.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/5/26.
//


/// Pure, nonisolated logic for splitting an incoming audio buffer across
/// chunk boundaries defined by a fixed frame count per chunk.
///
/// This has zero dependencies on AVFoundation, actors, or file I/O — it's
/// only integer arithmetic. That's deliberate: boundary-crossing math is
/// where off-by-one errors cause dropped or duplicated audio, so it's
/// isolated here where it can be tested exhaustively without touching
/// real hardware or files.
nonisolated enum ChunkBoundaryPlanner {
    /// One contiguous slice of an input buffer that belongs to a single
    /// chunk, plus whether writing it completes that chunk.
    struct Segment: Equatable, Sendable {
        /// Offset into the *input buffer* (not the chunk) where this
        /// segment starts.
        let sourceOffset: Int
        /// Number of frames in this segment.
        let frameCount: Int
        /// The chunk sequence number this segment belongs to.
        let chunkSequenceNumber: Int
        /// True if writing `frameCount` frames completes
        /// `chunkSequenceNumber` — i.e. that chunk has now reached
        /// `framesPerChunk` total frames and should be finalized.
        let completesChunk: Bool
    }

    /// Splits `bufferFrameCount` incoming frames into one or more
    /// `Segment`s.
    ///
    /// - Parameters:
    ///   - bufferFrameCount: frames in the incoming buffer. Must be
    ///     non-negative.
    ///   - framesAlreadyInCurrentChunk: frames the active chunk has
    ///     already accumulated before this buffer arrives. Must be
    ///     `< framesPerChunk` — the caller is responsible for rotating a
    ///     chunk the instant it completes, before more frames arrive.
    ///   - framesPerChunk: target frame count per chunk (e.g. 1,440,000
    ///     for 30s @ 48kHz).
    ///   - currentChunkSequenceNumber: sequence number of the chunk
    ///     currently active. Must be non-negative.
    /// - Returns: an ordered list of segments, empty only if
    ///   `bufferFrameCount == 0`. The sum of `frameCount` across all
    ///   returned segments always equals `bufferFrameCount` exactly.
    static func plan(
        bufferFrameCount: Int,
        framesAlreadyInCurrentChunk: Int,
        framesPerChunk: Int,
        currentChunkSequenceNumber: Int
    ) -> [Segment] {
        precondition(framesPerChunk > 0, "framesPerChunk must be positive")
        precondition(bufferFrameCount >= 0, "bufferFrameCount must be non-negative")
        precondition(framesAlreadyInCurrentChunk >= 0, "framesAlreadyInCurrentChunk must be non-negative")
        precondition(
            framesAlreadyInCurrentChunk < framesPerChunk,
            "framesAlreadyInCurrentChunk must be less than framesPerChunk — a full chunk must be rotated before more frames arrive"
        )
        precondition(currentChunkSequenceNumber >= 0, "currentChunkSequenceNumber must be non-negative")

        guard bufferFrameCount > 0 else { return [] }

        var segments: [Segment] = []
        var sourceOffset = 0
        var remaining = bufferFrameCount
        var framesInChunk = framesAlreadyInCurrentChunk
        var sequenceNumber = currentChunkSequenceNumber

        while remaining > 0 {
            let spaceLeftInChunk = framesPerChunk - framesInChunk
            let take = min(remaining, spaceLeftInChunk)
            let completes = take == spaceLeftInChunk

            segments.append(
                Segment(
                    sourceOffset: sourceOffset,
                    frameCount: take,
                    chunkSequenceNumber: sequenceNumber,
                    completesChunk: completes
                )
            )

            sourceOffset += take
            remaining -= take

            if completes {
                sequenceNumber += 1
                framesInChunk = 0
            } else {
                framesInChunk += take
            }
        }

        return segments
    }
}