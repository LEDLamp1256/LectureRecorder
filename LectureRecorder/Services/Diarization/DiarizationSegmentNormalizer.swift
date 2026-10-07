import Foundation

/// One speaker segment as a diarization backend reports it, before
/// normalization: the backend's own label (opaque, and meaningful only
/// within one run) and times in seconds from the start of the session's
/// audio. Backend-neutral: no backend library type appears here.
nonisolated struct DiarizationBackendSegment: Sendable, Equatable {
    var label: String
    var startSeconds: Double
    var endSeconds: Double
}

nonisolated enum DiarizationSegmentNormalizerError: LocalizedError, Sendable, Equatable {
    case invalidAudioDuration
    case malformedSegment(index: Int)

    var errorDescription: String? {
        switch self {
        case .invalidAudioDuration:
            return "The session audio duration is not a finite, positive value."
        case .malformedSegment(let index):
            return "Diarization backend segment \(index) has a non-finite, negative, or reversed time range."
        }
    }
}

/// Turns a backend's segments into validated session-relative
/// `SpeakerTimeRange`s. Pure and deterministic: the same segments, in any
/// input order, always produce the same ranges.
///
/// - Times: a backend time is a session time; ranges are clipped to
///   `[0, audioDurationSeconds]`, where the duration is the frame-exact
///   `LecturePlaybackTimeline.durationSeconds`.
/// - Labels: backend labels become `speaker_0`, `speaker_1`, … in order of
///   each speaker's first speech (earliest start after clipping; ties by
///   the backend label), so IDs never depend on dictionary or input order.
///   A label whose segments are all dropped gets no ID. The numbering
///   carries no meaning — `speaker_0` is not assumed to be the lecturer.
/// - Overlap: ranges of different speakers may overlap and are kept.
///   Overlapping or touching ranges of the *same* speaker are merged.
/// - Malformed input (non-finite, negative, or reversed) fails the whole
///   run rather than being silently repaired; zero-length segments, and
///   segments starting at or past the end of the audio, are dropped.
///
/// The output always satisfies `SpeakerDiarizationResult.validate()`.
nonisolated enum DiarizationSegmentNormalizer {
    static func normalize(
        _ segments: [DiarizationBackendSegment],
        audioDurationSeconds: Double
    ) throws -> [SpeakerTimeRange] {
        guard audioDurationSeconds.isFinite, audioDurationSeconds > 0 else {
            throw DiarizationSegmentNormalizerError.invalidAudioDuration
        }

        var usable: [DiarizationBackendSegment] = []
        for (index, segment) in segments.enumerated() {
            guard segment.startSeconds.isFinite, segment.endSeconds.isFinite,
                  segment.startSeconds >= 0, segment.endSeconds >= segment.startSeconds else {
                throw DiarizationSegmentNormalizerError.malformedSegment(index: index)
            }
            let end = min(segment.endSeconds, audioDurationSeconds)
            guard end > segment.startSeconds else { continue }
            usable.append(DiarizationBackendSegment(label: segment.label, startSeconds: segment.startSeconds, endSeconds: end))
        }

        // Stable IDs by first appearance.
        var firstStartByLabel: [String: Double] = [:]
        for segment in usable {
            firstStartByLabel[segment.label] = min(firstStartByLabel[segment.label] ?? .infinity, segment.startSeconds)
        }
        let orderedLabels: [String] = firstStartByLabel
            .sorted { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key }
            .map(\.key)

        var ranges: [SpeakerTimeRange] = []
        for (index, label) in orderedLabels.enumerated() {
            let speakerID = try SpeakerID(index: index)
            let own = usable
                .filter { $0.label == label }
                .sorted { lhs, rhs in lhs.startSeconds != rhs.startSeconds ? lhs.startSeconds < rhs.startSeconds : lhs.endSeconds < rhs.endSeconds }
            // Merge this speaker's overlapping or touching ranges.
            var current: SpeakerTimeRange?
            for segment in own {
                if var open = current, segment.startSeconds <= open.endSeconds {
                    open.endSeconds = max(open.endSeconds, segment.endSeconds)
                    current = open
                } else {
                    if let open = current { ranges.append(open) }
                    current = SpeakerTimeRange(speakerID: speakerID, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds)
                }
            }
            if let open = current { ranges.append(open) }
        }

        // The order `SpeakerDiarizationResult` requires.
        return ranges.sorted(by: SpeakerTimeRange.canonicallyPrecedes)
    }
}
