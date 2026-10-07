import Foundation

/// The completed session audio a diarizer analyzes: a
/// `LecturePlaybackSource` already proven frame-exact and playable by
/// `LecturePlaybackSourceLoader` (eligible completed session, canonical
/// contiguous chunks, every chunk file present, safe, linear PCM at the
/// session format, with exactly its persisted frame count). A backend reads
/// `source.chunkURLs` in `source.timeline.chunks` order, starting at session
/// frame 0, so its output times are session times. Read-only input — a
/// diarizer never modifies, converts in place, or copies over session files.
nonisolated struct SpeakerDiarizationRequest: Equatable, Sendable {
    let source: LecturePlaybackSource

    var sessionID: UUID { source.timeline.sessionID }
}

/// What a diarizer backend produces: its recipe and raw, backend-labelled
/// segments. Normalization into canonical speaker ranges, audio-source
/// binding, and validation happen outside the backend
/// (`SpeakerDiarizationResult.init(output:source:createdDate:)`).
nonisolated struct SpeakerDiarizationOutput: Equatable, Sendable {
    var provenance: SpeakerDiarizationProvenance
    var segments: [DiarizationBackendSegment]
}

/// The replaceable boundary for a local diarization backend: validated
/// completed-session audio in, raw speaker segments out. No production
/// conformer exists yet. Diarization runs only on completed sessions, and
/// nothing in the recording or transcription paths calls it.
nonisolated protocol SpeakerDiarizing: Sendable {
    func diarize(_ request: SpeakerDiarizationRequest) async throws -> SpeakerDiarizationOutput
}

nonisolated extension SpeakerDiarizationResult {
    /// Normalizes a backend's output against the exact audio it analyzed and
    /// binds the result to that audio's fingerprint. Pure.
    init(output: SpeakerDiarizationOutput, source: LecturePlaybackSource, createdDate: Date) throws {
        let ranges = try DiarizationSegmentNormalizer.normalize(
            output.segments,
            audioDurationSeconds: source.timeline.durationSeconds
        )
        try self.init(
            sessionID: source.timeline.sessionID,
            createdDate: createdDate,
            provenance: output.provenance,
            audioSource: DiarizationAudioSourceFingerprint.compute(source: source),
            ranges: ranges
        )
    }
}
