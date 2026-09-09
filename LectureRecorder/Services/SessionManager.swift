import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog

/// A failure that requires an explicit user action (retry or abandon)
/// before a new session can be started, because we cannot confirm the
/// on-disk manifest accurately reflects what happened.
struct UnresolvedSessionIssue: Equatable, Sendable {
    let sessionID: UUID
    let message: String
    let canRetry: Bool
}

/// Distinguishes what a pending retry is trying to accomplish, so
/// `retryResolution()` knows how to finish the job on success.
private enum RetryKind {
    case prepareFailure
    case stopFinalization
}

/// A single accepted operational failure for one recording cycle, in the
/// order it was recorded. The first entry is primary; later, distinct
/// entries are secondary diagnostics folded into `failureDescription`'s
/// formatting. `.userStopped` is deliberately not a case here — a user
/// Stop is a shutdown trigger, never an operational failure, and must
/// never by itself prevent a `.completed` outcome.
private enum OperationalFailureCause {
    case captureFailure(Error)
    case captureStopOutcomeFailure(Error)
    case writerStreamFailure(Error)
    case chunkSequenceViolation(expected: Int, got: Int)
    case interiorManifestPersistenceFailure(Error)

    var description: String {
        switch self {
        case .captureFailure(let error):
            return "Capture failure: \(error.localizedDescription)"
        case .captureStopOutcomeFailure(let error):
            return "Capture stop reported a retained failure: \(error.localizedDescription)"
        case .writerStreamFailure(let error):
            return "Audio writer failure: \(error.localizedDescription)"
        case .chunkSequenceViolation(let expected, let got):
            return "Chunk sequence violation: expected chunk #\(expected), got #\(got)"
        case .interiorManifestPersistenceFailure(let error):
            return "Failed to persist finalized chunk metadata: \(error.localizedDescription)"
        }
    }

    fileprivate var isCaptureFailure: Bool {
        if case .captureFailure = self { return true }
        return false
    }
}

/// What triggered a shutdown request. `.userStopped` never becomes an
/// `OperationalFailureCause` and never prevents a `.completed` outcome by
/// itself — only a genuinely retained operational failure does that, even
/// if that failure surfaces only after a user-initiated Stop already
/// began the same shutdown.
private enum ShutdownTrigger {
    case userStopped
    case operational(OperationalFailureCause)
}

/// One recording cycle's complete retained runtime state. Confined to
/// `SessionManager`'s `@MainActor` — nothing outside `SessionManager`
/// ever holds or mutates this. The only things that cross off this actor
/// are: the writer itself (a plain `Sendable` existential, captured
/// directly by the realtime buffer callback — never through this object)
/// and the failure callback's captured `[weak SessionManager, runtime id]`
/// pair, both of which reach back into `SessionManager` rather than into
/// this type.
@MainActor
private final class RecordingRuntime {
    let id: UUID
    let writer: any AudioChunkWriting
    let paths: SessionPaths

    var eventConsumerTask: Task<Void, Never>?
    var shutdownTask: Task<Void, Never>?

    var accumulatedChunks: [ChunkMetadata] = []
    var expectedNextSequence = 0
    var interiorPersistenceHasFailed = false
    var operationalFailures: [OperationalFailureCause] = []

    init(id: UUID, writer: any AudioChunkWriting, paths: SessionPaths) {
        self.id = id
        self.writer = writer
        self.paths = paths
    }

    var primaryOperationalFailure: OperationalFailureCause? {
        operationalFailures.first
    }
}

/// The single owner of recording state and the active session's lifecycle.
///
/// ## Resource ownership model
/// - `activeSession` is non-nil only while a session is being prepared,
///   recording, stopping, or while a failure involving that session is
///   still unresolved. While a runtime is active, its `chunks` reflect
///   the complete best-known in-memory chunk list — which may briefly run
///   ahead of what is actually confirmed on disk if an interior manifest
///   write is still catching up or has failed (see `RecordingRuntime`
///   below); the final manifest persisted at Stop is always built from
///   that complete in-memory list, never from disk state.
///   - If the final Stop-time write fails, the attempted final manifest
///     lives only in `pendingManifestForRetry` until a write for it
///     actually succeeds (see `retryResolution()`).
///   - If session preparation fails and the resulting `.failed` failure
///     record also fails to persist, `activeSession` is set to the
///     original prepared `.recording` manifest **only if that manifest's
///     own initial write is known to have succeeded**; otherwise it is
///     `nil`. The unconfirmed `.failed` manifest lives only in
///     `pendingManifestForRetry`.
/// - `lastCompletedSession` is set only once a session's final manifest
///   has been durably persisted as `.completed` and its logger closed. It
///   exists purely for display and is never mutated afterward.
/// - `unresolvedIssue` is non-nil only when we could not confirm a
///   session's on-disk state matches reality (a manifest write failed).
///   While it is non-nil, starting a new session is refused; the user
///   must call `retryResolution()` or `discardUnresolvedSession()` first.
/// - Leaving `.failed` for `.idle` only ever happens through the explicit
///   `resetAfterFailure()` call, which itself requires `unresolvedIssue`
///   to already be `nil`.
/// - `currentRuntime` is non-nil for exactly the lifetime of one
///   recording cycle: from the moment capture/writer/event-consumer are
///   fully installed during Start, through whichever shutdown path
///   (clean Stop or terminal failure) tears it down. Every terminal
///   signal (a capture failure callback, a writer stream failure, an
///   interior manifest failure, a sequence violation) is tagged with the
///   runtime's `id` and is safely ignored if it no longer matches
///   `currentRuntime?.id` — this is what makes a late signal for an
///   already-torn-down cycle harmless.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var activeSession: SessionManifest?
    @Published private(set) var lastCompletedSession: SessionManifest?
    @Published private(set) var unresolvedIssue: UnresolvedSessionIssue?
    @Published private(set) var lastKnownPermissionStatus: PermissionStatus = .undetermined
    @Published private(set) var revealFolderErrorMessage: String?

    private let store: any SessionStoring
    private let permissionService: MicrophonePermissionServing
    private let captureService: any AudioCapturing
    private let chunkWriterFactory: any AudioChunkWriterFactory

    private var currentSessionPaths: SessionPaths?
    private var currentSessionLogger: SessionFileLogger?
    private var pendingManifestForRetry: SessionManifest?
    private var retryKind: RetryKind?
    private var isRetryInFlight = false
    private var isDiscardInFlight = false

    /// The active recording cycle's complete runtime, or `nil` when idle,
    /// preparing, or between cycles. See the type's own documentation.
    private var currentRuntime: RecordingRuntime?

    init(
        store: any SessionStoring,
        permissionService: MicrophonePermissionServing,
        captureService: any AudioCapturing,
        chunkWriterFactory: any AudioChunkWriterFactory
    ) {
        self.store = store
        self.permissionService = permissionService
        self.captureService = captureService
        self.chunkWriterFactory = chunkWriterFactory
    }

    var canStart: Bool {
        unresolvedIssue == nil && (state == .idle || state == .completed)
    }

    var canStop: Bool {
        state.isRecording
    }

    var canReset: Bool {
        state.isFailed && unresolvedIssue == nil
    }

    var canRetry: Bool {
        unresolvedIssue?.canRetry == true
    }

    var canDiscard: Bool {
        unresolvedIssue != nil
    }

    func refreshPermissionStatus() async {
        lastKnownPermissionStatus = permissionService.currentStatus()
    }

    /// Asks Finder to reveal the resolved sessions directory. Uses the
    /// actual URL the running process resolves at the time of the call —
    /// this is the only reliable way to locate the directory when the app
    /// is sandboxed, since the container path includes an
    /// OS-assigned/redirected prefix that isn't safe to hardcode.
    func revealSessionsFolderInFinder() async {
        revealFolderErrorMessage = nil
        do {
            let root = try await store.sessionsRootDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } catch {
            Log.fileSystem.error("Unable to resolve sessions directory: \(error.localizedDescription, privacy: .public)")
            revealFolderErrorMessage = "Unable to open the sessions folder: \(error.localizedDescription)"
        }
    }

    // MARK: - Start

    func startSession() async {
        guard canStart else {
            Log.session.notice(
                "startSession() ignored; state=\(String(describing: self.state), privacy: .public) unresolved=\(self.unresolvedIssue != nil, privacy: .public)"
            )
            return
        }

        transition(to: .requestingPermission)
        let status = await permissionService.requestPermission()
        lastKnownPermissionStatus = status

        guard status == .granted else {
            Log.permission.error("Microphone permission not granted: \(String(describing: status), privacy: .public)")
            transition(to: .failed("Microphone permission not granted."))
            return
        }

        transition(to: .preparing)

        let sessionID = UUID()

        // Step 3: prepare() first, before anything is created on disk. A
        // failure here leaves nothing behind — no directory, no manifest
        // — since capture never mutates cycleState on a thrown prepare().
        let negotiatedFormat: AVAudioFormat
        do {
            negotiatedFormat = try captureService.prepare()
        } catch {
            Log.session.error("Capture preparation failed: \(error.localizedDescription, privacy: .public)")
            transition(to: .failed(error.localizedDescription))
            return
        }

        var createdPaths: SessionPaths?
        var preparedManifest: SessionManifest?
        var initialManifestPersisted = false
        var writerConstructed = false

        do {
            // Step 4: session directories.
            let paths = try await store.createSessionDirectories(sessionID: sessionID)
            createdPaths = paths

            // Step 5 + 6: bridge the negotiated format, build and persist
            // the initial manifest using it.
            let audioFormat = makeAudioFormatDescriptor(from: negotiatedFormat)
            let manifest = SessionManifest.newSession(
                id: sessionID,
                audioFormat: audioFormat,
                targetChunkDurationSeconds: 30.0
            )
            preparedManifest = manifest

            try await store.writeManifest(manifest, paths: paths)
            initialManifestPersisted = true

            let logger = try await store.createSessionLogger(paths: paths)
            await logger.log("Session \(sessionID.uuidString) created.")

            // Step 7: construct the writer through the injected factory.
            let writer = try chunkWriterFactory.makeWriter(
                chunksDirectory: paths.chunksDirectory,
                format: negotiatedFormat,
                targetChunkDurationSeconds: 30.0
            )
            writerConstructed = true

            // Step 8: construct and fully install the retained runtime
            // and its event consumer — strictly before any capture
            // callback is installed, so a callback firing at any point
            // during or immediately after start() can only ever observe
            // already-valid, fully-installed state.
            let runtime = RecordingRuntime(id: UUID(), writer: writer, paths: paths)
            currentRuntime = runtime
            activeSession = manifest
            currentSessionPaths = paths
            currentSessionLogger = logger

            let eventConsumerRuntimeID = runtime.id
            runtime.eventConsumerTask = Task { @MainActor [weak self] in
                await self?.consumeEvents(runtimeID: eventConsumerRuntimeID)
            }

            // Step 9: start capture. `onBuffer` captures ONLY `writer` —
            // a plain Sendable existential — never `self` or `runtime`,
            // so it remains safe no matter when the realtime IO thread
            // invokes it relative to this call returning. `onFailure`
            // captures a weak SessionManager reference and this runtime's
            // generation id, then schedules MainActor handling; it never
            // touches MainActor state itself and never blocks its caller.
            let runtimeID = runtime.id
            try captureService.start(
                onBuffer: { buffer in
                    writer.acceptBuffer(buffer)
                },
                onFailure: { [weak self] error in
                    Task { @MainActor in
                        self?.handleCaptureFailure(runtimeID: runtimeID, error: error)
                    }
                }
            )

            // Step 10: no suspension between here and the transition —
            // neither `captureService.start` nor `transition(to:)` is
            // `async`, so nothing can interleave in this interval.
            transition(to: .recording)
            Log.session.info("Session started: \(sessionID.uuidString, privacy: .public)")
        } catch {
            await handleStartFailure(
                sessionID: sessionID,
                paths: createdPaths,
                preparedManifest: preparedManifest,
                initialManifestPersisted: initialManifestPersisted,
                writerConstructed: writerConstructed,
                underlyingError: error
            )
        }
    }

    /// Cleans up after any failure occurring after a successful
    /// `prepare()` — directory creation, initial manifest persistence,
    /// writer construction, or `captureService.start()` itself. Always
    /// releases capture (which may already be `.prepared` or, if
    /// `start()` itself threw, `.running` with its tap/observer already
    /// installed — `stop()` is safe and correct from either state) and,
    /// if a writer/runtime was already constructed, finishes and drains
    /// it before discarding it. No buffer could have been accepted in
    /// either case: `start()` never calls `onBuffer` synchronously, and a
    /// thrown `start()` never actually gets the engine running.
    private func handleStartFailure(
        sessionID: UUID,
        paths: SessionPaths?,
        preparedManifest: SessionManifest?,
        initialManifestPersisted: Bool,
        writerConstructed: Bool,
        underlyingError: Error
    ) async {
        let description = underlyingError.localizedDescription
        Log.session.error("Session start failed: \(description, privacy: .public)")

        _ = await captureService.stop()

        if writerConstructed, let runtime = currentRuntime {
            runtime.writer.finishRecording()
            await runtime.eventConsumerTask?.value
            currentRuntime = nil
        }

        guard let paths else {
            // Directories were never created; nothing on disk to
            // reconcile, and startSession()'s ordering means a manifest
            // could not have been constructed without paths existing
            // first, so preparedManifest/initialManifestPersisted would
            // also be nil/false here.
            transition(to: .failed(description))
            return
        }

        var failedManifest = preparedManifest ?? SessionManifest.newSession(
            id: sessionID,
            audioFormat: .defaultTarget,
            targetChunkDurationSeconds: 30.0
        )
        failedManifest.status = .failed
        failedManifest.endDate = Date()
        failedManifest.endReason = .error
        failedManifest.endedCleanly = false
        failedManifest.failureDescription = description

        do {
            try await store.writeManifest(failedManifest, paths: paths)
            activeSession = nil
            currentSessionPaths = nil
            currentSessionLogger = nil
            transition(to: .failed(description))
        } catch let persistError {
            Log.session.error(
                "Failed to persist failure state for session \(sessionID.uuidString, privacy: .public): \(persistError.localizedDescription, privacy: .public)"
            )
            activeSession = initialManifestPersisted ? preparedManifest : nil
            currentSessionPaths = paths
            pendingManifestForRetry = failedManifest
            retryKind = .prepareFailure
            unresolvedIssue = UnresolvedSessionIssue(
                sessionID: sessionID,
                message: "Failed to save failure record for session \(sessionID.uuidString): \(persistError.localizedDescription)",
                canRetry: true
            )
            transition(to: .failed(description))
        }
    }

    // MARK: - Steady-state event consumption

    /// Consumes `.finalized` events for one recording cycle: validates
    /// sequence continuity, accumulates valid metadata in memory,
    /// publishes it, and persists it atomically unless a prior interior
    /// persistence failure has switched this cycle into memory-only mode.
    /// Never awaits its own task and never awaits the shared shutdown
    /// task it may signal — on any terminal condition it only *signals*
    /// `requestShutdown` (fire-and-forget) and then lets its own loop end
    /// naturally, so the separate shutdown task can safely await this
    /// task's completion without risking a self-await deadlock.
    private func consumeEvents(runtimeID: UUID) async {
        guard let runtime = currentRuntime, runtime.id == runtimeID else { return }
        let events = runtime.writer.events

        do {
            for try await event in events {
                guard let runtime = currentRuntime, runtime.id == runtimeID else { return }
                switch event {
                case .finalized(let metadata):
                    let wasValid = handleFinalizedEvent(metadata, runtime: runtime, runtimeID: runtimeID)
                    if wasValid, !runtime.interiorPersistenceHasFailed {
                        await persistInteriorUpdate(runtime: runtime, runtimeID: runtimeID)
                    }
                }
            }
        } catch {
            requestShutdown(runtimeID: runtimeID, trigger: .operational(.writerStreamFailure(error)))
        }
    }

    /// Validates one `.finalized` event's sequence number against the
    /// runtime's expectation. A duplicate, gap, or out-of-order event is
    /// terminal: it is not appended, the underlying file (if any) is left
    /// completely untouched, and a terminal sequence-violation failure is
    /// signaled. Returns whether the event was valid.
    private func handleFinalizedEvent(
        _ metadata: ChunkMetadata,
        runtime: RecordingRuntime,
        runtimeID: UUID
    ) -> Bool {
        guard metadata.sequenceNumber == runtime.expectedNextSequence else {
            requestShutdown(
                runtimeID: runtimeID,
                trigger: .operational(.chunkSequenceViolation(
                    expected: runtime.expectedNextSequence,
                    got: metadata.sequenceNumber
                ))
            )
            return false
        }

        runtime.expectedNextSequence += 1
        runtime.accumulatedChunks.append(metadata)

        if var manifest = activeSession, currentRuntime?.id == runtimeID {
            manifest.chunks = runtime.accumulatedChunks
            activeSession = manifest
        }

        return true
    }

    /// Persists the manifest after one valid finalized event, unless
    /// interior persistence has already failed once for this cycle. On
    /// failure, enters memory-only accumulation mode (no further interior
    /// writes are attempted) and signals shutdown without awaiting it —
    /// the complete accumulated list is retried exactly once, at Stop,
    /// via the existing unresolved-issue/retry mechanism.
    private func persistInteriorUpdate(runtime: RecordingRuntime, runtimeID: UUID) async {
        guard var manifest = activeSession, currentRuntime?.id == runtimeID else { return }
        manifest.chunks = runtime.accumulatedChunks
        do {
            try await store.writeManifest(manifest, paths: runtime.paths)
        } catch {
            runtime.interiorPersistenceHasFailed = true
            requestShutdown(
                runtimeID: runtimeID,
                trigger: .operational(.interiorManifestPersistenceFailure(error))
            )
        }
    }

    // MARK: - Failure signaling

    /// Routes an asynchronous capture failure into the shared shutdown
    /// path. Never awaits the resulting shutdown — the capture layer's
    /// own failure-delivery mechanism must never be blocked waiting for
    /// shutdown to complete.
    @MainActor
    private func handleCaptureFailure(runtimeID: UUID, error: Error) {
        requestShutdown(runtimeID: runtimeID, trigger: .operational(.captureFailure(error)))
    }

    /// Records an operational failure for diagnostic/precedence purposes.
    /// Avoids double-reporting the same underlying capture failure twice:
    /// a `.captureStopOutcomeFailure` that arrives after a `.captureFailure`
    /// was already recorded for this cycle is treated as mere
    /// confirmation of that same failure and is not appended again. Any
    /// other distinct failure — including a `.captureStopOutcomeFailure`
    /// with no matching prior `.captureFailure` — is retained as its own
    /// entry (primary if first, secondary diagnostic otherwise).
    private func recordOperationalFailure(_ cause: OperationalFailureCause, runtime: RecordingRuntime) {
        if case .captureStopOutcomeFailure = cause,
           runtime.operationalFailures.contains(where: { $0.isCaptureFailure }) {
            return
        }
        runtime.operationalFailures.append(cause)
    }

    /// Formats the accumulated operational failures into the single
    /// existing `failureDescription` field: the primary (first) cause's
    /// description, followed by a deterministic "; additional error
    /// during shutdown: ..." clause for each distinct later cause. No
    /// persisted schema change.
    private func formatFailureDescription(_ failures: [OperationalFailureCause]) -> String {
        guard let primary = failures.first else {
            return "Recording failed."
        }
        let secondaries = failures.dropFirst()
        guard !secondaries.isEmpty else {
            return primary.description
        }
        let secondaryText = secondaries
            .map { "; additional error during shutdown: \($0.description)" }
            .joined()
        return primary.description + secondaryText
    }

    // MARK: - Shared, joinable shutdown

    /// The single entry point for beginning or joining this runtime's
    /// shutdown. Idempotent and joinable: the first call (from whichever
    /// of user Stop, a capture failure callback, or the event consumer
    /// gets there first) creates the one shared shutdown `Task` and
    /// transitions `.recording` → `.stopping`; every later call — from
    /// any trigger — simply records its operational failure (if any) and
    /// returns the already-created task rather than starting a second
    /// one. A stale call for a runtime that has already been fully torn
    /// down (`currentRuntime` no longer matches `runtimeID`) is safely
    /// dropped.
    @discardableResult
    @MainActor
    private func requestShutdown(runtimeID: UUID, trigger: ShutdownTrigger) -> Task<Void, Never>? {
        guard let runtime = currentRuntime, runtime.id == runtimeID else {
            return nil
        }

        if case .operational(let cause) = trigger {
            recordOperationalFailure(cause, runtime: runtime)
        }

        if let existing = runtime.shutdownTask {
            return existing
        }

        if state == .recording {
            transition(to: .stopping)
        }

        // Strong self-capture, deliberately: the shutdown task must
        // finish tearing down capture and writer resources even if
        // SessionManager itself became otherwise unreferenced. The
        // resulting temporary retain cycle ends the moment this task
        // completes and clears `currentRuntime`/`shutdownTask` below.
        let task = Task {
            await self.performSharedShutdown(runtimeID: runtimeID)
        }
        runtime.shutdownTask = task
        return task
    }

    /// Performs the actual shutdown sequence exactly once per runtime:
    /// stop and drain capture, finish the writer, await the event
    /// consumer's completion, fold in the capture-stop outcome, build and
    /// persist the final manifest (`.completed` only if no operational
    /// failure was ever recorded; `.failed` with deterministic
    /// diagnostics otherwise), and release the runtime.
    private func performSharedShutdown(runtimeID: UUID) async {
        guard let runtime = currentRuntime, runtime.id == runtimeID else { return }

        let outcome = await captureService.stop()

        runtime.writer.finishRecording()
        await runtime.eventConsumerTask?.value

        if let failure = outcome.failure {
            recordOperationalFailure(.captureStopOutcomeFailure(failure), runtime: runtime)
        }

        let primaryFailure = runtime.primaryOperationalFailure

        guard var finalManifest = activeSession else {
            Log.session.fault("performSharedShutdown reached with no activeSession; this indicates a bug.")
            currentRuntime = nil
            transition(to: .failed("Internal error: session state lost during shutdown."))
            return
        }

        finalManifest.chunks = runtime.accumulatedChunks
        finalManifest.endDate = Date()
        finalManifest.observedCaptureCopyFailureCount = outcome.observedCopyFailureCount

        if let primaryFailure {
            finalManifest.status = .failed
            finalManifest.endReason = .error
            finalManifest.endedCleanly = false
            finalManifest.failureDescription = formatFailureDescription(runtime.operationalFailures)
        } else {
            finalManifest.status = .completed
            finalManifest.endReason = .userStopped
            finalManifest.endedCleanly = true
            finalManifest.failureDescription = nil
        }

        let paths = runtime.paths

        // `currentRuntime` is deliberately kept alive (not nil'd) through
        // the `await store.writeManifest(...)` suspension below and is
        // only cleared immediately before each branch's final
        // `transition(to:)` call. `store`'s production implementation is
        // an `actor`, so that `await` is a genuine cross-actor suspension
        // point — a second, concurrent `stopSession()` call landing in
        // its `.stopping` branch reads `currentRuntime?.shutdownTask` to
        // join this same shutdown; if `currentRuntime` were cleared
        // before this suspension, that read would see `nil` and return
        // immediately while `state` is still `.stopping`, breaking
        // `stopSession()`'s own documented "a second concurrent caller
        // observes the same real completion" contract.
        do {
            try await store.writeManifest(finalManifest, paths: paths)
            await currentSessionLogger?.log(
                primaryFailure == nil
                    ? "Session \(finalManifest.sessionID.uuidString) stopped by user."
                    : "Session \(finalManifest.sessionID.uuidString) ended with a failure: \(finalManifest.failureDescription ?? "unknown")",
                level: primaryFailure == nil ? "INFO" : "ERROR"
            )
            await currentSessionLogger?.close()

            activeSession = nil
            currentSessionPaths = nil
            currentSessionLogger = nil
            pendingManifestForRetry = nil
            retryKind = nil
            if finalManifest.status == .completed {
                lastCompletedSession = finalManifest
            }

            currentRuntime = nil
            transition(to: finalManifest.status == .completed ? .completed : .failed(finalManifest.failureDescription ?? "Recording failed."))
            Log.session.info(
                "Session ended: \(finalManifest.sessionID.uuidString, privacy: .public) status=\(finalManifest.status.rawValue, privacy: .public)"
            )
        } catch {
            Log.session.error(
                "Failed to persist final manifest for session \(finalManifest.sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            await currentSessionLogger?.log(
                "Failed to persist final manifest: \(error.localizedDescription)",
                level: "ERROR"
            )

            pendingManifestForRetry = finalManifest
            retryKind = .stopFinalization
            unresolvedIssue = UnresolvedSessionIssue(
                sessionID: finalManifest.sessionID,
                message: "Could not confirm session \(finalManifest.sessionID.uuidString) finished saving: \(error.localizedDescription)",
                canRetry: true
            )

            currentRuntime = nil
            transition(to: .failed(finalManifest.failureDescription ?? error.localizedDescription))
        }
    }

    // MARK: - Stop

    /// Requests or joins this cycle's shutdown. In `.recording`, begins a
    /// new shutdown (`.userStopped` trigger) and awaits it. In
    /// `.stopping`, joins whatever shutdown is already in flight rather
    /// than returning early — a second concurrent `stopSession()` call
    /// observes the same real completion as the first. Outside an active
    /// recording/runtime, remains a harmless no-op exactly as before.
    func stopSession() async {
        let task: Task<Void, Never>?

        switch state {
        case .recording:
            guard let runtime = currentRuntime else {
                Log.session.fault("stopSession() reached .recording with no active runtime; this indicates a bug.")
                transition(to: .failed("Internal error: no active session to stop."))
                return
            }
            task = requestShutdown(runtimeID: runtime.id, trigger: .userStopped)
        case .stopping:
            task = currentRuntime?.shutdownTask
        default:
            Log.session.notice("stopSession() ignored; state=\(String(describing: self.state), privacy: .public)")
            return
        }

        await task?.value
    }

    /// Retries whichever manifest write previously failed — either
    /// finishing a preparation failure's persisted failure record, or
    /// finalizing a stopped/failed session. Safe to call repeatedly;
    /// concurrent invocations are ignored while one is already in flight.
    func retryResolution() async {
        guard !isRetryInFlight else {
            Log.session.notice("retryResolution() ignored; a retry is already in progress")
            return
        }
        guard let issue = unresolvedIssue, issue.canRetry,
              let pending = pendingManifestForRetry,
              let paths = currentSessionPaths,
              let kind = retryKind else {
            Log.session.notice("retryResolution() called with nothing eligible to retry")
            return
        }

        isRetryInFlight = true
        defer { isRetryInFlight = false }

        do {
            try await store.writeManifest(pending, paths: paths)

            switch kind {
            case .stopFinalization:
                // A successfully retried final manifest must be
                // interpreted according to its own persisted status —
                // never unconditionally treated as a completed session.
                // `.failed` stays `.failed`: `(.failed, .failed)` is not
                // a listed valid transition and none is needed, since the
                // manifest is simply now durably confirmed, not changed.
                if pending.status == .completed {
                    await currentSessionLogger?.log("Session \(pending.sessionID.uuidString) finalized on retry.")
                    await currentSessionLogger?.close()
                    lastCompletedSession = pending
                    transition(to: .completed)
                    Log.session.info("Session finalized on retry: \(pending.sessionID.uuidString, privacy: .public)")
                } else {
                    await currentSessionLogger?.log("Failed session \(pending.sessionID.uuidString) finalized on retry.")
                    await currentSessionLogger?.close()
                    Log.session.info("Failed session's final manifest persisted on retry: \(pending.sessionID.uuidString, privacy: .public)")
                }
                activeSession = nil
                currentSessionPaths = nil
                currentSessionLogger = nil
                pendingManifestForRetry = nil
                retryKind = nil
                unresolvedIssue = nil

            case .prepareFailure:
                await currentSessionLogger?.close()
                activeSession = nil
                currentSessionPaths = nil
                currentSessionLogger = nil
                pendingManifestForRetry = nil
                retryKind = nil
                unresolvedIssue = nil
                Log.session.info(
                    "Failure record persisted on retry for session \(pending.sessionID.uuidString, privacy: .public); call resetAfterFailure() to continue."
                )
            }
        } catch {
            Log.session.error("retryResolution() failed again: \(error.localizedDescription, privacy: .public)")
            unresolvedIssue = UnresolvedSessionIssue(
                sessionID: pending.sessionID,
                message: "Retry failed again: \(error.localizedDescription)",
                canRetry: true
            )
        }
    }

    /// Gives up on confirming what happened to the unresolved session.
    /// Closes any open resources best-effort and clears in-memory
    /// references, but deliberately does NOT overwrite the on-disk
    /// manifest with unverified data and does NOT delete any session
    /// files. Only ever invoked in response to an explicit, confirmed
    /// user action — never automatically.
    func discardUnresolvedSession() async {
        guard !isDiscardInFlight else {
            Log.session.notice("discardUnresolvedSession() ignored; already in progress")
            return
        }
        guard let issue = unresolvedIssue else {
            Log.session.notice("discardUnresolvedSession() called with no unresolved issue")
            return
        }

        isDiscardInFlight = true
        defer { isDiscardInFlight = false }

        Log.session.error(
            "Abandoning recovery attempt for session \(issue.sessionID.uuidString, privacy: .public) without confirmed finalization. Session files are left untouched on disk."
        )
        await currentSessionLogger?.log(
            "Recovery attempt abandoned by user without confirmed finalization.",
            level: "ERROR"
        )
        await currentSessionLogger?.close()

        activeSession = nil
        currentSessionPaths = nil
        currentSessionLogger = nil
        pendingManifestForRetry = nil
        retryKind = nil
        unresolvedIssue = nil
    }

    /// Explicitly clears a resolved failure and returns to `.idle`. Only
    /// valid once `unresolvedIssue` is nil — i.e., after either the
    /// failure path automatically persisted an accurate failed manifest,
    /// or the user called `retryResolution()` / `discardUnresolvedSession()`.
    func resetAfterFailure() {
        guard canReset else {
            Log.session.notice(
                "resetAfterFailure() ignored; state=\(String(describing: self.state), privacy: .public) unresolved=\(self.unresolvedIssue != nil, privacy: .public)"
            )
            return
        }
        activeSession = nil
        currentSessionPaths = nil
        currentSessionLogger = nil
        transition(to: .idle)
    }

    private func transition(to newState: RecordingState) {
        guard RecordingState.isValidTransition(from: state, to: newState) else {
            Log.session.fault(
                "Rejected invalid state transition: \(String(describing: self.state), privacy: .public) -> \(String(describing: newState), privacy: .public)"
            )
            return
        }
        Log.session.debug(
            "State transition: \(String(describing: self.state), privacy: .public) -> \(String(describing: newState), privacy: .public)"
        )
        state = newState
    }
}
