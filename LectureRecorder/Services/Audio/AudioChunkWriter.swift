//
//  AudioChunkWriterError.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/6/26.
//


import AVFoundation
import Foundation
import OSLog

nonisolated enum AudioChunkWriterError: LocalizedError, Sendable {
    case invalidChunkDuration(Double)
    case unsupportedFormat(String)
    case chunkFileAlreadyExists(sequenceNumber: Int, url: URL)
    case unableToCreateChunkFile(sequenceNumber: Int, url: URL, underlying: String)
    case writeFailed(sequenceNumber: Int, underlying: String)
    case renameFailed(sequenceNumber: Int, from: URL, to: URL, underlying: String)
    case bufferFormatMismatch(expected: String, actual: String)

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
        }
    }

    var sequenceNumber: Int? {
        switch self {
        case .chunkFileAlreadyExists(let seq, _),
             .unableToCreateChunkFile(let seq, _, _),
             .writeFailed(let seq, _),
             .renameFailed(let seq, _, _, _):
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

nonisolated final class AudioChunkWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lecturerecorder.audiochunkwriter")
    private let chunksDirectory: URL
    private let format: AVAudioFormat
    private let framesPerChunk: Int
    private let continuation: AsyncThrowingStream<ChunkEvent, Error>.Continuation

    let events: AsyncThrowingStream<ChunkEvent, Error>

    private var currentFile: AVAudioFile?
    private var currentPartialURL: URL?
    private var currentSequenceNumber = 0
    private var framesInCurrentChunk = 0
    private var cumulativeFramesBeforeCurrentChunk: Int64 = 0
    private var hasFinished = false

    init(
        chunksDirectory: URL,
        format: AVAudioFormat,
        targetChunkDurationSeconds: Double
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
        if currentFile == nil {
            try openNewChunkFile(sequenceNumber: segment.chunkSequenceNumber)
        }

        guard let file = currentFile else {
            throw AudioChunkWriterError.writeFailed(
                sequenceNumber: segment.chunkSequenceNumber,
                underlying: "No open file after openNewChunkFile succeeded — internal inconsistency."
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

    private func openNewChunkFile(sequenceNumber: Int) throws {
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
            currentFile = file
            currentPartialURL = url
            Log.audio.debug("Opened chunk file #\(sequenceNumber, privacy: .public): \(url.lastPathComponent, privacy: .public)")
        } catch {
            throw AudioChunkWriterError.unableToCreateChunkFile(
                sequenceNumber: sequenceNumber,
                url: url,
                underlying: error.localizedDescription
            )
        }
    }

    private func finalizeCurrentChunk() throws {
        guard let file = currentFile, let partialURL = currentPartialURL else { return }

        let sequenceNumber = currentSequenceNumber
        let frameCount = framesInCurrentChunk

        file.close()
        currentFile = nil

        let canonicalURL = canonicalChunkURL(for: sequenceNumber)
        guard !FileManager.default.fileExists(atPath: canonicalURL.path) else {
            throw AudioChunkWriterError.chunkFileAlreadyExists(
                sequenceNumber: sequenceNumber,
                url: canonicalURL
            )
        }

        do {
            try FileManager.default.moveItem(at: partialURL, to: canonicalURL)
        } catch {
            throw AudioChunkWriterError.renameFailed(
                sequenceNumber: sequenceNumber,
                from: partialURL,
                to: canonicalURL,
                underlying: error.localizedDescription
            )
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
        currentPartialURL = nil

        Log.audio.info(
            "Finalized chunk #\(sequenceNumber, privacy: .public): \(metadata.fileName, privacy: .public) (\(frameCount, privacy: .public) frames)"
        )
        yield(.finalized(metadata))
    }

    private func finalizeOnStop() {
        guard currentFile != nil else {
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

    private func fail(with error: Error) {
        Log.audio.error("AudioChunkWriter failing: \(error.localizedDescription, privacy: .public)")
        hasFinished = true

        if currentFile != nil {
            currentFile?.close()
            Log.audio.error(
                "Preserving interrupted partial chunk for recovery: \(self.currentPartialURL?.lastPathComponent ?? "unknown", privacy: .public)"
            )
        }

        currentFile = nil
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
