//
//  AudioChunkWriterFactory.swift
//  LectureRecorder
//

import AVFoundation

/// Constructs the per-session `AudioChunkWriting` instance `SessionManager`
/// uses for one recording cycle. Exists as a protocol so tests can inject
/// a controlled fake writer instead of the real, filesystem-backed
/// `AudioChunkWriter`. Deliberately does not accept a
/// `ChunkFinalizationFileSystem` parameter: that durability seam stays an
/// implementation detail of the production factory below, never exposed
/// through this SessionManager-facing contract.
protocol AudioChunkWriterFactory: Sendable {
    func makeWriter(
        chunksDirectory: URL,
        format: AVAudioFormat,
        targetChunkDurationSeconds: Double
    ) throws -> any AudioChunkWriting
}

/// Production factory: builds a real, `DarwinChunkFinalizationFileSystem`-
/// backed `AudioChunkWriter`.
struct DefaultAudioChunkWriterFactory: AudioChunkWriterFactory {
    func makeWriter(
        chunksDirectory: URL,
        format: AVAudioFormat,
        targetChunkDurationSeconds: Double
    ) throws -> any AudioChunkWriting {
        try AudioChunkWriter(
            chunksDirectory: chunksDirectory,
            format: format,
            targetChunkDurationSeconds: targetChunkDurationSeconds,
            chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem()
        )
    }
}
