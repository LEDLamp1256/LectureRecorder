import Combine
import Foundation

/// Performs the one durable write of a diarization run: atomically replacing
/// the session's sidecar. The production conformer runs
/// `SpeakerDiarizationStore.save` off the main actor; tests inject a
/// conformer that can hold the save to observe the commit boundary.
nonisolated protocol SessionDiarizationSidecarCommitting: Sendable {
    func commit(_ result: SpeakerDiarizationResult, to snapshot: SessionDiarizationSourceSnapshot) async throws
}

/// Production `SessionDiarizationSidecarCommitting`: `SpeakerDiarizationStore`
/// on the global concurrent executor, never the caller's actor.
nonisolated struct SpeakerDiarizationStoreCommitter: SessionDiarizationSidecarCommitting {
    private let store: SpeakerDiarizationStore

    init(store: SpeakerDiarizationStore = SpeakerDiarizationStore()) {
        self.store = store
    }

    func commit(_ result: SpeakerDiarizationResult, to snapshot: SessionDiarizationSourceSnapshot) async throws {
        try await save(result, to: snapshot)
    }

    @concurrent
    private func save(_ result: SpeakerDiarizationResult, to snapshot: SessionDiarizationSourceSnapshot) async throws {
        try store.save(result, source: snapshot.source, sessionPaths: snapshot.sessionPaths)
    }
}

/// The single, app-wide authoritative owner of speaker-diarization
/// operations. Mirrors the transcription, Notes, and Summary services'
/// single-owner, epoch-guarded admission/cancellation/shutdown shape.
///
/// Owns: the active session ID, the operation epoch, the single in-flight
/// `Task`, the published phase, cancellation, and shutdown state. Views and
/// presenters never call a `SpeakerDiarizing` backend directly — only this
/// type does.
///
/// Its admission slot is fully independent: it never consults recording,
/// transcription, Notes, or Summary state, so a diarization run may overlap
/// any of them (including a different session's live recording). The only
/// refusals are another diarization run already owning the slot and app
/// shutdown. The target session's own eligibility (terminal status plus a
/// valid `LecturePlaybackSource`) is re-proven from disk by every run.
///
/// Durable state is exactly one artifact, `diarization/result.json`, replaced
/// atomically only by a fully validated result produced from audio still
/// current at commit time. A run that is cancelled, fails, or finds its
/// source changed leaves any previous sidecar untouched; an unfinished run
/// leaves nothing to recover. Nothing here runs automatically.
///
/// Commit boundary: once the result is validated, the run — on the main
/// actor, synchronously — checks cancellation and, if not cancelled, marks
/// the operation commit-authorized and enters `.saving`. `cancel` and
/// `beginShutdown` also run on the main actor, so the two are totally
/// ordered: a cancellation recorded first wins and nothing is saved; once
/// authorization has happened, cancellation is too late and is ignored for
/// that operation, and the atomic save (off the main actor) always runs to
/// `.completed` or `.failed(.saveFailed)`.
@MainActor
final class SessionDiarizationService: ObservableObject {
    enum OperationPhase: Equatable {
        case idle
        /// Reading and validating the session's current terminal audio.
        case preparingSource
        /// The backend is analyzing the audio.
        case diarizing
        /// Re-proving the audio is unchanged and normalizing the output.
        case validating
        /// Commit-authorized: atomically replacing the sidecar. Not
        /// cancellable — `cancel` is a no-op from here on.
        case saving
        case cancelling
        case finished(DiarizationOperationOutcome)
    }

    enum DiarizationOperationOutcome: Equatable, Sendable {
        /// The result was atomically committed as the session's sidecar.
        case completed(SpeakerDiarizationResult)
        /// Cancellation won before commit authorization; nothing new was
        /// saved.
        case cancelled
        /// The session's audio changed (different fingerprint) or stopped
        /// being terminal while the backend ran; the output was discarded.
        case staleSource
        /// The session's audio could not be loaded and validated — at
        /// operation start, or when re-proven after the backend ran (the
        /// output is then discarded).
        case sourceUnavailable(SessionDiarizationSourceError)
        case failed(DiarizationOperationFailure)
    }

    /// Operational failures. A backend failure carries the backend's own
    /// `LocalizedError` text (the backend owns keeping it free of paths and
    /// content); a save failure carries only `SpeakerDiarizationStoreError`
    /// text. Anything else gets a fixed generic description.
    enum DiarizationOperationFailure: Equatable, Sendable {
        case backendFailed(description: String)
        /// The backend output could not be normalized into a valid result.
        case invalidBackendOutput
        case saveFailed(description: String)
    }

    enum AdmissionResult: Sendable, Equatable {
        case admitted
        /// Another diarization operation is already active app-wide.
        case busy
        /// Shutdown has begun; admission is permanently closed.
        case shuttingDown
    }

    /// Identifies exactly one admitted operation that has fully released
    /// ownership — see `lastReleasedOperation`. A synchronization signal
    /// only, never a source of truth: an observer re-reads durable state
    /// (`peekState`) afterwards.
    struct OperationRelease: Equatable, Sendable {
        let sessionID: UUID
        /// The `operationEpoch` this operation was admitted under. Read
        /// `operationEpoch` synchronously right after `.admitted` to learn
        /// the token to match.
        let operationEpoch: Int
        /// The terminal outcome this operation published. `nil` only if the
        /// run ended without publishing a terminal phase, which no current
        /// path does.
        let outcome: DiarizationOperationOutcome?
    }

    /// What `peekState` found on disk for a session.
    enum DurableState: Equatable, Sendable {
        /// The session's current audio is not a diarization source.
        case sourceUnavailable(SessionDiarizationSourceError)
        /// The sidecar's state against the session's current audio:
        /// `.absent`, `.loaded` (usable), or `.unavailable` (stale, damaged,
        /// unsupported, or unsafe).
        case sidecar(SpeakerDiarizationLoadOutcome)
    }

    enum ShutdownOutcome: Sendable, Equatable {
        case completed
        case timedOut
    }

    nonisolated static let defaultShutdownTimeout: TimeInterval = 5

    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var phase: OperationPhase = .idle
    /// The most recently released admitted operation, published exactly
    /// once per admission, only after `currentTask`/`activeSessionID` have
    /// been cleared. `nil` until the first admitted operation releases;
    /// never published for a rejected admission. Memory-only.
    @Published private(set) var lastReleasedOperation: OperationRelease?

    /// Set synchronously by `beginShutdown()` and never cleared.
    private(set) var isShuttingDown = false
    private(set) var operationEpoch = 0

    private let diarizer: any SpeakerDiarizing
    private let sourceLoader: any SessionDiarizationSourceLoading
    private let store: SpeakerDiarizationStore
    private let sidecarCommitter: any SessionDiarizationSidecarCommitting
    private let now: @Sendable () -> Date
    private let shutdownPollInterval: TimeInterval

    private var currentTask: Task<Void, Never>?
    /// Set synchronously on the main actor when the current operation
    /// crosses commit authorization; cleared at admission and release.
    /// While set, `cancel` and `beginShutdown` never cancel the operation.
    private var isCommitAuthorized = false

    /// Cheap: stores its collaborators only. No model, audio, or sidecar is
    /// touched until an explicitly admitted operation (or `peekState`) runs.
    init(
        diarizer: any SpeakerDiarizing,
        sourceLoader: any SessionDiarizationSourceLoading = SessionDiarizationSourceLoader(),
        store: SpeakerDiarizationStore = SpeakerDiarizationStore(),
        sidecarCommitter: (any SessionDiarizationSidecarCommitting)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        shutdownPollInterval: TimeInterval = 0.02
    ) {
        self.diarizer = diarizer
        self.sourceLoader = sourceLoader
        self.store = store
        self.sidecarCommitter = sidecarCommitter ?? SpeakerDiarizationStoreCommitter(store: store)
        self.now = now
        self.shutdownPollInterval = shutdownPollInterval
    }

    // MARK: - Public entry points

    /// Explicitly diarizes `sessionID`'s current terminal audio and, on
    /// success, atomically replaces its sidecar (an existing valid result
    /// included). Admission is synchronous, before any suspension.
    @discardableResult
    func diarize(sessionID: UUID) -> AdmissionResult {
        guard !isShuttingDown else { return .shuttingDown }
        guard currentTask == nil else { return .busy }

        operationEpoch += 1
        let myEpoch = operationEpoch
        activeSessionID = sessionID
        isCommitAuthorized = false
        phase = .preparingSource

        currentTask = Task { [weak self] in
            await self?.run(sessionID: sessionID, epoch: myEpoch)
            self?.releaseOperation(sessionID: sessionID, epoch: myEpoch)
        }
        return .admitted
    }

    /// Requests cooperative cancellation of the active operation, if it
    /// belongs to `sessionID`; a no-op otherwise, and a no-op once the
    /// operation is commit-authorized (`.saving`). Best-effort before that:
    /// a backend may keep running a non-cancellable step, but its output is
    /// never saved once cancellation has been recorded.
    func cancel(sessionID: UUID) {
        guard currentTask != nil, activeSessionID == sessionID, !isCommitAuthorized else { return }
        phase = .cancelling
        currentTask?.cancel()
    }

    /// Read-only durable state for `sessionID`, re-derived from disk: the
    /// current source, then the sidecar checked against it. Never runs
    /// inference, never repairs or deletes, never writes anything, and is
    /// safe to call while any operation is active.
    func peekState(sessionID: UUID) async -> DurableState {
        let snapshot: SessionDiarizationSourceSnapshot
        do {
            snapshot = try await sourceLoader.loadSourceSnapshot(sessionID: sessionID)
        } catch {
            return .sourceUnavailable(Self.sourceError(error))
        }
        return .sidecar(await Self.loadSidecar(store: store, snapshot: snapshot))
    }

    // MARK: - Shutdown

    /// The synchronous half of app termination: closes admission and
    /// requests cancellation, with no `await`. Idempotent. An operation
    /// already commit-authorized is not cancelled; `shutdown` simply waits
    /// (bounded) for its atomic save to finish.
    func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        if currentTask != nil, !isCommitAuthorized {
            phase = .cancelling
            currentTask?.cancel()
        }
    }

    /// Begins shutdown, then waits at most `timeout` for the active
    /// operation to release. Polls ownership rather than awaiting the task,
    /// so an uncooperative backend cannot extend the bound. A timeout is
    /// safe: the sidecar save is atomic and nothing else is persisted.
    @discardableResult
    func shutdown(timeout: TimeInterval = SessionDiarizationService.defaultShutdownTimeout) async -> ShutdownOutcome {
        beginShutdown()
        guard currentTask != nil else { return .completed }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(max(timeout, 0) * 1_000)))
        let pollNanoseconds = UInt64(max(shutdownPollInterval, 0.001) * 1_000_000_000)
        while currentTask != nil {
            if clock.now >= deadline { return .timedOut }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return .completed
    }

    // MARK: - Release

    /// Publication order: the release is captured first, ownership is
    /// cleared next, and `lastReleasedOperation` is published last.
    private func releaseOperation(sessionID: UUID, epoch: Int) {
        guard epoch == operationEpoch else { return }
        var outcome: DiarizationOperationOutcome?
        if case .finished(let terminal) = phase { outcome = terminal }
        let release = OperationRelease(sessionID: sessionID, operationEpoch: epoch, outcome: outcome)
        currentTask = nil
        activeSessionID = nil
        isCommitAuthorized = false
        lastReleasedOperation = release
    }

    // MARK: - Execution

    private func run(sessionID: UUID, epoch: Int) async {
        // Defensive: a stale epoch cannot be admitted while this run owns
        // the slot, but every publication stays epoch-guarded regardless.
        func finish(_ outcome: DiarizationOperationOutcome) {
            guard epoch == operationEpoch else { return }
            phase = .finished(outcome)
        }
        // Progress never overwrites `.cancelling`.
        func advance(to next: OperationPhase) {
            guard epoch == operationEpoch, !Task.isCancelled else { return }
            phase = next
        }

        guard !Task.isCancelled else { return finish(.cancelled) }

        let analyzed: SessionDiarizationSourceSnapshot
        do {
            analyzed = try await sourceLoader.loadSourceSnapshot(sessionID: sessionID)
        } catch {
            return finish(Task.isCancelled ? .cancelled : .sourceUnavailable(Self.sourceError(error)))
        }
        guard !Task.isCancelled else { return finish(.cancelled) }

        advance(to: .diarizing)
        let output: SpeakerDiarizationOutput
        do {
            output = try await diarizer.diarize(SpeakerDiarizationRequest(source: analyzed.source))
        } catch {
            if Task.isCancelled || error is CancellationError { return finish(.cancelled) }
            return finish(.failed(.backendFailed(description: Self.backendFailureDescription(error))))
        }
        // A backend that finished a non-cancellable step after cancellation
        // was requested still never reaches the commit.
        guard !Task.isCancelled else { return finish(.cancelled) }

        advance(to: .validating)
        // The source must still be the exact audio analyzed: re-read the
        // manifest, re-prove terminal status and playback validity, and
        // compare the D1 fingerprint. The output is discarded unless all
        // three hold: a session that stopped being terminal or whose
        // fingerprint changed is stale; one that can no longer be loaded
        // and validated at all is unavailable.
        let current: SessionDiarizationSourceSnapshot
        do {
            current = try await sourceLoader.loadSourceSnapshot(sessionID: sessionID)
        } catch {
            if Task.isCancelled { return finish(.cancelled) }
            let sourceError = Self.sourceError(error)
            if case .notTerminal = sourceError { return finish(.staleSource) }
            return finish(.sourceUnavailable(sourceError))
        }
        guard !Task.isCancelled else { return finish(.cancelled) }
        guard current.audioSource == analyzed.audioSource else { return finish(.staleSource) }

        let result: SpeakerDiarizationResult
        do {
            result = try SpeakerDiarizationResult(output: output, source: analyzed.source, createdDate: now())
        } catch {
            return finish(.failed(.invalidBackendOutput))
        }

        // Commit authorization: synchronous on the main actor, with no
        // suspension since the check above, so it is totally ordered with
        // `cancel`/`beginShutdown`. A cancellation recorded before this
        // point wins; after it, cancellation is ignored for this operation.
        guard epoch == operationEpoch, !Task.isCancelled else { return finish(.cancelled) }
        isCommitAuthorized = true
        phase = .saving

        do {
            try await sidecarCommitter.commit(result, to: current)
        } catch {
            return finish(.failed(.saveFailed(description: Self.saveFailureDescription(error))))
        }
        finish(.completed(result))
    }

    // MARK: - Off-main-actor sidecar I/O

    @concurrent
    nonisolated private static func loadSidecar(
        store: SpeakerDiarizationStore,
        snapshot: SessionDiarizationSourceSnapshot
    ) async -> SpeakerDiarizationLoadOutcome {
        store.load(source: snapshot.source, sessionPaths: snapshot.sessionPaths)
    }

    // MARK: - Error mapping

    nonisolated private static func sourceError(_ error: any Error) -> SessionDiarizationSourceError {
        (error as? SessionDiarizationSourceError) ?? .sessionUnavailable
    }

    nonisolated private static func backendFailureDescription(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Speaker diarization failed."
    }

    nonisolated private static func saveFailureDescription(_ error: any Error) -> String {
        (error as? SpeakerDiarizationStoreError)?.errorDescription ?? "The diarization result could not be saved."
    }
}
