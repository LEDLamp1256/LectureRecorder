import Darwin
import Foundation

/// The outcome of `ExclusiveArtifactFileSystem.createExclusive(data:at:)`.
nonisolated enum ExclusiveCreateOutcome: Sendable {
    /// The temp file was written, synchronized, exclusively renamed into
    /// place, and the containing directory was itself successfully
    /// synchronized — the artifact is durably committed.
    case created
    /// The exclusive rename succeeded — the artifact is readable at its
    /// canonical path right now — but the subsequent containing-directory
    /// synchronization failed. The artifact itself must **not** be treated
    /// as a failure (it is really there), but its survival across a crash
    /// before the directory entry is otherwise flushed is unconfirmed.
    /// Callers must not treat this as equivalent to `.created`; see
    /// `TranscriptionCoordinator`'s handling.
    case createdDurabilityUncertain
    /// `url` already existed; nothing was written or replaced. The
    /// existing file's raw bytes are returned for the caller to decode and
    /// compare.
    case alreadyExists(existingData: Data)
}

nonisolated enum ExclusiveArtifactFileSystemError: LocalizedError, Sendable {
    case unableToCreateTemporaryFile(URL)
    case writeFailed(url: URL, underlying: String)
    case renameFailed(from: URL, to: URL, underlying: String)

    var errorDescription: String? {
        switch self {
        case .unableToCreateTemporaryFile(let url):
            return "Unable to create temporary file at \(url.path)."
        case .writeFailed(let url, let underlying):
            return "Failed writing temporary file at \(url.path): \(underlying)"
        case .renameFailed(let from, let to, let underlying):
            return "Failed to exclusively rename \(from.lastPathComponent) to \(to.lastPathComponent): \(underlying)"
        }
    }
}

/// A narrow, transcription-owned seam for committing an artifact exactly
/// once: write a unique temporary file in the destination's own directory,
/// synchronize it, then atomically rename it into place *without*
/// replacing an existing file at the destination.
///
/// Deliberately independent from `Services/Audio/ChunkFinalizationFileSystem`
/// — reusing or refactoring that audio-owned type would couple
/// transcription's failure semantics to `Chunk`-prefixed error types and
/// would touch code `CLAUDE.md`'s Architecture Boundaries protect. Some
/// low-level similarity (the same `renamex_np(..., RENAME_EXCL)` primitive)
/// is accepted as the cost of keeping the two subsystems independent.
nonisolated protocol ExclusiveArtifactFileSystem: Sendable {
    /// Writes `data` to a unique temporary file beside `url`, synchronizes
    /// and closes it, then attempts an exclusive (non-replacing) rename to
    /// `url`. Removes the temporary file on any failure path where that is
    /// safely possible. Never replaces or deletes an existing file at
    /// `url`.
    func createExclusive(data: Data, at url: URL) throws -> ExclusiveCreateOutcome

    /// Re-synchronizes an already-existing directory's own entry to disk,
    /// independent of any specific file inside it. Gives a caller a way to
    /// obtain *fresh* durability evidence for a directory whose earlier
    /// synchronization (inside a prior `createExclusive` call) could not be
    /// confirmed — see `TranscriptionCoordinator.reconcileState`'s handling
    /// of `.committedDurabilityUncertain`. Never throws: mirrors
    /// `createExclusive`'s own containing-directory sync step, which
    /// reports that same class of failure as data
    /// (`.createdDurabilityUncertain`) rather than as a thrown error.
    func synchronizeDirectory(at url: URL) -> Bool
}

/// Production `ExclusiveArtifactFileSystem`, backed by
/// `FileHandle.synchronize()` for the temporary file (matching
/// `AtomicFileWriter`'s own proven approach) and raw
/// `renamex_np(_:_:RENAME_EXCL)` plus a directory `fsync` for the
/// exclusive-commit step.
nonisolated struct DarwinExclusiveArtifactFileSystem: ExclusiveArtifactFileSystem {
    init() {}

    func createExclusive(data: Data, at url: URL) throws -> ExclusiveCreateOutcome {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")

        guard fm.createFile(atPath: tempURL.path, contents: nil) else {
            throw ExclusiveArtifactFileSystemError.unableToCreateTemporaryFile(tempURL)
        }

        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw ExclusiveArtifactFileSystemError.writeFailed(url: tempURL, underlying: error.localizedDescription)
        }

        let renameResult = renamex_np(tempURL.path, url.path, UInt32(RENAME_EXCL))
        if renameResult != 0 {
            let renameErrno = errno
            if renameErrno == EEXIST {
                try? fm.removeItem(at: tempURL)
                let existingData = try Data(contentsOf: url)
                return .alreadyExists(existingData: existingData)
            }
            try? fm.removeItem(at: tempURL)
            throw ExclusiveArtifactFileSystemError.renameFailed(
                from: tempURL,
                to: url,
                underlying: String(cString: strerror(renameErrno))
            )
        }

        // The rename itself already succeeded — the artifact is real and
        // readable at `url` from this point on, regardless of what
        // happens below. A directory-sync failure here must never be
        // reported as though the artifact does not exist.
        return Self.synchronize(directory: directory) ? .created : .createdDurabilityUncertain
    }

    func synchronizeDirectory(at url: URL) -> Bool {
        Self.synchronize(directory: url)
    }

    /// Opens `directory` and `fsync`s it, reporting whether that succeeded.
    /// Shared by `createExclusive`'s own containing-directory sync step and
    /// the standalone `synchronizeDirectory(at:)` re-confirmation entry
    /// point, so both paths use exactly the same Darwin primitive.
    private static func synchronize(directory: URL) -> Bool {
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        return fsync(directoryFD) == 0
    }
}
