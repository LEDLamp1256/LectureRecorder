import Darwin
import Foundation

/// The outcome of `NotesExclusiveArtifactFileSystem.createExclusive(data:at:)`.
nonisolated enum NotesExclusiveCreateOutcome: Sendable {
    /// The temp file was written, synchronized, exclusively renamed into
    /// place, and the containing directory was itself successfully
    /// synchronized.
    case created
    /// The exclusive rename succeeded — the artifact is readable at its
    /// canonical path right now — but the subsequent containing-directory
    /// synchronization failed. Callers must not treat this as a failure.
    case createdDurabilityUncertain
    /// `url` already existed; nothing was written or replaced. The
    /// existing file's raw bytes are returned for the caller to decode and
    /// compare.
    case alreadyExists(existingData: Data)
}

nonisolated enum NotesExclusiveArtifactFileSystemError: LocalizedError, Sendable {
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

/// A narrow, notes-owned seam for committing an artifact exactly once:
/// write a unique temporary file in the destination's own directory,
/// synchronize it, then atomically rename it into place *without*
/// replacing an existing file at the destination.
///
/// Deliberately independent from transcription's own
/// `ExclusiveArtifactFileSystem` — the notes domain owns its own
/// persistence namespace end to end, and reusing a subsystem-owned type
/// across domains is the exact coupling that type's own documentation
/// warns against. Some low-level similarity (the same
/// `renamex_np(..., RENAME_EXCL)` primitive) is accepted as the cost of
/// keeping the two domains independent.
nonisolated protocol NotesExclusiveArtifactFileSystem: Sendable {
    func createExclusive(data: Data, at url: URL) throws -> NotesExclusiveCreateOutcome
}

nonisolated struct DarwinNotesExclusiveArtifactFileSystem: NotesExclusiveArtifactFileSystem {
    init() {}

    func createExclusive(data: Data, at url: URL) throws -> NotesExclusiveCreateOutcome {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try DefaultFileSystemLocator.ensureDirectoryExists(directory)

        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")

        guard fm.createFile(atPath: tempURL.path, contents: nil) else {
            throw NotesExclusiveArtifactFileSystemError.unableToCreateTemporaryFile(tempURL)
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
            throw NotesExclusiveArtifactFileSystemError.writeFailed(url: tempURL, underlying: error.localizedDescription)
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
            throw NotesExclusiveArtifactFileSystemError.renameFailed(
                from: tempURL,
                to: url,
                underlying: String(cString: strerror(renameErrno))
            )
        }

        return Self.synchronize(directory: directory) ? .created : .createdDurabilityUncertain
    }

    private static func synchronize(directory: URL) -> Bool {
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        return fsync(directoryFD) == 0
    }
}
