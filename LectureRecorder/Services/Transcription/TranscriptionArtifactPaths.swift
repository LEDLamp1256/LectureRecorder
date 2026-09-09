import Foundation

/// Validated, transcription-owned on-disk locations for one session's
/// transcription artifacts. Deliberately **not** an extension of the
/// existing, shared `SessionPaths` type (per architecture decision) — this
/// type owns only the new `transcription/` subtree, derived from an
/// already-validated `SessionPaths`/`SessionManifest` pair.
///
/// The only way to construct one is `validated(manifest:sessionPaths:)`,
/// which proves the supplied manifest and paths actually belong together
/// and that every chunk reference is safe, *before* any directory or file
/// is created. No other initializer exists.
nonisolated struct TranscriptionArtifactPaths: Sendable, Equatable {
    /// Every validation failure `validated(manifest:sessionPaths:)` can
    /// throw, checked in the exact order listed here.
    nonisolated enum ValidationError: LocalizedError, Sendable, Equatable {
        /// The manifest's `status` is not `.completed`. Named
        /// `sessionNotCompleted`, not `sessionNotTerminal`, because
        /// `.failed`/`.interrupted` are also terminal recording states but
        /// are deliberately rejected by T1.
        case sessionNotCompleted(SessionStatus)
        /// `sessionPaths.sessionDirectory`'s last path component does not
        /// match `manifest.sessionID` — proves the supplied paths do not
        /// actually belong to this manifest.
        case pathSessionMismatch
        /// `sessionPaths` does not have the expected
        /// `<session>/chunks/`, `<session>/session.json` topology after
        /// standardization.
        case unexpectedPathTopology
        /// `manifest.chunks`' sequence numbers are not a contiguous,
        /// duplicate-free `0..<count` range.
        case nonContiguousChunkSequence
        /// A chunk's `fileName` is not the exact canonical filename for
        /// its own `sequenceNumber` (e.g. sequence 2 claiming a filename
        /// that belongs to a different sequence, or any non-canonical
        /// name).
        case nonCanonicalChunkFileName(sequenceNumber: Int, fileName: String)
        /// A chunk's resolved URL does not remain beneath the session's
        /// `chunksDirectory` after standardization — defense in depth
        /// beyond the canonical-filename check above.
        case chunkURLEscapesDirectory(sequenceNumber: Int)

        var errorDescription: String? {
            switch self {
            case .sessionNotCompleted(let status):
                return "Session is not completed (status: \(status.rawValue)); T1 only processes completed sessions."
            case .pathSessionMismatch:
                return "The supplied session paths do not belong to the supplied manifest's session ID."
            case .unexpectedPathTopology:
                return "The supplied session paths do not have the expected chunks/session.json layout."
            case .nonContiguousChunkSequence:
                return "The manifest's chunk sequence numbers are not a contiguous, duplicate-free range starting at 0."
            case .nonCanonicalChunkFileName(let seq, let name):
                return "Chunk #\(seq) has a non-canonical file name: \(name)"
            case .chunkURLEscapesDirectory(let seq):
                return "Chunk #\(seq)'s resolved URL does not remain beneath the session's chunks directory."
            }
        }
    }

    let sessionID: UUID
    let chunksDirectory: URL
    let transcriptionDirectory: URL
    let jobsDirectory: URL
    let resultsDirectory: URL

    /// Validates `manifest` against `sessionPaths` in the following exact
    /// order, before any directory or file is created:
    /// 1. `manifest.status == .completed`.
    /// 2. `sessionPaths.sessionDirectory` belongs to `manifest.sessionID`.
    /// 3. `sessionPaths`' internal topology (chunks/session.json layout)
    ///    matches expectations.
    /// 4. Every `ChunkMetadata.sequenceNumber` in `manifest.chunks` forms a
    ///    contiguous, duplicate-free `0..<count` range.
    /// 5. Every `ChunkMetadata.fileName` is the *exact* canonical filename
    ///    for its own sequence number.
    /// 6. Every chunk's resolved URL remains beneath `chunksDirectory`.
    static func validated(
        manifest: SessionManifest,
        sessionPaths: SessionPaths
    ) throws -> TranscriptionArtifactPaths {
        guard manifest.status == .completed else {
            throw ValidationError.sessionNotCompleted(manifest.status)
        }

        guard sessionPaths.sessionDirectory.lastPathComponent == manifest.sessionID.uuidString else {
            throw ValidationError.pathSessionMismatch
        }

        let standardizedSessionDirectory = sessionPaths.sessionDirectory.standardizedFileURL
        let standardizedChunksDirectory = sessionPaths.chunksDirectory.standardizedFileURL
        let standardizedManifestURL = sessionPaths.manifestURL.standardizedFileURL

        guard
            standardizedChunksDirectory.deletingLastPathComponent() == standardizedSessionDirectory,
            standardizedChunksDirectory.lastPathComponent == "chunks",
            standardizedManifestURL.deletingLastPathComponent() == standardizedSessionDirectory,
            standardizedManifestURL.lastPathComponent == "session.json"
        else {
            throw ValidationError.unexpectedPathTopology
        }

        let sequenceNumbers = manifest.chunks.map(\.sequenceNumber).sorted()
        guard sequenceNumbers == Array(0..<manifest.chunks.count) else {
            throw ValidationError.nonContiguousChunkSequence
        }

        let chunksDirectoryPrefix = standardizedChunksDirectory.path.hasSuffix("/")
            ? standardizedChunksDirectory.path
            : standardizedChunksDirectory.path + "/"

        for chunk in manifest.chunks {
            let expectedFileName = canonicalChunkFileName(for: chunk.sequenceNumber)
            guard chunk.fileName == expectedFileName else {
                throw ValidationError.nonCanonicalChunkFileName(
                    sequenceNumber: chunk.sequenceNumber,
                    fileName: chunk.fileName
                )
            }

            let resolvedURL = standardizedChunksDirectory
                .appendingPathComponent(chunk.fileName)
                .standardizedFileURL
            guard resolvedURL.path.hasPrefix(chunksDirectoryPrefix) else {
                throw ValidationError.chunkURLEscapesDirectory(sequenceNumber: chunk.sequenceNumber)
            }
        }

        let transcriptionDirectory = sessionPaths.sessionDirectory
            .appendingPathComponent("transcription", isDirectory: true)
        let jobsDirectory = transcriptionDirectory.appendingPathComponent("jobs", isDirectory: true)
        let resultsDirectory = transcriptionDirectory.appendingPathComponent("results", isDirectory: true)

        return TranscriptionArtifactPaths(
            sessionID: manifest.sessionID,
            chunksDirectory: sessionPaths.chunksDirectory,
            transcriptionDirectory: transcriptionDirectory,
            jobsDirectory: jobsDirectory,
            resultsDirectory: resultsDirectory
        )
    }

    /// The canonical `chunk_%06d.caf` filename for `sequenceNumber` —
    /// mirrors `AudioChunkWriter`'s own naming convention exactly, without
    /// depending on that (audio-owned, `Services/Audio/`-private) type.
    static func canonicalChunkFileName(for sequenceNumber: Int) -> String {
        "chunk_\(String(format: "%06d", sequenceNumber)).caf"
    }

    static func jobFileName(for sequenceNumber: Int) -> String {
        "chunk_\(String(format: "%06d", sequenceNumber)).job.json"
    }

    static func resultFileName(for sequenceNumber: Int) -> String {
        "chunk_\(String(format: "%06d", sequenceNumber)).transcript.json"
    }

    func jobURL(sequenceNumber: Int) -> URL {
        jobsDirectory.appendingPathComponent(Self.jobFileName(for: sequenceNumber))
    }

    func resultURL(sequenceNumber: Int) -> URL {
        resultsDirectory.appendingPathComponent(Self.resultFileName(for: sequenceNumber))
    }

    /// The source `.caf` file's URL for a given chunk file name, resolved
    /// beneath `chunksDirectory`. Used only for read-only existence checks
    /// (source-presence validation) — this type never writes into
    /// `chunksDirectory`.
    func chunkAudioURL(fileName: String) -> URL {
        chunksDirectory.appendingPathComponent(fileName)
    }
}
