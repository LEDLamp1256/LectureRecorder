import Foundation

nonisolated enum DiarizationAudioStagingError: LocalizedError, Sendable, Equatable {
    case chunkURLCountMismatch
    case unsupportedSampleRate
    case timelineTooLong
    case chunkDecodeFailed(sequenceNumber: Int)
    case chunkLengthMismatch(sequenceNumber: Int, expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .chunkURLCountMismatch:
            return "The session audio source does not have exactly one file per chunk."
        case .unsupportedSampleRate:
            return "The session's audio sample rate is not a whole number of samples per second."
        case .timelineTooLong:
            return "The session audio is too long to stage for speaker diarization."
        case .chunkDecodeFailed(let sequenceNumber):
            return "Audio chunk #\(sequenceNumber) could not be decoded for speaker diarization."
        case .chunkLengthMismatch(let sequenceNumber, let expected, let actual):
            return "Audio chunk #\(sequenceNumber) decoded to \(actual) samples where its session position requires \(expected)."
        }
    }
}

/// A whole session's audio as one 16 kHz mono buffer whose sample 0 is
/// session frame 0, so a diarizer's times over this buffer are session
/// times. Held in memory only (about 3.8 MB per minute); nothing is
/// written to disk.
nonisolated struct StagedDiarizationAudio: Sendable, Equatable {
    static let sampleRate = 16_000

    var samples: [Float]

    var durationSeconds: Double { Double(samples.count) / Double(Self.sampleRate) }
}

/// Builds `StagedDiarizationAudio` from a validated `LecturePlaybackSource`.
///
/// Placement authority is the source's integer session-frame timeline
/// (`LecturePlaybackTimeline`, from persisted `frameCount`s) — never
/// `startOffsetSeconds`, accumulated durations, or transcript times. Every
/// chunk occupies exactly
/// `[destinationFrame(chunk.startFrame), destinationFrame(chunk.endFrame))`
/// of the output, where `destinationFrame` maps a source session frame to
/// the nearest 16 kHz frame in exact integer arithmetic. A chunk's place
/// therefore never depends on how many samples an earlier chunk decoded to,
/// so resampling rounding cannot accumulate across chunks.
///
/// Each chunk is decoded and resampled on its own by the existing,
/// format-validating `WhisperAudioDecoder`, whose output length can differ
/// from the mapped interval by a sample or two. Within
/// `maximumBoundaryReconciliationSamples`, a short decode is padded with
/// silence and a long one trimmed at the interval's end; anything larger
/// fails the staging rather than shifting the timeline.
///
/// Accepts any validated source — recorded or imported, whatever its
/// terminal status — since `LecturePlaybackSourceLoader` already decided
/// eligibility. Synchronous file I/O and decoding: call it off the main
/// actor. Checks for cancellation before every chunk. Only reads chunks.
nonisolated struct DiarizationAudioStager: Sendable {
    typealias ChunkDecoder = @Sendable (URL, WhisperAudioSourceMetadata) throws -> [Float]

    /// One millisecond at 16 kHz.
    static let maximumBoundaryReconciliationSamples = 16

    private let decodeChunk: ChunkDecoder

    init(decodeChunk: @escaping ChunkDecoder = { url, metadata in
        try WhisperAudioDecoder.decode(url: url, source: metadata).samples
    }) {
        self.decodeChunk = decodeChunk
    }

    func stage(_ source: LecturePlaybackSource) throws -> StagedDiarizationAudio {
        let timeline = source.timeline
        guard source.chunkURLs.count == timeline.chunks.count else {
            throw DiarizationAudioStagingError.chunkURLCountMismatch
        }
        let sourceRate = try Self.integralSampleRate(timeline.sampleRate)
        let totalSamples = try Self.destinationFrame(forSessionFrame: timeline.totalFrameCount, sourceSampleRate: sourceRate)

        var samples = [Float](repeating: 0, count: totalSamples)
        for (chunk, url) in zip(timeline.chunks, source.chunkURLs) {
            try Task.checkCancellation()

            let start = try Self.destinationFrame(forSessionFrame: chunk.startFrame, sourceSampleRate: sourceRate)
            let end = try Self.destinationFrame(forSessionFrame: chunk.endFrame, sourceSampleRate: sourceRate)
            let expected = end - start

            let decoded: [Float]
            do {
                decoded = try decodeChunk(url, WhisperAudioSourceMetadata(
                    frameCount: Int(chunk.frameCount),
                    durationSeconds: Double(chunk.frameCount) / timeline.sampleRate,
                    sampleRate: timeline.sampleRate,
                    channelCount: source.channelCount,
                    // Every session chunk is written as packed Float32 PCM
                    // (`AudioFormatBridge`); the decoder checks the file's
                    // physical format against this and fails otherwise.
                    bitsPerChannel: 32,
                    formatIdentifier: "lpcm-float32"
                ))
            } catch let error as CancellationError {
                throw error
            } catch {
                throw DiarizationAudioStagingError.chunkDecodeFailed(sequenceNumber: chunk.sequenceNumber)
            }

            guard abs(decoded.count - expected) <= Self.maximumBoundaryReconciliationSamples else {
                throw DiarizationAudioStagingError.chunkLengthMismatch(
                    sequenceNumber: chunk.sequenceNumber, expected: expected, actual: decoded.count
                )
            }
            let copied = min(decoded.count, expected)
            samples.replaceSubrange(start..<(start + copied), with: decoded[0..<copied])
        }
        return StagedDiarizationAudio(samples: samples)
    }

    /// The 16 kHz output frame for a source session frame: `frame * 16000 /
    /// sourceSampleRate` rounded to nearest, halves up — the same rule
    /// `LecturePlaybackTimeline.sessionFrame(forSessionTime:)` uses — in
    /// exact integer arithmetic. Monotonic, and maps frame 0 to 0.
    static func destinationFrame(forSessionFrame frame: Int64, sourceSampleRate: Int64) throws -> Int {
        precondition(frame >= 0 && sourceSampleRate > 0)
        let target = Int64(StagedDiarizationAudio.sampleRate)
        let scaled = frame.multipliedReportingOverflow(by: 2 * target)
        let numerator = scaled.partialValue.addingReportingOverflow(sourceSampleRate)
        guard !scaled.overflow, !numerator.overflow else {
            throw DiarizationAudioStagingError.timelineTooLong
        }
        let destination = numerator.partialValue / (2 * sourceSampleRate)
        guard destination <= Int64(Int.max) else { throw DiarizationAudioStagingError.timelineTooLong }
        return Int(destination)
    }

    /// Session sample rates are whole numbers (44.1 kHz, 48 kHz, ...);
    /// exact frame mapping requires it.
    static func integralSampleRate(_ sampleRate: Double) throws -> Int64 {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 10_000_000,
              sampleRate.rounded(.towardZero) == sampleRate else {
            throw DiarizationAudioStagingError.unsupportedSampleRate
        }
        return Int64(sampleRate)
    }
}
