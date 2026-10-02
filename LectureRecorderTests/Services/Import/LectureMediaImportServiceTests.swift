import AVFoundation
import CryptoKit
import os
import XCTest
@testable import LectureRecorder

// MARK: - Fixtures

/// Small media files generated per test — never committed binaries. Every
/// linear-PCM sample encodes its own frame and channel, so imported chunks
/// can be compared exactly against the source.
private enum ImportTestMedia {
    static let sampleStep: Float = 1e-6

    static func sampleValue(frame: Int, channel: Int) -> Float {
        Float(frame) * sampleStep + Float(channel) * 0.5
    }

    /// A Float32 linear-PCM file (`.caf` or `.wav`, chosen by extension).
    static func writePCM(to url: URL, frameCount: Int, sampleRate: Double, channelCount: AVAudioChannelCount) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false
        ))
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let blockFrames = 65_536
            var written = 0
            while written < frameCount {
                let count = min(blockFrames, frameCount - written)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                let channels = try XCTUnwrap(buffer.floatChannelData)
                for channel in 0..<Int(channelCount) {
                    for frame in 0..<count {
                        channels[channel][frame] = sampleValue(frame: written + frame, channel: channel)
                    }
                }
                try file.write(from: buffer)
                written += count
            }
            file.close()
        }
    }

    /// A tone as an AAC `.m4a`, encoded by `AVAudioFile`.
    static func writeAAC(to url: URL, frameCount: Int, sampleRate: Double, channelCount: AVAudioChannelCount) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
        ]
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try toneBuffer(frameCount: frameCount, sampleRate: sampleRate, channelCount: channelCount)
            try file.write(from: buffer)
            file.close()
        }
    }

    /// A tone as AAC in a QuickTime or MPEG-4 container (`.mov`/`.mp4`),
    /// written by `AVAssetWriter` as a single sample buffer.
    static func writeContainer(to url: URL, fileType: AVFileType, frameCount: Int, sampleRate: Double) async throws {
        let pcm = try toneBuffer(frameCount: frameCount, sampleRate: sampleRate, channelCount: 1)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: pcm.format.formatDescription, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
        ), noErr)
        let buffer = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList
        ), noErr)
        XCTAssertTrue(input.isReadyForMoreMediaData)
        XCTAssertTrue(input.append(buffer))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private static func toneBuffer(frameCount: Int, sampleRate: Double, channelCount: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channelCount) {
            for frame in 0..<frameCount {
                channels[channel][frame] = 0.25 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        return buffer
    }

    static func digest(of url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }
}

/// A decoder double yielding scripted buffers, then failing or ending —
/// for failures a real file cannot produce on demand.
private final class ScriptedAudioReader: LectureMediaAudioReading {
    let format: AVAudioFormat
    private var remaining: [AVAudioPCMBuffer]
    private let failure: LectureMediaDecodeError?
    private let endless: Bool
    private(set) var cancelled = false

    init(format: AVAudioFormat, buffers: [AVAudioPCMBuffer], failure: LectureMediaDecodeError? = nil, endless: Bool = false) {
        self.format = format
        self.remaining = buffers
        self.failure = failure
        self.endless = endless
    }

    func nextBuffer() throws -> AVAudioPCMBuffer? {
        if endless, let first = remaining.first { return first }
        if !remaining.isEmpty { return remaining.removeFirst() }
        if let failure { throw failure }
        return nil
    }

    func cancel() { cancelled = true }
}

private struct ScriptedDecoder: LectureMediaAudioDecoding, @unchecked Sendable {
    let open: () throws -> any LectureMediaAudioReading

    func openAudio(at url: URL) async throws -> any LectureMediaAudioReading {
        try open()
    }
}

/// Real chunk durability, failing the `failAt`th chunk file sync.
private final class FailingFileSyncFileSystem: ChunkFinalizationFileSystem, @unchecked Sendable {
    private let real = DarwinChunkFinalizationFileSystem()
    private let lock = NSLock()
    private var fileSyncCount = 0
    private let failAt: Int

    init(failAt: Int) {
        self.failAt = failAt
    }

    func synchronizeFile(at url: URL) throws {
        let count: Int = lock.withLock { fileSyncCount += 1; return fileSyncCount }
        if count == failAt {
            throw ChunkDurabilityFailure(stage: .partialFileSync, path: url, primaryErrno: EIO, primaryMessage: "Injected failure",
                                         secondaryCloseErrno: nil, secondaryCloseMessage: nil)
        }
        try real.synchronizeFile(at: url)
    }

    func rename(from source: URL, to destination: URL) throws {
        try real.rename(from: source, to: destination)
    }

    func synchronizeDirectory(at url: URL) throws {
        try real.synchronizeDirectory(at: url)
    }
}

/// Builds the production `AudioChunkWriter` over an injected durability
/// file system — the importer's failure injection goes through the same
/// factory seam `SessionManager` uses.
private struct DurabilityInjectingWriterFactory: AudioChunkWriterFactory {
    let fileSystem: any ChunkFinalizationFileSystem

    func makeWriter(chunksDirectory: URL, format: AVAudioFormat, targetChunkDurationSeconds: Double) throws -> any AudioChunkWriting {
        try AudioChunkWriter(
            chunksDirectory: chunksDirectory,
            format: format,
            targetChunkDurationSeconds: targetChunkDurationSeconds,
            chunkFinalizationFileSystem: fileSystem
        )
    }
}

// MARK: - Tests

final class LectureMediaImportServiceTests: XCTestCase {
    private var root: URL!
    private var sessionsRoot: URL!
    private var stagingRoot: URL!
    private var sourceDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectureMediaImportTests-\(UUID().uuidString)", isDirectory: true)
        sessionsRoot = root.appendingPathComponent("Sessions", isDirectory: true)
        stagingRoot = root.appendingPathComponent("ImportStaging", isDirectory: true)
        sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        for directory in [sessionsRoot!, stagingRoot!, sourceDirectory!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService(
        decoder: any LectureMediaAudioDecoding = AVAssetLectureMediaAudioDecoder(),
        writerFactory: any AudioChunkWriterFactory = DefaultAudioChunkWriterFactory(),
        sessionID: UUID = UUID()
    ) -> LectureMediaImportService {
        let sessionsRoot = sessionsRoot!
        let stagingRoot = stagingRoot!
        return LectureMediaImportService(
            sessionsRootResolver: { sessionsRoot },
            stagingRootResolver: { stagingRoot },
            decoder: decoder,
            writerFactory: writerFactory,
            makeSessionID: { sessionID }
        )
    }

    private func setPermissions(_ permissions: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func source(_ name: String) -> URL {
        sourceDirectory.appendingPathComponent(name)
    }

    private func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// Nothing published, no staging left behind.
    private func assertNothingPublished(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(contents(of: sessionsRoot), [], "no session published", file: file, line: line)
        XCTAssertEqual(contents(of: stagingRoot), [], "staging removed", file: file, line: line)
        let catalog = CompletedSessionCatalog(sessionsRootResolver: { [sessionsRoot] in sessionsRoot! })
        XCTAssertEqual(try catalog.listCompletedSessions().sessions, [], file: file, line: line)
    }

    private func assertImportFails(
        _ service: LectureMediaImportService,
        from url: URL,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (LectureMediaImportError) -> Void
    ) async {
        do {
            let result = try await service.importLecture(from: url)
            XCTFail("unexpectedly imported \(result.sessionID)", file: file, line: line)
        } catch let error as LectureMediaImportError {
            check(error)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    /// Reads every chunk of `result` back and checks each sample against the
    /// source's frame/channel encoding, across chunk boundaries.
    private func assertChunksMatchSource(_ result: LectureMediaImportResult, totalFrames: Int, channelCount: Int,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        var frameIndex = 0
        for chunk in result.manifest.chunks {
            let url = result.sessionPaths.chunksDirectory.appendingPathComponent(chunk.fileName)
            let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            XCTAssertEqual(audio.length, AVAudioFramePosition(chunk.frameCount), file: file, line: line)
            // One `read(into:)` may return fewer frames than requested, so
            // read until the chunk's whole length has been checked.
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 65_536))
            var chunkFrame = 0
            while chunkFrame < chunk.frameCount {
                try audio.read(into: buffer)
                let read = Int(buffer.frameLength)
                guard read > 0 else { return XCTFail("chunk \(chunk.sequenceNumber) ended early at \(chunkFrame)", file: file, line: line) }
                let channels = try XCTUnwrap(buffer.floatChannelData)
                for channel in 0..<channelCount {
                    for frame in 0..<read where channels[channel][frame] != ImportTestMedia.sampleValue(frame: frameIndex + chunkFrame + frame, channel: channel) {
                        return XCTFail("sample mismatch at frame \(frameIndex + chunkFrame + frame), channel \(channel)", file: file, line: line)
                    }
                }
                chunkFrame += read
            }
            XCTAssertEqual(chunkFrame, chunk.frameCount, file: file, line: line)
            frameIndex += chunk.frameCount
        }
        XCTAssertEqual(frameIndex, totalFrames, "no dropped or added audio", file: file, line: line)
    }

    // MARK: Chunking and frame accounting

    func testShortMonoInputBecomesOneCompletedChunk() async throws {
        let url = source("short.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 80_000, sampleRate: 8_000, channelCount: 1)

        let result = try await makeService().importLecture(from: url)

        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(result.manifest.audioFormat, AudioFormatDescriptor(sampleRate: 8_000, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32"))
        XCTAssertEqual(result.manifest.targetChunkDurationSeconds, 30)
        XCTAssertEqual(result.manifest.chunks.map(\.frameCount), [80_000])
        XCTAssertEqual(result.manifest.chunks.map(\.fileName), ["chunk_000000.caf"])
        XCTAssertEqual(result.manifest.chunks.map(\.state), [.completed])
        XCTAssertEqual(result.sessionPaths.sessionDirectory.deletingLastPathComponent().standardizedFileURL, sessionsRoot.standardizedFileURL)
        try assertChunksMatchSource(result, totalFrames: 80_000, channelCount: 1)
        XCTAssertEqual(contents(of: stagingRoot), [], "staging is empty after publication")
    }

    func testExactlyOneChunkProducesNoEmptyTrailingChunk() async throws {
        let url = source("one-chunk.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 240_000, sampleRate: 8_000, channelCount: 1)

        let result = try await makeService().importLecture(from: url)

        XCTAssertEqual(result.manifest.chunks.map(\.frameCount), [240_000])
        try assertChunksMatchSource(result, totalFrames: 240_000, channelCount: 1)
    }

    func testMultipleChunksWithFinalPartialChunkKeepEveryFrameInSequence() async throws {
        let total = 240_000 * 2 + 12_345
        let url = source("multi.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: total, sampleRate: 8_000, channelCount: 1)

        let result = try await makeService().importLecture(from: url)

        let chunks = result.manifest.chunks
        XCTAssertEqual(chunks.map(\.sequenceNumber), [0, 1, 2])
        XCTAssertEqual(chunks.map(\.fileName), ["chunk_000000.caf", "chunk_000001.caf", "chunk_000002.caf"])
        XCTAssertEqual(chunks.map(\.frameCount), [240_000, 240_000, 12_345])
        XCTAssertEqual(chunks.map(\.startOffsetSeconds), [0, 30, 60])
        XCTAssertEqual(chunks.last?.durationSeconds, 12_345.0 / 8_000)
        try assertChunksMatchSource(result, totalFrames: total, channelCount: 1)
    }

    func testStereoInputKeepsBothChannelsExactly() async throws {
        let url = source("stereo.wav")
        try ImportTestMedia.writePCM(to: url, frameCount: 50_000, sampleRate: 16_000, channelCount: 2)

        let result = try await makeService().importLecture(from: url)

        XCTAssertEqual(result.manifest.audioFormat.channelCount, 2)
        XCTAssertEqual(result.manifest.audioFormat.sampleRate, 16_000)
        try assertChunksMatchSource(result, totalFrames: 50_000, channelCount: 2)
    }

    /// The source sample rate is kept — no resampling — and drives the
    /// frame-exact chunk size, exactly as a live device rate does.
    func testNonDefaultSampleRatesArePreservedWithFrameExactChunks() async throws {
        for sampleRate in [22_050.0, 48_000.0] {
            let framesPerChunk = Int(sampleRate * 30)
            let total = framesPerChunk + 1
            let url = source("rate-\(Int(sampleRate)).caf")
            try ImportTestMedia.writePCM(to: url, frameCount: total, sampleRate: sampleRate, channelCount: 1)

            let result = try await makeService().importLecture(from: url)

            XCTAssertEqual(result.manifest.audioFormat.sampleRate, sampleRate)
            XCTAssertEqual(result.manifest.chunks.map(\.frameCount), [framesPerChunk, 1])
            XCTAssertEqual(result.manifest.chunks.map(\.startOffsetSeconds), [0, 30])
            try assertChunksMatchSource(result, totalFrames: total, channelCount: 1)
        }
    }

    func testMoreThanTwoChannelsAreDownmixedToMono() async throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, interleaved: false, channelLayout: layout)
        let url = source("quad.caf")
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
            buffer.frameLength = 8_000
            try file.write(from: buffer)
            file.close()
        }

        let result = try await makeService().importLecture(from: url)

        XCTAssertEqual(result.manifest.audioFormat.channelCount, 1)
        XCTAssertEqual(result.manifest.chunks.map(\.frameCount), [8_000])
    }

    // MARK: Compressed and container formats

    func testAACM4AImportsWithinEncoderPaddingOfItsDuration() async throws {
        let url = source("lecture.m4a")
        try ImportTestMedia.writeAAC(to: url, frameCount: 44_100 * 31, sampleRate: 44_100, channelCount: 1)

        let result = try await makeService().importLecture(from: url)

        XCTAssertEqual(result.manifest.audioFormat.sampleRate, 44_100)
        XCTAssertEqual(result.manifest.chunks.count, 2)
        XCTAssertEqual(result.manifest.chunks.first?.frameCount, 44_100 * 30)
        let total = result.manifest.chunks.reduce(0) { $0 + $1.frameCount }
        XCTAssertEqual(Double(total), Double(44_100 * 31), accuracy: 4_096, "AAC priming/remainder only")
    }

    func testAudioTrackOfQuickTimeAndMPEG4ContainersImports() async throws {
        for (name, fileType) in [("lecture.mov", AVFileType.mov), ("lecture.mp4", AVFileType.mp4)] {
            let url = source(name)
            try await ImportTestMedia.writeContainer(to: url, fileType: fileType, frameCount: 44_100 * 2, sampleRate: 44_100)

            let result = try await makeService().importLecture(from: url)

            XCTAssertEqual(result.manifest.chunks.count, 1, name)
            XCTAssertEqual(Double(result.manifest.chunks[0].frameCount), Double(44_100 * 2), accuracy: 4_096, name)
        }
    }

    // MARK: Rejections

    func testZeroFrameAudioIsRejectedAndNothingPublished() async throws {
        let url = source("empty.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 0, sampleRate: 8_000, channelCount: 1)

        // AVFoundation reports an empty file as unreadable rather than as
        // an empty track; either way it is rejected before staging output.
        await assertImportFails(makeService(), from: url) { error in
            switch error {
            case .noAudio, .decode(.noAudioTrack), .decode(.unreadable): break
            default: XCTFail("expected an empty-audio rejection, got \(error)")
            }
        }
        try assertNothingPublished()
    }

    func testTrackThatDecodesToNoFramesIsRejectedAsNoAudio() async throws {
        let url = source("silent-track.m4a")
        try Data().write(to: url)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false))
        let decoder = ScriptedDecoder { ScriptedAudioReader(format: format, buffers: []) }

        await assertImportFails(makeService(decoder: decoder), from: url) {
            XCTAssertEqual($0, .noAudio)
        }
        try assertNothingPublished()
    }

    func testNonMediaFileIsRejectedAndNothingPublished() async throws {
        let url = source("notes.m4a")
        try Data("not audio".utf8).write(to: url)

        await assertImportFails(makeService(), from: url) { error in
            guard case .decode = error else { return XCTFail("expected a decode rejection, got \(error)") }
        }
        try assertNothingPublished()
    }

    func testMissingAudioTrackIsRejected() async throws {
        let url = source("video-only.mov")
        try Data().write(to: url)
        let decoder = ScriptedDecoder { throw LectureMediaDecodeError.noAudioTrack }

        await assertImportFails(makeService(decoder: decoder), from: url) { error in
            XCTAssertEqual(error, .decode(.noAudioTrack))
        }
        try assertNothingPublished()
    }

    func testSourcePathSafety() async throws {
        await assertImportFails(makeService(), from: try XCTUnwrap(URL(string: "https://example.com/lecture.m4a"))) {
            XCTAssertEqual($0, .sourceNotAFileURL)
        }
        await assertImportFails(makeService(), from: source("missing.caf")) {
            XCTAssertEqual($0, .sourceUnavailable)
        }
        await assertImportFails(makeService(), from: sourceDirectory) {
            XCTAssertEqual($0, .sourceUnavailable)
        }
        try assertNothingPublished()
    }

    func testUnsafeSessionsRootIsRejected() async throws {
        let url = source("short.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 800, sampleRate: 8_000, channelCount: 1)
        try FileManager.default.removeItem(at: sessionsRoot)
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessionsRoot, withDestinationURL: elsewhere)

        await assertImportFails(makeService(), from: url) { error in
            guard case .storageUnavailable = error else { return XCTFail("expected storageUnavailable, got \(error)") }
        }
        XCTAssertEqual(contents(of: elsewhere), [])
        XCTAssertEqual(contents(of: stagingRoot), [])
    }

    func testExistingSessionWithSameIDIsNeverOverwritten() async throws {
        let url = source("short.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 800, sampleRate: 8_000, channelCount: 1)
        let sessionID = UUID()
        let existing = sessionsRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let marker = existing.appendingPathComponent("marker")
        try Data("keep".utf8).write(to: marker)

        await assertImportFails(makeService(sessionID: sessionID), from: url) {
            XCTAssertEqual($0, .sessionAlreadyExists(sessionID))
        }
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertEqual(contents(of: stagingRoot), [])
    }

    // MARK: Failure midway and transaction semantics

    func testDecodeFailureMidwayPublishesNothingAndKeepsSource() async throws {
        let url = source("lecture.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 800, sampleRate: 8_000, channelCount: 1)
        let digest = try ImportTestMedia.digest(of: url)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false))
        let block = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100_000))
        block.frameLength = 100_000
        let reader = ScriptedAudioReader(format: format, buffers: [block, block, block, block, block],
                                         failure: .decodingFailed(reason: "corrupt packet"))

        await assertImportFails(makeService(decoder: ScriptedDecoder { reader }), from: url) {
            XCTAssertEqual($0, .decode(.decodingFailed(reason: "corrupt packet")))
        }
        XCTAssertTrue(reader.cancelled)
        try assertNothingPublished()
        XCTAssertEqual(try ImportTestMedia.digest(of: url), digest, "source untouched")
    }

    func testChunkDurabilityFailurePublishesNothing() async throws {
        let url = source("multi.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 240_000 * 2 + 10, sampleRate: 8_000, channelCount: 1)
        let factory = DurabilityInjectingWriterFactory(fileSystem: FailingFileSyncFileSystem(failAt: 2))

        await assertImportFails(makeService(writerFactory: factory), from: url) { error in
            guard case .chunkWritingFailed = error else { return XCTFail("expected chunkWritingFailed, got \(error)") }
        }
        try assertNothingPublished()
    }

    func testPublicationRenameFailurePublishesNothing() async throws {
        let url = source("short.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 800, sampleRate: 8_000, channelCount: 1)
        // Read and search only: the publishing rename into it is refused.
        try setPermissions(0o500, of: sessionsRoot)
        defer { try? setPermissions(0o755, of: sessionsRoot) }

        await assertImportFails(makeService(), from: url) { error in
            guard case .publicationFailed = error else { return XCTFail("expected publicationFailed, got \(error)") }
        }
        try setPermissions(0o755, of: sessionsRoot)
        try assertNothingPublished()
    }

    /// The rename already made a complete, valid session visible; only its
    /// crash durability is unconfirmed, so it is reported but kept.
    func testUnconfirmedPublicationSyncKeepsTheCompleteSession() async throws {
        let url = source("short.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 800, sampleRate: 8_000, channelCount: 1)
        // Write and search only: the rename succeeds, but opening the
        // directory to sync it is refused.
        try setPermissions(0o300, of: sessionsRoot)
        defer { try? setPermissions(0o755, of: sessionsRoot) }
        let sessionID = UUID()

        await assertImportFails(makeService(sessionID: sessionID), from: url) { error in
            guard case .publicationNotDurable(let id, _) = error else { return XCTFail("expected publicationNotDurable, got \(error)") }
            XCTAssertEqual(id, sessionID)
        }
        try setPermissions(0o755, of: sessionsRoot)
        let catalog = CompletedSessionCatalog(sessionsRootResolver: { [sessionsRoot] in sessionsRoot! })
        XCTAssertEqual(try catalog.listCompletedSessions().sessions.map(\.manifest.sessionID), [sessionID])
    }

    func testCancellationPublishesNothing() async throws {
        let url = source("lecture.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 800, sampleRate: 8_000, channelCount: 1)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false))
        let block = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_000))
        block.frameLength = 1_000
        let reader = ScriptedAudioReader(format: format, buffers: [block], endless: true)
        let service = makeService(decoder: ScriptedDecoder { reader })

        let task = Task { try await service.importLecture(from: url) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("an endless import must end only by cancellation")
        } catch let error as LectureMediaImportError {
            XCTAssertEqual(error, .cancelled)
        }
        try assertNothingPublished()
    }

    @MainActor
    func testImportCalledFromMainActorDecodesOffTheMainThread() async throws {
        let url = source("lecture.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: 800, sampleRate: 8_000, channelCount: 1)
        let openedOnMainThread = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let decoder = ScriptedDecoder {
            openedOnMainThread.withLock { $0 = Thread.isMainThread }
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false))
            let block = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
            block.frameLength = 800
            return ScriptedAudioReader(format: format, buffers: [block])
        }

        _ = try await makeService(decoder: decoder).importLecture(from: url)

        XCTAssertEqual(openedOnMainThread.withLock { $0 }, false)
    }

    func testSuccessfulImportNeverModifiesTheSource() async throws {
        let url = source("lecture.wav")
        try ImportTestMedia.writePCM(to: url, frameCount: 9_000, sampleRate: 8_000, channelCount: 2)
        let digest = try ImportTestMedia.digest(of: url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        _ = try await makeService().importLecture(from: url)

        XCTAssertEqual(try ImportTestMedia.digest(of: url), digest)
        XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(contents(of: sourceDirectory), ["lecture.wav"])
    }

    // MARK: Downstream compatibility

    /// The imported session goes through the unchanged catalog, playback
    /// source, and transcription audio boundaries — no import branch.
    func testImportedSessionIsConsumedByExistingCatalogPlaybackAndTranscriptionDecoding() async throws {
        let total = 240_000 + 4_000
        let url = source("lecture.caf")
        try ImportTestMedia.writePCM(to: url, frameCount: total, sampleRate: 8_000, channelCount: 2)

        let result = try await makeService().importLecture(from: url)

        let catalog = CompletedSessionCatalog(sessionsRootResolver: { [sessionsRoot] in sessionsRoot! })
        let listed = try catalog.listCompletedSessions()
        XCTAssertEqual(listed.errors, [])
        let entry = try XCTUnwrap(listed.sessions.first)
        XCTAssertEqual(entry.manifest, result.manifest)
        XCTAssertEqual(try AtomicFileWriter.readJSON(SessionManifest.self, from: entry.sessionPaths.manifestURL), result.manifest)

        let playback = try LecturePlaybackSourceLoader.load(
            expectedSessionID: entry.manifest.sessionID, manifest: entry.manifest, sessionPaths: entry.sessionPaths
        )
        XCTAssertEqual(playback.timeline.totalFrameCount, Int64(total))
        XCTAssertEqual(playback.channelCount, 2)

        for chunk in entry.manifest.chunks {
            let decoded = try WhisperAudioDecoder.decode(
                url: entry.sessionPaths.chunksDirectory.appendingPathComponent(chunk.fileName),
                source: WhisperAudioSourceMetadata(
                    frameCount: chunk.frameCount,
                    durationSeconds: chunk.durationSeconds,
                    sampleRate: entry.manifest.audioFormat.sampleRate,
                    channelCount: entry.manifest.audioFormat.channelCount,
                    bitsPerChannel: entry.manifest.audioFormat.bitsPerChannel,
                    formatIdentifier: entry.manifest.audioFormat.formatIdentifier
                )
            )
            XCTAssertEqual(decoded.durationMilliseconds, Int64((Double(chunk.frameCount) * 1_000 / 8_000).rounded()))
        }
    }
}
