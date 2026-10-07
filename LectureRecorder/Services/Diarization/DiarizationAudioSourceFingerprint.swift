import CryptoKit
import Foundation

/// A deterministic, collision-resistant identity for the terminal session
/// audio one diarization result was produced from. It identifies the
/// audio's *structure* — which chunk files, in which order, with exactly how
/// many frames, at which format — not its bytes: completed session audio is
/// app-owned and immutable, and `LecturePlaybackSourceLoader` has already
/// proven every chunk file matches that structure, so a whole-lecture byte
/// hash would add cost without adding a contract.
///
/// This fingerprints audio, not transcript content; it is deliberately
/// independent of `TranscriptSourceFingerprint`, and diarization never
/// changes that fingerprint.
nonisolated struct DiarizationAudioSourceFingerprint: Codable, Equatable, Hashable, Sendable {
    static let currentAlgorithmVersion = 1
    static let domainTag = "LectureRecorder.DiarizationAudioSourceFingerprint.v\(currentAlgorithmVersion)"

    var algorithmVersion: Int
    var digestHex: String

    /// Current algorithm and a 64-character lowercase hexadecimal SHA-256
    /// digest.
    var isWellFormed: Bool {
        algorithmVersion == Self.currentAlgorithmVersion
            && digestHex.utf8.count == 64
            && digestHex.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            }
    }

    static func compute(source: LecturePlaybackSource) -> DiarizationAudioSourceFingerprint {
        compute(
            sessionID: source.timeline.sessionID,
            sampleRate: source.timeline.sampleRate,
            channelCount: source.channelCount,
            chunks: source.timeline.chunks
        )
    }

    /// Computes a SHA-256 digest over an explicit, unambiguous binary
    /// encoding of exactly:
    ///
    /// 1. the domain-separation/version tag (`domainTag`), so this byte
    ///    stream can never collide with another fingerprint's or with a
    ///    differently-encoded future version;
    /// 2. `sessionID` (as its canonical UUID string);
    /// 3. `sampleRate` (raw IEEE-754 bit pattern) and `channelCount` — the
    ///    canonical session audio format `LecturePlaybackSourceLoader`
    ///    validated every chunk against;
    /// 4. for each chunk, sorted ascending by `sequenceNumber`: its
    ///    `sequenceNumber`, `fileName`, and integer `frameCount`.
    ///
    /// Strings are prefixed with their exact UTF-8 byte length; integers
    /// and the sample rate's bit pattern are fixed 8-byte big-endian. Every
    /// chunk record has a fixed shape, so the stream is self-delimiting and
    /// a chunk count would add no information.
    ///
    /// Deliberately NOT covered: `startOffsetSeconds`/`durationSeconds`
    /// (lossy floating-point values derived from `frameCount` and never
    /// authoritative for placement — `LecturePlaybackChunk` does not even
    /// carry them), `startFrame` and the total frame count (both derived
    /// from the ordered frame counts), transcript text or timing,
    /// Notes/Summary data, and the diarization result itself.
    /// `algorithmVersion` is bumped whenever coverage or encoding changes.
    static func compute(
        sessionID: UUID,
        sampleRate: Double,
        channelCount: UInt32,
        chunks: [LecturePlaybackChunk]
    ) -> DiarizationAudioSourceFingerprint {
        var hasher = SHA256()

        func updateUInt64(_ value: UInt64) {
            var bigEndian = value.bigEndian
            let bytes = withUnsafeBytes(of: &bigEndian) { Array($0) }
            hasher.update(data: Data(bytes))
        }
        func updateInt64(_ value: Int64) {
            updateUInt64(UInt64(bitPattern: value))
        }
        func updateLengthPrefixedString(_ string: String) {
            let bytes = Array(string.utf8)
            updateUInt64(UInt64(bytes.count))
            hasher.update(data: Data(bytes))
        }

        updateLengthPrefixedString(domainTag)
        updateLengthPrefixedString(sessionID.uuidString)
        updateUInt64(sampleRate.bitPattern)
        updateUInt64(UInt64(channelCount))
        for chunk in chunks.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            updateInt64(Int64(chunk.sequenceNumber))
            updateLengthPrefixedString(chunk.fileName)
            updateInt64(chunk.frameCount)
        }

        let digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return DiarizationAudioSourceFingerprint(algorithmVersion: currentAlgorithmVersion, digestHex: digestHex)
    }
}
