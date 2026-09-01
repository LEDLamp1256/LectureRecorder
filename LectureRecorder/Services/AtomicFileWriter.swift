import Darwin
import Foundation
import OSLog

enum AtomicFileWriterError: LocalizedError, Sendable {
    case unableToCreateTemporaryFile(URL)

    var errorDescription: String? {
        switch self {
        case .unableToCreateTemporaryFile(let url):
            return "Unable to create temporary file at \(url.path)."
        }
    }
}

/// Writes and reads Codable values as JSON, minimizing the chance that a
/// crash or power loss mid-write leaves a corrupt or partially-written
/// file at the destination path.
///
/// ## What this guarantees
/// The value is encoded to a temporary file in the *same directory* as the
/// destination, fsync'd, then moved into place with an atomic rename
/// (`FileManager.replaceItemAt`/`moveItem`, both backed by POSIX
/// `rename(2)` on APFS/HFS+). Because the rename is atomic, a reader can
/// only ever observe the fully-old file's contents or the fully-new
/// file's contents — never a half-written one.
///
/// After a successful rename, this also makes a **best-effort** attempt
/// to open and fsync the *containing directory*, which is what actually
/// flushes the directory-entry update (the rename itself) to stable
/// storage. This step is best-effort only: if it fails — for example due
/// to an unusual filesystem or a permissions issue — the failure is
/// logged via `Log.fileSystem.error` and swallowed, not thrown, because
/// by that point the JSON file itself has already been safely written
/// and renamed, and failing the whole write over a diagnostic-only step
/// would be misleading to callers. In practice, on a normal, healthy
/// local disk both the file contents and the directory entry pointing at
/// it are flushed before this function returns. But if the directory
/// fsync silently fails, this function still returns success: the file
/// contents are safely written, while the extra assurance that the
/// directory entry itself survives a full power loss is only attempted
/// for that call, not confirmed.
///
/// ## What this does NOT guarantee
/// This is not a database-grade durability guarantee. It does not protect
/// against: drive or controller write caches that acknowledge `fsync`
/// before data is physically on the media; network or removable volumes
/// with weaker consistency semantics; or a crash in the narrow window
/// between the temp file's own fsync and the rename call itself. For the
/// small, infrequent manifest writes in this phase (created once per
/// session, updated at start/stop/failure), this is an appropriate and
/// proportionate level of durability. Do not extend this reasoning to
/// high-frequency or large-payload writes (e.g. audio chunks) without
/// reconsidering the approach.
enum AtomicFileWriter {
    static var defaultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var defaultDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: dateString) {
                return date
            }

            let withoutFractional = ISO8601DateFormatter()
            withoutFractional.formatOptions = [.withInternetDateTime]
            if let date = withoutFractional.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO 8601 date string, got \(dateString)"
            )
        }
        return decoder
    }

    static func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL,
        encoder: JSONEncoder = AtomicFileWriter.defaultEncoder
    ) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try DefaultFileSystemLocator.ensureDirectoryExists(directory)

        let data = try encoder.encode(value)
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")

        guard fm.createFile(atPath: tempURL.path, contents: nil) else {
            throw AtomicFileWriterError.unableToCreateTemporaryFile(tempURL)
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
            throw error
        }

        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }

        synchronizeDirectory(at: directory)
    }

    static func readJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        decoder: JSONDecoder = AtomicFileWriter.defaultDecoder
    ) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    /// Opens and fsyncs `directory`, best-effort, so a preceding rename
    /// into that directory has a better chance of being flushed to
    /// stable storage. This is deliberately best-effort: failures here
    /// are logged but never thrown. By the time this runs, the JSON file
    /// itself has already been written and renamed successfully, so
    /// failing the caller's write over a diagnostic-only step would
    /// misrepresent what actually went wrong.
    private static func synchronizeDirectory(at url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            Log.fileSystem.error(
                "Unable to open directory for fsync: \(url.path, privacy: .public) errno=\(errno, privacy: .public)"
            )
            return
        }
        defer { close(fd) }
        if fsync(fd) != 0 {
            Log.fileSystem.error(
                "fsync failed for directory: \(url.path, privacy: .public) errno=\(errno, privacy: .public)"
            )
        }
    }
}
