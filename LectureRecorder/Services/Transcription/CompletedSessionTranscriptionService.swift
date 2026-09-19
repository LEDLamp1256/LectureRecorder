import Combine
import Foundation

/// The single, app-wide authoritative owner of completed-session
/// transcription operations. `@MainActor` so its admission check can
/// inspect `SessionManager.state` synchronously, on the same actor and
/// without an intervening suspension — required so a recording Start that
/// has already transitioned `SessionManager` away from `.idle` can never
/// race a transcription admission that hasn't yet reserved ownership (see
/// `beginOperation`).
///
/// Owns: the active session ID, the operation generation, the single
/// in-flight `Task`, published phase/progress, and cancellation. Views
/// must never call `TranscriptionCoordinator` directly — only this type
/// does.
@MainActor
final class CompletedSessionTranscriptionService: ObservableObject {
    enum OperationPhase: Equatable {
        case idle
        case preparing
        case recovering
        case enqueuing
        case processing(completed: Int, total: Int, currentlyProcessing: Int)
        case cancelling
        case finished(SessionTranscriptionStatus)
    }

    enum AdmissionResult: Sendable, Equatable {
        case admitted
        /// Another completed-session transcription operation is already
        /// active app-wide.
        case busy
        /// `SessionManager` has already won admission for a recording
        /// cycle (or holds an unresolved recovery state) — see the
        /// accepted asymmetric overlap policy.
        case recordingActive
        /// `shutdown()` has been called: app termination is underway and
        /// admission is permanently closed for the remainder of this
        /// instance's lifetime. Never reported as `.busy` (a transient,
        /// retryable state) or `.recordingActive` (an unrelated refusal
        /// reason) — a caller needs to know quitting is genuinely why this
        /// was refused, not that it should retry.
        case shuttingDown
    }

    /// The result of `shutdown(timeout:)`: whether the active operation (if
    /// any) actually released ownership within the bound, or the bound
    /// elapsed first. Either way `shutdown` has already closed admission
    /// and requested cancellation before returning — `.timedOut` only means
    /// cooperative cleanup did not finish in time, never that shutdown
    /// failed to start it.
    enum ShutdownOutcome: Sendable, Equatable {
        case completed
        case timedOut
    }

    /// The app-termination bound used by production callers
    /// (`AppTerminationDelegate`). Deliberately independent of
    /// `WhisperT3BPolicy.processTimeout` (300s, the *inference* timeout) —
    /// this is a separate, much smaller "how long normal quit waits for
    /// cooperative cleanup" policy. `FoundationProcessRunner`'s own
    /// cancellation escalation (default 2s grace period) already bounds
    /// how long a killed worker process takes to actually die; this value
    /// only needs enough headroom above that for the coordinator's
    /// post-cancellation filesystem reconciliation, not for inference
    /// itself.
    /// `nonisolated` (not just `static`): under this codebase's default
    /// `MainActor` isolation, a plain `static let` on a `@MainActor` type
    /// is itself `MainActor`-isolated, which made it illegal to reference
    /// as a default-argument expression (`timeout:` below) — default
    /// arguments are evaluated in a context Swift does not treat as
    /// inheriting the enclosing type's isolation. A `nonisolated` constant
    /// is safe here: it is an immutable `TimeInterval` literal, not
    /// mutable state, so nothing about actor-isolation safety is given up.
    nonisolated static let defaultShutdownTimeout: TimeInterval = 5

    /// Poll granularity for `shutdown`'s bounded wait. Exposed via `init`
    /// only so tests can keep the bounded-wait tests fast; production
    /// always uses the default.
    private let shutdownPollInterval: TimeInterval

    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var phase: OperationPhase = .idle {
        didSet {
            // Purely additive acceptance-diagnostics observation of every
            // terminal state this operation reaches — see
            // `AcceptanceDiagnosticLogger`. Never itself a source of truth;
            // reads only already-published state.
            guard case .finished(let status) = phase, let activeSessionID else { return }
            AcceptanceDiagnosticLogger.shared.log(
                AcceptanceDiagnosticEvent.Transcription.completed,
                metadata: [
                    "sessionID": .uuid(activeSessionID),
                    "status": .string(Self.diagnosticDescription(for: status))
                ],
                elapsedSeconds: currentRunStartInstant.map(AcceptanceDiagnosticLogger.elapsedSeconds(since:))
            )
        }
    }
    @Published private(set) var displayedSegments: [OrderedSegment] = []
    /// Set alongside `activeSessionID` at admission, purely so the
    /// `phase` diagnostic observer above can report total run elapsed —
    /// never consulted by any operational logic.
    private var currentRunStartInstant: ContinuousClock.Instant?

    /// Set synchronously, before any `await`, by `shutdown()` — never by
    /// any other path, and never cleared once set (this instance is done
    /// admitting new work for the rest of its lifetime; deliberately not
    /// persisted). Checked first in `beginOperation`, ahead of every other
    /// admission rule, so there is no window in which a concurrent
    /// Transcribe/Continue/Retry from another window can be admitted after
    /// shutdown has begun.
    private(set) var isShuttingDown = false

    private(set) var generation = 0

    private let sessionManager: SessionManager
    private let store: any TranscriptionStoring
    private let coordinator: TranscriptionCoordinator
    private let sessionsRootResolver: @Sendable () throws -> URL

    private var currentTask: Task<Void, Never>?

    init(
        sessionManager: SessionManager,
        transcriptionStore: any TranscriptionStoring,
        transcriber: any Transcribing,
        sessionsRootResolver: @escaping @Sendable () throws -> URL = {
            try DefaultFileSystemLocator.resolveSessionsRootPathWithoutCreating()
        },
        shutdownPollInterval: TimeInterval = 0.02
    ) {
        self.sessionManager = sessionManager
        self.store = transcriptionStore
        self.coordinator = TranscriptionCoordinator(store: transcriptionStore, transcriber: transcriber)
        self.sessionsRootResolver = sessionsRootResolver
        self.shutdownPollInterval = shutdownPollInterval
    }

    // MARK: - Public entry points

    /// Fresh transcription: enqueues eligible chunks and processes queued
    /// jobs in order. Does not retry previously-failed retryable jobs —
    /// that only happens under `continueOrRetry`.
    @discardableResult
    func transcribe(sessionID: UUID) -> AdmissionResult {
        beginOperation(sessionID: sessionID, retryFailedJobs: false)
    }

    /// Resumes a session after cancellation/interruption, or retries
    /// eligible retryable failures: reconciles, retries every currently
    /// `.failed(.retryable)` job, enqueues any still-missing chunks, then
    /// processes queued jobs in order. Uses the same execution algorithm
    /// as `transcribe` — the only difference is that eligible retryable
    /// failures are moved back to `.queued` first.
    @discardableResult
    func continueOrRetry(sessionID: UUID) -> AdmissionResult {
        beginOperation(sessionID: sessionID, retryFailedJobs: true)
    }

    /// Requests cooperative cancellation of the active operation, if it
    /// matches `sessionID`. A no-op if no operation is active or a
    /// different session's operation is active. Never cancels merely
    /// because a view disappeared — this must be called explicitly.
    func cancel(sessionID: UUID) {
        guard currentTask != nil, activeSessionID == sessionID else { return }
        AcceptanceDiagnosticLogger.shared.log(
            AcceptanceDiagnosticEvent.Transcription.cancelRequested,
            metadata: ["sessionID": .uuid(sessionID)]
        )
        phase = .cancelling
        currentTask?.cancel()
    }

    // MARK: - App termination

    /// The synchronous half of app-termination shutdown: closes admission
    /// and requests cancellation, with no `await` anywhere in this
    /// function. Split out from `shutdown(timeout:)` specifically so
    /// `AppTerminationDelegate.applicationShouldTerminate(_:)` can call it
    /// directly, synchronously, before returning `.terminateLater` —
    /// calling it only from inside a freshly spawned `Task` (as an earlier
    /// version of the delegate did) leaves a real window, between the
    /// AppKit callback starting and that `Task` actually being scheduled,
    /// in which another window's Transcribe/Continue/Retry could still be
    /// admitted after termination has already begun. Calling this here
    /// closes that window: `isShuttingDown` flips before
    /// `applicationShouldTerminate` returns at all.
    ///
    /// Idempotent: a second call (from `shutdown(timeout:)` calling it
    /// again, or a genuinely concurrent second termination attempt) is a
    /// no-op — it never re-cancels, re-mutates `phase`, or double-invokes
    /// anything, since everything here is gated on the same `!isShuttingDown`
    /// check `shutdown(timeout:)` used to gate inline.
    ///
    /// Ordering, synchronously: (1) `isShuttingDown` is set `true` — from
    /// this point on `beginOperation` refuses every new
    /// Transcribe/Continue/Retry with `.shuttingDown`; (2) the active
    /// operation, if any, is cancelled via the same `Task.cancel()` path
    /// `cancel(sessionID:)` already uses — this propagates through
    /// `TranscriptionCoordinator` and into `FoundationProcessRunner`'s
    /// existing bounded terminate-then-SIGKILL escalation, so the worker
    /// process itself is never waited on unboundedly here.
    func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        if currentTask != nil {
            phase = .cancelling
            currentTask?.cancel()
        }
    }

    /// Called exactly once per normal app termination, by
    /// `AppTerminationDelegate` — never by `SessionManager` or any view.
    /// Idempotent and safe to call more than once (a repeat call, or a
    /// concurrent overlapping call, simply re-observes the same state and
    /// re-applies the same bounded wait; it never re-cancels, re-mutates,
    /// or double-invokes anything).
    ///
    /// Calls `beginShutdown()` first — safe whether or not the caller
    /// already called it directly (as `AppTerminationDelegate` does, to
    /// close admission synchronously before this function's first
    /// `await`; see `beginShutdown()`'s own doc comment). Every other
    /// caller (tests, and any future non-AppKit caller) gets the same
    /// admission-closing-before-cancellation guarantee simply by calling
    /// this function alone.
    ///
    /// The wait itself deliberately never does `await currentTask?.value` —
    /// an already-cancelled `Task<Void, Never>` still only resolves when
    /// its body actually returns, so awaiting it directly would make this
    /// function's own bound only as good as whatever that body's slowest
    /// uncooperative dependency does, defeating the point of a bound.
    /// Instead this polls `currentTask == nil` (the same observable
    /// ownership-release signal `releaseOperation` already publishes),
    /// against a `ContinuousClock` deadline — mirroring this repository's
    /// own established `FoundationProcessRunner.watchAndEscalate`/
    /// `waitWhileRunningOrDeadline` polling idiom for exactly the same
    /// reason: a poll loop can always be abandoned once its deadline
    /// passes, no matter what the awaited work is doing.
    ///
    /// If the bound elapses first, this returns `.timedOut` and the app is
    /// still safe to terminate: no aggregate transcript file exists to be
    /// left half-written (transcripts are always assembled at read time
    /// from already-durable, atomically-committed per-chunk results — see
    /// `finishFromDurableState`), and an abandoned `.running` job with no
    /// live owner is already a state `TranscriptionCoordinator.reconcileState`
    /// correctly recognizes and reclassifies on the very next launch or
    /// operation for this session (see its "Reconciliation" doc comment) —
    /// exactly the same abandoned-running-attempt case a crash or `kill -9`
    /// would leave behind, which this codebase already tolerates.
    @discardableResult
    func shutdown(timeout: TimeInterval = CompletedSessionTranscriptionService.defaultShutdownTimeout) async -> ShutdownOutcome {
        beginShutdown()
        return await waitForRelease(timeout: timeout)
    }

    private func waitForRelease(timeout: TimeInterval) async -> ShutdownOutcome {
        guard currentTask != nil else { return .completed }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64((max(timeout, 0)) * 1_000)))
        let pollNanoseconds = UInt64(max(shutdownPollInterval, 0.001) * 1_000_000_000)

        while currentTask != nil {
            if clock.now >= deadline { return .timedOut }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return .completed
    }

    /// A best-effort, non-mutating status snapshot for display before any
    /// explicit recovery action has run. Deliberately never calls
    /// `reconcileState` (browsing must never mutate persisted job/result
    /// state — recovery only runs under an explicit owner-held action).
    /// Uses the same read-only `SessionArtifactPreflight` the operation
    /// path uses, so browsing and the real operation never develop
    /// contradictory integrity semantics: a corrupt/orphaned/mismatched
    /// artifact is surfaced as `.blocked`, never silently dropped into
    /// `.notTranscribed`/`.incomplete`/`.completed`. An ownerless
    /// `.running` job (not itself a blocking finding) is reported as
    /// `.interrupted` from the raw job list; a durability-uncertain
    /// committed result can only be resolved by an explicit
    /// Transcribe/Continue/Retry.
    func peekStatus(
        sessionID: UUID,
        manifest: SessionManifest,
        sessionPaths: SessionPaths
    ) async -> SessionTranscriptionStatus {
        guard let validated = try? SessionTranscriptionEligibility.validate(
            expectedSessionID: sessionID,
            manifest: manifest,
            sessionPaths: sessionPaths
        ) else {
            return .blocked(reasons: ["Session failed structural/identity eligibility validation."])
        }

        let report = await SessionArtifactPreflight.run(
            manifest: validated.manifest,
            sessionPaths: validated.sessionPaths,
            artifactPaths: validated.artifactPaths,
            store: store
        )
        guard report.blockingReasons.isEmpty else {
            return .blocked(reasons: report.blockingReasons)
        }

        return SessionTranscriptionClassifier.classify(
            manifest: validated.manifest,
            jobs: Array(report.jobsBySequence.values),
            results: Array(report.resultsBySequence.values),
            inconsistencies: []
        )
    }

    /// Read-only: if this session is genuinely `.completed`, assembles and
    /// returns its ordered transcript directly from already-durable
    /// canonical per-chunk results — `nil` otherwise. Never reconciles,
    /// never enqueues, never invokes the transcriber, and is safe to call
    /// at any time, including while a different session's operation is
    /// active. This is what lets a saved, already-complete transcript
    /// reopen and display without rerunning inference and without
    /// requiring today's Whisper model/worker to be available.
    func peekOrderedSegments(
        sessionID: UUID,
        manifest: SessionManifest,
        sessionPaths: SessionPaths
    ) async -> [OrderedSegment]? {
        guard let validated = try? SessionTranscriptionEligibility.validate(
            expectedSessionID: sessionID,
            manifest: manifest,
            sessionPaths: sessionPaths
        ) else {
            return nil
        }

        let report = await SessionArtifactPreflight.run(
            manifest: validated.manifest,
            sessionPaths: validated.sessionPaths,
            artifactPaths: validated.artifactPaths,
            store: store
        )
        guard report.blockingReasons.isEmpty else { return nil }

        let jobs = Array(report.jobsBySequence.values)
        let results = Array(report.resultsBySequence.values)
        guard SessionTranscriptionClassifier.isCompletionValid(manifest: validated.manifest, jobs: jobs, results: results) else {
            return nil
        }

        return coordinator.assembleOrderedTranscript(chunks: validated.manifest.chunks, jobs: jobs, results: results)
    }

    // MARK: - Admission

    /// Rejects first if `shutdown()` has already begun, then if another
    /// transcription operation is already active, then if recording already
    /// owns admission (checked on `SessionManager`'s own `@MainActor`,
    /// `state` outside `{.idle, .completed}`), then reserves ownership. No
    /// `await` occurs between any of these checks and reservation.
    private func beginOperation(sessionID: UUID, retryFailedJobs: Bool) -> AdmissionResult {
        guard !isShuttingDown else { return .shuttingDown }
        guard currentTask == nil else { return .busy }

        let recordingState = sessionManager.state
        guard recordingState == .idle || recordingState == .completed else { return .recordingActive }

        generation += 1
        let myGeneration = generation
        activeSessionID = sessionID
        phase = .preparing
        // Cleared synchronously, before any suspension, so a new
        // operation's admission can never leave a previous session's
        // assembled transcript visibly attached to `activeSessionID`
        // pointing at a different, not-yet-processed session.
        displayedSegments = []

        currentRunStartInstant = AcceptanceDiagnosticLogger.startInstant()
        AcceptanceDiagnosticLogger.shared.log(
            retryFailedJobs ? AcceptanceDiagnosticEvent.Transcription.continueOrRetryStarted : AcceptanceDiagnosticEvent.Transcription.started,
            metadata: ["sessionID": .uuid(sessionID)]
        )

        currentTask = Task { [weak self] in
            await self?.run(sessionID: sessionID, generation: myGeneration, retryFailedJobs: retryFailedJobs)
            await self?.releaseOperation(generation: myGeneration)
        }
        return .admitted
    }

    /// Releases ownership only after `run()` (including all of its cleanup,
    /// via `finishFromDurableState`) has genuinely finished. `activeSessionID`
    /// is cleared here too — not just `currentTask` — because
    /// `SessionTranscriptView.isActiveOperation` (and other observers) key
    /// off `activeSessionID` to distinguish "this session currently owns
    /// the live operation" from "this is merely the last session that ran
    /// one". Leaving it set after release would falsely present Cancel as
    /// available (a no-op, since `currentTask` is already nil) and falsely
    /// keep Continue/Retry disabled for a session that just finished
    /// incomplete/interrupted/recovery-pending.
    private func releaseOperation(generation: Int) {
        guard generation == self.generation else { return }
        currentTask = nil
        activeSessionID = nil
    }

    // MARK: - Execution

    private func run(sessionID: UUID, generation: Int, retryFailedJobs: Bool) async {
        // Defensive, not currently reachable: `beginOperation` refuses a
        // new admission whenever `currentTask != nil`, and `currentTask`
        // is held non-nil for this run's *entire* lifetime — including
        // this function's every awaited step and `finishFromDurableState`
        // — until `releaseOperation` clears it after this function
        // returns. `generation` only advances inside `beginOperation`,
        // which cannot run concurrently with this function under that
        // same guard. So no second `run(...)` can be admitted, and no
        // stale generation's `publish` can ever race a newer one's, while
        // this single-task-ownership invariant holds. The guard below is
        // kept anyway as cheap, load-bearing-if-that-invariant-ever-
        // changes defense in depth, not because it is currently exercised.
        func publish(_ mutate: () -> Void) {
            guard generation == self.generation else { return }
            mutate()
        }

        // Reload manifest fresh from disk — never trust a catalog-cached copy.
        let root: URL
        do {
            root = try sessionsRootResolver()
        } catch {
            publish { self.phase = .finished(.blocked(reasons: ["Unable to resolve sessions storage: \(error.localizedDescription)"])) }
            return
        }

        // Verify the root and the selected session directory themselves,
        // in that order, before ever reading anything beneath them — a
        // symlinked root or session directory must never be followed to
        // reach `session.json`. Never assume the caller came through
        // `CompletedSessionCatalog`'s own (separate) scan.
        guard CompletedSessionPathSafety.checkExistingDirectory(root) == .safe else {
            publish { self.phase = .finished(.blocked(reasons: ["Sessions root is missing, a symlink, or not a directory."])) }
            return
        }

        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)

        guard CompletedSessionPathSafety.checkExistingDirectory(sessionPaths.sessionDirectory) == .safe else {
            publish { self.phase = .finished(.blocked(reasons: ["Session directory is missing, a symlink, or not a directory."])) }
            return
        }

        guard CompletedSessionPathSafety.checkExistingRegularFile(sessionPaths.manifestURL) == .safe else {
            publish { self.phase = .finished(.blocked(reasons: ["Session manifest is missing, a symlink, or not a regular file."])) }
            return
        }

        let manifest: SessionManifest
        do {
            manifest = try AtomicFileWriter.readJSON(SessionManifest.self, from: sessionPaths.manifestURL)
        } catch {
            publish { self.phase = .finished(.blocked(reasons: ["Session manifest could not be read: \(error.localizedDescription)"])) }
            return
        }

        let validated: ValidatedCompletedSession
        do {
            validated = try SessionTranscriptionEligibility.validate(
                expectedSessionID: sessionID,
                manifest: manifest,
                sessionPaths: sessionPaths
            )
        } catch {
            publish { self.phase = .finished(.blocked(reasons: [error.localizedDescription])) }
            return
        }

        if validated.manifest.chunks.isEmpty {
            publish { self.phase = .finished(.zeroChunkSession) }
            return
        }

        guard !Task.isCancelled else {
            publish { self.phase = .finished(.incomplete(completed: 0, total: validated.manifest.chunks.count)) }
            return
        }

        // Read-only pre-mutation validation: load every recognizable
        // job/result artifact, prove path safety, identity, and coverage,
        // and block on any genuine integrity conflict — strictly before
        // the first mutating coordinator call. Never repairs, retries,
        // enqueues, or infers; an ownerless-running/recovery-pending
        // situation is deliberately left for `reconcileState` below, not
        // treated as a blocker here.
        let preflightReport = await SessionArtifactPreflight.run(
            manifest: validated.manifest,
            sessionPaths: validated.sessionPaths,
            artifactPaths: validated.artifactPaths,
            store: store
        )
        guard preflightReport.blockingReasons.isEmpty else {
            publish { self.phase = .finished(.blocked(reasons: preflightReport.blockingReasons)) }
            return
        }

        if Task.isCancelled {
            publish { self.phase = .finished(.incomplete(completed: 0, total: validated.manifest.chunks.count)) }
            return
        }

        // Recovery: only runs while this operation holds authoritative
        // ownership, and only on an explicit Transcribe/Continue/Retry —
        // and only once the read-only preflight above has proven it is
        // safe to let the coordinator mutate anything.
        publish { self.phase = .recovering }
        let reconciliation: ReconciliationReport
        do {
            reconciliation = try await coordinator.reconcileState(paths: validated.artifactPaths)
        } catch {
            publish { self.phase = .finished(.blocked(reasons: ["Recovery could not run: \(error.localizedDescription)"])) }
            return
        }

        if Task.isCancelled {
            await finishFromDurableState(validated: validated, generation: generation, publish: publish)
            return
        }

        if retryFailedJobs {
            for job in reconciliation.jobs where job.state == .failed && job.lastFailure?.retryDisposition == .retryable {
                do {
                    _ = try await coordinator.retryJob(sequenceNumber: job.source.chunkSequenceNumber, paths: validated.artifactPaths)
                } catch {
                    // A retry write failure must not silently masquerade as
                    // an ordinary incomplete/not-transcribed state — the
                    // operation cannot establish authoritative durable
                    // truth for this chunk, so it is surfaced truthfully.
                    publish {
                        self.phase = .finished(.blocked(reasons: [
                            "Unable to retry chunk #\(job.source.chunkSequenceNumber): \(error.localizedDescription)"
                        ]))
                    }
                    return
                }
            }
        }

        if Task.isCancelled {
            await finishFromDurableState(validated: validated, generation: generation, publish: publish)
            return
        }

        publish { self.phase = .enqueuing }
        do {
            _ = try await coordinator.enqueueEligibleChunks(manifest: validated.manifest, sessionPaths: validated.sessionPaths)
        } catch {
            publish { self.phase = .finished(.blocked(reasons: ["Unable to enqueue eligible chunks: \(error.localizedDescription)"])) }
            return
        }

        var currentJobs: [Int: TranscriptionJob]
        do {
            currentJobs = try await loadAllJobs(paths: validated.artifactPaths)
        } catch {
            // A failed authoritative reload must never be treated as "no
            // jobs" — that would let the loop below silently skip real,
            // already-queued work and misreport progress.
            publish { self.phase = .finished(.blocked(reasons: ["Unable to reload jobs after enqueue: \(error.localizedDescription)"])) }
            return
        }
        let totalExpected = validated.manifest.chunks.count

        for chunk in validated.manifest.chunks.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            guard !Task.isCancelled else { break }
            guard let job = currentJobs[chunk.sequenceNumber], job.state == .queued else { continue }

            let completedSoFar = currentJobs.values.filter { $0.state == .completed }.count
            publish {
                self.phase = .processing(completed: completedSoFar, total: totalExpected, currentlyProcessing: chunk.sequenceNumber)
            }

            let chunkStart = AcceptanceDiagnosticLogger.startInstant()
            AcceptanceDiagnosticLogger.shared.log(
                AcceptanceDiagnosticEvent.Transcription.chunkStarted,
                metadata: ["sessionID": .uuid(sessionID), "chunkSequenceNumber": .int(chunk.sequenceNumber)]
            )
            do {
                let resultJob = try await coordinator.processJob(sequenceNumber: chunk.sequenceNumber, paths: validated.artifactPaths)
                currentJobs[chunk.sequenceNumber] = resultJob
                AcceptanceDiagnosticLogger.shared.log(
                    resultJob.state == .completed ? AcceptanceDiagnosticEvent.Transcription.chunkCompleted : AcceptanceDiagnosticEvent.Transcription.chunkFailed,
                    metadata: [
                        "sessionID": .uuid(sessionID),
                        "chunkSequenceNumber": .int(chunk.sequenceNumber),
                        "state": .string(resultJob.state.rawValue),
                        "errorCategory": .string(resultJob.lastFailure?.category.rawValue)
                    ],
                    elapsedSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: chunkStart)
                )
                if resultJob.state != .completed {
                    // Fail-fast: stop scheduling further chunks after the
                    // first unsuccessful result. The successful prefix
                    // already committed remains durable.
                    break
                }
            } catch {
                // Cancellation, commitDurabilityUncertain, or any other
                // processJob failure — stop scheduling; terminal reload
                // and classification below reports the true state.
                AcceptanceDiagnosticLogger.shared.log(
                    AcceptanceDiagnosticEvent.Transcription.chunkFailed,
                    metadata: [
                        "sessionID": .uuid(sessionID),
                        "chunkSequenceNumber": .int(chunk.sequenceNumber),
                        "errorCategory": .string(Self.diagnosticErrorCategory(for: error))
                    ],
                    elapsedSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: chunkStart)
                )
                break
            }
        }

        await finishFromDurableState(validated: validated, generation: generation, publish: publish)
    }

    /// Terminal validation: reloads authoritative persisted jobs/results
    /// fresh from disk (never trusting in-memory accumulation), derives
    /// the transcript only from canonical results when complete, and
    /// publishes using the generation guard. Called whether the run
    /// completed normally, hit a failure, or was cancelled — the true
    /// durable state is reported in every case.
    private func finishFromDurableState(
        validated: ValidatedCompletedSession,
        generation: Int,
        publish: (() -> Void) -> Void
    ) async {
        // A failure here must never be papered over as an ordinary
        // incomplete/not-transcribed state — the operation cannot
        // establish authoritative durable truth, so it is reported
        // truthfully as blocked rather than risking a false `.completed`
        // (or any other) outcome derived from a stale/partial reload.
        let finalJobs: [TranscriptionJob]
        let finalResults: [TranscriptResult]
        let inconsistencies: [TranscriptionInconsistency]
        do {
            let reconciliation = try await coordinator.reconcileState(paths: validated.artifactPaths)
            finalJobs = reconciliation.jobs
            finalResults = try await loadAllResults(paths: validated.artifactPaths)
            inconsistencies = reconciliation.inconsistencies
        } catch {
            publish {
                self.phase = .finished(.blocked(reasons: ["Unable to confirm final transcription state: \(error.localizedDescription)"]))
                self.displayedSegments = []
            }
            return
        }

        let status = SessionTranscriptionClassifier.classify(
            manifest: validated.manifest,
            jobs: finalJobs,
            results: finalResults,
            inconsistencies: inconsistencies
        )

        publish {
            self.phase = .finished(status)
            if case .completed = status {
                self.displayedSegments = self.coordinator.assembleOrderedTranscript(
                    chunks: validated.manifest.chunks,
                    jobs: finalJobs,
                    results: finalResults
                )
            } else {
                self.displayedSegments = []
            }
        }
    }

    // MARK: - Diagnostics

    /// A content-free description of one terminal `SessionTranscriptionStatus`
    /// for the acceptance-diagnostics trace — case name plus structural
    /// counts only, never the full `.blocked(reasons:)` text (those reasons
    /// can reference internal artifact detail beyond what this trace needs
    /// to stay minimal).
    private static func diagnosticDescription(for status: SessionTranscriptionStatus) -> String {
        switch status {
        case .notTranscribed: return "notTranscribed"
        case .zeroChunkSession: return "zeroChunkSession"
        case .incomplete(let completed, let total): return "incomplete(completed: \(completed), total: \(total))"
        case .interrupted(let retryable): return "interrupted(retryableCount: \(retryable.count))"
        case .recoveryPending: return "recoveryPending"
        case .completed: return "completed"
        case .blocked(let reasons): return "blocked(reasonCount: \(reasons.count))"
        }
    }

    /// A deterministic, content-free classification of an error thrown out
    /// of `coordinator.processJob(...)`, for the acceptance-diagnostics
    /// trace only. Never `localizedDescription` or `String(describing:
    /// error)` on the error value itself (either can embed arbitrary
    /// underlying I/O detail, e.g. a filesystem path) — known cases are
    /// named explicitly; anything else falls back to just the concrete
    /// Swift error *type* name, never its message.
    /// Not `private` so `@testable import` unit tests can verify no
    /// arbitrary error text ever escapes into this classification.
    static func diagnosticErrorCategory(for error: Error) -> String {
        if error is CancellationError { return "cancellation" }
        if let coordinatorError = error as? TranscriptionCoordinatorError {
            switch coordinatorError {
            case .alreadyClaimedByThisCoordinator: return "alreadyClaimedByThisCoordinator"
            case .jobNotFound: return "jobNotFound"
            case .jobNotClaimable: return "jobNotClaimable"
            case .attemptSuperseded: return "attemptSuperseded"
            case .sourceMissing: return "sourceMissing"
            case .commitDurabilityUncertain: return "commitDurabilityUncertain"
            case .retryNotEligible: return "retryNotEligible"
            }
        }
        return String(describing: type(of: error))
    }

    // MARK: - Load helpers

    private func loadAllJobs(paths: TranscriptionArtifactPaths) async throws -> [Int: TranscriptionJob] {
        let loaded = try await store.loadAllJobArtifacts(paths: paths)
        var dict: [Int: TranscriptionJob] = [:]
        for entry in loaded {
            if case .success(let sequenceNumber, let job) = entry {
                dict[sequenceNumber] = job
            }
        }
        return dict
    }

    private func loadAllResults(paths: TranscriptionArtifactPaths) async throws -> [TranscriptResult] {
        let loaded = try await store.loadAllResultArtifacts(paths: paths)
        return loaded.compactMap {
            if case .success(_, let value) = $0 { return value }
            return nil
        }
    }
}
