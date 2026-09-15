import AVFoundation
import Foundation

nonisolated struct WhisperAudioSourceMetadata: Sendable, Equatable {
    let frameCount: Int
    let durationSeconds: Double
    let sampleRate: Double
    let channelCount: UInt32
    let bitsPerChannel: UInt32
    let formatIdentifier: String
}

nonisolated struct DecodedWhisperAudio: Sendable, Equatable {
    let samples: [Float]
    let durationMilliseconds: Int64
}

nonisolated enum WhisperAudioDecodeError: Error, Sendable, Equatable {
    case invalidCAF
    case metadataMismatch
    case invalidChannels
    case unsupportedFormat
    case nonfiniteSample
    case limitExceeded
    case conversionFailed
}

nonisolated enum WhisperAudioDecoder {
    typealias SourceRead = (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void

    static let maximumSamples = 496_000
    static let maximumDurationMilliseconds: Int64 = 31_000
    private static let inputBlockFrames: AVAudioFrameCount = 4_096
    private static let outputBlockFrames: AVAudioFrameCount = 4_096

    static func decode(
        url: URL,
        source: WhisperAudioSourceMetadata,
        readSource: @escaping SourceRead = { file, buffer, frames in
            try file.read(into: buffer, frameCount: frames)
        }
    ) throws -> DecodedWhisperAudio {
        guard url.pathExtension.lowercased() == "caf", try hasCAFMagic(url) else {
            throw WhisperAudioDecodeError.invalidCAF
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw WhisperAudioDecodeError.unsupportedFormat
        }
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw WhisperAudioDecodeError.unsupportedFormat
        }
        let channels = Int(format.channelCount)
        guard channels == 1 || channels == 2 else { throw WhisperAudioDecodeError.invalidChannels }
        try validateStoredFormat(file.fileFormat.streamDescription.pointee, source: source)
        guard source.bitsPerChannel == 32, source.formatIdentifier == "lpcm-float32",
              format.sampleRate.isFinite, format.sampleRate > 0,
              source.frameCount >= 0,
              file.length == AVAudioFramePosition(source.frameCount),
              source.channelCount == format.channelCount,
              abs(source.sampleRate - format.sampleRate) < 0.001,
              source.durationSeconds.isFinite, source.durationSeconds >= 0,
              abs(source.durationSeconds - Double(source.frameCount) / format.sampleRate) < 0.001 else {
            throw WhisperAudioDecodeError.metadataMismatch
        }

        let durationMillisecondsDouble = Double(source.frameCount) * 1_000 / format.sampleRate
        guard durationMillisecondsDouble.isFinite,
              durationMillisecondsDouble <= Double(maximumDurationMilliseconds) else {
            throw WhisperAudioDecodeError.limitExceeded
        }
        let durationMilliseconds = Int64(durationMillisecondsDouble.rounded())
        guard source.frameCount > 0 else {
            return DecodedWhisperAudio(samples: [], durationMilliseconds: 0)
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: monoFormat, to: outputFormat) else {
            throw WhisperAudioDecodeError.conversionFailed
        }

        final class InputState: @unchecked Sendable {
            var reachedEnd = false
            var consumedSourceFrames: AVAudioFramePosition = 0
            var error: WhisperAudioDecodeError?
        }
        let state = InputState()
        let inputBlock: AVAudioConverterInputBlock = { requestedFrames, status in
            if state.reachedEnd {
                status.pointee = .endOfStream
                return nil
            }
            let remainingFileFrames = file.length - file.framePosition
            let remainingTrustedFrames = AVAudioFramePosition(source.frameCount) - state.consumedSourceFrames
            guard remainingFileFrames >= 0, remainingTrustedFrames >= 0,
                  file.framePosition == state.consumedSourceFrames else {
                status.pointee = .noDataNow
                state.error = .conversionFailed
                return nil
            }
            guard remainingFileFrames > 0 || remainingTrustedFrames > 0 else {
                state.reachedEnd = true
                status.pointee = .endOfStream
                return nil
            }
            guard remainingFileFrames > 0, remainingTrustedFrames > 0 else {
                status.pointee = .noDataNow
                state.error = .conversionFailed
                return nil
            }
            let requested = min(
                inputBlockFrames,
                max(1, requestedFrames),
                AVAudioFrameCount(min(remainingFileFrames, remainingTrustedFrames))
            )
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requested),
                  let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: requested) else {
                status.pointee = .noDataNow
                state.error = .conversionFailed
                return nil
            }
            do {
                try readSource(file, sourceBuffer, requested)
            } catch {
                status.pointee = .noDataNow
                state.error = .conversionFailed
                return nil
            }
            guard sourceBuffer.frameLength > 0 else {
                // A zero-frame read is EOF only after both the descriptor's
                // advertised extent and the trusted snapshot have been fully
                // consumed. Treat an early zero as truncation, never as a
                // successful prefix.
                status.pointee = .noDataNow
                state.error = .conversionFailed
                return nil
            }
            let framesRead = AVAudioFramePosition(sourceBuffer.frameLength)
            guard framesRead <= AVAudioFramePosition(requested),
                  file.framePosition == state.consumedSourceFrames + framesRead else {
                status.pointee = .noDataNow
                state.error = .conversionFailed
                return nil
            }
            state.consumedSourceFrames += framesRead
            guard let input = sourceBuffer.floatChannelData,
                  let mono = monoBuffer.floatChannelData else {
                status.pointee = .noDataNow
                state.error = .conversionFailed
                return nil
            }
            monoBuffer.frameLength = sourceBuffer.frameLength
            for frame in 0..<Int(sourceBuffer.frameLength) {
                let value = channels == 1 ? input[0][frame] : (input[0][frame] + input[1][frame]) / 2
                guard value.isFinite else {
                    status.pointee = .noDataNow
                    state.error = .nonfiniteSample
                    return nil
                }
                mono[0][frame] = value
            }
            status.pointee = .haveData
            return monoBuffer
        }

        var samples: [Float] = []
        samples.reserveCapacity(min(maximumSamples, Int((Double(source.frameCount) * 16_000 / format.sampleRate).rounded(.up)) + 256))
        var iterations = 0
        while true {
            iterations += 1
            guard iterations < 100_000,
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputBlockFrames) else {
                throw WhisperAudioDecodeError.conversionFailed
            }
            var conversionNSError: NSError?
            let conversionStatus = converter.convert(to: output, error: &conversionNSError, withInputFrom: inputBlock)
            if let stateError = state.error { throw stateError }
            if conversionNSError != nil || conversionStatus == .error {
                throw WhisperAudioDecodeError.conversionFailed
            }
            if output.frameLength > 0 {
                guard let channel = output.floatChannelData else { throw WhisperAudioDecodeError.conversionFailed }
                let outputCount = Int(output.frameLength)
                let newCount = samples.count.addingReportingOverflow(outputCount)
                guard !newCount.overflow, newCount.partialValue <= maximumSamples else {
                    throw WhisperAudioDecodeError.limitExceeded
                }
                for index in 0..<outputCount {
                    let value = channel[0][index]
                    guard value.isFinite else { throw WhisperAudioDecodeError.nonfiniteSample }
                    samples.append(value)
                }
            }
            if conversionStatus == .endOfStream {
                guard state.reachedEnd,
                      state.consumedSourceFrames == AVAudioFramePosition(source.frameCount),
                      file.framePosition == file.length else {
                    throw WhisperAudioDecodeError.conversionFailed
                }
                break
            }
            if conversionStatus == .inputRanDry, state.reachedEnd { continue }
        }
        return DecodedWhisperAudio(samples: samples, durationMilliseconds: durationMilliseconds)
    }

    /// AudioChunkWriter supplies non-interleaved client buffers, but CAF stores
    /// interleaved little-endian packed Float32 PCM. The durable snapshot's
    /// lpcm-float32 identity implies these fields; it records no channel layout.
    /// Compare the physical ASBD before accepting any decoded client samples.
    static func validateStoredFormat(
        _ actual: AudioStreamBasicDescription,
        source: WhisperAudioSourceMetadata
    ) throws {
        guard source.formatIdentifier == "lpcm-float32", source.bitsPerChannel == 32,
              source.channelCount == 1 || source.channelCount == 2,
              source.sampleRate.isFinite, source.sampleRate > 0,
              actual.mFormatID == kAudioFormatLinearPCM,
              actual.mFormatFlags == (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked),
              actual.mBitsPerChannel == source.bitsPerChannel,
              actual.mChannelsPerFrame == source.channelCount,
              actual.mSampleRate == source.sampleRate,
              actual.mFramesPerPacket == 1,
              actual.mBytesPerFrame == 4 * source.channelCount,
              actual.mBytesPerPacket == 4 * source.channelCount,
              actual.mReserved == 0 else {
            throw WhisperAudioDecodeError.metadataMismatch
        }
    }

    private static func hasCAFMagic(_ url: URL) throws -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: 4) == Data([0x63, 0x61, 0x66, 0x66])
        } catch {
            throw WhisperAudioDecodeError.invalidCAF
        }
    }
}
