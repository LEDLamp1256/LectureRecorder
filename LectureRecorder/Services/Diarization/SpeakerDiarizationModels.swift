import Foundation

/// An opaque speaker label that is stable only within one
/// `SpeakerDiarizationResult`: exactly `speaker_<index>`, where `index` is
/// a decimal integer with no sign or leading zeros. It says nothing about
/// who the speaker is or what role they play: `speaker_0` is not "the
/// lecturer", and the same label in two different results need not refer
/// to the same person. Display names ("Speaker 1") are a presentation
/// concern and are never persisted.
///
/// Ordered by `index`, so `speaker_2` sorts before `speaker_10`.
nonisolated struct SpeakerID: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    static let prefix = "speaker_"
    static let maximumIndex = 999_999

    let index: Int

    var rawValue: String { "\(Self.prefix)\(index)" }

    init(index: Int) throws {
        guard (0...Self.maximumIndex).contains(index) else {
            throw SpeakerDiarizationValidationError.invalidSpeakerID
        }
        self.index = index
    }

    /// Accepts only the canonical `speaker_<index>` spelling, so a label can
    /// never carry transcript text, paths, or display prose into the
    /// sidecar, and two spellings can never name the same speaker.
    init(_ rawValue: String) throws {
        guard rawValue.hasPrefix(Self.prefix) else {
            throw SpeakerDiarizationValidationError.invalidSpeakerID
        }
        let digits = rawValue.utf8.dropFirst(Self.prefix.utf8.count)
        let maximumDigits = String(Self.maximumIndex).utf8.count
        guard !digits.isEmpty,
              digits.count <= maximumDigits,
              digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              digits.count == 1 || digits.first != UInt8(ascii: "0"),
              let index = Int(String(decoding: digits, as: UTF8.self)) else {
            throw SpeakerDiarizationValidationError.invalidSpeakerID
        }
        try self.init(index: index)
    }

    init(from decoder: Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: SpeakerID, rhs: SpeakerID) -> Bool {
        lhs.index < rhs.index
    }

    var description: String { rawValue }
}

/// One interval, in seconds from the start of the session's audio, during
/// which the diarizer attributed speech to `speakerID`. Half-open:
/// `[startSeconds, endSeconds)`.
///
/// Seconds are the diarizer's natural unit and are what is persisted. They
/// are not a second audio timeline: consumers place a range on the
/// frame-exact `LecturePlaybackTimeline` by converting each boundary once
/// with `LecturePlaybackTimeline.sessionFrame(forSessionTime:)`.
nonisolated struct SpeakerTimeRange: Codable, Equatable, Sendable {
    var speakerID: SpeakerID
    var startSeconds: Double
    var endSeconds: Double

    /// Finite, nonnegative, and nonempty.
    func validate(index: Int) throws {
        guard startSeconds.isFinite, endSeconds.isFinite else {
            throw SpeakerDiarizationValidationError.nonFiniteBoundary(index: index)
        }
        guard startSeconds >= 0 else {
            throw SpeakerDiarizationValidationError.negativeStart(index: index)
        }
        guard endSeconds > startSeconds else {
            throw SpeakerDiarizationValidationError.emptyOrReversedRange(index: index)
        }
    }

    /// The canonical range order: start, then end, then speaker.
    static func canonicallyPrecedes(_ lhs: SpeakerTimeRange, _ rhs: SpeakerTimeRange) -> Bool {
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
        if lhs.endSeconds != rhs.endSeconds { return lhs.endSeconds < rhs.endSeconds }
        return lhs.speakerID < rhs.speakerID
    }
}

/// Which diarizer recipe produced a result, so a result from one backend or
/// configuration is never silently reinterpreted as another's and can be
/// regenerated when the backend changes. Must not contain local paths.
nonisolated struct SpeakerDiarizationProvenance: Codable, Equatable, Sendable {
    var backendIdentifier: String
    var backendVersion: String
    var configurationIdentifier: String
}

nonisolated enum SpeakerDiarizationValidationError: LocalizedError, Equatable, Sendable {
    case invalidSpeakerID
    case nonFiniteBoundary(index: Int)
    case negativeStart(index: Int)
    case emptyOrReversedRange(index: Int)
    case unordered(index: Int)
    case overlappingSameSpeaker(index: Int)
    case nonDenseSpeakerIDs
    case speakerNumberingNotByFirstSpeech
    case rangeBeyondAudio(index: Int)
    case emptyProvenanceField(String)
    case malformedAudioSourceFingerprint
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSpeakerID: return "A speaker label is not a canonical speaker_<index> identifier."
        case .nonFiniteBoundary(let index): return "Speaker range \(index) has a non-finite boundary."
        case .negativeStart(let index): return "Speaker range \(index) starts before the recording."
        case .emptyOrReversedRange(let index): return "Speaker range \(index) is empty or ends before it starts."
        case .unordered(let index): return "Speaker range \(index) is out of order."
        case .overlappingSameSpeaker(let index): return "Speaker range \(index) overlaps an earlier range of the same speaker."
        case .nonDenseSpeakerIDs: return "Speaker labels are not exactly speaker_0 through speaker_N."
        case .speakerNumberingNotByFirstSpeech: return "Speaker labels are not numbered in order of first speech."
        case .rangeBeyondAudio(let index): return "Speaker range \(index) ends after the session audio."
        case .emptyProvenanceField(let field): return "Diarization provenance field \(field) is empty."
        case .malformedAudioSourceFingerprint: return "The diarization audio-source fingerprint is malformed."
        case .unsupportedSchemaVersion(let version): return "Unsupported diarization result schema version \(version)."
        }
    }
}

/// The complete diarization of one session's audio: who spoke when.
/// Derived, regenerable sidecar data — the transcript, its rows, their
/// timestamps, and Notes/Summary source references never depend on it.
///
/// `audioSource` binds the result to the exact terminal session audio it
/// was produced from; a result whose fingerprint does not match the
/// session's current audio is never used.
///
/// Invariants (checked by `validate()`):
/// - every range is finite, nonnegative, and nonempty;
/// - ranges are in canonical order (`SpeakerTimeRange.canonicallyPrecedes`
///   or equal);
/// - ranges of *different* speakers may overlap (people talk over each
///   other); ranges of the *same* speaker may touch but not overlap, so
///   per-speaker speech time is never double-counted;
/// - speaker IDs are exactly `speaker_0..<count`, numbered in order of each
///   speaker's first speech (nondecreasing first start).
///
/// Holds no transcript identities and no display labels.
nonisolated struct SpeakerDiarizationResult: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: UUID
    var createdDate: Date
    var provenance: SpeakerDiarizationProvenance
    var audioSource: DiarizationAudioSourceFingerprint
    var ranges: [SpeakerTimeRange]

    /// Builds a validated, current-schema result.
    init(
        sessionID: UUID,
        createdDate: Date,
        provenance: SpeakerDiarizationProvenance,
        audioSource: DiarizationAudioSourceFingerprint,
        ranges: [SpeakerTimeRange]
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.createdDate = createdDate
        self.provenance = provenance
        self.audioSource = audioSource
        self.ranges = ranges
        try validate()
    }

    /// The distinct speaker labels present, in label order.
    var speakerIDs: [SpeakerID] {
        Array(Set(ranges.map(\.speakerID))).sorted()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SpeakerDiarizationValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        for (field, value) in [
            ("backendIdentifier", provenance.backendIdentifier),
            ("backendVersion", provenance.backendVersion),
            ("configurationIdentifier", provenance.configurationIdentifier),
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SpeakerDiarizationValidationError.emptyProvenanceField(field)
        }
        guard audioSource.isWellFormed else {
            throw SpeakerDiarizationValidationError.malformedAudioSourceFingerprint
        }

        var latestEndBySpeaker: [SpeakerID: Double] = [:]
        var firstStartBySpeaker: [SpeakerID: Double] = [:]
        for (index, range) in ranges.enumerated() {
            try range.validate(index: index)
            if index > 0, SpeakerTimeRange.canonicallyPrecedes(range, ranges[index - 1]) {
                throw SpeakerDiarizationValidationError.unordered(index: index)
            }
            if let latestEnd = latestEndBySpeaker[range.speakerID], range.startSeconds < latestEnd {
                throw SpeakerDiarizationValidationError.overlappingSameSpeaker(index: index)
            }
            latestEndBySpeaker[range.speakerID] = range.endSeconds
            if firstStartBySpeaker[range.speakerID] == nil {
                firstStartBySpeaker[range.speakerID] = range.startSeconds
            }
        }

        let speakers = firstStartBySpeaker.keys.sorted()
        guard speakers.map(\.index) == Array(0..<speakers.count) else {
            throw SpeakerDiarizationValidationError.nonDenseSpeakerIDs
        }
        for (earlier, later) in zip(speakers, speakers.dropFirst())
        where firstStartBySpeaker[earlier]! > firstStartBySpeaker[later]! {
            throw SpeakerDiarizationValidationError.speakerNumberingNotByFirstSpeech
        }
    }

    /// `validate()` plus the checks that need the session's audio: every
    /// range ends within the audio's duration. Does not compare
    /// `audioSource`; callers do that explicitly so a mismatch is reported
    /// as such.
    func validate(against timeline: LecturePlaybackTimeline) throws {
        try validate()
        let duration = timeline.durationSeconds
        if let index = ranges.firstIndex(where: { $0.endSeconds > duration }) {
            throw SpeakerDiarizationValidationError.rangeBeyondAudio(index: index)
        }
    }
}
