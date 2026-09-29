import AVFoundation
import Foundation

nonisolated enum LecturePlaybackSourceError: LocalizedError, Sendable, Equatable {
    case sessionIneligible(SessionEligibilityError)
    case sessionDirectoryUnsafe
    case timeline(LecturePlaybackTimelineError)
    case invalidChannelCount
    case chunkFileMissing(sequenceNumber: Int)
    case chunkFileUnsafe(sequenceNumber: Int)
    case chunkAudioUnreadable(sequenceNumber: Int)
    case chunkFrameCountMismatch(sequenceNumber: Int)
    case chunkFormatMismatch(sequenceNumber: Int)

    var errorDescription: String? {
        switch self {
        case .sessionIneligible(let underlying):
            return underlying.errorDescription
        case .sessionDirectoryUnsafe:
            return "The session directory is missing, a symlink, or not a directory."
        case .timeline(let underlying):
            return underlying.errorDescription
        case .invalidChannelCount:
            return "The session's audio channel count is not playable."
        case .chunkFileMissing(let sequenceNumber):
            return "Chunk #\(sequenceNumber)'s audio file is missing."
        case .chunkFileUnsafe(let sequenceNumber):
            return "Chunk #\(sequenceNumber)'s audio file is a symlink or not a regular file."
        case .chunkAudioUnreadable(let sequenceNumber):
            return "Chunk #\(sequenceNumber)'s audio file cannot be read."
        case .chunkFrameCountMismatch(let sequenceNumber):
            return "Chunk #\(sequenceNumber)'s audio length does not match the session record."
        case .chunkFormatMismatch(let sequenceNumber):
            return "Chunk #\(sequenceNumber)'s audio format does not match the session's format."
        }
    }
}

/// A completed session proven playable: its frame-exact timeline plus the
/// validated, canonical source URL of each chunk (index-aligned with
/// `timeline.chunks`). Construct through `LecturePlaybackSourceLoader`.
nonisolated struct LecturePlaybackSource: Equatable, Sendable {
    let timeline: LecturePlaybackTimeline
    let chunkURLs: [URL]
    let channelCount: UInt32
}

/// Read-only validation of one completed session's durable audio for
/// playback. Never creates, modifies, converts, or copies any file and
/// never writes the manifest.
///
/// Synchronous and performs file I/O (opens every chunk once, then closes
/// it) — run it off the main actor.
nonisolated enum LecturePlaybackSourceLoader {
    /// Validates, in order:
    /// 1. The session directory is a real directory, not a symlink — before
    ///    any filesystem access beneath it (`CompletedSessionPathSafety`
    ///    checks only a path's leaf, so the outer path is proven first).
    /// 2. T4 completed-session eligibility (`SessionTranscriptionEligibility`:
    ///    schema, identity, completed status, path topology, contiguous
    ///    canonical chunk sequence, safe chunks directory, completed chunks).
    /// 3. The frame-exact timeline (`LecturePlaybackTimeline`). A completed
    ///    session with zero chunks passes eligibility but is rejected here
    ///    as `.timeline(.noChunks)`: there is no audio to play.
    /// 4. A positive persisted channel count.
    /// 5. Per chunk, in sequence order: a present, non-symlinked regular
    ///    file; readable as an audio file; linear PCM at exactly the
    ///    session's sample rate and channel count; and a file length equal
    ///    to the persisted `frameCount`.
    static func load(
        expectedSessionID: UUID,
        manifest: SessionManifest,
        sessionPaths: SessionPaths
    ) throws -> LecturePlaybackSource {
        guard CompletedSessionPathSafety.checkExistingDirectory(sessionPaths.sessionDirectory) == .safe else {
            throw LecturePlaybackSourceError.sessionDirectoryUnsafe
        }

        let validated: ValidatedCompletedSession
        do {
            validated = try SessionTranscriptionEligibility.validate(
                expectedSessionID: expectedSessionID,
                manifest: manifest,
                sessionPaths: sessionPaths
            )
        } catch let error as SessionEligibilityError {
            throw LecturePlaybackSourceError.sessionIneligible(error)
        }

        let timeline: LecturePlaybackTimeline
        do {
            timeline = try LecturePlaybackTimeline(manifest: validated.manifest)
        } catch let error as LecturePlaybackTimelineError {
            throw LecturePlaybackSourceError.timeline(error)
        }

        let channelCount = validated.manifest.audioFormat.channelCount
        guard channelCount > 0 else {
            throw LecturePlaybackSourceError.invalidChannelCount
        }

        var chunkURLs: [URL] = []
        chunkURLs.reserveCapacity(timeline.chunks.count)
        for chunk in timeline.chunks {
            let url = validated.artifactPaths.chunkAudioURL(fileName: chunk.fileName)
            let file = try openValidatedChunkFile(
                at: url,
                chunk: chunk,
                sampleRate: timeline.sampleRate,
                channelCount: channelCount
            )
            file.close()
            chunkURLs.append(url)
        }

        return LecturePlaybackSource(timeline: timeline, chunkURLs: chunkURLs, channelCount: channelCount)
    }

    /// Path-safety plus audio-content checks for one chunk file, returning
    /// the opened read-only file. Shared with the AVFoundation backend's
    /// schedule-time re-check, so a file replaced after loading is caught
    /// before it is played.
    static func openValidatedChunkFile(
        at url: URL,
        chunk: LecturePlaybackChunk,
        sampleRate: Double,
        channelCount: UInt32
    ) throws -> AVAudioFile {
        switch CompletedSessionPathSafety.checkExistingRegularFile(url) {
        case .safe:
            break
        case .missing:
            throw LecturePlaybackSourceError.chunkFileMissing(sequenceNumber: chunk.sequenceNumber)
        case .unsafe:
            throw LecturePlaybackSourceError.chunkFileUnsafe(sequenceNumber: chunk.sequenceNumber)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LecturePlaybackSourceError.chunkAudioUnreadable(sequenceNumber: chunk.sequenceNumber)
        }

        let stored = file.fileFormat.streamDescription.pointee
        guard stored.mFormatID == kAudioFormatLinearPCM,
              stored.mSampleRate == sampleRate,
              stored.mChannelsPerFrame == channelCount,
              file.processingFormat.sampleRate == sampleRate,
              file.processingFormat.channelCount == channelCount else {
            file.close()
            throw LecturePlaybackSourceError.chunkFormatMismatch(sequenceNumber: chunk.sequenceNumber)
        }
        guard file.length == AVAudioFramePosition(chunk.frameCount) else {
            file.close()
            throw LecturePlaybackSourceError.chunkFrameCountMismatch(sequenceNumber: chunk.sequenceNumber)
        }
        return file
    }
}
