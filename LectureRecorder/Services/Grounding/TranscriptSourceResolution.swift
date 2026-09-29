import Foundation

/// Session-relative audio time for resolved transcript source, at exactly
/// the precision the recording pipeline persists: whole recording chunks.
/// Offsets are seconds of recorded audio from the session's first frame
/// (`ChunkMetadata.startOffsetSeconds`, derived from cumulative written
/// frames) — not wall-clock time, and never a position *within* a chunk.
/// Nothing here is interpolated from text length, word count, or segment
/// output; a reference identifies whole chunks, so its time is only ever
/// the bounds of those chunks.
nonisolated enum TranscriptSourceTiming: Equatable, Sendable {
    /// From the start of the first referenced chunk to the latest end among
    /// all referenced chunks.
    case chunkBounded(startOffsetSeconds: Double, endOffsetSeconds: Double)
    /// At least one referenced chunk has no trustworthy audio location (see
    /// `ResolvedTranscriptSourceUnit.audioChunk`), or the chunks' starts are
    /// not in sequence order — no truthful time can be derived.
    case unavailable
}

/// The durable recording chunk one resolved transcript unit was
/// transcribed from — what later playback needs to locate its audio.
/// `fileName` is the canonical chunk file name within the session
/// directory; this type never resolves or touches the file itself.
nonisolated struct TranscriptSourceAudioChunk: Equatable, Sendable {
    var fileName: String
    var startOffsetSeconds: Double
    var endOffsetSeconds: Double
}

/// One transcript unit covered by a resolved source reference.
/// `audioChunk` is `nil` when the unit's persisted chunk file name is not
/// the canonical name for its sequence number, or its persisted timing is
/// not a finite, non-negative start with a positive duration — the text
/// still resolves, but no audio location is claimed.
nonisolated struct ResolvedTranscriptSourceUnit: Equatable, Sendable {
    var sequenceNumber: Int
    var text: String
    var audioChunk: TranscriptSourceAudioChunk?
}

/// A persisted `NotesSourceReference` resolved against the transcript it
/// was generated from: the transcript units it covers, in sequence order,
/// and the time those units occupy in the recording. Derived on demand,
/// never persisted.
nonisolated struct ResolvedTranscriptSource: Equatable, Sendable {
    var sessionID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    var firstSequenceNumber: Int
    var lastSequenceNumber: Int
    var units: [ResolvedTranscriptSourceUnit]
    var timing: TranscriptSourceTiming
}

nonisolated enum TranscriptSourceResolutionError: LocalizedError, Sendable, Equatable {
    /// The reference names a different session than the transcript.
    case sessionMismatch
    /// The generated content was built from a transcript whose fingerprint
    /// differs from the transcript loaded now — its sequence numbers may
    /// no longer mean the same text, so it is not resolved at all.
    case transcriptMismatch
    case invertedRange(firstSequenceNumber: Int, lastSequenceNumber: Int)
    case emptySource
    /// The transcript lists the same sequence number more than once, so a
    /// reference to it cannot be resolved unambiguously.
    case duplicateSourceSequenceNumber(Int)
    /// Some sequence number in the reference's range has no transcript unit.
    case outOfRange(availableRange: ClosedRange<Int>)

    var errorDescription: String? {
        switch self {
        case .sessionMismatch:
            return "The source reference's session ID does not match the transcript it was resolved against."
        case .transcriptMismatch:
            return "The source reference was generated from a different transcript than the one currently loaded."
        case .invertedRange(let first, let last):
            return "Source reference range is inverted: first (\(first)) is greater than last (\(last))."
        case .emptySource:
            return "The transcript has no units to reference."
        case .duplicateSourceSequenceNumber(let sequenceNumber):
            return "The transcript contains more than one unit for chunk #\(sequenceNumber)."
        case .outOfRange(let availableRange):
            return "Source reference falls outside the transcript's available range \(availableRange)."
        }
    }
}

/// Resolves persisted transcript source references into transcript
/// material and recording time. The single shared boundary for every
/// generated-content path back to the transcript: Notes items resolve their
/// own references here, and Summary reaches the transcript through the
/// Notes items it cites — never through a resolver of its own.
///
/// Pure and read-only: takes value inputs, returns a derived value, and
/// never repairs, reinterprets, or rewrites a reference. `snapshot` is
/// expected to come from `NotesTranscriptSourceLoading`, which computes its
/// fingerprint fresh from durable transcription state.
nonisolated enum TranscriptSourceResolver {
    /// - Parameters:
    ///   - reference: A persisted source reference, e.g. from a
    ///     `LectureNoteItem`.
    ///   - fingerprint: The transcript fingerprint recorded by the artifact
    ///     that holds `reference` (e.g.
    ///     `LectureNotesDocument.transcriptFingerprint`).
    ///   - snapshot: The session's current transcript.
    static func resolve(
        _ reference: NotesSourceReference,
        generatedFrom fingerprint: TranscriptSourceFingerprint,
        in snapshot: NotesTranscriptSourceSnapshot
    ) throws -> ResolvedTranscriptSource {
        guard reference.sessionID == snapshot.sessionID else {
            throw TranscriptSourceResolutionError.sessionMismatch
        }
        guard fingerprint == snapshot.fingerprint else {
            throw TranscriptSourceResolutionError.transcriptMismatch
        }
        let first = reference.firstSequenceNumber
        let last = reference.lastSequenceNumber
        guard first <= last else {
            throw TranscriptSourceResolutionError.invertedRange(firstSequenceNumber: first, lastSequenceNumber: last)
        }

        var unitsBySequence: [Int: NotesTranscriptSourceUnit] = [:]
        for unit in snapshot.units {
            guard unitsBySequence.updateValue(unit, forKey: unit.sequenceNumber) == nil else {
                throw TranscriptSourceResolutionError.duplicateSourceSequenceNumber(unit.sequenceNumber)
            }
        }
        guard
            let minSequence = unitsBySequence.keys.min(),
            let maxSequence = unitsBySequence.keys.max()
        else {
            throw TranscriptSourceResolutionError.emptySource
        }
        let outOfRange = TranscriptSourceResolutionError.outOfRange(availableRange: minSequence...maxSequence)

        // Persisted bounds are untrusted: bound the work by the number of
        // real units, never by the numeric width of the requested range.
        let (span, overflowed) = last.subtractingReportingOverflow(first)
        guard !overflowed, span < unitsBySequence.count else {
            throw outOfRange
        }

        var resolvedUnits: [ResolvedTranscriptSourceUnit] = []
        resolvedUnits.reserveCapacity(span + 1)
        for sequenceNumber in first...last {
            guard let unit = unitsBySequence[sequenceNumber] else {
                throw outOfRange
            }
            resolvedUnits.append(ResolvedTranscriptSourceUnit(
                sequenceNumber: unit.sequenceNumber,
                text: unit.text,
                audioChunk: audioChunk(for: unit)
            ))
        }

        return ResolvedTranscriptSource(
            sessionID: snapshot.sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            firstSequenceNumber: first,
            lastSequenceNumber: last,
            units: resolvedUnits,
            timing: timing(for: resolvedUnits)
        )
    }

    private static func audioChunk(for unit: NotesTranscriptSourceUnit) -> TranscriptSourceAudioChunk? {
        guard
            unit.chunkFileName == TranscriptionArtifactPaths.canonicalChunkFileName(for: unit.sequenceNumber),
            unit.startOffsetSeconds.isFinite,
            unit.startOffsetSeconds >= 0,
            unit.durationSeconds.isFinite,
            unit.durationSeconds > 0
        else {
            return nil
        }
        let end = unit.startOffsetSeconds + unit.durationSeconds
        guard end.isFinite else {
            return nil
        }
        return TranscriptSourceAudioChunk(
            fileName: unit.chunkFileName,
            startOffsetSeconds: unit.startOffsetSeconds,
            endOffsetSeconds: end
        )
    }

    private static func timing(for units: [ResolvedTranscriptSourceUnit]) -> TranscriptSourceTiming {
        let chunks = units.compactMap(\.audioChunk)
        guard
            chunks.count == units.count,
            let firstChunk = chunks.first,
            let latestEnd = chunks.map(\.endOffsetSeconds).max(),
            zip(chunks, chunks.dropFirst()).allSatisfy({ $0.startOffsetSeconds <= $1.startOffsetSeconds })
        else {
            return .unavailable
        }
        // The last chunk need not end last in malformed persisted timing;
        // the envelope must still bound every resolved chunk.
        return .chunkBounded(
            startOffsetSeconds: firstChunk.startOffsetSeconds,
            endOffsetSeconds: latestEnd
        )
    }
}
