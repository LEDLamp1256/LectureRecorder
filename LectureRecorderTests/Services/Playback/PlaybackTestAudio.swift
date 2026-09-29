import AVFoundation
import XCTest
@testable import LectureRecorder

/// Small deterministic on-disk sessions for playback tests. Every sample
/// encodes its own session frame (`frame * sampleStep`), so rendered audio
/// can be checked for exact continuity.
enum PlaybackTestAudio {
    static let sampleStep: Float = 1e-5

    static func sampleValue(forSessionFrame frame: Int64) -> Float {
        Float(frame) * sampleStep
    }

    /// Writes one float32 non-interleaved CAF whose samples are
    /// `sampleValue(forSessionFrame: firstSessionFrame + i)` on every channel.
    static func writeChunk(
        to url: URL,
        frameCount: Int,
        firstSessionFrame: Int64,
        sampleRate: Double = 44_100,
        channelCount: AVAudioChannelCount = 1
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false
        ))
        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
            )
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(channelCount) {
                for frame in 0..<frameCount {
                    channels[channel][frame] = sampleValue(forSessionFrame: firstSessionFrame + Int64(frame))
                }
            }
            try file.write(from: buffer)
            file.close()
        }
    }

    /// Creates `<root>/<session>/chunks/` with one CAF per manifest chunk
    /// (using each chunk's persisted frame count) and returns the manifest
    /// and its paths.
    static func makeSession(
        root: URL,
        frameCounts: [Int],
        sampleRate: Double = 44_100
    ) throws -> (manifest: SessionManifest, paths: SessionPaths) {
        let manifest = PlaybackTestManifest.make(sampleRate: sampleRate, frameCounts: frameCounts)
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: manifest.sessionID)
        var firstFrame: Int64 = 0
        for chunk in manifest.chunks {
            try writeChunk(
                to: paths.chunksDirectory.appendingPathComponent(chunk.fileName),
                frameCount: chunk.frameCount,
                firstSessionFrame: firstFrame,
                sampleRate: sampleRate
            )
            firstFrame += Int64(chunk.frameCount)
        }
        return (manifest, paths)
    }

    static func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LecturePlaybackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
