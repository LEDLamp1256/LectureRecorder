import Combine
import Foundation

/// Application-level coordinator that takes one already-existing, normal
/// completed session to finished Notes: ensure transcription is durably
/// complete, then ensure a completed Notes generation exists. Sits strictly
/// above `CompletedSessionTranscriptionService` and
/// `LectureNotesGenerationService` and drives them only through their public
/// commands and exact release signals; every decision is made from durable
/// state read through the existing read-only surfaces
/// (`CompletedSessionTranscriptionService.peekStatus` and
/// `SessionNotesStateLoader`), never from presenter state.
///
/// Never resumes, continues, or retries anything: any durable state that
/// needs an explicit Continue/Retry or owner choice stops the workflow and is
/// left untouched for the existing manual recovery paths. Workflow state is
/// memory-only orchestration state — never persisted, and nothing resumes it
/// on relaunch.
///
/// One run at a time per instance. Each run is identified by a workflow-local
/// `runToken`; every continuation re-checks it after each suspension, so a
/// cancelled or superseded run can never advance.
@MainActor
final class LectureProcessingWorkflow: ObservableObject {
    nonisolated enum Stage: Equatable, Sendable {
        case transcription
        case notes
    }

    nonisolated enum StopReason: Equatable {
        /// `cancel()` was called.
        case cancelled
        /// A recording cycle (or its unresolved recovery state) owns
        /// `SessionManager` — reported by transcription admission itself, or
        /// by this workflow's own pre-Notes check.
        case recordingActive
        /// The stage's service already runs another operation.
        case serviceBusy
        /// The stage's service has begun app-termination shutdown.
        case serviceShuttingDown
        /// Durable transcription state is not `.completed` — before the
        /// workflow started anything, or after its own Transcribe released.
        case transcriptionNotCompleted(SessionTranscriptionStatus)
        /// The session's Notes generation is in a durable state that needs
        /// an explicit Continue/Retry or owner choice (resumable, ready for
        /// synthesis, stale, damaged, incompatible), or the workflow's own
        /// run released as completed but durable state does not confirm it.
        case notesRequireAttention(generationID: UUID, classification: NotesGenerationRecoveryClassification)
        /// The workflow's own Generate released without a completed result.
        case notesGenerationNotCompleted(LectureNotesGenerationService.NotesGenerationOutcome?)
        /// No Notes generation exists, but the transcript source Notes would
        /// be generated from cannot currently be loaded.
        case notesSourceNotReady
        /// Durable Notes state could not be read.
        case notesStateUnreadable(String)
    }

    nonisolated enum State: Equatable {
        case idle
        case transcribing(sessionID: UUID)
        case generatingNotes(sessionID: UUID)
        case finished(sessionID: UUID, notesGenerationID: UUID)
        case stopped(sessionID: UUID, stage: Stage, reason: StopReason)
    }

    nonisolated enum StartResult: Equatable, Sendable {
        case started
        /// This instance is already running a workflow; nothing changed.
        case alreadyRunning
    }

    @Published private(set) var state: State = .idle

    private let sessionManager: SessionManager
    private let transcriptionService: CompletedSessionTranscriptionService
    private let notesService: LectureNotesGenerationService
    private let notesStateLoader: SessionNotesStateLoader

    /// Identifies workflow runs only — never an underlying service operation.
    private var runToken = 0
    private var activeRun: ActiveRun?

    private struct ActiveRun {
        let token: Int
        let sessionID: UUID
        var stage: Stage
        /// Set only while an operation this run admitted has not yet been
        /// observed releasing — the only window in which `cancel()` forwards
        /// to the stage's service.
        var pendingRelease: (any OperationReleaseWaiting)?
    }

    init(
        sessionManager: SessionManager,
        transcriptionService: CompletedSessionTranscriptionService,
        notesService: LectureNotesGenerationService,
        notesStateLoader: SessionNotesStateLoader
    ) {
        self.sessionManager = sessionManager
        self.transcriptionService = transcriptionService
        self.notesService = notesService
        self.notesStateLoader = notesStateLoader
    }

    // MARK: - Commands

    /// Starts taking `entry` to finished Notes. Returns `.alreadyRunning`
    /// without side effects while a previous run of this instance is still
    /// active; a finished or stopped run may be followed by a new one.
    @discardableResult
    func processToNotes(entry: CompletedSessionEntry) -> StartResult {
        guard activeRun == nil else { return .alreadyRunning }
        runToken += 1
        let token = runToken
        let sessionID = entry.manifest.sessionID
        activeRun = ActiveRun(token: token, sessionID: sessionID, stage: .transcription, pendingRelease: nil)
        state = .transcribing(sessionID: sessionID)
        Task { [weak self] in
            await self?.run(entry: entry, token: token)
        }
        return .started
    }

    /// Stops the active run, if any, and never lets it advance again. While
    /// an operation this run admitted is still unreleased, forwards
    /// cancellation to that stage's service; otherwise no service is
    /// touched. Idempotent: a second call, or a call with no active run, does
    /// nothing.
    func cancel() {
        guard let run = activeRun else { return }
        activeRun = nil
        if let pendingRelease = run.pendingRelease {
            if pendingRelease.isAwaitingRelease {
                switch run.stage {
                case .transcription:
                    transcriptionService.cancel(sessionID: run.sessionID)
                case .notes:
                    notesService.cancel(sessionID: run.sessionID)
                }
            }
            pendingRelease.abandon()
        }
        state = .stopped(sessionID: run.sessionID, stage: run.stage, reason: .cancelled)
    }

    // MARK: - Run

    private func run(entry: CompletedSessionEntry, token: Int) async {
        guard await ensureTranscriptionCompleted(entry: entry, token: token) else { return }
        await ensureNotesCompleted(entry: entry, token: token)
    }

    private func isCurrent(_ token: Int) -> Bool {
        activeRun?.token == token
    }

    private func stop(_ token: Int, stage: Stage, reason: StopReason) {
        guard let run = activeRun, run.token == token else { return }
        activeRun = nil
        state = .stopped(sessionID: run.sessionID, stage: stage, reason: reason)
    }

    private func finish(_ token: Int, notesGenerationID: UUID) {
        guard let run = activeRun, run.token == token else { return }
        activeRun = nil
        state = .finished(sessionID: run.sessionID, notesGenerationID: notesGenerationID)
    }

    // MARK: - Transcription stage

    /// `true` only when durable transcription state is verified `.completed`
    /// and this run is still current.
    private func ensureTranscriptionCompleted(entry: CompletedSessionEntry, token: Int) async -> Bool {
        let sessionID = entry.manifest.sessionID

        let initialStatus = await transcriptionService.peekStatus(
            sessionID: sessionID,
            manifest: entry.manifest,
            sessionPaths: entry.sessionPaths
        )
        guard isCurrent(token) else { return false }
        switch initialStatus {
        case .completed:
            return true
        case .notTranscribed:
            break
        case .zeroChunkSession, .incomplete, .interrupted, .recoveryPending, .blocked:
            // Partial or recovery-requiring state belongs to the manual
            // Continue/Retry path — never resumed automatically.
            stop(token, stage: .transcription, reason: .transcriptionNotCompleted(initialStatus))
            return false
        }

        // Subscribe before admission so even an immediate release is observed.
        let waiter = OperationReleaseWaiter(releases: transcriptionService.$lastReleasedOperation) { release, sessionID, operationToken in
            release.sessionID == sessionID && release.generation == operationToken
        }
        switch transcriptionService.transcribe(sessionID: sessionID) {
        case .admitted:
            // Read synchronously — no suspension between admission and token.
            waiter.expect(sessionID: sessionID, token: transcriptionService.generation)
        case .busy:
            waiter.abandon()
            stop(token, stage: .transcription, reason: .serviceBusy)
            return false
        case .recordingActive:
            waiter.abandon()
            stop(token, stage: .transcription, reason: .recordingActive)
            return false
        case .shuttingDown:
            waiter.abandon()
            stop(token, stage: .transcription, reason: .serviceShuttingDown)
            return false
        }
        activeRun?.pendingRelease = waiter

        guard await waiter.wait() != nil, isCurrent(token) else { return false }
        activeRun?.pendingRelease = nil

        // The release only says the operation is over; durable state says
        // whether it succeeded.
        let finalStatus = await transcriptionService.peekStatus(
            sessionID: sessionID,
            manifest: entry.manifest,
            sessionPaths: entry.sessionPaths
        )
        guard isCurrent(token) else { return false }
        guard finalStatus == .completed else {
            stop(token, stage: .transcription, reason: .transcriptionNotCompleted(finalStatus))
            return false
        }
        return true
    }

    // MARK: - Notes stage

    private func ensureNotesCompleted(entry: CompletedSessionEntry, token: Int) async {
        let sessionID = entry.manifest.sessionID
        guard isCurrent(token) else { return }
        activeRun?.stage = .notes
        state = .generatingNotes(sessionID: sessionID)

        let existing = await notesStateLoader.loadDefaultState(sessionID: sessionID, sessionPaths: entry.sessionPaths)
        guard isCurrent(token) else { return }
        switch existing {
        case .loaded(let record, .completed, _):
            finish(token, notesGenerationID: record.generationID)
            return
        case .loaded(let record, let classification, _):
            stop(token, stage: .notes, reason: .notesRequireAttention(generationID: record.generationID, classification: classification))
            return
        case .noGeneration(transcriptSourceReady: false):
            stop(token, stage: .notes, reason: .notesSourceNotReady)
            return
        case .noGeneration(transcriptSourceReady: true):
            break
        case .loadError(let description):
            stop(token, stage: .notes, reason: .notesStateUnreadable(description))
            return
        case .loading:
            // Never returned by `SessionNotesStateLoader`.
            stop(token, stage: .notes, reason: .notesStateUnreadable("Notes state did not load."))
            return
        }

        // Workflow-only overlap rule: never start heavy Notes work while a
        // recording owns `SessionManager`. Checked with no suspension before
        // admission. `LectureNotesGenerationService`'s own admission is
        // deliberately independent of recording and is not changed.
        let recordingState = sessionManager.state
        guard recordingState == .idle || recordingState == .completed else {
            stop(token, stage: .notes, reason: .recordingActive)
            return
        }

        let waiter = OperationReleaseWaiter(releases: notesService.$lastReleasedOperation) { release, sessionID, operationToken in
            release.sessionID == sessionID && release.operationEpoch == operationToken
        }
        switch notesService.generate(sessionID: sessionID) {
        case .admitted:
            waiter.expect(sessionID: sessionID, token: notesService.operationEpoch)
        case .busy:
            waiter.abandon()
            stop(token, stage: .notes, reason: .serviceBusy)
            return
        case .shuttingDown:
            waiter.abandon()
            stop(token, stage: .notes, reason: .serviceShuttingDown)
            return
        }
        activeRun?.pendingRelease = waiter

        guard let release = await waiter.wait(), isCurrent(token) else { return }
        activeRun?.pendingRelease = nil

        guard let generationID = release.generationID else {
            stop(token, stage: .notes, reason: .notesGenerationNotCompleted(release.outcome))
            return
        }
        // Verify exactly the generation this run produced.
        let verified = await notesStateLoader.loadState(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: generationID)
        guard isCurrent(token) else { return }
        switch (verified, release.outcome) {
        case (.loaded(_, .completed, _), _):
            finish(token, notesGenerationID: generationID)
        case (.loaded(_, let classification, _), .completed?):
            // Released as completed, but durable state does not confirm it.
            stop(token, stage: .notes, reason: .notesRequireAttention(generationID: generationID, classification: classification))
        case (.loadError(let description), .completed?):
            stop(token, stage: .notes, reason: .notesStateUnreadable(description))
        default:
            stop(token, stage: .notes, reason: .notesGenerationNotCompleted(release.outcome))
        }
    }
}

// MARK: - Exact release waiting

/// The type-erased surface `LectureProcessingWorkflow.cancel()` needs from a
/// pending `OperationReleaseWaiter`.
@MainActor
protocol OperationReleaseWaiting: AnyObject {
    /// `true` while the expected operation has not been observed releasing
    /// and the wait has not been abandoned.
    var isAwaitingRelease: Bool { get }
    func abandon()
}

/// Waits for exactly one service-operation release identified by session and
/// exact operation token. Subscribes in `init` — callers construct it before
/// attempting admission — so a release published at any point after
/// admission is observed. Matching uses only the payload each emission
/// carries; the service's current value is never re-read. Releases seen
/// before `expect` (such as the replayed current value of an earlier
/// operation) are buffered and matched once the token is known. After the
/// first match or `abandon()`, every later emission is ignored and the
/// subscription is dropped.
@MainActor
final class OperationReleaseWaiter<Release>: OperationReleaseWaiting {
    private enum Phase {
        case waiting
        case matched(Release)
        case abandoned
    }

    private let matches: (Release, UUID, Int) -> Bool
    private var cancellable: AnyCancellable?
    private var phase: Phase = .waiting
    private var target: (sessionID: UUID, token: Int)?
    private var unmatchedBeforeTarget: [Release] = []
    private var continuation: CheckedContinuation<Release?, Never>?

    init<P: Publisher>(
        releases: P,
        matches: @escaping (_ release: Release, _ sessionID: UUID, _ token: Int) -> Bool
    ) where P.Output == Release?, P.Failure == Never {
        self.matches = matches
        cancellable = releases.sink { [weak self] release in
            guard let release else { return }
            self?.receive(release)
        }
    }

    var isAwaitingRelease: Bool {
        if case .waiting = phase { return true }
        return false
    }

    /// Fixes the exact operation to wait for. Call synchronously right after
    /// the service reports `.admitted`.
    func expect(sessionID: UUID, token: Int) {
        guard case .waiting = phase, target == nil else { return }
        target = (sessionID, token)
        let buffered = unmatchedBeforeTarget
        unmatchedBeforeTarget = []
        if let early = buffered.first(where: { matches($0, sessionID, token) }) {
            resolve(.matched(early))
        }
    }

    /// The matching release, or `nil` if the wait was abandoned first.
    func wait() async -> Release? {
        switch phase {
        case .matched(let release):
            return release
        case .abandoned:
            return nil
        case .waiting:
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    /// Ends the wait with `nil`. Idempotent; a no-op after a match.
    func abandon() {
        guard case .waiting = phase else { return }
        resolve(.abandoned)
    }

    private func receive(_ release: Release) {
        guard case .waiting = phase else { return }
        guard let target else {
            unmatchedBeforeTarget.append(release)
            return
        }
        guard matches(release, target.sessionID, target.token) else { return }
        resolve(.matched(release))
    }

    private func resolve(_ terminal: Phase) {
        phase = terminal
        cancellable = nil
        unmatchedBeforeTarget = []
        guard let continuation else { return }
        self.continuation = nil
        if case .matched(let release) = terminal {
            continuation.resume(returning: release)
        } else {
            continuation.resume(returning: nil)
        }
    }
}
