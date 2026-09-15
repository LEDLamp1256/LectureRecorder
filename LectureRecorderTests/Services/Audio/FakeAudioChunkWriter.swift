//
//  FakeAudioChunkWriter.swift
//  LectureRecorderTests
//

import AVFoundation
import Synchronization
@testable import LectureRecorder

/// Deterministic, fully test-controlled `AudioChunkWriting` double. Lets
/// SessionManager-level tests drive finalized-chunk events, stream
/// termination, and buffer/finish call observation without depending on
/// real filesystem durability timing. Mirrors the existing
/// `SpyChunkFinalizationFileSystem` synchronization pattern: all mutable
/// state lives behind a `Synchronization.Mutex`.
final class FakeAudioChunkWriter: AudioChunkWriting, @unchecked Sendable {
    let events: AsyncThrowingStream<ChunkEvent, Error>
    private let continuation: AsyncThrowingStream<ChunkEvent, Error>.Continuation

    private struct State {
        var acceptedBuffers: [AVAudioPCMBuffer] = []
        var finishRecordingCallCount = 0
    }
    private let state = Mutex(State())
    private let finishRecordingAutoTerminatesStream: Bool

    /// - Parameter finishRecordingAutoTerminatesStream: when `true`
    ///   (default), `finishRecording()` immediately calls
    ///   `continuation.finish()`, mirroring the real writer's clean-Stop
    ///   behavior. When `false`, `finishRecording()` only records the
    ///   call — a test must terminate the stream explicitly via
    ///   `finishStream()`/`failStream(_:)`, useful for proving ordering
    ///   (e.g. that a final partial-chunk event is consumed before
    ///   termination) with an explicit test-controlled gate instead of a
    ///   race against automatic termination.
    init(finishRecordingAutoTerminatesStream: Bool = true) {
        self.finishRecordingAutoTerminatesStream = finishRecordingAutoTerminatesStream
        var continuation: AsyncThrowingStream<ChunkEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<ChunkEvent, Error>(bufferingPolicy: .unbounded) { cont in
            continuation = cont
        }
        self.continuation = continuation
    }

    var acceptedBuffers: [AVAudioPCMBuffer] {
        state.withLock { $0.acceptedBuffers }
    }

    var acceptBufferCallCount: Int {
        state.withLock { $0.acceptedBuffers.count }
    }

    var finishRecordingCallCount: Int {
        state.withLock { $0.finishRecordingCallCount }
    }

    func acceptBuffer(_ buffer: AVAudioPCMBuffer) {
        state.withLock { $0.acceptedBuffers.append(buffer) }
    }

    func finishRecording() {
        state.withLock { $0.finishRecordingCallCount += 1 }
        if finishRecordingAutoTerminatesStream {
            continuation.finish()
        }
    }

    // MARK: - Test control surface (never used by production code)

    /// Yields one event on the stream, as the real writer would after
    /// durably finalizing a chunk.
    func yield(_ event: ChunkEvent) {
        continuation.yield(event)
    }

    /// Terminates the stream cleanly, as the real writer does once
    /// `finishRecording()` completes with no chunk left open.
    func finishStream() {
        continuation.finish()
    }

    /// Terminates the stream with a failure, as the real writer does on
    /// any unrecoverable write/finalization/durability error.
    func failStream(_ error: Error) {
        continuation.finish(throwing: error)
    }
}

/// Deterministic `AudioChunkWriterFactory` test double. Records every
/// call's arguments and either returns a preconfigured writer or throws a
/// preconfigured error, letting tests prove exact factory-argument
/// wiring and force deterministic writer-construction failures.
final class FakeAudioChunkWriterFactory: AudioChunkWriterFactory, @unchecked Sendable {
    struct RecordedCall {
        let chunksDirectory: URL
        let format: AVAudioFormat
        let targetChunkDurationSeconds: Double
    }

    private struct State {
        var recordedCalls: [RecordedCall] = []
        var writerToReturn: (any AudioChunkWriting)?
        var errorToThrow: Error?
    }
    private let state = Mutex(State())

    func setWriterToReturn(_ writer: any AudioChunkWriting) {
        state.withLock { $0.writerToReturn = writer }
    }

    func setErrorToThrow(_ error: Error?) {
        state.withLock { $0.errorToThrow = error }
    }

    var recordedCalls: [RecordedCall] {
        state.withLock { $0.recordedCalls }
    }

    /// If no writer was explicitly configured via `setWriterToReturn`, a
    /// fresh, working `FakeAudioChunkWriter` is created automatically —
    /// so tests that don't care about writer identity can call
    /// `startSession()` without any setup, exactly like the real factory.
    func makeWriter(
        chunksDirectory: URL,
        format: AVAudioFormat,
        targetChunkDurationSeconds: Double
    ) throws -> any AudioChunkWriting {
        let (error, configuredWriter): (Error?, (any AudioChunkWriting)?) = state.withLock { s in
            s.recordedCalls.append(RecordedCall(
                chunksDirectory: chunksDirectory,
                format: format,
                targetChunkDurationSeconds: targetChunkDurationSeconds
            ))
            return (s.errorToThrow, s.writerToReturn)
        }
        if let error {
            throw error
        }
        return configuredWriter ?? FakeAudioChunkWriter()
    }
}
