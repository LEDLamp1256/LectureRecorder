import CryptoKit
import Foundation

/// One ordered unit of transcript text available to notes generation,
/// derived directly from one canonical, completed transcription chunk.
/// `sequenceNumber`/`chunkFileName` tie this unit back to the authoritative
/// per-chunk transcription artifacts (`TranscriptionSourceSnapshot`) —
/// notes code never re-derives chunk identity independently.
/// `startOffsetSeconds`/`durationSeconds` are the same chunk-level (not
/// word-level) timing the recording pipeline already produces; this type
/// never claims finer-grained alignment than that.
nonisolated struct NotesTranscriptSourceUnit: Codable, Equatable, Sendable {
    var sequenceNumber: Int
    var chunkFileName: String
    var text: String
    var startOffsetSeconds: Double
    var durationSeconds: Double
}

/// A deterministic, collision-resistant identity for the exact transcript
/// content one notes generation was built from — SHA-256 is relied upon as
/// a persisted collision-resistant digest of exactly the covered fields,
/// not as a mathematical guarantee that no two distinct inputs could ever
/// produce the same digest. Two snapshots with an identical fingerprint
/// are, for every practical purpose, guaranteed to have identical values
/// for every field `compute` actually hashes; nothing outside that list is
/// detected — see `compute`.
nonisolated struct TranscriptSourceFingerprint: Codable, Equatable, Hashable, Sendable {
    static let currentAlgorithmVersion = 1

    var algorithmVersion: Int
    var digestHex: String

    /// Computes a SHA-256 digest over an explicit, unambiguous binary
    /// encoding of exactly:
    ///
    /// 1. a domain-separation/version tag (`"LectureRecorder.
    ///    TranscriptSourceFingerprint.v<algorithmVersion>"`), so this
    ///    fingerprint's byte stream can never collide with an unrelated
    ///    hash or a differently-encoded future algorithm version;
    /// 2. `sessionID` (as its canonical UUID string);
    /// 3. the total unit count;
    /// 4. for each unit — sorted ascending by `sequenceNumber` first, so
    ///    filesystem or caller enumeration order can never affect the
    ///    result — its `sequenceNumber`, `chunkFileName`, `text`,
    ///    `startOffsetSeconds`, and `durationSeconds`.
    ///
    /// Every variable-length field (`sessionID`'s string form,
    /// `chunkFileName`, `text`) is prefixed with its own exact UTF-8 byte
    /// length, encoded as a fixed 8-byte big-endian integer, before its
    /// bytes — never joined with a delimiter character. This makes field
    /// boundaries a function of an explicit length prefix, never of
    /// scanning for a separator, so no byte value (including NUL) that may
    /// appear inside transcript text can ever be mistaken for a field
    /// boundary or used to engineer a collision between two different
    /// logical inputs. `sequenceNumber` is encoded as a fixed 8-byte
    /// big-endian `Int64`; `startOffsetSeconds`/`durationSeconds` are
    /// encoded as their raw IEEE-754 bit pattern (also fixed 8 bytes,
    /// big-endian) — never as a locale- or precision-dependent string.
    ///
    /// Deliberately NOT covered: `audioFormat`, job/attempt metadata,
    /// completion timestamps, or anything filesystem-derived (mtimes,
    /// directory listing order). A change to any of those does not change
    /// this fingerprint. `algorithmVersion` is bumped whenever this
    /// coverage or encoding changes, so a persisted fingerprint's meaning
    /// is never silently reinterpreted.
    static func compute(sessionID: UUID, units: [NotesTranscriptSourceUnit]) -> TranscriptSourceFingerprint {
        var hasher = SHA256()

        func updateUInt64(_ value: UInt64) {
            var bigEndian = value.bigEndian
            let bytes = withUnsafeBytes(of: &bigEndian) { Array($0) }
            hasher.update(data: Data(bytes))
        }
        func updateInt64(_ value: Int64) {
            updateUInt64(UInt64(bitPattern: value))
        }
        func updateDouble(_ value: Double) {
            updateUInt64(value.bitPattern)
        }
        func updateLengthPrefixedString(_ string: String) {
            let bytes = Array(string.utf8)
            updateUInt64(UInt64(bytes.count))
            hasher.update(data: Data(bytes))
        }

        updateLengthPrefixedString("LectureRecorder.TranscriptSourceFingerprint.v\(currentAlgorithmVersion)")
        updateLengthPrefixedString(sessionID.uuidString)

        let sortedUnits = units.sorted { $0.sequenceNumber < $1.sequenceNumber }
        updateUInt64(UInt64(sortedUnits.count))
        for unit in sortedUnits {
            updateInt64(Int64(unit.sequenceNumber))
            updateLengthPrefixedString(unit.chunkFileName)
            updateLengthPrefixedString(unit.text)
            updateDouble(unit.startOffsetSeconds)
            updateDouble(unit.durationSeconds)
        }

        let digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return TranscriptSourceFingerprint(algorithmVersion: currentAlgorithmVersion, digestHex: digestHex)
    }
}

/// The immutable logical input to one note generation: every ordered
/// transcript source unit for a session's fully completed, valid
/// transcript, plus a fingerprint of exactly that content. Constructing
/// one never touches `.caf` audio, the Whisper worker, or any model —
/// only already-durable `SessionManifest`/`TranscriptResult` state.
nonisolated struct NotesTranscriptSourceSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: UUID
    /// Ordered ascending by `sequenceNumber`, contiguous `0..<count` — the
    /// same coverage guarantee `TranscriptionArtifactPaths.validated`
    /// already enforces on the manifest this was built from.
    var units: [NotesTranscriptSourceUnit]
    var fingerprint: TranscriptSourceFingerprint
}

nonisolated enum NotesTranscriptSourceError: LocalizedError, Sendable, Equatable {
    /// `SessionTranscriptionClassifier.isCompletionValid` returned `false`
    /// — this is the single authoritative "transcript completed"
    /// definition; T5-A deliberately does not define a second, looser one.
    case transcriptNotEligible
    /// Defensive: `isCompletionValid` guarantees a matching result exists
    /// for every manifest chunk, so this should be unreachable in
    /// practice, but the builder never force-unwraps that guarantee.
    case missingResultForChunk(sequenceNumber: Int)
    /// `isCompletionValid` validates job/result correspondence per manifest
    /// chunk but does not itself require `manifest.chunks`' own sequence
    /// numbers to be unique and contiguous. This case is the builder's own
    /// independent enforcement of that topology — a snapshot is never
    /// silently constructed with duplicate or gapped sequence numbers.
    case invalidSourceTopology(sequenceNumbers: [Int])

    var errorDescription: String? {
        switch self {
        case .transcriptNotEligible:
            return "The session's transcript is not a fully completed, valid transcript and cannot be used as notes input."
        case .missingResultForChunk(let sequenceNumber):
            return "No transcript result was found for chunk #\(sequenceNumber) despite completion validation."
        case .invalidSourceTopology(let sequenceNumbers):
            return "Transcript chunk sequence numbers are not a unique, contiguous 0..<count range: \(sequenceNumbers.sorted())"
        }
    }
}

nonisolated enum NotesTranscriptSourceBuilder {
    /// Builds a `NotesTranscriptSourceSnapshot` from durable transcription
    /// state. Requires `SessionTranscriptionClassifier.isCompletionValid`
    /// to hold for `manifest`/`jobs`/`results` — reusing that existing,
    /// authoritative completion rule rather than re-deriving eligibility
    /// independently. Pure: performs no filesystem I/O itself.
    static func build(
        manifest: SessionManifest,
        jobs: [TranscriptionJob],
        results: [TranscriptResult]
    ) throws -> NotesTranscriptSourceSnapshot {
        guard SessionTranscriptionClassifier.isCompletionValid(manifest: manifest, jobs: jobs, results: results) else {
            throw NotesTranscriptSourceError.transcriptNotEligible
        }

        var resultsBySequence: [Int: TranscriptResult] = [:]
        for result in results {
            resultsBySequence[result.source.chunkSequenceNumber] = result
        }

        let sequenceNumbers = manifest.chunks.map(\.sequenceNumber)
        guard
            Set(sequenceNumbers).count == sequenceNumbers.count,
            sequenceNumbers.sorted() == Array(0..<sequenceNumbers.count)
        else {
            throw NotesTranscriptSourceError.invalidSourceTopology(sequenceNumbers: sequenceNumbers)
        }

        let units = try manifest.chunks
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map { chunk -> NotesTranscriptSourceUnit in
                guard let result = resultsBySequence[chunk.sequenceNumber] else {
                    throw NotesTranscriptSourceError.missingResultForChunk(sequenceNumber: chunk.sequenceNumber)
                }
                return NotesTranscriptSourceUnit(
                    sequenceNumber: chunk.sequenceNumber,
                    chunkFileName: chunk.fileName,
                    text: result.output.text,
                    startOffsetSeconds: chunk.startOffsetSeconds,
                    durationSeconds: chunk.durationSeconds
                )
            }

        let fingerprint = TranscriptSourceFingerprint.compute(sessionID: manifest.sessionID, units: units)

        return NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: manifest.sessionID,
            units: units,
            fingerprint: fingerprint
        )
    }
}

/// A stable reference to one contiguous range of transcript source units
/// (by chunk sequence number), suitable for attaching evidence to a
/// generated note item. Independent of UI position and filesystem
/// enumeration order — it is defined purely in terms of the authoritative
/// chunk sequence numbers already carried by `NotesTranscriptSourceUnit`.
nonisolated struct NotesSourceReference: Codable, Equatable, Sendable {
    var sessionID: UUID
    var firstSequenceNumber: Int
    var lastSequenceNumber: Int

    init(sessionID: UUID, firstSequenceNumber: Int, lastSequenceNumber: Int) {
        self.sessionID = sessionID
        self.firstSequenceNumber = firstSequenceNumber
        self.lastSequenceNumber = lastSequenceNumber
    }

    init(sessionID: UUID, sequenceNumber: Int) {
        self.init(sessionID: sessionID, firstSequenceNumber: sequenceNumber, lastSequenceNumber: sequenceNumber)
    }
}

nonisolated enum NotesSourceReferenceError: LocalizedError, Sendable, Equatable {
    case sessionMismatch
    case invertedRange(firstSequenceNumber: Int, lastSequenceNumber: Int)
    case emptySource
    case outOfRange(availableRange: ClosedRange<Int>)

    var errorDescription: String? {
        switch self {
        case .sessionMismatch:
            return "The source reference's session ID does not match the transcript source it was validated against."
        case .invertedRange(let first, let last):
            return "Source reference range is inverted: first (\(first)) is greater than last (\(last))."
        case .emptySource:
            return "The transcript source has no units to reference."
        case .outOfRange(let availableRange):
            return "Source reference falls outside the transcript's available range \(availableRange)."
        }
    }
}

extension NotesSourceReference {
    /// Validates this reference against `snapshot`: the session must
    /// match, the range must not be inverted, and *every* sequence number
    /// in `firstSequenceNumber...lastSequenceNumber` must actually exist
    /// as a unit in `snapshot` — not merely fall between its minimum and
    /// maximum. A reference spanning a gap in the snapshot's coverage is
    /// rejected exactly like one that falls outside it entirely. Never
    /// repairs an invalid reference — only rejects it.
    func validate(against snapshot: NotesTranscriptSourceSnapshot) throws {
        guard sessionID == snapshot.sessionID else {
            throw NotesSourceReferenceError.sessionMismatch
        }
        guard firstSequenceNumber <= lastSequenceNumber else {
            throw NotesSourceReferenceError.invertedRange(
                firstSequenceNumber: firstSequenceNumber,
                lastSequenceNumber: lastSequenceNumber
            )
        }
        let availableSequenceNumbers = Set(snapshot.units.map(\.sequenceNumber))
        guard let minSequence = availableSequenceNumbers.min(), let maxSequence = availableSequenceNumbers.max() else {
            throw NotesSourceReferenceError.emptySource
        }
        let requestedRange = firstSequenceNumber...lastSequenceNumber
        guard requestedRange.allSatisfy({ availableSequenceNumbers.contains($0) }) else {
            throw NotesSourceReferenceError.outOfRange(availableRange: minSequence...maxSequence)
        }
    }
}
