import AVFoundation
import XCTest
@testable import LectureRecorder

final class DiarizationAudioStagerTests: XCTestCase {
    private typealias F = DiarizationTestFixtures

    /// Records every decode call; tests only.
    private final class DecodeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(url: URL, metadata: WhisperAudioSourceMetadata)] = []
        var calls: [(url: URL, metadata: WhisperAudioSourceMetadata)] { lock.withLock { stored } }
        func append(_ url: URL, _ metadata: WhisperAudioSourceMetadata) { lock.withLock { stored.append((url, metadata)) } }
    }

    /// Independent reference for the expected 16 kHz position of a source
    /// frame (nearest, halves up), computed with quotient and remainder.
    private static func expectedDestination(_ frame: Int64, rate: Int64) -> Int {
        let numerator = frame * 16_000
        let quotient = numerator / rate
        let remainder = numerator % rate
        return Int(remainder * 2 >= rate ? quotient + 1 : quotient)
    }

    private func expectedDestination(_ frame: Int64, rate: Int64) -> Int {
        Self.expectedDestination(frame, rate: rate)
    }

    /// A decoder that fills each chunk with `sequenceNumber + 1` and returns
    /// `expectedLength + lengthDelta(sequenceNumber)` samples.
    private func fillingDecoder(
        source: LecturePlaybackSource,
        log: DecodeLog = DecodeLog(),
        lengthDelta: @escaping @Sendable (Int) -> Int = { _ in 0 }
    ) -> DiarizationAudioStager.ChunkDecoder {
        let rate = Int64(source.timeline.sampleRate)
        let byURL = Dictionary(uniqueKeysWithValues: zip(source.chunkURLs, source.timeline.chunks))
        return { url, metadata in
            log.append(url, metadata)
            guard let chunk = byURL[url] else { throw CocoaError(.fileNoSuchFile) }
            let expected = Self.expectedDestination(chunk.endFrame, rate: rate) - Self.expectedDestination(chunk.startFrame, rate: rate)
            return Array(repeating: Float(chunk.sequenceNumber + 1), count: max(0, expected + lengthDelta(chunk.sequenceNumber)))
        }
    }

    private func assertChunkPlacement(
        _ staged: StagedDiarizationAudio,
        source: LecturePlaybackSource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rate = Int64(source.timeline.sampleRate)
        XCTAssertEqual(staged.samples.count, expectedDestination(source.timeline.totalFrameCount, rate: rate), file: file, line: line)
        for chunk in source.timeline.chunks {
            let start = expectedDestination(chunk.startFrame, rate: rate)
            let end = expectedDestination(chunk.endFrame, rate: rate)
            XCTAssertTrue(
                staged.samples[start..<end].allSatisfy { $0 == Float(chunk.sequenceNumber + 1) },
                "chunk \(chunk.sequenceNumber) at rate \(rate) is not exactly [\(start), \(end))",
                file: file, line: line
            )
        }
    }

    private func source(_ manifest: SessionManifest, root: String = "/nonexistent", channelCount: UInt32 = 1) throws -> LecturePlaybackSource {
        let timeline = try LecturePlaybackTimeline(manifest: manifest)
        return LecturePlaybackSource(
            timeline: timeline,
            chunkURLs: timeline.chunks.map { URL(fileURLWithPath: "\(root)/\(manifest.sessionID.uuidString)/chunks/\($0.fileName)") },
            channelCount: channelCount
        )
    }

    // MARK: - Frame mapping

    func testDestinationFrameIsNearestSixteenKilohertzFrameWithHalvesUp() throws {
        let cases: [(frame: Int64, rate: Int64, expected: Int)] = [
            (0, 44_100, 0),
            (0, 48_000, 0),
            (1, 16_000, 1),
            (12_345, 16_000, 12_345),
            (1, 48_000, 0), (2, 48_000, 1), (3, 48_000, 1), (48_000, 48_000, 16_000),
            (1, 44_100, 0), (2, 44_100, 1), (11_025, 44_100, 4_000), (1_323_000, 44_100, 480_000),
            (1_323_001, 44_100, 480_000),
            // Exact halves round up.
            (1, 32_000, 1), (3, 32_000, 2), (5, 32_000, 3),
            // ~90 minutes at 48 kHz.
            (259_200_000, 48_000, 86_400_000),
        ]
        for (frame, rate, expected) in cases {
            XCTAssertEqual(try DiarizationAudioStager.destinationFrame(forSessionFrame: frame, sourceSampleRate: rate), expected, "\(frame) @ \(rate)")
            XCTAssertEqual(expected, expectedDestination(frame, rate: rate), "reference disagrees for \(frame) @ \(rate)")
        }
    }

    func testDestinationFrameOverflowFailsExplicitly() {
        XCTAssertThrowsError(try DiarizationAudioStager.destinationFrame(forSessionFrame: .max, sourceSampleRate: 44_100)) {
            XCTAssertEqual($0 as? DiarizationAudioStagingError, .timelineTooLong)
        }
    }

    func testOnlyWholeNumberSampleRatesAreAccepted() throws {
        XCTAssertEqual(try DiarizationAudioStager.integralSampleRate(44_100), 44_100)
        XCTAssertEqual(try DiarizationAudioStager.integralSampleRate(48_000), 48_000)
        for rate in [44_100.5, 0, -16_000, .nan, .infinity, 0.5] {
            XCTAssertThrowsError(try DiarizationAudioStager.integralSampleRate(rate), "\(rate)") {
                XCTAssertEqual($0 as? DiarizationAudioStagingError, .unsupportedSampleRate)
            }
        }
    }

    // MARK: - Placement

    func testEachChunkOccupiesExactlyItsFrameDerivedIntervalAtSeveralSampleRates() throws {
        for rate in [16_000.0, 22_050, 32_000, 44_100, 48_000] {
            // Uneven chunks (an odd frame each) and a short final chunk.
            let frames = Int(rate)
            let source = try F.source(sampleRate: rate, frameCounts: [frames + 1, frames - 1, frames / 7 + 3])
            let staged = try DiarizationAudioStager(decodeChunk: fillingDecoder(source: source)).stage(source)
            assertChunkPlacement(staged, source: source)
            XCTAssertEqual(staged.durationSeconds, source.timeline.durationSeconds, accuracy: 1.0 / 32_000, "\(rate)")
        }
    }

    func testLaterChunkPlacementIgnoresEarlierDecodedLengthRounding() throws {
        let source = try F.source(sampleRate: 44_100, frameCounts: [44_101, 44_099, 22_051])
        // Chunk 0 decodes 3 short (padded with silence), chunk 1 three long
        // (trimmed); both within the reconciliation tolerance.
        let stager = DiarizationAudioStager(decodeChunk: fillingDecoder(source: source) { $0 == 0 ? -3 : ($0 == 1 ? 3 : 0) })
        let staged = try stager.stage(source)

        let chunk0End = expectedDestination(44_101, rate: 44_100)
        let chunk1Start = chunk0End
        let chunk2Start = expectedDestination(44_101 + 44_099, rate: 44_100)
        XCTAssertEqual(Array(staged.samples[(chunk0End - 3)..<chunk0End]), [0, 0, 0], "a short decode is padded, not shifted")
        XCTAssertEqual(staged.samples[chunk0End - 4], 1)
        XCTAssertEqual(staged.samples[chunk1Start], 2, "chunk 1 starts at its own frame-derived position")
        XCTAssertEqual(staged.samples[chunk2Start - 1], 2)
        XCTAssertEqual(staged.samples[chunk2Start], 3, "chunk 1's overrun is trimmed, never shifting chunk 2")
        XCTAssertEqual(staged.samples.count, expectedDestination(44_101 + 44_099 + 22_051, rate: 44_100))
    }

    func testManyChunksAccumulateNoDriftWhenEveryDecodeRoundsDown() throws {
        // 1,103 frames at 44.1 kHz is 400.18... output samples. A decoder
        // that always emits the floor (400) would drift ~181 samples by the
        // last chunk if placement summed emitted lengths.
        let count = 1_000
        let source = try F.source(sampleRate: 44_100, frameCounts: Array(repeating: 1_103, count: count))
        let byURL = Dictionary(uniqueKeysWithValues: zip(source.chunkURLs, source.timeline.chunks))
        let staged = try DiarizationAudioStager(decodeChunk: { url, _ in
            Array(repeating: Float(byURL[url]?.sequenceNumber ?? -1), count: 400)
        }).stage(source)

        let last = source.timeline.chunks[count - 1]
        let lastStart = expectedDestination(last.startFrame, rate: 44_100)
        XCTAssertEqual(lastStart, 399_781)
        XCTAssertNotEqual(lastStart, 400 * (count - 1), "the drifting placement would be here")
        XCTAssertEqual(staged.samples[lastStart], Float(count - 1))
        XCTAssertNotEqual(staged.samples[lastStart - 1], Float(count - 1))
        XCTAssertEqual(staged.samples.count, expectedDestination(1_103 * Int64(count), rate: 44_100))
    }

    func testStartOffsetAndDurationSecondsAreNotPlacementAuthority() throws {
        let sessionID = UUID()
        let frameCounts = [48_001, 47_999, 4_801]
        let honest = PlaybackTestManifest.make(sessionID: sessionID, sampleRate: 48_000, frameCounts: frameCounts)
        var skewed = honest
        for index in skewed.chunks.indices {
            skewed.chunks[index].startOffsetSeconds += 7.3 * Double(index + 1)
            skewed.chunks[index].durationSeconds *= 1.5
        }
        let honestSource = try source(honest)
        let skewedSource = try source(skewed)
        let skewedLog = DecodeLog()
        let honestAudio = try DiarizationAudioStager(decodeChunk: fillingDecoder(source: honestSource)).stage(honestSource)
        let skewedAudio = try DiarizationAudioStager(decodeChunk: fillingDecoder(source: skewedSource, log: skewedLog)).stage(skewedSource)
        XCTAssertEqual(skewedAudio, honestAudio)
        XCTAssertEqual(skewedLog.calls.map(\.metadata.durationSeconds), frameCounts.map { Double($0) / 48_000 },
                       "decoder metadata derives from frame counts, not persisted seconds")
    }

    // MARK: - Eligible sources

    func testTerminalStatusDoesNotAffectStaging() throws {
        let sessionID = UUID()
        var outputs: [SessionStatus: StagedDiarizationAudio] = [:]
        for (status, endReason) in [(SessionStatus.completed, SessionEndReason.userStopped), (.interrupted, .appTerminated), (.failed, .error)] {
            var manifest = PlaybackTestManifest.make(sessionID: sessionID, sampleRate: 44_100, frameCounts: [44_101, 2_205])
            manifest.status = status
            manifest.endReason = endReason
            manifest.endedCleanly = status == .completed
            let source = try source(manifest)
            outputs[status] = try DiarizationAudioStager(decodeChunk: fillingDecoder(source: source)).stage(source)
        }
        XCTAssertEqual(outputs.count, 3, "no terminal status is rejected")
        XCTAssertEqual(outputs[.interrupted], outputs[.completed])
        XCTAssertEqual(outputs[.failed], outputs[.completed])
    }

    func testRecordedAndImportedShapedSourcesStageIdentically() throws {
        // Import writes an ordinary completed manifest whose fields other
        // than the chunk frame timeline (dates, end state) can differ from a
        // live recording's, and whose chunks live under another root until
        // publication.
        let sessionID = UUID()
        let recorded = PlaybackTestManifest.make(sessionID: sessionID, sampleRate: 48_000, frameCounts: [48_000, 24_000])
        var imported = recorded
        imported.creationDate = Date(timeIntervalSince1970: 5_000)
        imported.endDate = Date(timeIntervalSince1970: 5_001)
        imported.endedCleanly = true
        let recordedSource = try source(recorded, root: "/Sessions")
        let importedSource = try source(imported, root: "/ImportStaging")
        XCTAssertEqual(
            try DiarizationAudioStager(decodeChunk: fillingDecoder(source: recordedSource)).stage(recordedSource),
            try DiarizationAudioStager(decodeChunk: fillingDecoder(source: importedSource)).stage(importedSource)
        )
    }

    // MARK: - Decoder contract

    func testDecoderReceivesTimelineMetadataInSourceOrder() throws {
        let source = try F.source(sampleRate: 44_100, channelCount: 2, frameCounts: [44_100, 1_000, 22_050])
        let log = DecodeLog()
        _ = try DiarizationAudioStager(decodeChunk: fillingDecoder(source: source, log: log)).stage(source)
        XCTAssertEqual(log.calls.map(\.url), source.chunkURLs)
        XCTAssertEqual(log.calls.map(\.metadata), source.timeline.chunks.map {
            WhisperAudioSourceMetadata(
                frameCount: Int($0.frameCount),
                durationSeconds: Double($0.frameCount) / 44_100,
                sampleRate: 44_100,
                channelCount: 2,
                bitsPerChannel: 32,
                formatIdentifier: "lpcm-float32"
            )
        })
    }

    func testDecoderFailureNamesTheChunkAndStopsStaging() throws {
        let source = try F.source(sampleRate: 16_000, frameCounts: [16_000, 16_000, 16_000])
        let log = DecodeLog()
        let fill = fillingDecoder(source: source, log: log)
        let failingURL = source.chunkURLs[1]
        let stager = DiarizationAudioStager(decodeChunk: { url, metadata in
            let samples = try fill(url, metadata)
            if url == failingURL { throw WhisperAudioDecodeError.metadataMismatch }
            return samples
        })
        XCTAssertThrowsError(try stager.stage(source)) {
            XCTAssertEqual($0 as? DiarizationAudioStagingError, .chunkDecodeFailed(sequenceNumber: 1))
        }
        XCTAssertEqual(log.calls.map(\.url), Array(source.chunkURLs.prefix(2)), "chunk 2 is never decoded")
    }

    func testDecodedLengthBeyondToleranceFailsInsteadOfShiftingTheTimeline() throws {
        let source = try F.source(sampleRate: 48_000, frameCounts: [48_000, 48_000])
        let tolerance = DiarizationAudioStager.maximumBoundaryReconciliationSamples
        for delta in [tolerance + 1, -(tolerance + 1)] {
            let stager = DiarizationAudioStager(decodeChunk: fillingDecoder(source: source) { $0 == 1 ? delta : 0 })
            XCTAssertThrowsError(try stager.stage(source), "\(delta)") {
                XCTAssertEqual($0 as? DiarizationAudioStagingError,
                               .chunkLengthMismatch(sequenceNumber: 1, expected: 16_000, actual: 16_000 + delta))
            }
        }
        for delta in [tolerance, -tolerance] {
            let staged = try DiarizationAudioStager(decodeChunk: fillingDecoder(source: source) { $0 == 1 ? delta : 0 }).stage(source)
            XCTAssertEqual(staged.samples.count, 32_000, "\(delta) is reconciled")
            XCTAssertEqual(staged.samples[16_000], 2, "chunk 1 still starts at its frame-derived position")
        }
    }

    func testMismatchedChunkURLCountFails() throws {
        let valid = try F.source(sampleRate: 16_000, frameCounts: [16_000, 16_000])
        let source = LecturePlaybackSource(timeline: valid.timeline, chunkURLs: Array(valid.chunkURLs.dropLast()), channelCount: 1)
        let log = DecodeLog()
        XCTAssertThrowsError(try DiarizationAudioStager(decodeChunk: fillingDecoder(source: valid, log: log)).stage(source)) {
            XCTAssertEqual($0 as? DiarizationAudioStagingError, .chunkURLCountMismatch)
        }
        XCTAssertTrue(log.calls.isEmpty)
    }

    func testNonIntegralSampleRateFailsBeforeDecoding() throws {
        let source = try F.source(sampleRate: 44_100.5, frameCounts: [44_100])
        let log = DecodeLog()
        XCTAssertThrowsError(try DiarizationAudioStager(decodeChunk: fillingDecoder(source: source, log: log)).stage(source)) {
            XCTAssertEqual($0 as? DiarizationAudioStagingError, .unsupportedSampleRate)
        }
        XCTAssertTrue(log.calls.isEmpty)
    }

    // MARK: - Cancellation

    func testCancellationBetweenChunksStopsFurtherDecoding() async throws {
        let source = try F.source(sampleRate: 16_000, frameCounts: [16_000, 16_000, 16_000])
        let log = DecodeLog()
        let fill = fillingDecoder(source: source, log: log)
        let stager = DiarizationAudioStager(decodeChunk: { url, metadata in
            let samples = try fill(url, metadata)
            // Cancel the staging task while chunk 0 is decoding.
            withUnsafeCurrentTask { $0?.cancel() }
            return samples
        })
        let result = await Task.detached { try stager.stage(source) }.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(log.calls.map(\.url), [source.chunkURLs[0]], "no chunk after the cancellation point is decoded")
    }

    func testAlreadyCancelledTaskDecodesNothing() async throws {
        let source = try F.source(sampleRate: 16_000, frameCounts: [16_000])
        let log = DecodeLog()
        let stager = DiarizationAudioStager(decodeChunk: fillingDecoder(source: source, log: log))
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try stager.stage(source)
        }.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertTrue(log.calls.isEmpty)
    }

    // MARK: - Real decoder

    func testRealDecoderOutputReconcilesWithFrameDerivedIntervals() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiarizationAudioStagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for rate in [44_100.0, 48_000] {
            let frames = Int(rate)
            let manifest = PlaybackTestManifest.make(sampleRate: rate, frameCounts: [frames + 1, frames - 1, frames / 10 + 1])
            let timeline = try LecturePlaybackTimeline(manifest: manifest)
            var urls: [URL] = []
            for chunk in timeline.chunks {
                let url = directory.appendingPathComponent("\(Int(rate))-\(chunk.fileName)")
                // A constant per chunk, so placement is visible after
                // resampling, away from the chunk edges.
                try writeMonoCAF(url, sampleRate: rate, value: 0.1 * Float(chunk.sequenceNumber + 1), frames: Int(chunk.frameCount))
                urls.append(url)
            }
            let source = LecturePlaybackSource(timeline: timeline, chunkURLs: urls, channelCount: 1)
            let staged = try DiarizationAudioStager().stage(source)

            let rateInt = Int64(rate)
            XCTAssertEqual(staged.samples.count, expectedDestination(timeline.totalFrameCount, rate: rateInt))
            for chunk in timeline.chunks {
                let start = expectedDestination(chunk.startFrame, rate: rateInt)
                let end = expectedDestination(chunk.endFrame, rate: rateInt)
                XCTAssertEqual(staged.samples[(start + end) / 2], 0.1 * Float(chunk.sequenceNumber + 1), accuracy: 0.01,
                               "chunk \(chunk.sequenceNumber) @ \(rate)")
            }
        }
    }

    private func writeMonoCAF(_ url: URL, sampleRate: Double, value: Float, frames: Int) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channel = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<frames { channel[0][frame] = value }
            try file.write(from: buffer)
            file.close()
        }
    }
}
