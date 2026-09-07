//
//  AudioChunkWriterTests.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/6/26.
//


import AVFoundation
import XCTest
@testable import LectureRecorder

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
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001)
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
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001)
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
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001)
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
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001)
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
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: stereoFormat, targetChunkDurationSeconds: 0.001)

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
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0)
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
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0)
        writer.finishRecording()

        let events = try await collectEvents(writer.events)
        XCTAssertTrue(events.isEmpty)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testNoStrayPartialFilesRemainAfterNormalFinalization() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001)
        writer.acceptBuffer(makeBuffer(frameCount: 20, startValue: 0))
        writer.finishRecording()
        _ = try await collectEvents(writer.events)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertTrue(contents.allSatisfy { !$0.contains("partial") }, "No .partial.caf files should remain: \(contents)")
        XCTAssertEqual(Set(contents), Set(["chunk_000000.caf", "chunk_000001.caf", "chunk_000002.caf"]))
    }

    func testTotalInputFramesEqualsTotalFinalizedFrameCount() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001)
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

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0)
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
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0)
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

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001)
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

        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 0.001)
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
                try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: duration)
            ) { error in
                guard case AudioChunkWriterError.invalidChunkDuration = error else {
                    return XCTFail("Expected invalidChunkDuration for \(duration), got \(error)")
                }
            }
        }
    }

    func testInt16BufferFailsWithFormatMismatch() async throws {
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0)
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
        let writer = try AudioChunkWriter(chunksDirectory: tempDirectory, format: format, targetChunkDurationSeconds: 1.0)
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
}