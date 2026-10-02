import AVFoundation
import CoreMedia
import Foundation

/// Why a media file's audio could not be decoded for import. Never carries
/// a path; `reason` is the framework's own description.
nonisolated enum LectureMediaDecodeError: LocalizedError, Sendable, Equatable {
    /// The file could not be opened as media at all.
    case unreadable(reason: String)
    /// The media opened but contains no audio track.
    case noAudioTrack
    /// The audio track's format cannot be decoded to linear PCM (unknown or
    /// non-finite sample rate, no channels, or no format description).
    case unsupportedAudioFormat(reason: String)
    /// Decoding stopped before the end of the track. Never skipped.
    case decodingFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "The file could not be opened as media: \(reason)"
        case .noAudioTrack:
            return "The file has no audio track."
        case .unsupportedAudioFormat(let reason):
            return "The file's audio format is not supported: \(reason)"
        case .decodingFailed(let reason):
            return "The file's audio could not be decoded completely: \(reason)"
        }
    }
}

/// Sequential, decoded linear-PCM audio from one media file. `format` is
/// fixed for the whole read and is always non-interleaved Float32 with one
/// or two channels — the same shape `AudioChunkWriter` accepts from live
/// capture. Single-use and not thread-safe: read from one task only.
nonisolated protocol LectureMediaAudioReading: AnyObject {
    var format: AVAudioFormat { get }
    /// The next decoded buffer, or `nil` once the whole track has been
    /// decoded. Throws as soon as decoding fails; never skips audio.
    func nextBuffer() throws -> AVAudioPCMBuffer?
    /// Stops decoding early (import failed or was cancelled).
    func cancel()
}

/// Opens a media file's audio for import.
nonisolated protocol LectureMediaAudioDecoding: Sendable {
    func openAudio(at url: URL) async throws -> any LectureMediaAudioReading
}

/// AVFoundation decoding of the first audio track of any media AVFoundation
/// can read — audio files (m4a/AAC, mp3, wav, caf, aiff, …) and the audio
/// track of a video container (mp4, mov). Video is never decoded.
///
/// The track keeps its own sample rate (no resampling). Mono and stereo
/// keep their channel count; any other channel count is downmixed to mono
/// by Core Audio, since chunks hold one or two channels.
nonisolated struct AVAssetLectureMediaAudioDecoder: LectureMediaAudioDecoding {
    func openAudio(at url: URL) async throws -> any LectureMediaAudioReading {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw LectureMediaDecodeError.unreadable(reason: error.localizedDescription)
        }
        guard let track = tracks.first else { throw LectureMediaDecodeError.noAudioTrack }

        let descriptions: [CMFormatDescription]
        do {
            descriptions = try await track.load(.formatDescriptions)
        } catch {
            throw LectureMediaDecodeError.unreadable(reason: error.localizedDescription)
        }
        guard let description = descriptions.first,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw LectureMediaDecodeError.unsupportedAudioFormat(reason: "The audio track has no format description.")
        }
        let sampleRate = streamDescription.mSampleRate
        guard sampleRate.isFinite, sampleRate > 0, streamDescription.mChannelsPerFrame > 0 else {
            throw LectureMediaDecodeError.unsupportedAudioFormat(
                reason: "Unusable sample rate (\(sampleRate)) or channel count (\(streamDescription.mChannelsPerFrame))."
            )
        }
        let channelCount: AVAudioChannelCount = streamDescription.mChannelsPerFrame == 2 ? 2 : 1
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw LectureMediaDecodeError.unsupportedAudioFormat(reason: "No PCM format for \(sampleRate) Hz, \(channelCount) channel(s).")
        }

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelCount == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LectureMediaDecodeError.unreadable(reason: error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LectureMediaDecodeError.unsupportedAudioFormat(reason: "The audio track cannot be decoded to linear PCM.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw LectureMediaDecodeError.unreadable(reason: reader.error?.localizedDescription ?? "Reading could not start.")
        }
        return AVAssetLectureMediaAudioReader(reader: reader, output: output, format: format)
    }
}

/// Converts each decoded `CMSampleBuffer` into an `AVAudioPCMBuffer` of the
/// reader's fixed `format`.
private nonisolated final class AVAssetLectureMediaAudioReader: LectureMediaAudioReading {
    let format: AVAudioFormat
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, format: AVAudioFormat) {
        self.reader = reader
        self.output = output
        self.format = format
    }

    func nextBuffer() throws -> AVAudioPCMBuffer? {
        while true {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                guard reader.status == .completed else {
                    throw LectureMediaDecodeError.decodingFailed(
                        reason: reader.error?.localizedDescription ?? "Reading stopped with status \(reader.status.rawValue)."
                    )
                }
                return nil
            }
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0 else { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
                throw LectureMediaDecodeError.decodingFailed(reason: "Unable to allocate a \(frameCount)-frame buffer.")
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: buffer.mutableAudioBufferList
            )
            guard status == noErr else {
                throw LectureMediaDecodeError.decodingFailed(reason: "Decoded audio could not be copied (OSStatus \(status)).")
            }
            return buffer
        }
    }

    func cancel() {
        reader.cancelReading()
    }
}
