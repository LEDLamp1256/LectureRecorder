import Foundation
import OSLog

/// A structured value an acceptance-diagnostic event's metadata may carry.
/// Deliberately restricted to primitives cheap to compute and safe to log —
/// never raw lecture content (transcript text, Notes prose, Summary prose,
/// prompts, or model responses). See `AcceptanceDiagnosticLogger`'s own
/// header comment for the full privacy contract.
nonisolated enum AcceptanceDiagnosticValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case uuid(UUID)
    case null

    static func uuid(_ value: UUID?) -> AcceptanceDiagnosticValue {
        value.map { .uuid($0) } ?? .null
    }

    static func int(_ value: Int?) -> AcceptanceDiagnosticValue {
        value.map { .int($0) } ?? .null
    }

    static func string(_ value: String?) -> AcceptanceDiagnosticValue {
        value.map { .string($0) } ?? .null
    }
}

extension AcceptanceDiagnosticValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .uuid(let value): try container.encode(value.uuidString)
        case .null: try container.encodeNil()
        }
    }
}

extension AcceptanceDiagnosticValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension AcceptanceDiagnosticValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
}

extension AcceptanceDiagnosticValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension AcceptanceDiagnosticValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .double(value) }
}

/// Typed event-name constants for `AcceptanceDiagnosticLogger.log(_:...)` —
/// grouped by pipeline so call sites never hand-type a raw event string.
/// New event names belong here, not inline at call sites.
nonisolated enum AcceptanceDiagnosticEvent {
    enum Transcription {
        static let started = "transcription.started"
        static let continueOrRetryStarted = "transcription.continueOrRetry.started"
        static let chunkStarted = "transcription.chunk.started"
        static let chunkCompleted = "transcription.chunk.completed"
        static let chunkFailed = "transcription.chunk.failed"
        static let cancelRequested = "transcription.cancel.requested"
        static let completed = "transcription.completed"
    }

    enum Notes {
        static let started = "notes.started"
        static let continueStarted = "notes.continue.started"
        static let retryStarted = "notes.retry.started"
        static let windowStarted = "notes.window.started"
        static let windowCompleted = "notes.window.completed"
        static let synthesisStarted = "notes.synthesis.started"
        static let synthesisCompleted = "notes.synthesis.completed"
        static let cancelRequested = "notes.cancel.requested"
        static let preflight = "notes.preflight"
        /// Terminal outcome. `event` is chosen per-outcome from
        /// `completed`/`failed`/`cancelled` below — kept as three distinct
        /// constants (rather than one generic "finished" event) so a trace
        /// reader can filter for exactly one outcome kind.
        static let completed = "notes.completed"
        static let failed = "notes.failed"
        static let cancelled = "notes.cancelled"
    }

    enum Summary {
        static let started = "summary.started"
        static let continueStarted = "summary.continue.started"
        static let retryStarted = "summary.retry.started"
        static let preflight = "summary.preflight"
        static let analysisBatchStarted = "summary.analysis.batch.started"
        static let analysisBatchCompleted = "summary.analysis.batch.completed"
        static let reductionLevelStarted = "summary.reduction.level.started"
        static let reductionLevelCompleted = "summary.reduction.level.completed"
        /// One actual model-invoking reduction group within a reduction
        /// level — never logged for a singleton group carried forward
        /// unchanged (that is a passthrough, not a model call).
        static let reductionGroupStarted = "summary.reduction.group.started"
        static let reductionGroupCompleted = "summary.reduction.group.completed"
        static let finalStructureStarted = "summary.finalStructure.started"
        static let finalStructureCompleted = "summary.finalStructure.completed"
        static let finalSectionStarted = "summary.finalSection.started"
        static let finalSectionCompleted = "summary.finalSection.completed"
        /// A failed generated-output attempt — not necessarily one that
        /// will be retried; see the event's own `willRetry` metadata field.
        static let generatedOutputAttemptFailed = "summary.generatedOutput.attemptFailed"
        static let synthesisStarted = "summary.synthesis.started"
        static let synthesisCompleted = "summary.synthesis.completed"
        static let cancelRequested = "summary.cancel.requested"
        /// See `Notes.completed`/`failed`/`cancelled` above for why these
        /// are three distinct constants.
        static let completed = "summary.completed"
        static let failed = "summary.failed"
        static let cancelled = "summary.cancelled"
    }
}

/// One append-only line of the acceptance-diagnostics trace. Every field is
/// diagnostic-only metadata — never raw lecture content — see
/// `AcceptanceDiagnosticLogger`.
private struct AcceptanceDiagnosticRecord: Encodable {
    var schemaVersion: Int
    var timestamp: String
    var pid: Int32
    var event: String
    var elapsedSeconds: Double?
    var metadata: [String: AcceptanceDiagnosticValue]
}

/// Strictly diagnostic, opt-in, append-only trace of what happens during a
/// real acceptance run of record/import → transcription → detailed Notes →
/// dedicated Summary. Exists solely so a 60–90 minute hands-on acceptance
/// session can be reconstructed afterward (timings, batch/window progress,
/// preflight/reduction decisions, cancellation latency, recovery paths,
/// failures) — it changes no product behavior and is never consulted by any
/// generation, recovery, or persistence logic.
///
/// **Privacy**: never logs transcript text, Notes prose, Summary prose,
/// prompts, model responses, raw audio, or other lecture content. Callers
/// must only ever pass metadata such as identifiers, counts, byte/character
/// counts, indexes, states, timings, and error categories/codes.
///
/// **Activation**: off unless the environment variable named by
/// `environmentVariableName` is set to exactly `"1"` (checked once, cached
/// in `isEnabled`). When disabled, `log(...)` is a single cheap boolean
/// check — no filesystem access, no allocation beyond the caller's own
/// already-computed arguments.
///
/// **Failure semantics**: every filesystem operation (directory creation,
/// file open, write, JSON encoding) is best-effort. A failure here never
/// throws, never blocks, and never turns a successful product operation
/// into a failure — see the `try?`s throughout `write`. This type never
/// participates in generation recovery/classification semantics.
///
/// **Concurrency**: a plain, `@unchecked Sendable` class backed by one
/// private serial `DispatchQueue` (the same "hand a value to a dedicated
/// serial queue" shape `AudioChunkWriter` already uses for its own
/// concurrency-safe background writing) — chosen specifically so call sites
/// on `@MainActor` services, `nonisolated` generator structs, and the
/// `TranscriptionCoordinator` actor can all log synchronously and
/// fire-and-forget, with no `await` and no actor hop. Every mutable stored
/// property below is touched only from blocks submitted to `queue`.
nonisolated final class AcceptanceDiagnosticLogger: @unchecked Sendable {
    static let environmentVariableName = "LECTURE_RECORDER_ACCEPTANCE_DIAGNOSTICS"
    static let schemaVersion = 1

    /// Computed once per process launch; the environment does not change
    /// underneath a running process, so re-reading it per call would only
    /// add cost without adding correctness.
    static let isEnabled: Bool = ProcessInfo.processInfo.environment[environmentVariableName] == "1"

    static let shared = AcceptanceDiagnosticLogger()

    private let queue = DispatchQueue(label: "com.example.lecturerecorder.acceptance-diagnostics", qos: .utility)
    /// Instance-level enablement, defaulting to the process-wide
    /// `isEnabled` check. Kept separate from the `static let` so tests can
    /// construct a logger pinned to a known enabled/disabled state without
    /// depending on (or mutating) this process's real environment.
    private let isEnabled: Bool
    private let fileURLProvider: @Sendable () -> URL?
    private let now: @Sendable () -> Date

    /// Queue-confined: only ever read or written from blocks submitted to
    /// `queue`.
    private var fileHandle: FileHandle?
    private var resolvedFileURL: URL?
    private var didAttemptOpen = false
    private var didLogFailure = false

    init(
        isEnabled: Bool = AcceptanceDiagnosticLogger.isEnabled,
        fileURLProvider: @escaping @Sendable () -> URL? = AcceptanceDiagnosticLogger.defaultFileURL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.isEnabled = isEnabled
        self.fileURLProvider = fileURLProvider
        self.now = now
    }

    /// One diagnostic trace file per process/run: `~/Library/Logs/
    /// LectureRecorder/acceptance-<timestamp>-<pid>.jsonl`. The timestamp is
    /// filesystem-safe (no colons) and computed once, when this is first
    /// consulted by the first successfully-enabled log call — not at
    /// process launch — so a process that never actually logs an event
    /// never touches the filesystem at all.
    static func defaultFileURL() -> URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = library.appendingPathComponent("Logs/LectureRecorder", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmssZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        return directory.appendingPathComponent("acceptance-\(timestamp)-\(pid).jsonl")
    }

    /// A monotonic starting point for measuring an elapsed duration —
    /// wall-clock timestamps (recorded separately, per event) are useful for
    /// correlating events across a trace, but elapsed timing must never be
    /// skewed by a wall-clock adjustment mid-measurement.
    static func startInstant() -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    static func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Records one diagnostic event. A no-op (single boolean check) unless
    /// `isEnabled`. Never throws; never blocks the caller on filesystem I/O
    /// — the actual write happens asynchronously on `queue`.
    /// `metadata` is `@autoclosure` so the dictionary literal at every call
    /// site is only actually built after the `isEnabled` guard below — a
    /// disabled run never allocates a call site's metadata dictionary at
    /// all, while every call site keeps writing an ordinary
    /// `metadata: ["key": .value, ...]` argument exactly as before.
    func log(
        _ event: String,
        metadata: @autoclosure () -> [String: AcceptanceDiagnosticValue] = [:],
        elapsedSeconds: Double? = nil
    ) {
        guard isEnabled else { return }
        let record = AcceptanceDiagnosticRecord(
            schemaVersion: Self.schemaVersion,
            timestamp: Self.isoFormatter.string(from: now()),
            pid: ProcessInfo.processInfo.processIdentifier,
            event: event,
            elapsedSeconds: elapsedSeconds,
            metadata: metadata()
        )
        queue.async { [weak self] in
            self?.write(record)
        }
    }

    /// Blocks until every previously-`log`ged event on this instance has
    /// been written (or has failed best-effort). Exists only so tests can
    /// deterministically observe file contents without depending on timing;
    /// harmless in production since nothing calls it there.
    func waitUntilAllEventsWritten() {
        queue.sync {}
    }

    /// The trace file this instance actually resolved and opened, if any —
    /// only meaningful after at least one event has been logged and
    /// `waitUntilAllEventsWritten()` called. Test-only accessor.
    func resolvedFileURLForTesting() -> URL? {
        queue.sync { resolvedFileURL }
    }

    // MARK: - Queue-confined implementation

    private func write(_ record: AcceptanceDiagnosticRecord) {
        guard let handle = openFileHandleIfNeeded() else { return }
        do {
            var data = try Self.encoder.encode(record)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            logFailureOnce("Unable to write acceptance diagnostic event: \(error.localizedDescription)")
        }
    }

    private func openFileHandleIfNeeded() -> FileHandle? {
        if let fileHandle { return fileHandle }
        guard !didAttemptOpen else { return nil }
        didAttemptOpen = true

        guard let url = fileURLProvider() else {
            logFailureOnce("Unable to resolve an acceptance diagnostics log file path.")
            return nil
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logFailureOnce("Unable to create the acceptance diagnostics log directory: \(error.localizedDescription)")
            return nil
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                logFailureOnce("Unable to create the acceptance diagnostics log file.")
                return nil
            }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            logFailureOnce("Unable to open the acceptance diagnostics log file for writing.")
            return nil
        }
        handle.seekToEndOfFile()
        fileHandle = handle
        resolvedFileURL = url
        return handle
    }

    private func logFailureOnce(_ message: String) {
        guard !didLogFailure else { return }
        didLogFailure = true
        Log.fileSystem.error("Acceptance diagnostics: \(message, privacy: .public)")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
