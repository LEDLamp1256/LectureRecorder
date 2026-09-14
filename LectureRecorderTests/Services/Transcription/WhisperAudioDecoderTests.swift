import AVFoundation
import XCTest
@testable import LectureRecorder

final class WhisperAudioDecoderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperAudioDecoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testMonoAt16KPreservesSamplesAndEmptyInputSucceeds() throws {
        let values: [Float] = [0.25, -0.5, 0.75, 0]
        let mono = try writeCAF(name: "mono.caf", sampleRate: 16_000, channels: [values])
        let decoded = try WhisperAudioDecoder.decode(url: mono, source: metadata(frames: values.count, rate: 16_000, channels: 1))
        XCTAssertEqual(decoded.samples.count, values.count)
        for (actual, expected) in zip(decoded.samples, values) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }

        let empty = try writeCAF(name: "empty.caf", sampleRate: 44_100, channels: [[]])
        XCTAssertEqual(
            try WhisperAudioDecoder.decode(url: empty, source: metadata(frames: 0, rate: 44_100, channels: 1)),
            DecodedWhisperAudio(samples: [], durationMilliseconds: 0)
        )
    }

    func testStereoDownmixIsArithmeticMean() throws {
        let left: [Float] = [1, -1, 0.5, -0.25]
        let right: [Float] = [-1, 1, 0.5, 0.75]
        let url = try writeCAF(name: "stereo.caf", sampleRate: 16_000, channels: [left, right])
        let decoded = try WhisperAudioDecoder.decode(url: url, source: metadata(frames: left.count, rate: 16_000, channels: 2))
        let expected: [Float] = [0, 0, 0.5, 0.25]
        XCTAssertEqual(decoded.samples.count, expected.count)
        for (actual, expected) in zip(decoded.samples, expected) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
    }

    func testNon16KMultiBufferConversionDrainsEndOfStream() throws {
        let frames = 44_100 * 2 + 137
        let input = (0..<frames).map { Float(sin(Double($0) * 2 * .pi * 440 / 44_100)) * 0.2 }
        let url = try writeCAF(name: "resample.caf", sampleRate: 44_100, channels: [input])
        let original = try Data(contentsOf: url)
        let decoded = try WhisperAudioDecoder.decode(url: url, source: metadata(frames: frames, rate: 44_100, channels: 1))
        let expected = Int((Double(frames) * 16_000 / 44_100).rounded())
        XCTAssertEqual(decoded.samples.count, expected, accuracy: 1)
        XCTAssertEqual(decoded.durationMilliseconds, Int64((Double(frames) * 1_000 / 44_100).rounded()))
        XCTAssertTrue(decoded.samples.allSatisfy(\.isFinite))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testPhysicalInt16WithMatchingFramesIsRejectedBeforeAnyReadAndRemainsUnchanged() throws {
        let url = directory.appendingPathComponent("physical-int16.caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 16_000, channels: 1, interleaved: true))
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
            buffer.frameLength = 4
            let samples = try XCTUnwrap(buffer.int16ChannelData)
            for index in 0..<4 { samples[0][index] = 123 }
            try file.write(from: buffer)
            file.close()
        }
        let original = try Data(contentsOf: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.length, 4)
        XCTAssertEqual(file.processingFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        file.close()
        var reads = 0
        XCTAssertThrowsError(try WhisperAudioDecoder.decode(url: url,
            source: metadata(frames: 4, rate: 16_000, channels: 1),
            readSource: { _, _, _ in reads += 1 })) {
            XCTAssertEqual($0 as? WhisperAudioDecodeError, .metadataMismatch)
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testPhysicalCanonicalFieldsAndEveryRepresentationMismatch() throws {
        for channels in 1...2 {
            let url = try writeCAF(name: "canonical-\(channels).caf", sampleRate: 16_000,
                channels: Array(repeating: [0.25, -0.25], count: channels))
            let original = try Data(contentsOf: url)
            let file = try AVAudioFile(forReading: url)
            let stored = file.fileFormat.streamDescription.pointee
            file.close()
            let source = metadata(frames: 2, rate: 16_000, channels: UInt32(channels))
            XCTAssertEqual(stored.mFormatFlags, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
            XCTAssertNoThrow(try WhisperAudioDecoder.validateStoredFormat(stored, source: source))
            let mutations: [(inout AudioStreamBasicDescription) -> Void] = [
                { $0.mFormatID = kAudioFormatAppleLossless },
                { $0.mFormatFlags ^= kAudioFormatFlagIsFloat },
                { $0.mFormatFlags |= kAudioFormatFlagIsSignedInteger },
                { $0.mFormatFlags ^= kAudioFormatFlagIsPacked },
                { $0.mFormatFlags |= kAudioFormatFlagIsAlignedHigh },
                { $0.mFormatFlags |= kAudioFormatFlagIsBigEndian },
                { $0.mFormatFlags |= kAudioFormatFlagIsNonInterleaved },
                { $0.mBitsPerChannel = 16 }, { $0.mBytesPerFrame += 1 },
                { $0.mBytesPerPacket += 1 }, { $0.mFramesPerPacket = 2 },
                { $0.mSampleRate += 1 }, { $0.mChannelsPerFrame += 1 },
                { $0.mReserved = 1 }
            ]
            for mutate in mutations {
                var invalid = stored
                mutate(&invalid)
                XCTAssertThrowsError(try WhisperAudioDecoder.validateStoredFormat(invalid, source: source)) {
                    XCTAssertEqual($0 as? WhisperAudioDecodeError, .metadataMismatch)
                }
            }
            XCTAssertEqual(try WhisperAudioDecoder.decode(url: url, source: source).samples.count, 2)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testPrematureZeroFrameReadIsNoDataNowFailureRatherThanEOF() throws {
        let frames = 8_192
        let url = try writeCAF(
            name: "premature-zero.caf",
            sampleRate: 16_000,
            channels: [Array(repeating: 0.1, count: frames)]
        )
        var readCount = 0
        XCTAssertThrowsError(try WhisperAudioDecoder.decode(
            url: url,
            source: metadata(frames: frames, rate: 16_000, channels: 1),
            readSource: { file, buffer, requested in
                readCount += 1
                if readCount == 1 {
                    try file.read(into: buffer, frameCount: requested)
                } else {
                    buffer.frameLength = 0
                }
            }
        )) {
            XCTAssertEqual($0 as? WhisperAudioDecodeError, .conversionFailed)
        }
        XCTAssertGreaterThanOrEqual(readCount, 2)
    }

    func testImmediateZeroFrameReadWithAdvertisedFramesRemainingIsRejected() throws {
        let url = try writeCAF(name: "immediate-zero.caf", sampleRate: 44_100, channels: [[0, 0, 0, 0]])
        XCTAssertThrowsError(try WhisperAudioDecoder.decode(
            url: url,
            source: metadata(frames: 4, rate: 44_100, channels: 1),
            readSource: { _, buffer, _ in buffer.frameLength = 0 }
        )) {
            XCTAssertEqual($0 as? WhisperAudioDecodeError, .conversionFailed)
        }
    }

    func testRejectsMalformedTruncatedWrongExtensionAndMetadataMismatch() throws {
        let malformed = directory.appendingPathComponent("bad.caf")
        try Data("caff-not-an-audio-file".utf8).write(to: malformed)
        XCTAssertThrowsError(try WhisperAudioDecoder.decode(url: malformed, source: metadata(frames: 1, rate: 44_100, channels: 1)))

        let valid = try writeCAF(name: "valid.caf", sampleRate: 44_100, channels: [[0, 0, 0, 0]])
        var bytes = try Data(contentsOf: valid)
        bytes.removeLast(min(8, bytes.count))
        let truncated = directory.appendingPathComponent("truncated.caf")
        try bytes.write(to: truncated)
        XCTAssertThrowsError(try WhisperAudioDecoder.decode(url: truncated, source: metadata(frames: 4, rate: 44_100, channels: 1)))

        let wrongExtension = directory.appendingPathComponent("audio.wav")
        try FileManager.default.copyItem(at: valid, to: wrongExtension)
        XCTAssertThrowsError(try WhisperAudioDecoder.decode(url: wrongExtension, source: metadata(frames: 4, rate: 44_100, channels: 1)))

        XCTAssertThrowsError(try WhisperAudioDecoder.decode(url: valid, source: metadata(frames: 5, rate: 44_100, channels: 1)))
        XCTAssertThrowsError(try WhisperAudioDecoder.decode(
            url: valid,
            source: WhisperAudioSourceMetadata(frameCount: 4, durationSeconds: 4 / 44_100, sampleRate: 44_100,
                channelCount: 1, bitsPerChannel: 16, formatIdentifier: "lpcm-float32")
        ))
    }

    func testRejectsInvalidChannelCountsNonfiniteSamplesAndCeiling() throws {
        let threeChannel = try writeCAF(name: "three.caf", sampleRate: 16_000, channels: [[0], [0], [0]])
        XCTAssertThrowsError(try WhisperAudioDecoder.decode(url: threeChannel, source: metadata(frames: 1, rate: 16_000, channels: 3))) {
            XCTAssertEqual($0 as? WhisperAudioDecodeError, .invalidChannels)
        }

        for (name, value) in [("nan", Float.nan), ("infinity", Float.infinity)] {
            let url = try writeCAF(name: "\(name).caf", sampleRate: 16_000, channels: [[value]])
            XCTAssertThrowsError(try WhisperAudioDecoder.decode(url: url, source: metadata(frames: 1, rate: 16_000, channels: 1))) {
                XCTAssertEqual($0 as? WhisperAudioDecodeError, .nonfiniteSample)
            }
        }

        let frames = 496_001
        let overDuration = try writeCAF(name: "long.caf", sampleRate: 16_000, channels: [Array(repeating: 0, count: frames)])
        XCTAssertThrowsError(try WhisperAudioDecoder.decode(url: overDuration, source: metadata(frames: frames, rate: 16_000, channels: 1))) {
            XCTAssertEqual($0 as? WhisperAudioDecodeError, .limitExceeded)
        }
    }

    private func metadata(frames: Int, rate: Double, channels: UInt32) -> WhisperAudioSourceMetadata {
        WhisperAudioSourceMetadata(
            frameCount: frames,
            durationSeconds: Double(frames) / rate,
            sampleRate: rate,
            channelCount: channels,
            bitsPerChannel: 32,
            formatIdentifier: "lpcm-float32"
        )
    }

    private func writeCAF(name: String, sampleRate: Double, channels: [[Float]]) throws -> URL {
        let channelCount = AVAudioChannelCount(channels.count)
        let frameCount = channels.first?.count ?? 0
        XCTAssertTrue(channels.allSatisfy { $0.count == frameCount })
        let url = directory.appendingPathComponent(name)
        let candidateFormat: AVAudioFormat?
        if channelCount <= 2 {
            candidateFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: channelCount, interleaved: false
            )
        } else {
            let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channelCount)
            )
            candidateFormat = layout.flatMap {
                AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: $0)
            }
        }
        let format = try XCTUnwrap(candidateFormat)
        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
            )
            if frameCount > 0 {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
                buffer.frameLength = AVAudioFrameCount(frameCount)
                let output = try XCTUnwrap(buffer.floatChannelData)
                for channel in 0..<channels.count {
                    for frame in 0..<frameCount { output[channel][frame] = channels[channel][frame] }
                }
                try file.write(from: buffer)
            }
            file.close()
        }
        return url
    }
}
