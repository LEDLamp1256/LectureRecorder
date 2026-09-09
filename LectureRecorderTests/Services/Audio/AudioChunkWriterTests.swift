//
//  AudioChunkWriterTests.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/6/26.
//


import AVFoundation
import XCTest
@testable import LectureRecorder

/// Mirrors production's own `UnsafeSendableBuffer` boxing pattern
/// (`AudioChunkWriter.swift`) so an `AVAudioPCMBuffer` — not itself
/// `Sendable` — can be handed into a `Task.detached` closure for the
/// nonblocking-submission test below, without weakening any Sendable
/// checking anywhere else.
private struct TestUnsafeSendableBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

final class AudioChunkWriterTests: XCTestCase {
    private var tempDirectory: URL!
    private var format: AVAudioFormat!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioChunkWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeBuffer(frameCount: Int, startValue: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channel = buffer.floatChannelData![0]
        for i in 0..<frameCount {
            channel[i] = startValue + Float(i)
        }
        return buffer
    }

    private func readSamples(at url: URL) throws -> [Float] {
        try readChannels(at: url, channelCount: 1)[0]
    }

    private func readChannels(at url: URL, channelCount: Int) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let readFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.fileFormat.sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        return (0..<channelCount).map { channel in
            (0..<Int(buffer.frameLength)).map { data[channel][$0] }
        }
    }

    private func collectEvents(_ stream: AsyncThrowingStream<ChunkEvent, Error>) async throws -> [ChunkEvent] {
        var events: [ChunkEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    /// Unlike `collectEvents`, never discards what was actually observed:
    /// if the stream throws, the events already yielded before the throw
    /// are still returned alongside the terminal error, instead of being
    /// lost inside a re-thrown call. `error` is `nil` only if the stream
    /// finished with no error at all. This is what a failure test must use
    /// to assert "zero `.finalized` events preceded the terminal error" —
    /// catching a thrown error alone does not prove that on its own, since
    /// an `AsyncThrowingStream` may yield any number of events before it
    /// throws.
    private func collectEventsUntilTermination(
        _ stream: AsyncThrowingStream<ChunkEvent, Error>
    ) async -> (events: [ChunkEvent], error: Error?) {
        var events: [ChunkEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func writeStandaloneFile(at url: URL, frameCount: Int, startValue: Float) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try file.write(from: makeBuffer(frameCount: frameCount, startValue: startValue))
        file.close()
    }

    /// `XCTAssertEqual` has no built-in overload for comparing two
    /// `[Float]` arrays with a floating-point `accuracy:` tolerance —
    /// only scalar `Float`/`Double` pairs. This does that: count first
    /// (a length mismatch is a distinct, clearer failure than an
    /// out-of-bounds crash), then element-by-element, forwarding
    /// `file`/`line` so a failure is reported at the calling test's line
    /// rather than inside this helper.
    private func assertFloatArraysEqual(
        _ lhs: [Float],
        _ rhs: [Float],
        accuracy: Float,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.count, rhs.count, "Array counts differ. \(message)", file: file, line: line)
        for (index, pair) in zip(lhs, rhs).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "Mismatch at index \(index). \(message)", file: file, line: line)
        }
    }

    // MARK: - Boundary / rotation

    func testExactBoundaryProducesOneFinalizedChunkWithCorrectMetadata() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        XCTAssertEqual(events.count, 1)
        guard case .finalized(let metadata) = events[0] else { return XCTFail("Expected .finalized event") }

        XCTAssertEqual(metadata.sequenceNumber, 0)
        XCTAssertEqual(metadata.fileName, "chunk_000000.caf")
        XCTAssertEqual(metadata.state, .completed)
        XCTAssertEqual(metadata.frameCount, 8)
        XCTAssertEqual(metadata.startOffsetSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(metadata.durationSeconds, 0.001, accuracy: 0.0001)

        let finalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(try readSamples(at: finalURL), (0..<8).map { Float($0) })
    }

    func testBoundaryCrossingSplitsIntoTwoChunks() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 12, startValue: 0))
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        XCTAssertEqual(events.count, 2)
        guard case .finalized(let first) = events[0], case .finalized(let second) = events[1] else {
            return XCTFail("Expected two .finalized events")
        }

        XCTAssertEqual(first.sequenceNumber, 0)
        XCTAssertEqual(first.frameCount, 8)
        XCTAssertEqual(second.sequenceNumber, 1)
        XCTAssertEqual(second.frameCount, 4)
        XCTAssertEqual(second.startOffsetSeconds, 0.001, accuracy: 0.0001)

        XCTAssertEqual(try readSamples(at: tempDirectory.appendingPathComponent("chunk_000000.caf")), (0..<8).map { Float($0) })
        XCTAssertEqual(try readSamples(at: tempDirectory.appendingPathComponent("chunk_000001.caf")), (8..<12).map { Float($0) })
    }

    func testMultipleBoundariesInASingleBufferProduceMultipleChunks() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 20, startValue: 0))
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        let metadatas = events.compactMap { event -> ChunkMetadata? in
            if case .finalized(let m) = event { return m }
            return nil
        }
        XCTAssertEqual(metadatas.map(\.sequenceNumber), [0, 1, 2])
        XCTAssertEqual(metadatas.map(\.frameCount), [8, 8, 4])

        XCTAssertEqual(try readSamples(at: tempDirectory.appendingPathComponent("chunk_000000.caf")), (0..<8).map { Float($0) })
        XCTAssertEqual(try readSamples(at: tempDirectory.appendingPathComponent("chunk_000001.caf")), (8..<16).map { Float($0) })
        XCTAssertEqual(try readSamples(at: tempDirectory.appendingPathComponent("chunk_000002.caf")), (16..<20).map { Float($0) })
    }

    func testFramesAccumulateAcrossSeparateBufferCallsNotJustWithinOne() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 3, startValue: 0))
        writer.acceptBuffer(makeBuffer(frameCount: 3, startValue: 3))
        writer.acceptBuffer(makeBuffer(frameCount: 3, startValue: 6))
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        let metadatas = events.compactMap { event -> ChunkMetadata? in
            if case .finalized(let m) = event { return m }
            return nil
        }
        XCTAssertEqual(metadatas.map(\.frameCount), [8, 1])

        XCTAssertEqual(try readSamples(at: tempDirectory.appendingPathComponent("chunk_000000.caf")), (0..<8).map { Float($0) })
        XCTAssertEqual(try readSamples(at: tempDirectory.appendingPathComponent("chunk_000001.caf")), [Float(8)])
    }

    // MARK: - Multi-channel

    /// Proves the writer preserves native channel count and per-channel
    /// data ordering — required by the Phase 2A "no forced mono
    /// down-mixing" contract. Left and right channels carry distinct,
    /// ordinary signal-range values (roughly -1...1, as real PCM audio
    /// would) so any channel-swap or interleaving bug would show up as a
    /// mismatched read-back.
    func testStereoNonInterleavedBufferPreservesChannelDataAcrossBoundary() async throws {
        let stereoFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 2, interleaved: false)
        )
        // Same 8-frame-per-chunk math as the mono tests (8000 Hz * 0.001s).
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: stereoFormat, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 12))
        buffer.frameLength = 12
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let leftValues = (0..<12).map { Float($0) * 0.05 }         // 0.00 ... 0.55
        let rightValues = (0..<12).map { -0.1 - Float($0) * 0.03 } // -0.10 ... -0.43
        for i in 0..<12 {
            channels[0][i] = leftValues[i]
            channels[1][i] = rightValues[i]
        }

        writer.acceptBuffer(buffer)
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        XCTAssertEqual(events.count, 2)
        guard case .finalized(let first) = events[0], case .finalized(let second) = events[1] else {
            return XCTFail("Expected two .finalized events")
        }
        XCTAssertEqual(first.frameCount, 8)
        XCTAssertEqual(second.frameCount, 4)

        let firstChannels = try readChannels(at: tempDirectory.appendingPathComponent("chunk_000000.caf"), channelCount: 2)
        let secondChannels = try readChannels(at: tempDirectory.appendingPathComponent("chunk_000001.caf"), channelCount: 2)

        assertFloatArraysEqual(firstChannels[0], Array(leftValues[0..<8]), accuracy: 0.0001, "Left channel, chunk 0")
        assertFloatArraysEqual(firstChannels[1], Array(rightValues[0..<8]), accuracy: 0.0001, "Right channel, chunk 0")
        assertFloatArraysEqual(secondChannels[0], Array(leftValues[8..<12]), accuracy: 0.0001, "Left channel, chunk 1")
        assertFloatArraysEqual(secondChannels[1], Array(rightValues[8..<12]), accuracy: 0.0001, "Right channel, chunk 1")
    }

    // MARK: - Stop behavior

    func testFinalPartialChunkIsPreservedOnFinishRecording() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 100, startValue: 0))
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        XCTAssertEqual(events.count, 1)
        guard case .finalized(let metadata) = events[0] else { return XCTFail("Expected .finalized event") }
        XCTAssertEqual(metadata.sequenceNumber, 0)
        XCTAssertEqual(metadata.frameCount, 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("chunk_000000.caf").path))
    }

    func testStopWithNoAudioProducesNoEventsAndNoFiles() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        XCTAssertTrue(events.isEmpty)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testNoStrayPartialFilesRemainAfterNormalFinalization() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 20, startValue: 0))
        writer.finishRecording()
        _ = try await collectEvents(writer.events)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertTrue(contents.allSatisfy { !$0.contains("partial") }, "No .partial.caf files should remain: \(contents)")
        XCTAssertEqual(Set(contents), Set(["chunk_000000.caf", "chunk_000001.caf", "chunk_000002.caf"]))
    }

    func testTotalInputFramesEqualsTotalFinalizedFrameCount() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        let frameCounts = [5, 8, 1, 13, 8, 2]
        var cursor: Float = 0
        for count in frameCounts {
            writer.acceptBuffer(makeBuffer(frameCount: count, startValue: cursor))
            cursor += Float(count)
        }
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        let totalFinalizedFrames = events.reduce(0) { sum, event -> Int in
            guard case .finalized(let m) = event else { return sum }
            return sum + m.frameCount
        }
        XCTAssertEqual(totalFinalizedFrames, frameCounts.reduce(0, +))
    }

    // MARK: - Failure propagation

    func testWriteFailureThrowsFromEventsStream() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDirectory.path)
        }

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 10, startValue: 0))
        writer.finishRecording()

        do {
            _ = try await collectEvents(writer.events)
            XCTFail("Expected the events stream to throw")
        } catch let error as AudioChunkWriterError {
            XCTAssertEqual(error.sequenceNumber, 0)
        }
    }

    /// Proves `fail(with:)`'s explicit `close()` call actually leaves
    /// something recoverable: writes good frames into an active partial
    /// chunk, then triggers a failure mid-chunk (before it ever
    /// finalizes/renames), and confirms the `.partial.caf` file is
    /// still openable and contains exactly the frames written before
    /// the failure — not truncated, not corrupted, not deleted.
    func testFailureClosesPartialFileButPreservesRecoverableAudio() async throws {
        // framesPerChunk = 8000 (1.0s @ 8000Hz), so 50 good frames stays
        // well within chunk 0 — it never finalizes/renames on its own.
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 50, startValue: 0))

        let mismatchedFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: false)
        )
        let badBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mismatchedFormat, frameCapacity: 10))
        badBuffer.frameLength = 10
        writer.acceptBuffer(badBuffer)

        do {
            _ = try await collectEvents(writer.events)
            XCTFail("Expected a format mismatch error")
        } catch let error as AudioChunkWriterError {
            guard case .bufferFormatMismatch = error else {
                return XCTFail("Expected bufferFormatMismatch, got \(error)")
            }
        }

        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertEqual(
            try readSamples(at: partialURL),
            (0..<50).map { Float($0) },
            "The 50 good frames written before the failure must still be intact and readable"
        )
    }

    func testExistingCanonicalChunkCollisionLeavesOriginalFileUntouched() async throws {
        let canonicalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")
        try writeStandaloneFile(at: canonicalURL, frameCount: 4, startValue: 999)
        let originalSamples = try readSamples(at: canonicalURL)

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()

        do {
            _ = try await collectEvents(writer.events)
            XCTFail("Expected the events stream to throw a collision error")
        } catch let error as AudioChunkWriterError {
            guard case .chunkFileAlreadyExists(let seq, let url) = error else {
                return XCTFail("Expected chunkFileAlreadyExists, got \(error)")
            }
            XCTAssertEqual(seq, 0)
            XCTAssertEqual(url, canonicalURL)
        }

        XCTAssertEqual(try readSamples(at: canonicalURL), originalSamples)

        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertEqual(try readSamples(at: partialURL), (0..<8).map { Float($0) })
    }

    func testExistingPartialChunkCollisionLeavesOriginalFileUntouched() async throws {
        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        try writeStandaloneFile(at: partialURL, frameCount: 3, startValue: 777)
        let originalSamples = try readSamples(at: partialURL)

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 4, startValue: 0))
        writer.finishRecording()

        do {
            _ = try await collectEvents(writer.events)
            XCTFail("Expected the events stream to throw a collision error")
        } catch let error as AudioChunkWriterError {
            guard case .chunkFileAlreadyExists(let seq, let url) = error else {
                return XCTFail("Expected chunkFileAlreadyExists, got \(error)")
            }
            XCTAssertEqual(seq, 0)
            XCTAssertEqual(url, partialURL)
        }

        XCTAssertEqual(try readSamples(at: partialURL), originalSamples)
    }

    // MARK: - Input validation

    func testInitThrowsForInvalidChunkDurations() {
        let invalidDurations: [Double] = [0.0, -1.0, .nan, .infinity, -.infinity]
        for duration in invalidDurations {
            XCTAssertThrowsError(
                try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: duration, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
            ) { error in
                guard case AudioChunkWriterError.invalidChunkDuration = error else {
                    return XCTFail("Expected invalidChunkDuration for \(duration), got \(error)")
                }
            }
        }
    }

    func testInt16BufferFailsWithFormatMismatch() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        let int16Format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: false)
        )
        let mismatchedBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: 10))
        mismatchedBuffer.frameLength = 10

        writer.acceptBuffer(mismatchedBuffer)
        writer.finishRecording()

        do {
            _ = try await collectEvents(writer.events)
            XCTFail("Expected a format mismatch error")
        } catch let error as AudioChunkWriterError {
            guard case .bufferFormatMismatch = error else {
                return XCTFail("Expected bufferFormatMismatch, got \(error)")
            }
        }
    }

    func testInterleavedBufferFailsWithFormatMismatch() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        let interleavedFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: true)
        )
        let mismatchedBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: interleavedFormat, frameCapacity: 10))
        mismatchedBuffer.frameLength = 10

        writer.acceptBuffer(mismatchedBuffer)
        writer.finishRecording()

        do {
            _ = try await collectEvents(writer.events)
            XCTFail("Expected a format mismatch error")
        } catch let error as AudioChunkWriterError {
            guard case .bufferFormatMismatch = error else {
                return XCTFail("Expected bufferFormatMismatch, got \(error)")
            }
        }
    }

    // MARK: - Stage 2: finalization durability call order

    func testFinalizationCallsOccurInExactOrderOnBoundaryCompletion() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()
        _ = try await collectEvents(writer.events)

        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        let canonicalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")
        XCTAssertEqual(spy.recordedCalls, [
            .synchronizeFile(partialURL),
            .rename(from: partialURL, to: canonicalURL),
            .synchronizeDirectory(tempDirectory)
        ])
    }

    func testFinalizationCallsOccurInExactOrderOnStopTriggeredFinalChunk() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 50, startValue: 0))
        writer.finishRecording()
        _ = try await collectEvents(writer.events)

        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        let canonicalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")
        XCTAssertEqual(spy.recordedCalls, [
            .synchronizeFile(partialURL),
            .rename(from: partialURL, to: canonicalURL),
            .synchronizeDirectory(tempDirectory)
        ])
    }

    func testFinalizationCallsHappenExactlyOncePerChunkAcrossMultipleChunks() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 20, startValue: 0)) // three chunks: 8, 8, 4 frames
        writer.finishRecording()
        _ = try await collectEvents(writer.events)

        let expected: [SpyChunkFinalizationFileSystem.Call] = (0..<3).flatMap { sequenceNumber -> [SpyChunkFinalizationFileSystem.Call] in
            let padded = String(format: "%06d", sequenceNumber)
            let partialURL = tempDirectory.appendingPathComponent("chunk_\(padded).partial.caf")
            let canonicalURL = tempDirectory.appendingPathComponent("chunk_\(padded).caf")
            return [
                .synchronizeFile(partialURL),
                .rename(from: partialURL, to: canonicalURL),
                .synchronizeDirectory(tempDirectory)
            ]
        }
        XCTAssertEqual(spy.recordedCalls, expected, "All three durability calls must happen exactly once per chunk, in order, with no batching or skipping across chunks")
    }

    // MARK: - Stage 2: failure stages

    func testFileSyncFailurePreservesPartialAndSkipsRenameAndDirectorySync() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        spy.setSynchronizeFileError(ChunkDurabilityFailure(
            stage: .partialFileSync,
            path: partialURL,
            primaryErrno: EIO,
            primaryMessage: "Simulated synchronizeFile failure",
            secondaryCloseErrno: nil,
            secondaryCloseMessage: nil
        ))

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()

        let result = await collectEventsUntilTermination(writer.events)
        XCTAssertTrue(result.events.isEmpty, "No .finalized event should have been observed before the file-sync failure")
        guard let thrown = result.error else {
            return XCTFail("Expected the stream to terminate with an error")
        }
        guard let error = thrown as? AudioChunkWriterError else {
            return XCTFail("Expected AudioChunkWriterError, got \(thrown)")
        }
        guard case .chunkFinalizationFailed(let seq, let recoveryURL, let failure) = error else {
            return XCTFail("Expected chunkFinalizationFailed, got \(error)")
        }
        XCTAssertEqual(seq, 0)
        XCTAssertEqual(recoveryURL, partialURL)
        guard case .durability(let durabilityFailure) = failure else {
            return XCTFail("Expected .durability, got \(failure)")
        }
        XCTAssertEqual(durabilityFailure.stage, .partialFileSync)

        XCTAssertTrue(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertEqual(try readSamples(at: partialURL), (0..<8).map { Float($0) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("chunk_000000.caf").path))
        XCTAssertEqual(spy.recordedCalls, [.synchronizeFile(partialURL)])
    }

    func testRenameCollisionSkipsDirectorySyncAndPreservesArtifacts() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let canonicalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")
        try writeStandaloneFile(at: canonicalURL, frameCount: 4, startValue: 999)
        let originalSamples = try readSamples(at: canonicalURL)

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()

        let result = await collectEventsUntilTermination(writer.events)
        XCTAssertTrue(result.events.isEmpty, "No .finalized event should have been observed before the collision error")
        guard let thrown = result.error else {
            return XCTFail("Expected the stream to terminate with a collision error")
        }
        guard let error = thrown as? AudioChunkWriterError else {
            return XCTFail("Expected AudioChunkWriterError, got \(thrown)")
        }
        guard case .chunkFileAlreadyExists(let seq, let url) = error else {
            return XCTFail("Expected chunkFileAlreadyExists, got \(error)")
        }
        XCTAssertEqual(seq, 0)
        XCTAssertEqual(url, canonicalURL, "The collision error carries the canonical destination — the colliding path, not this writer's recovery artifact")

        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        XCTAssertEqual(try readSamples(at: canonicalURL), originalSamples, "Pre-existing canonical file must survive untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialURL.path), "Partial source must be preserved as the recovery artifact")
        XCTAssertEqual(try readSamples(at: partialURL), (0..<8).map { Float($0) })
        XCTAssertEqual(
            spy.recordedCalls,
            [.synchronizeFile(partialURL), .rename(from: partialURL, to: canonicalURL)],
            "synchronizeDirectory must never be called after a rename collision"
        )
    }

    func testGenericRenameFailurePreservesPartialAndSkipsDirectorySync() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        let canonicalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")
        spy.setRenameError(ChunkDurabilityFailure(
            stage: .rename,
            path: canonicalURL,
            primaryErrno: EIO,
            primaryMessage: "Simulated rename failure",
            secondaryCloseErrno: nil,
            secondaryCloseMessage: nil
        ))

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()

        let result = await collectEventsUntilTermination(writer.events)
        XCTAssertTrue(result.events.isEmpty, "No .finalized event should have been observed before the rename failure")
        guard let thrown = result.error else {
            return XCTFail("Expected the stream to terminate with an error")
        }
        guard let error = thrown as? AudioChunkWriterError else {
            return XCTFail("Expected AudioChunkWriterError, got \(thrown)")
        }
        guard case .chunkFinalizationFailed(let seq, let recoveryURL, let failure) = error else {
            return XCTFail("Expected chunkFinalizationFailed, got \(error)")
        }
        XCTAssertEqual(seq, 0)
        XCTAssertEqual(recoveryURL, partialURL)
        guard case .durability(let durabilityFailure) = failure else {
            return XCTFail("Expected .durability, got \(failure)")
        }
        XCTAssertEqual(durabilityFailure.stage, .rename)

        XCTAssertTrue(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertEqual(spy.recordedCalls, [.synchronizeFile(partialURL), .rename(from: partialURL, to: canonicalURL)])
    }

    func testDirectorySyncFailureAfterRealRenameLeavesCanonicalVisibleWithNoFinalizedEvent() async throws {
        // spy wraps a real DarwinChunkFinalizationFileSystem by default, so
        // the rename this test relies on is a genuine filesystem rename.
        let spy = SpyChunkFinalizationFileSystem()
        spy.setSynchronizeDirectoryError(ChunkDurabilityFailure(
            stage: .directorySync,
            path: tempDirectory,
            primaryErrno: EIO,
            primaryMessage: "Simulated directory sync failure",
            secondaryCloseErrno: nil,
            secondaryCloseMessage: nil
        ))

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()

        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        let canonicalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")

        // Catching a thrown AudioChunkWriterError alone would NOT be proof
        // that no .finalized event preceded it — an AsyncThrowingStream may
        // yield any number of events before it throws. collectEventsUntilTermination
        // explicitly returns whatever events were actually observed
        // alongside the terminal error, and the empty-events assertion
        // below is the real proof, not the catch itself.
        let result = await collectEventsUntilTermination(writer.events)
        XCTAssertTrue(result.events.isEmpty, "No .finalized event should have been observed before the directory-sync failure")
        guard let thrown = result.error else {
            return XCTFail("Expected the stream to terminate with an error")
        }
        guard let error = thrown as? AudioChunkWriterError else {
            return XCTFail("Expected AudioChunkWriterError, got \(thrown)")
        }
        guard case .chunkFinalizationFailed(let seq, let recoveryURL, let failure) = error else {
            return XCTFail("Expected chunkFinalizationFailed, got \(error)")
        }
        XCTAssertEqual(seq, 0)
        XCTAssertEqual(recoveryURL, canonicalURL, "Recovery URL must be the canonical file — the partial file no longer exists after a successful rename")
        guard case .durability(let durabilityFailure) = failure else {
            return XCTFail("Expected .durability, got \(failure)")
        }
        XCTAssertEqual(durabilityFailure.stage, .directorySync)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path), "Partial file no longer exists — it was already renamed away")
        // This proves the canonical file is presently visible with its
        // content already durable (synchronizeFile succeeded before the
        // real rename). It does NOT and cannot prove the renamed directory
        // entry itself would survive an unclean shutdown — no automated
        // test can prove that.
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path), "Canonical file is presently visible after a real, successful rename")
        XCTAssertEqual(try readSamples(at: canonicalURL), (0..<8).map { Float($0) })
        XCTAssertEqual(spy.recordedCalls, [
            .synchronizeFile(partialURL),
            .rename(from: partialURL, to: canonicalURL),
            .synchronizeDirectory(tempDirectory)
        ])
    }

    func testUnexpectedProtocolErrorMapsToUnexpectedFailure() async throws {
        struct UnexpectedStubError: Error {}
        let spy = SpyChunkFinalizationFileSystem()
        spy.setSynchronizeFileError(UnexpectedStubError())

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()

        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")

        let result = await collectEventsUntilTermination(writer.events)
        XCTAssertTrue(result.events.isEmpty, "No .finalized event should have been observed before the unexpected-error failure")
        guard let thrown = result.error else {
            return XCTFail("Expected the stream to terminate with an error")
        }
        guard let error = thrown as? AudioChunkWriterError else {
            return XCTFail("Expected AudioChunkWriterError, got \(thrown)")
        }
        guard case .chunkFinalizationFailed(let seq, let recoveryURL, let failure) = error else {
            return XCTFail("Expected chunkFinalizationFailed, got \(error)")
        }
        XCTAssertEqual(seq, 0)
        XCTAssertEqual(recoveryURL, partialURL)
        guard case .unexpected(let description) = failure else {
            return XCTFail("An unexpected non-collision error must never become a collision or be silently dropped; expected .unexpected, got \(failure)")
        }
        XCTAssertFalse(description.isEmpty)
    }

    // MARK: - Stage 2: terminal behavior

    func testTerminalFailureProducesExactlyOneStreamErrorAndNoFurtherOutputFromQueuedOrNewBuffers() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        spy.setSynchronizeFileError(ChunkDurabilityFailure(
            stage: .partialFileSync,
            path: partialURL,
            primaryErrno: EIO,
            primaryMessage: "Simulated synchronizeFile failure",
            secondaryCloseErrno: nil,
            secondaryCloseMessage: nil
        ))

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)

        // The failing chunk, plus buffers already queued immediately behind
        // it before any processing has had a chance to run — FIFO submission
        // order (not a race) is what keeps these from producing output.
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 100))
        writer.finishRecording()

        var terminalErrorCount = 0
        var finalizedCount = 0
        do {
            for try await event in writer.events {
                if case .finalized = event { finalizedCount += 1 }
            }
        } catch {
            terminalErrorCount += 1
        }
        XCTAssertEqual(terminalErrorCount, 1)
        XCTAssertEqual(finalizedCount, 0)

        // A buffer submitted well after the stream has already terminated.
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 200))

        // Best-effort settle window: acceptBuffer only enqueues work on the
        // writer's own private queue, which this test has no direct handle
        // to drain, and no test-only access was added to expose one. A
        // bounded wait is the most rigorous negative-proof available
        // without weakening that boundary.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(spy.recordedCalls, [.synchronizeFile(partialURL)], "No further durability calls from queued or newly submitted buffers after termination")
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertEqual(Set(contents), Set(["chunk_000000.partial.caf"]), "No new files from queued or newly submitted buffers after termination")
    }

    // MARK: - Stage 2: finishRecording behavior

    func testEmptyFinishRecordingPerformsZeroDurabilityCalls() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0, chunkFinalizationFileSystem: spy)
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(spy.recordedCalls.isEmpty)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testRepeatedFinishRecordingIsIdempotent() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        XCTAssertEqual(events.count, 1)

        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        let canonicalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")
        XCTAssertEqual(
            spy.recordedCalls,
            [.synchronizeFile(partialURL), .rename(from: partialURL, to: canonicalURL), .synchronizeDirectory(tempDirectory)],
            "A second finishRecording() call must not trigger a second finalization sequence"
        )
    }

    // MARK: - Stage 2: nonblocking submission / queuing during finalization

    func testAcceptBufferReturnsWhileSynchronizeFileIsBlocked() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        spy.armSynchronizeFileGate()
        defer { spy.releaseSynchronizeFileGate() } // safety net if an assertion fails before the explicit release below

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0)) // completes chunk 0, blocks inside synchronizeFile

        let entered = spy.waitForSynchronizeFileEntry(timeout: .now() + 5)
        XCTAssertEqual(entered, .success, "synchronizeFile should have been entered")

        let probe = TestUnsafeSendableBuffer(buffer: makeBuffer(frameCount: 4, startValue: 100))
        let acceptReturned = expectation(description: "acceptBuffer returned")
        Task.detached {
            writer.acceptBuffer(probe.buffer)
            acceptReturned.fulfill()
        }
        // The deterministic proof is ordering, not elapsed time: this
        // expectation is fulfilled — meaning acceptBuffer already returned —
        // while the durability gate is still unreleased below. If
        // acceptBuffer were actually blocking on the writer's busy queue,
        // this await would hang until the timeout rather than resolve, since
        // nothing else releases the gate before the next line runs. The
        // timeout is a liveness/deadlock ceiling, not a performance bound.
        await fulfillment(of: [acceptReturned], timeout: 2.0)

        spy.releaseSynchronizeFileGate()
        writer.finishRecording()
        _ = try await collectEvents(writer.events)
    }

    /// Proves writer-internal queuing behavior only: a buffer submitted
    /// while a previous chunk's finalization is blocked is processed
    /// correctly once that finalization completes. This is not proof of
    /// the full `AudioCaptureService.deepCopy()` -> `AudioChunkWriter`
    /// buffer-ownership contract — that chain is not wired into production
    /// yet (SessionManager Stage C) and its end-to-end verification belongs
    /// to that later stage.
    func testQueuedBufferAfterBlockedFinalizationIsProcessedCorrectlyOnceReleased() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        spy.armSynchronizeFileGate()
        defer { spy.releaseSynchronizeFileGate() }

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0)) // completes chunk 0, blocks inside synchronizeFile

        let entered = spy.waitForSynchronizeFileEntry(timeout: .now() + 5)
        XCTAssertEqual(entered, .success)

        // Submitted while chunk 0's finalization is still blocked.
        writer.acceptBuffer(makeBuffer(frameCount: 4, startValue: 8))
        writer.finishRecording()

        spy.releaseSynchronizeFileGate()

        let events = try await collectEvents(writer.events)
        let metadatas = events.compactMap { event -> ChunkMetadata? in
            if case .finalized(let m) = event { return m }
            return nil
        }
        XCTAssertEqual(metadatas.map(\.sequenceNumber), [0, 1])
        XCTAssertEqual(metadatas.map(\.frameCount), [8, 4])

        XCTAssertEqual(try readSamples(at: tempDirectory.appendingPathComponent("chunk_000000.caf")), (0..<8).map { Float($0) })
        XCTAssertEqual(try readSamples(at: tempDirectory.appendingPathComponent("chunk_000001.caf")), (8..<12).map { Float($0) })
    }

    // MARK: - Stage 2: real integration and success visibility

    func testRealAVAudioFileWithRealDarwinChunkFinalizationFileSystemSucceeds() async throws {
        // Exercises the real Darwin adapter (not a spy) against a file this
        // writer's real AVAudioFile actually wrote and closed — closing the
        // residual gap that Stage 1's own tests only ever exercised
        // Data.write(to:)-produced files, never an AVAudioFile-produced one.
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: DarwinChunkFinalizationFileSystem())
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        XCTAssertEqual(events.count, 1)
        guard case .finalized(let metadata) = events[0] else { return XCTFail("Expected .finalized event") }
        XCTAssertEqual(metadata.state, .completed)

        let canonicalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertEqual(try readSamples(at: canonicalURL), (0..<8).map { Float($0) })
    }

    func testFinalizedEventIsNotObservedBeforeDirectorySyncCompletes() async throws {
        let spy = SpyChunkFinalizationFileSystem()
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001, chunkFinalizationFileSystem: spy)
        writer.acceptBuffer(makeBuffer(frameCount: 8, startValue: 0))
        writer.finishRecording()

        let partialURL = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        let canonicalURL = tempDirectory.appendingPathComponent("chunk_000000.caf")
        let expectedCallsBeforeFinalized: [SpyChunkFinalizationFileSystem.Call] = [
            .synchronizeFile(partialURL),
            .rename(from: partialURL, to: canonicalURL),
            .synchronizeDirectory(tempDirectory)
        ]

        var sawFinalized = false
        for try await event in writer.events {
            if case .finalized = event {
                sawFinalized = true
                XCTAssertEqual(
                    spy.recordedCalls,
                    expectedCallsBeforeFinalized,
                    "The .finalized event must not be observable until synchronizeFile, rename, and synchronizeDirectory have all already completed"
                )
            }
        }
        XCTAssertTrue(sawFinalized)
    }
}