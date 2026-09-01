import Foundation
import OSLog

/// Appends structured, human-readable lines to a single session's
/// `logs/recording.log`.
///
/// This is an `actor` so concurrent lifecycle events can log safely
/// without a hand-rolled lock. Note that actor isolation here provides
/// *mutual exclusion* (calls are serialized, never run concurrently with
/// each other) — it does not provide a dedicated background thread or an
/// I/O-optimized executor. By default this actor's isolated code runs on
/// Swift's shared, size-limited concurrent executor pool, same as any
/// other non-`@MainActor` actor. For the tiny, infrequent log lines
/// written in this phase, that's an appropriate and simple choice.
actor SessionFileLogger {
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private let isoFormatter: ISO8601DateFormatter

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.isoFormatter = ISO8601DateFormatter()

        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        _ = try handle.seekToEnd()
        self.fileHandle = handle
    }

    func log(_ message: String, level: String = "INFO") {
        let timestamp = isoFormatter.string(from: Date())
        let line = "\(timestamp) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8), let fileHandle else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            Log.fileSystem.error(
                "SessionFileLogger failed to write to \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Safe to call more than once; a second call is a harmless no-op.
    func close() {
        try? fileHandle?.close()
        fileHandle = nil
    }
}
