//
//  AudioChunkWriterError.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/6/26.
//


import AVFoundation
import Foundation
import OSLog

/// The outcome of a chunk finalization durability failure, distinguishing a
/// structured Stage 1 `ChunkDurabilityFailure` (preserved intact, including
/// its stage and errno information) from any other, unexpected error a
/// `ChunkFinalizationFileSystem` conformer might throw. `ChunkRenameCollision`
/// is deliberately never represented here — it always maps to
/// `AudioChunkWriterError.chunkFileAlreadyExists` instead, never to this type.
nonisolated enum AudioChunkFinalizationFailure: Sendable {
    case durability(ChunkDurabilityFailure)
    case unexpected(String)
}

nonisolated enum AudioChunkWriterError: LocalizedError, Sendable {
    case invalidChunkDuration(Double)
    case unsupportedFormat(String)
    case chunkFileAlreadyExists(sequenceNumber: Int, url: URL)
    case unableToCreateChunkFile(sequenceNumber: Int, url: URL, underlying: String)
    case writeFailed(sequenceNumber: Int, underlying: String)
    case renameFailed(sequenceNumber: Int, from: URL, to: URL, underlying: String)
    case bufferFormatMismatch(expected: String, actual: String)
    /// A chunk's file-sync, atomic rename, or directory-sync durability
    /// operation failed after its `AVAudioFile` was already closed.
    /// `recoveryURL` is the writer's own determination of which artifact is
    /// recoverable — the partial file for a file-sync or rename failure, or
    /// the canonical file for a directory-sync failure (which occurs only
    /// after a successful rename) — and is not simply copied from a
    /// structured `ChunkDurabilityFailure.path`, since that path is the
    /// directory itself for directory-sync failures.
    case chunkFinalizationFailed(sequenceNumber: Int, recoveryURL: URL, failure: AudioChunkFinalizationFailure)

    var errorDescription: String? {
        switch self {
        case .invalidChunkDuration(let seconds):
            return "Invalid target chunk duration (\(seconds)s): must be finite and greater than zero."
        case .unsupportedFormat(let description):
            return "Unsupported audio format for chunk writing: \(description)"
        case .chunkFileAlreadyExists(let seq, let url):
            return "Refusing to overwrite existing file for chunk #\(seq) at \(url.lastPathComponent) — it may contain recoverable audio."
        case .unableToCreateChunkFile(let seq, let url, let underlying):
            return "Unable to create chunk file #\(seq) at \(url.lastPathComponent): \(underlying)"
        case .writeFailed(let seq, let underlying):
            return "Failed writing audio frames to chunk #\(seq): \(underlying)"
        case .renameFailed(let seq, let from, let to, let underlying):
            return "Failed to rename chunk #\(seq) from \(from.lastPathComponent) to \(to.lastPathComponent): \(underlying)"
        case .bufferFormatMismatch(let expected, let actual):
            return "Captured buffer format (\(actual)) does not match the writer's negotiated format (\(expected))"
        case .chunkFinalizationFailed(let seq, let url, let failure):
            switch failure {
            case .durability(let durabilityFailure):
                return "Failed to durably finalize chunk #\(seq) (recoverable at \(url.lastPathComponent)) during \(durabilityFailure.stage.rawValue): \(durabilityFailure.primaryMessage) (errno \(durabilityFailure.primaryErrno))"
            case .unexpected(let description):
                return "Failed to durably finalize chunk #\(seq) (recoverable at \(url.lastPathComponent)): unexpected error — \(description)"
            }
        }
    }

    var sequenceNumber: Int? {
        switch self {
        case .chunkFileAlreadyExists(let seq, _),
             .unableToCreateChunkFile(let seq, _, _),
             .writeFailed(let seq, _),
             .renameFailed(let seq, _, _, _),
             .chunkFinalizationFailed(let seq, _, _):
            return seq
        case .invalidChunkDuration, .unsupportedFormat, .bufferFormatMismatch:
            return nil
        }
    }
}

nonisolated enum ChunkEvent: Sendable {
    case finalized(ChunkMetadata)
}

private struct UnsafeSendableBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// The state of whatever chunk file is currently owned by the writer,
/// replacing a pair of independently-nilable `AVAudioFile?`/`URL?` fields
/// (which could not by themselves distinguish "closed but not yet synced"
/// from "renamed but not yet directory-synced") with an explicit enum that
/// makes those recovery windows — and their correct recovery URL —
/// unambiguous. Mirrors the explicit-state-enum pattern already used by
/// `AudioCaptureService.CycleState`.
private enum InFlightChunk {
    case none
    case writing(file: AVAudioFile, partialURL: URL)
    case finalizingPartial(partialURL: URL)
    case pendingDirectorySync(canonicalURL: URL)
}

nonisolated final class AudioChunkWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lecturerecorder.audiochunkwriter")
    private let chunksDirectory: URL
    private let format: AVAudioFormat
    private let framesPerChunk: Int
    private let chunkFinalizationFileSystem: any ChunkFinalizationFileSystem
    private let continuation: AsyncThrowingStream<ChunkEvent, Error>.Continuation

    let events: AsyncThrowingStream<ChunkEvent, Error>

    private var inFlightChunk: InFlightChunk = .none
    private var currentSequenceNumber = 0
    private var framesInCurrentChunk = 0
    private var cumulativeFramesBeforeCurrentChunk: Int64 = 0
    private var hasFinished = false

    init(
        chunksDirectory: URL,
        format: AVAudioFormat,
        targetChunkDurationSeconds: Double,
        chunkFinalizationFileSystem: any ChunkFinalizationFileSystem
    ) throws {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw AudioChunkWriterError.unsupportedFormat(
                "Expected non-interleaved Float32 PCM, got commonFormat=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)"
            )
        }
        guard targetChunkDurationSeconds.isFinite, targetChunkDurationSeconds > 0 else {
            throw AudioChunkWriterError.invalidChunkDuration(targetChunkDurationSeconds)
        }
        let computedFramesPerChunk = Int((format.sampleRate * targetChunkDurationSeconds).rounded())
        guard computedFramesPerChunk > 0 else {
            throw AudioChunkWriterError.invalidChunkDuration(targetChunkDurationSeconds)
        }

        self.chunksDirectory = chunksDirectory
        self.format = format
        self.framesPerChunk = computedFramesPerChunk
        self.chunkFinalizationFileSystem = chunkFinalizationFileSystem

        var continuation: AsyncThrowingStream<ChunkEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<ChunkEvent, Error>(bufferingPolicy: .unbounded) { cont in
            continuation = cont
        }
        self.continuation = continuation
    }

    func acceptBuffer(_ buffer: AVAudioPCMBuffer) {
        let boxed = UnsafeSendableBuffer(buffer: buffer)
        queue.async { [self] in
            handleBuffer(boxed.buffer)
        }
    }

    func finishRecording() {
        queue.async { [self] in
            guard !hasFinished else { return }
            hasFinished = true
            finalizeOnStop()
        }
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !hasFinished else {
            Log.audio.fault("AudioChunkWriter received a buffer after finishRecording() already ran — the upstream Stop-ordering contract was violated. Dropping buffer.")
            return
        }

        guard
            buffer.format.commonFormat == format.commonFormat,
            buffer.format.isInterleaved == format.isInterleaved,
            buffer.format.sampleRate == format.sampleRate,
            buffer.format.channelCount == format.channelCount
        else {
            fail(with: AudioChunkWriterError.bufferFormatMismatch(
                expected: describeFormat(format),
                actual: describeFormat(buffer.format)
            ))
            return
        }

        guard buffer.frameLength > 0 else { return }

        let segments = ChunkBoundaryPlanner.plan(
            bufferFrameCount: Int(buffer.frameLength),
            framesAlreadyInCurrentChunk: framesInCurrentChunk,
            framesPerChunk: framesPerChunk,
            currentChunkSequenceNumber: currentSequenceNumber
        )

        for segment in segments {
            do {
                try writeSegment(segment, from: buffer)
            } catch {
                fail(with: error)
                return
            }

            framesInCurrentChunk += segment.frameCount

            if segment.completesChunk {
                do {
                    try finalizeCurrentChunk()
                } catch {
                    fail(with: error)
                    return
                }
                currentSequenceNumber += 1
                framesInCurrentChunk = 0
            }
        }
    }

    private func writeSegment(_ segment: ChunkBoundaryPlanner.Segment, from buffer: AVAudioPCMBuffer) throws {
        let file: AVAudioFile
        switch inFlightChunk {
        case .none:
            file = try openNewChunkFile(sequenceNumber: segment.chunkSequenceNumber)
        case .writing(let existingFile, _):
            file = existingFile
        case .finalizingPartial, .pendingDirectorySync:
            throw AudioChunkWriterError.writeFailed(
                sequenceNumber: segment.chunkSequenceNumber,
                underlying: "writeSegment called while a previous chunk was still finalizing — internal inconsistency."
            )
        }

        guard let segmentBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(segment.frameCount)
        ) else {
            throw AudioChunkWriterError.writeFailed(
                sequenceNumber: segment.chunkSequenceNumber,
                underlying: "Unable to allocate a \(segment.frameCount)-frame segment buffer."
            )
        }

        segmentBuffer.frameLength = AVAudioFrameCount(segment.frameCount)

        let channelCount = Int(format.channelCount)
        guard
            let sourceChannels = buffer.floatChannelData,
            let destChannels = segmentBuffer.floatChannelData
        else {
            throw AudioChunkWriterError.writeFailed(
                sequenceNumber: segment.chunkSequenceNumber,
                underlying: "Missing float channel data on source or destination buffer."
            )
        }

        for channel in 0..<channelCount {
            let sourcePointer = sourceChannels[channel].advanced(by: segment.sourceOffset)
            destChannels[channel].update(from: sourcePointer, count: segment.frameCount)
        }

        do {
            try file.write(from: segmentBuffer)
        } catch {
            throw AudioChunkWriterError.writeFailed(
                sequenceNumber: segment.chunkSequenceNumber,
                underlying: error.localizedDescription
            )
        }
    }

    @discardableResult
    private func openNewChunkFile(sequenceNumber: Int) throws -> AVAudioFile {
        let url = partialURL(for: sequenceNumber)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AudioChunkWriterError.chunkFileAlreadyExists(sequenceNumber: sequenceNumber, url: url)
        }

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            inFlightChunk = .writing(file: file, partialURL: url)
            Log.audio.debug("Opened chunk file #\(sequenceNumber, privacy: .public): \(url.lastPathComponent, privacy: .public)")
            return file
        } catch {
            throw AudioChunkWriterError.unableToCreateChunkFile(
                sequenceNumber: sequenceNumber,
                url: url,
                underlying: error.localizedDescription
            )
        }
    }

    /// Finalizes the currently-open chunk through the full durability
    /// sequence: close the `AVAudioFile`, synchronize the completed
    /// `.partial` file to stable storage, atomically (non-replacingly)
    /// rename it to its canonical name, and synchronize the containing
    /// directory so the rename itself survives a crash. `.finalized` is
    /// yielded, and `cumulativeFramesBeforeCurrentChunk`/`inFlightChunk`'s
    /// success state advance, only after all three durability operations —
    /// not just the rename — have returned successfully. Every durability
    /// call happens on this writer's own private serial `queue`, never on
    /// the caller of `acceptBuffer`/`finishRecording` or any real-time
    /// audio callback thread.
    ///
    /// A collision on rename (`ChunkRenameCollision`) is kept distinct from
    /// every other durability failure and maps to the existing
    /// `.chunkFileAlreadyExists` error, carrying the canonical destination
    /// URL — the colliding path, not this writer's recoverable artifact.
    /// Every other failure (a real `ChunkDurabilityFailure`, or any other
    /// unexpected error a `ChunkFinalizationFileSystem` conformer might
    /// throw) maps to `.chunkFinalizationFailed`, carrying this writer's own
    /// determination of the correct recovery URL — the partial file for a
    /// file-sync or non-collision rename failure, or the canonical file for
    /// a directory-sync failure, since that failure occurs only after the
    /// rename already succeeded.
    private func finalizeCurrentChunk() throws {
        guard case .writing(let file, let partialURL) = inFlightChunk else { return }

        let sequenceNumber = currentSequenceNumber
        let frameCount = framesInCurrentChunk

        file.close()
        inFlightChunk = .finalizingPartial(partialURL: partialURL)

        do {
            try chunkFinalizationFileSystem.synchronizeFile(at: partialURL)
        } catch {
            throw mapFinalizationError(error, sequenceNumber: sequenceNumber, recoveryURL: partialURL)
        }

        let canonicalURL = canonicalChunkURL(for: sequenceNumber)

        do {
            try chunkFinalizationFileSystem.rename(from: partialURL, to: canonicalURL)
        } catch let collision as ChunkRenameCollision {
            throw AudioChunkWriterError.chunkFileAlreadyExists(
                sequenceNumber: sequenceNumber,
                url: collision.destination
            )
        } catch {
            throw mapFinalizationError(error, sequenceNumber: sequenceNumber, recoveryURL: partialURL)
        }

        inFlightChunk = .pendingDirectorySync(canonicalURL: canonicalURL)

        do {
            try chunkFinalizationFileSystem.synchronizeDirectory(at: chunksDirectory)
        } catch {
            throw mapFinalizationError(error, sequenceNumber: sequenceNumber, recoveryURL: canonicalURL)
        }

        let metadata = ChunkMetadata(
            sequenceNumber: sequenceNumber,
            fileName: canonicalURL.lastPathComponent,
            startOffsetSeconds: Double(cumulativeFramesBeforeCurrentChunk) / format.sampleRate,
            durationSeconds: Double(frameCount) / format.sampleRate,
            frameCount: frameCount,
            state: .completed
        )

        cumulativeFramesBeforeCurrentChunk += Int64(frameCount)
        inFlightChunk = .none

        Log.audio.info(
            "Finalized chunk #\(sequenceNumber, privacy: .public): \(metadata.fileName, privacy: .public) (\(frameCount, privacy: .public) frames)"
        )
        yield(.finalized(metadata))
    }

    /// Maps any thrown error other than `ChunkRenameCollision` (handled
    /// separately at its own call site) into `.chunkFinalizationFailed`. A
    /// structured Stage 1 `ChunkDurabilityFailure` is preserved intact so
    /// its stage/errno information is never lost; any other, unexpected
    /// error from a `ChunkFinalizationFileSystem` conformer is captured by
    /// description rather than silently dropped or misreported as a
    /// durability failure it did not actually produce.
    private func mapFinalizationError(
        _ error: Error,
        sequenceNumber: Int,
        recoveryURL: URL
    ) -> AudioChunkWriterError {
        let failure: AudioChunkFinalizationFailure
        if let durabilityFailure = error as? ChunkDurabilityFailure {
            failure = .durability(durabilityFailure)
        } else {
            failure = .unexpected(String(describing: error))
        }
        return .chunkFinalizationFailed(
            sequenceNumber: sequenceNumber,
            recoveryURL: recoveryURL,
            failure: failure
        )
    }

    private func finalizeOnStop() {
        guard case .writing = inFlightChunk else {
            continuation.finish()
            return
        }

        do {
            try finalizeCurrentChunk()
            continuation.finish()
        } catch {
            fail(with: error)
        }
    }

    /// Terminates the writer after any failure — a write-time failure while
    /// a chunk is still open, or a finalization-stage failure after its
    /// file was already closed. Recovery logging is driven by
    /// `inFlightChunk` rather than a `currentFile != nil` check, so it
    /// remains correct (and never silent) across every recovery window:
    /// mid-write (file still open, must be closed exactly once here),
    /// mid-finalization before rename succeeds (file already closed;
    /// partial file is the recoverable artifact), and after a successful
    /// rename but before directory sync completes (canonical file is the
    /// recoverable artifact; its directory-entry durability is unconfirmed,
    /// not lost).
    private func fail(with error: Error) {
        Log.audio.error("AudioChunkWriter failing: \(error.localizedDescription, privacy: .public)")
        hasFinished = true

        switch inFlightChunk {
        case .none:
            break
        case .writing(let file, let partialURL):
            file.close()
            Log.audio.error(
                "Preserving interrupted partial chunk for recovery: \(partialURL.lastPathComponent, privacy: .public)"
            )
        case .finalizingPartial(let partialURL):
            Log.audio.error(
                "Preserving interrupted partial chunk for recovery: \(partialURL.lastPathComponent, privacy: .public)"
            )
        case .pendingDirectorySync(let canonicalURL):
            Log.audio.error(
                "Chunk was renamed to its canonical name but directory synchronization did not complete — its directory-entry durability across an unclean shutdown is unconfirmed. Preserving for recovery: \(canonicalURL.lastPathComponent, privacy: .public)"
            )
        }

        inFlightChunk = .none
        continuation.finish(throwing: error)
    }

    private func yield(_ event: ChunkEvent) {
        switch continuation.yield(event) {
        case .enqueued:
            break
        case .dropped:
            Log.audio.fault("AudioChunkWriter dropped a ChunkEvent — should be impossible with unbounded buffering.")
        case .terminated:
            Log.audio.fault("AudioChunkWriter tried to yield a ChunkEvent after its stream had already terminated.")
        @unknown default:
            Log.audio.fault("AudioChunkWriter got an unrecognized YieldResult when yielding a ChunkEvent.")
        }
    }

    private func partialURL(for sequenceNumber: Int) -> URL {
        chunksDirectory.appendingPathComponent(chunkFileName(for: sequenceNumber, partial: true))
    }

    private func canonicalChunkURL(for sequenceNumber: Int) -> URL {
        chunksDirectory.appendingPathComponent(chunkFileName(for: sequenceNumber, partial: false))
    }

    private func chunkFileName(for sequenceNumber: Int, partial: Bool) -> String {
        let padded = String(format: "%06d", sequenceNumber)
        return partial ? "chunk_\(padded).partial.caf" : "chunk_\(padded).caf"
    }

    private func describeFormat(_ format: AVAudioFormat) -> String {
        let formatName: String
        switch format.commonFormat {
        case .pcmFormatFloat32: formatName = "Float32"
        case .pcmFormatFloat64: formatName = "Float64"
        case .pcmFormatInt16: formatName = "Int16"
        case .pcmFormatInt32: formatName = "Int32"
        case .otherFormat: formatName = "Other"
        @unknown default: formatName = "Unknown"
        }

        let interleavedDescription = format.isInterleaved ? "interleaved" : "nonInterleaved"
        return "\(formatName)/\(interleavedDescription)/\(format.sampleRate)Hz/\(format.channelCount)ch"
    }
}
