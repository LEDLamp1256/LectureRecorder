import Foundation

/// How much of one transcript item a speaker's ranges cover, in exact
/// session frames.
nonisolated struct SpeakerOverlap: Equatable, Sendable {
    var speakerID: SpeakerID
    var frames: Int64
}

/// The alignment outcome for one transcript item. When the evidence does
/// not single out one speaker, the aligner says so instead of choosing one.
nonisolated enum SpeakerAttribution: Equatable, Sendable {
    /// Exactly one speaker has the largest overlap, and it meets the
    /// minimum-overlap threshold.
    case speaker(SpeakerID)
    /// Two or more speakers tie for the largest overlap (within the tie
    /// tolerance), listed in label order.
    case ambiguous([SpeakerID])
    /// The item is eligible, but no speaker overlaps it enough to attribute
    /// it — including no overlap at all (silence) or an empty item.
    case unknown
    /// The item's timing is not precise enough to attribute to a speaker at
    /// all: a `.chunkStart` fallback spans its whole ~30-second chunk, and
    /// naming one speaker for it would claim "one chunk = one speaker".
    case ineligible
}

/// One alignment per `TranscriptPlaybackItem`, joined back to it by its
/// existing identity — never a new transcript identity.
nonisolated struct SpeakerItemAlignment: Equatable, Sendable {
    var itemID: TranscriptPlaybackItem.ID
    var attribution: SpeakerAttribution
    /// Every speaker with positive overlap, largest first, ties ordered by
    /// label. Empty for `.ineligible` items, which are never measured.
    var overlaps: [SpeakerOverlap]
}

nonisolated enum SpeakerTranscriptAlignmentError: LocalizedError, Equatable, Sendable {
    case invalidResult(SpeakerDiarizationValidationError)
    /// The result, navigation, and audio source are not all one session's.
    case sessionMismatch
    case sampleRateMismatch
    /// The result was not produced from this audio source.
    case audioSourceMismatch

    var errorDescription: String? {
        switch self {
        case .invalidResult(let underlying): return underlying.errorDescription
        case .sessionMismatch: return "The diarization result, transcript, and audio do not belong to the same session."
        case .sampleRateMismatch: return "The transcript navigation and audio use different sample rates."
        case .audioSourceMismatch: return "The diarization result was not produced from this session's audio."
        }
    }
}

/// Deterministically labels transcript playback items with the speaker
/// whose diarized speech overlaps them most. Pure integer arithmetic over
/// the frame-exact session timeline: no model, no transcript text, and
/// nothing is written back to the transcript. Item identity and order are
/// the input's, unchanged.
///
/// Frame domain: each `SpeakerTimeRange` boundary is converted once to a
/// session frame with `LecturePlaybackTimeline.sessionFrame(forSessionTime:)`
/// — nearest frame, ties away from zero, clamped to
/// `0...totalFrameCount` — the same rounding `TranscriptPlaybackNavigationBuilder`
/// uses for transcript segment boundaries, so a speaker change and a
/// segment boundary at the same instant land on the same frame. A range
/// shorter than half a frame may round to empty and then counts for
/// nobody. Item and range intervals are both half-open
/// `[startSessionFrame, endSessionFrame)`, so ranges that merely touch an
/// item's edge contribute zero frames. Accumulated overlaps are never
/// converted back to seconds.
///
/// Policy, per item:
/// 1. A `.chunkStart` item is `.ineligible` and is not measured.
/// 2. Each speaker's overlap is the total frame count of the intersection
///    of the item with that speaker's ranges. Overlapped speech of
///    different speakers counts for each; silence counts for nobody. A
///    validated result never overlaps one speaker's ranges, and rounding
///    is monotone, so this never double-counts.
/// 3. If the largest overlap is below `minimumOverlapFrames` (including no
///    overlap, or an empty item), the item is `.unknown`.
/// 4. If more than one speaker is within `tieToleranceFrames` of the
///    largest overlap, the item is `.ambiguous` — never broken arbitrarily.
/// 5. Otherwise the item is `.speaker(dominant)`.
nonisolated struct SpeakerTranscriptAligner: Sendable {
    static let defaultMinimumOverlapSeconds = 0.5
    /// Overlaps within 1 ms of each other are treated as equal.
    static let tieToleranceSeconds = 0.001

    let minimumOverlapSeconds: Double

    init(minimumOverlapSeconds: Double = Self.defaultMinimumOverlapSeconds) {
        precondition(minimumOverlapSeconds.isFinite && minimumOverlapSeconds > 0, "the overlap threshold must be positive")
        self.minimumOverlapSeconds = minimumOverlapSeconds
    }

    /// The smallest whole number of frames that is at least `seconds`
    /// (and at least one frame).
    static func minimumOverlapFrames(seconds: Double, sampleRate: Double) -> Int64 {
        max(1, Int64((seconds * sampleRate).rounded(.up)))
    }

    /// The largest whole number of frames that is at most
    /// `tieToleranceSeconds` — an exact frame tie is always ambiguous.
    static func tieToleranceFrames(sampleRate: Double) -> Int64 {
        max(0, Int64((tieToleranceSeconds * sampleRate).rounded(.down)))
    }

    /// `range` as a half-open session-frame interval on `timeline`; empty
    /// (`end <= start`) when it rounds to less than one frame.
    static func sessionFrameInterval(
        of range: SpeakerTimeRange,
        on timeline: LecturePlaybackTimeline
    ) -> (start: Int64, end: Int64) {
        // A validated range is finite, so conversion never returns nil.
        let start = timeline.sessionFrame(forSessionTime: range.startSeconds) ?? 0
        let end = timeline.sessionFrame(forSessionTime: range.endSeconds) ?? 0
        return (start, end)
    }

    /// One alignment per navigation item, in navigation order.
    func align(
        _ navigation: TranscriptPlaybackNavigation,
        with result: SpeakerDiarizationResult,
        source: LecturePlaybackSource
    ) throws -> [SpeakerItemAlignment] {
        let timeline = source.timeline
        do {
            try result.validate(against: timeline)
        } catch let error as SpeakerDiarizationValidationError {
            throw SpeakerTranscriptAlignmentError.invalidResult(error)
        }
        guard result.sessionID == timeline.sessionID, navigation.sessionID == timeline.sessionID else {
            throw SpeakerTranscriptAlignmentError.sessionMismatch
        }
        guard navigation.sampleRate == timeline.sampleRate else {
            throw SpeakerTranscriptAlignmentError.sampleRateMismatch
        }
        guard result.audioSource == DiarizationAudioSourceFingerprint.compute(source: source) else {
            throw SpeakerTranscriptAlignmentError.audioSourceMismatch
        }

        // Converted once; still ordered by start because rounding is monotone.
        let frameRanges = result.ranges.compactMap { range -> (speakerID: SpeakerID, start: Int64, end: Int64)? in
            let interval = Self.sessionFrameInterval(of: range, on: timeline)
            return interval.end > interval.start ? (range.speakerID, interval.start, interval.end) : nil
        }
        let minimumFrames = Self.minimumOverlapFrames(seconds: minimumOverlapSeconds, sampleRate: timeline.sampleRate)
        let toleranceFrames = Self.tieToleranceFrames(sampleRate: timeline.sampleRate)

        return navigation.items.map { item in
            guard case .timedSegment = item.target else {
                return SpeakerItemAlignment(itemID: item.id, attribution: .ineligible, overlaps: [])
            }

            var framesBySpeaker: [SpeakerID: Int64] = [:]
            if item.endSessionFrame > item.startSessionFrame {
                for range in frameRanges {
                    if range.start >= item.endSessionFrame { break }
                    let overlap = min(range.end, item.endSessionFrame) - max(range.start, item.startSessionFrame)
                    if overlap > 0 {
                        framesBySpeaker[range.speakerID, default: 0] += overlap
                    }
                }
            }

            let overlaps = framesBySpeaker
                .map { SpeakerOverlap(speakerID: $0.key, frames: $0.value) }
                .sorted { $0.frames != $1.frames ? $0.frames > $1.frames : $0.speakerID < $1.speakerID }

            let attribution: SpeakerAttribution
            if let largest = overlaps.first?.frames, largest >= minimumFrames {
                let leaders = overlaps
                    .filter { largest - $0.frames <= toleranceFrames }
                    .map(\.speakerID)
                    .sorted()
                attribution = leaders.count == 1 ? .speaker(leaders[0]) : .ambiguous(leaders)
            } else {
                attribution = .unknown
            }
            return SpeakerItemAlignment(itemID: item.id, attribution: attribution, overlaps: overlaps)
        }
    }
}
