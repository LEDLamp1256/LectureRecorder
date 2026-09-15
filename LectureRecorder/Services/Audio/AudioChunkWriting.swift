//
//  AudioChunkWriting.swift
//  LectureRecorder
//

import AVFoundation

/// The narrow surface `SessionManager` needs from a per-session chunk
/// writer: submit captured buffers, signal the end of the recording
/// cycle, and observe finalized-chunk events. Deliberately excludes every
/// durability internal (`ChunkFinalizationFileSystem`, on-disk file
/// layout, etc.) — those remain entirely behind `AudioChunkWriter` and
/// are never visible through this seam. Exists so tests can inject a
/// fully controlled writer double without depending on real filesystem
/// durability timing.
protocol AudioChunkWriting: Sendable {
    /// Finalized-chunk events for this writer's single recording cycle.
    /// Terminates via `.finish()` on clean completion, or
    /// `.finish(throwing:)` on any unrecoverable writer failure.
    var events: AsyncThrowingStream<ChunkEvent, Error> { get }

    /// Submits a captured buffer for chunking. Never blocks the caller —
    /// safe to call from a realtime audio callback.
    func acceptBuffer(_ buffer: AVAudioPCMBuffer)

    /// Signals the end of this recording cycle. Finalizes any
    /// in-progress partial chunk and terminates `events`. Idempotent:
    /// only the first call has an effect.
    func finishRecording()
}
