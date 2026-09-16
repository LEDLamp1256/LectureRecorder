import Combine
import Foundation

/// The single, app-wide authoritative owner of notes-generation
/// operations for completed sessions. Mirrors
/// `CompletedSessionTranscriptionService`'s single-owner, generation-
/// counter-guarded admission/cancellation shape, adapted for the notes
/// domain (T5-B contract §2). `@MainActor` for the same reason that type
/// is: published state must be safely observable by views without an
/// intervening suspension.
///
/// Owns: the active session/generation identity, the operation epoch, the
/// single in-flight `Task`, published phase, and cancellation. Never adds
/// responsibilities to `SessionManager` or any transcription
/// coordinator/service/store, and never cross-checks recording or
/// transcription admission state — this service's admission is entirely
/// independent of both (T5-B contract §2).
@MainActor
final class LectureNotesGenerationService: ObservableObject {
    enum OperationPhase: Equatable {
        case idle
        case preparingSource
        case classifying
        case analyzing(windowIndex: Int, totalWindows: Int)
        case synthesizing
        case cancelling
        case finished(NotesGenerationOutcome)
    }

    /// The terminal result of one Generate/Continue/Retry run. Never
    /// itself a source of truth — every case here is derived from, and
    /// consistent with, what `NotesGenerationRecoveryClassifier` would
    /// independently compute from durable artifacts alone.
    enum NotesGenerationOutcome: Equatable {
        case completed(document: LectureNotesDocument)
        case cancelled
        case staleSource
        case damaged(reason: NotesGenerationDamageReason)
        case failed(description: String)
    }

    enum AdmissionResult: Sendable, Equatable {
        case admitted
        /// Another notes-generation operation is already active app-wide.
        case busy
        case shuttingDown
    }

    enum ShutdownOutcome: Sendable, Equatable {
        case completed
        case timedOut
    }

    nonisolated static let defaultShutdownTimeout: TimeInterval = 5

    private let shutdownPollInterval: TimeInterval

    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var activeGenerationID: UUID?
    @Published private(set) var phase: OperationPhase = .idle

    private(set) var isShuttingDown = false
    private(set) var operationEpoch = 0

    private let sourceLoader: any NotesTranscriptSourceLoading
    private let notesStore: any LectureNotesStoring
    private let operationStateStore: any LectureNotesOperationStateStoring
    private let generator: any LectureNotesGenerating
    private let windowBudget: NotesWindowBudget
    /// Frozen into each new immutable generation record. Continue/Retry load
    /// the already-persisted record and therefore never consult this value.
    private let generationProvenance: LectureNotesGenerationProvenance
    private let sessionsRootResolver: @Sendable () throws -> URL
    /// Mints the identity for a brand-new generation (Generate only —
    /// Continue/Retry always reuse a caller-supplied `generationID` and
    /// never call this). Exposed only so tests can pre-target a known
    /// generation-record URL (e.g. to force a durability-uncertain commit
    /// outcome deterministically); production always uses a fresh random
    /// `UUID`.
    private let generationIDProvider: @Sendable () -> UUID

    private var currentTask: Task<Void, Never>?

    init(
        sourceLoader: any NotesTranscriptSourceLoading,
        notesStore: any LectureNotesStoring,
        operationStateStore: any LectureNotesOperationStateStoring,
        generator: any LectureNotesGenerating,
        windowBudget: NotesWindowBudget,
        generationProvenance: LectureNotesGenerationProvenance = LectureNotesGenerationProvenance(recipeVersion: "t5-notes-v1"),
        sessionsRootResolver: @escaping @Sendable () throws -> URL = {
            try DefaultFileSystemLocator.resolveSessionsRootPathWithoutCreating()
        },
        generationIDProvider: @escaping @Sendable () -> UUID = { UUID() },
        shutdownPollInterval: TimeInterval = 0.02
    ) {
        self.sourceLoader = sourceLoader
        self.notesStore = notesStore
        self.operationStateStore = operationStateStore
        self.generator = generator
        self.windowBudget = windowBudget
        self.generationProvenance = generationProvenance
        self.sessionsRootResolver = sessionsRootResolver
        self.generationIDProvider = generationIDProvider
        self.shutdownPollInterval = shutdownPollInterval
    }

    // MARK: - Public entry points

    /// Starts a brand-new generation for `sessionID`. Always mints a fresh
    /// generation ID and never overwrites or deletes any prior generation
    /// for this session (T5-B contract §6).
    @discardableResult
    func generate(sessionID: UUID) -> AdmissionResult {
        beginOperation(sessionID: sessionID, generationID: nil)
    }

    /// Resumes `generationID` after cancellation, interruption, or clean
    /// incompleteness. Never replans and never mints a new generation ID
    /// (T5-B contract §7).
    @discardableResult
    func continueGeneration(sessionID: UUID, generationID: UUID) -> AdmissionResult {
        beginOperation(sessionID: sessionID, generationID: generationID)
    }

    /// Resumes `generationID` after a recoverable failure. Uses the same
    /// resumption mechanics as `continueGeneration`, differing only in
    /// which case a caller invokes it from — see T5-B contract §8.
    @discardableResult
    func retry(sessionID: UUID, generationID: UUID) -> AdmissionResult {
        beginOperation(sessionID: sessionID, generationID: generationID)
    }

    /// Requests cooperative cancellation of the active operation, if it
    /// belongs to `sessionID`. A no-op otherwise. Never cancels merely
    /// because a view disappeared.
    func cancel(sessionID: UUID) {
        guard currentTask != nil, activeSessionID == sessionID else { return }
        phase = .cancelling
        currentTask?.cancel()
    }

    // MARK: - Shutdown

    func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        if currentTask != nil {
            phase = .cancelling
            currentTask?.cancel()
        }
    }

    @discardableResult
    func shutdown(timeout: TimeInterval = LectureNotesGenerationService.defaultShutdownTimeout) async -> ShutdownOutcome {
        beginShutdown()
        return await waitForRelease(timeout: timeout)
    }

    private func waitForRelease(timeout: TimeInterval) async -> ShutdownOutcome {
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

    // MARK: - Admission

    private func beginOperation(sessionID: UUID, generationID: UUID?) -> AdmissionResult {
        guard !isShuttingDown else { return .shuttingDown }
        guard currentTask == nil else { return .busy }

        operationEpoch += 1
        let myEpoch = operationEpoch
        activeSessionID = sessionID
        activeGenerationID = generationID
        phase = .preparingSource

        currentTask = Task { [weak self] in
            await self?.run(sessionID: sessionID, generationID: generationID, epoch: myEpoch)
            await self?.releaseOperation(epoch: myEpoch)
        }
        return .admitted
    }

    private func releaseOperation(epoch: Int) {
        guard epoch == operationEpoch else { return }
        currentTask = nil
        activeSessionID = nil
        activeGenerationID = nil
    }

    // MARK: - Execution

    private func run(sessionID: UUID, generationID: UUID?, epoch: Int) async {
        func publish(_ mutate: () -> Void) {
            guard epoch == self.operationEpoch else { return }
            mutate()
        }

        let sourceSnapshot: NotesTranscriptSourceSnapshot
        do {
            sourceSnapshot = try await sourceLoader.loadCurrentSnapshot(sessionID: sessionID)
        } catch {
            publish { self.phase = .finished(.failed(description: "Unable to load transcript source: \(error.localizedDescription)")) }
            return
        }

        guard !Task.isCancelled else {
            publish { self.phase = .finished(.cancelled) }
            return
        }

        let sessionPaths: SessionPaths
        do {
            let root = try sessionsRootResolver()
            guard CompletedSessionPathSafety.checkExistingDirectory(root) == .safe else {
                publish { self.phase = .finished(.failed(description: "Sessions root is missing, a symlink, or not a directory.")) }
                return
            }
            sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)
        } catch {
            publish { self.phase = .finished(.failed(description: "Unable to resolve sessions storage: \(error.localizedDescription)")) }
            return
        }

        let resolvedGenerationID: UUID
        let record: LectureNotesGenerationRecord

        if let generationID {
            resolvedGenerationID = generationID
            let paths: NotesArtifactPaths
            do {
                paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
            } catch {
                publish { self.phase = .finished(.failed(description: "Invalid generation paths: \(error.localizedDescription)")) }
                return
            }
            do {
                guard let loaded = try notesStore.loadGeneration(paths: paths) else {
                    publish { self.phase = .finished(.failed(description: "No generation record exists for the given generation ID.")) }
                    return
                }
                record = loaded
            } catch {
                publish { self.phase = .finished(.failed(description: "Unable to load generation record: \(error.localizedDescription)")) }
                return
            }
        } else {
            resolvedGenerationID = generationIDProvider()
            let plan = NotesWindowPlan(windows: NotesWindowPlanner.plan(units: sourceSnapshot.units, budget: windowBudget))
            let newRecord = LectureNotesGenerationRecord.newGeneration(
                generationID: resolvedGenerationID,
                sessionID: sessionID,
                transcriptFingerprint: sourceSnapshot.fingerprint,
                windowPlan: plan,
                provenance: generationProvenance
            )
            let paths: NotesArtifactPaths
            do {
                paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: resolvedGenerationID)
            } catch {
                publish { self.phase = .finished(.failed(description: "Invalid generation paths: \(error.localizedDescription)")) }
                return
            }
            do {
                let outcome = try notesStore.createGenerationIfAbsent(newRecord, paths: paths)
                switch outcome {
                case .created, .alreadyExistsIdentical:
                    break
                case .createdDurabilityUncertain:
                    publish {
                        self.phase = .finished(.failed(description: "Generation record commit durability is uncertain; use Continue or Retry to confirm."))
                    }
                    return
                case .conflict:
                    publish { self.phase = .finished(.failed(description: "A conflicting generation record already exists at this generation ID.")) }
                    return
                }
            } catch {
                publish { self.phase = .finished(.failed(description: "Unable to persist generation record: \(error.localizedDescription)")) }
                return
            }
            record = newRecord
        }

        let paths: NotesArtifactPaths
        do {
            paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: resolvedGenerationID)
        } catch {
            publish { self.phase = .finished(.failed(description: error.localizedDescription)) }
            return
        }

        publish {
            self.activeGenerationID = resolvedGenerationID
            self.phase = .classifying
        }

        let loadedAnalyses: [LectureNotesWindowAnalysis]
        do {
            let entries = try notesStore.loadAllWindowAnalyses(paths: paths)
            var values: [LectureNotesWindowAnalysis] = []
            for entry in entries {
                switch entry {
                case .success(_, let value):
                    values.append(value)
                case .failure(let windowIndex, let errorDescription):
                    publish { self.phase = .finished(.damaged(reason: .corruptOrInvalidAnalysis(windowIndex: windowIndex, underlying: errorDescription))) }
                    return
                }
            }
            loadedAnalyses = values
        } catch {
            publish { self.phase = .finished(.failed(description: "Unable to load window analyses: \(error.localizedDescription)")) }
            return
        }

        let document: LectureNotesDocument?
        do {
            document = try notesStore.loadDocument(paths: paths)
        } catch {
            publish { self.phase = .finished(.failed(description: "Unable to load document: \(error.localizedDescription)")) }
            return
        }

        let loadedOperationState: NotesGenerationOperationState?
        do {
            loadedOperationState = try operationStateStore.loadOperationState(paths: paths)
        } catch {
            publish { self.phase = .finished(.failed(description: "Unable to load operation state: \(error.localizedDescription)")) }
            return
        }
        // "No operation-state artifact exists" and "an operation-state
        // artifact exists but disagrees with this generation's transcript
        // fingerprint" are NOT the same thing and must never be conflated:
        // the former is normal (a fresh generation, or one whose advisory
        // metadata was never written) and classification proceeds; the
        // latter is an identity/integrity failure on untrusted persisted
        // input and must stop the run before classification, canonical
        // artifacts, or the generator are ever touched.
        let operationState: NotesGenerationOperationState?
        switch operationStateIdentity(of: loadedOperationState, forGeneration: record) {
        case .absent:
            operationState = nil
        case .matching(let state):
            operationState = state
        case .mismatchedFingerprint:
            publish {
                self.phase = .finished(.failed(description: "Operation-state transcript fingerprint does not match this generation's; refusing to proceed."))
            }
            return
        }

        let classification = NotesGenerationRecoveryClassifier.classify(
            generation: record,
            sourceSnapshot: sourceSnapshot,
            analyses: loadedAnalyses,
            document: document,
            operationState: operationState
        )

        switch classification {
        case .completed(let document):
            publish { self.phase = .finished(.completed(document: document)) }
        case .staleSource:
            publish { self.phase = .finished(.staleSource) }
        case .damaged(let reason):
            publish { self.phase = .finished(.damaged(reason: reason)) }
        case .readyForSynthesis(let analyses):
            switch nextRunAttemptCount(after: operationState) {
            case .failure(let error):
                publish { self.phase = .finished(.failed(description: "Operation-state run-attempt count is invalid: \(error.errorDescription ?? "unknown reason")")) }
            case .success(let attemptCount):
                await runSynthesis(
                    record: record,
                    paths: paths,
                    sessionID: sessionID,
                    analyses: analyses,
                    runID: UUID(),
                    attemptCount: attemptCount,
                    publish: publish
                )
            }
        case .resumable(let nextWindowIndex, _):
            switch nextRunAttemptCount(after: operationState) {
            case .failure(let error):
                publish { self.phase = .finished(.failed(description: "Operation-state run-attempt count is invalid: \(error.errorDescription ?? "unknown reason")")) }
            case .success(let attemptCount):
                await runSequentialGeneration(
                    record: record,
                    paths: paths,
                    sessionID: sessionID,
                    startingWindowIndex: nextWindowIndex,
                    sourceSnapshotAtStart: sourceSnapshot,
                    existingAnalyses: loadedAnalyses,
                    runID: UUID(),
                    attemptCount: attemptCount,
                    publish: publish
                )
            }
        }
    }

    /// Every way `NotesGenerationOperationState.runAttemptCount` can be
    /// invalid untrusted persisted input, or would overflow on increment.
    /// Never allowed to trap the process.
    private enum RunAttemptCountError: LocalizedError {
        case negativePersistedValue(Int)
        case overflow

        var errorDescription: String? {
            switch self {
            case .negativePersistedValue(let value):
                return "persisted run-attempt count \(value) is negative"
            case .overflow:
                return "persisted run-attempt count would overflow Int on increment"
            }
        }
    }

    /// Computes the next run-attempt count from `operationState` (already
    /// fingerprint-validated by the caller), or `nil`/absent meaning "no
    /// prior attempt" → `1`. Overflow-safe: a persisted `Int.max` or
    /// negative value is rejected as a typed error, never trapped.
    /// Deliberately computed only where a run is actually about to start
    /// (the `.resumable`/`.readyForSynthesis` branches) — classifications
    /// that will not start any generator work never need this computed at
    /// all.
    private func nextRunAttemptCount(after operationState: NotesGenerationOperationState?) -> Result<Int, RunAttemptCountError> {
        guard let previous = operationState?.runAttemptCount else { return .success(1) }
        guard previous >= 0 else { return .failure(.negativePersistedValue(previous)) }
        let (next, overflowed) = previous.addingReportingOverflow(1)
        guard !overflowed else { return .failure(.overflow) }
        return .success(next)
    }

    /// The three, deliberately distinct ways a loaded operation-state
    /// record relates to the generation it was loaded for. `.absent` and
    /// `.mismatchedFingerprint` are NOT the same outcome — see
    /// `operationStateIdentity(of:forGeneration:)`.
    private enum OperationStateIdentity {
        case absent
        case matching(NotesGenerationOperationState)
        /// `loaded` exists and already passed the store's own
        /// `sessionID`/`generationID` identity check (proving it belongs
        /// to the right *path*), but its own `transcriptFingerprint`
        /// disagrees with `generation`'s — it does not describe the same
        /// *transcript content* this generation was fixed against. This is
        /// an integrity failure on untrusted persisted input, never
        /// silently treated as equivalent to "no operation state exists".
        case mismatchedFingerprint
    }

    private func operationStateIdentity(
        of loaded: NotesGenerationOperationState?,
        forGeneration generation: LectureNotesGenerationRecord
    ) -> OperationStateIdentity {
        guard let loaded else { return .absent }
        guard loaded.transcriptFingerprint == generation.transcriptFingerprint else { return .mismatchedFingerprint }
        return .matching(loaded)
    }

    // MARK: - Sequential window generation

    private func runSequentialGeneration(
        record: LectureNotesGenerationRecord,
        paths: NotesArtifactPaths,
        sessionID: UUID,
        startingWindowIndex: Int,
        sourceSnapshotAtStart: NotesTranscriptSourceSnapshot,
        existingAnalyses: [LectureNotesWindowAnalysis],
        runID: UUID,
        attemptCount: Int,
        publish: (() -> Void) -> Void
    ) async {
        let orderedWindows = record.windowPlan.windows.sorted { $0.windowIndex < $1.windowIndex }
        var analyses = existingAnalyses

        for window in orderedWindows where window.windowIndex >= startingWindowIndex {
            // Checkpoint: before beginning another window.
            guard !Task.isCancelled else {
                persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.cancelled) }
                return
            }

            publish { self.phase = .analyzing(windowIndex: window.windowIndex, totalWindows: orderedWindows.count) }
            persistState(
                .running,
                stage: .analyzingWindow(windowIndex: window.windowIndex),
                failureDescription: nil,
                record: record,
                paths: paths,
                runID: runID,
                attemptCount: attemptCount
            )

            // Checkpoint: before generator invocation.
            guard !Task.isCancelled else {
                persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.cancelled) }
                return
            }

            let units = sourceUnits(for: window, in: sourceSnapshotAtStart)
            let analysis: LectureNotesWindowAnalysis
            do {
                analysis = try await generator.analyzeWindow(units: units, window: window, generation: record)
            } catch {
                // A generator that observes cancellation (e.g. via
                // `Task.checkCancellation()`) throws rather than returning
                // normally — that must still be reported as `.cancelled`,
                // never misreported as a genuine generator failure.
                guard !Task.isCancelled else {
                    persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                    publish { self.phase = .finished(.cancelled) }
                    return
                }
                let description = "Analysis for window \(window.windowIndex) failed: \(error.localizedDescription)"
                persistState(.failed, stage: .analyzingWindow(windowIndex: window.windowIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: description)) }
                return
            }

            // Checkpoint: after generator return — a cancelled run must
            // never commit output the generator returns after the fact.
            guard !Task.isCancelled else {
                persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.cancelled) }
                return
            }

            let currentSnapshot: NotesTranscriptSourceSnapshot
            do {
                currentSnapshot = try await sourceLoader.loadCurrentSnapshot(sessionID: sessionID)
            } catch {
                let description = "Unable to reconfirm transcript source before commit: \(error.localizedDescription)"
                persistState(.failed, stage: .analyzingWindow(windowIndex: window.windowIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: description)) }
                return
            }

            do {
                try NotesIntegrityValidator.validateSourceMatchesGeneration(sourceSnapshot: currentSnapshot, generation: record)
            } catch {
                // The source moved on since this generation's plan was
                // fixed — the freshly generated `analysis` is discarded,
                // never committed, and never attached to this now-stale
                // generation.
                publish { self.phase = .finished(.staleSource) }
                return
            }

            // Checkpoint: immediately before validating/committing.
            guard !Task.isCancelled else {
                persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.cancelled) }
                return
            }

            do {
                try NotesIntegrityValidator.validate(analysis: analysis, generation: record, plannedWindow: window, sourceSnapshot: currentSnapshot)
            } catch {
                let description = "Analysis for window \(window.windowIndex) failed validation: \(error.localizedDescription)"
                persistState(.failed, stage: .analyzingWindow(windowIndex: window.windowIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: description)) }
                return
            }

            let commitOutcome: NotesWindowAnalysisCommitOutcome
            do {
                commitOutcome = try notesStore.commitWindowAnalysis(analysis, paths: paths)
            } catch {
                let description = "Unable to commit analysis for window \(window.windowIndex): \(error.localizedDescription)"
                persistState(.failed, stage: .analyzingWindow(windowIndex: window.windowIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: description)) }
                return
            }

            switch commitOutcome {
            case .committed, .alreadyCommittedIdentical:
                analyses.append(analysis)
            case .committedDurabilityUncertain:
                let description = "Commit durability for window \(window.windowIndex) is uncertain; use Continue or Retry to confirm."
                persistState(.failed, stage: .analyzingWindow(windowIndex: window.windowIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: description)) }
                return
            case .conflict:
                let description = "Window \(window.windowIndex) already has a conflicting committed analysis."
                persistState(.failed, stage: .analyzingWindow(windowIndex: window.windowIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: description)) }
                return
            }
        }

        await runSynthesis(
            record: record,
            paths: paths,
            sessionID: sessionID,
            analyses: analyses,
            runID: runID,
            attemptCount: attemptCount,
            publish: publish
        )
    }

    // MARK: - Synthesis

    private func runSynthesis(
        record: LectureNotesGenerationRecord,
        paths: NotesArtifactPaths,
        sessionID: UUID,
        analyses: [LectureNotesWindowAnalysis],
        runID: UUID,
        attemptCount: Int,
        publish: (() -> Void) -> Void
    ) async {
        // Checkpoint: before synthesis.
        guard !Task.isCancelled else {
            persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.cancelled) }
            return
        }

        // Revalidate the source and this generation's exact committed
        // analysis coverage immediately before synthesis — analogous to,
        // but distinct from, the post-synthesis check below. A generation
        // can sit at "ready for synthesis" for an arbitrary amount of time
        // (e.g. across a Continue) before this ever runs, so the source
        // must be reconfirmed fresh here too, not only after synthesis.
        let preSynthesisSnapshot: NotesTranscriptSourceSnapshot
        do {
            preSynthesisSnapshot = try await sourceLoader.loadCurrentSnapshot(sessionID: sessionID)
        } catch {
            let description = "Unable to reconfirm transcript source before synthesis: \(error.localizedDescription)"
            persistState(.failed, stage: .synthesizing, failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.failed(description: description)) }
            return
        }
        do {
            try NotesIntegrityValidator.validateSourceMatchesGeneration(sourceSnapshot: preSynthesisSnapshot, generation: record)
        } catch {
            // The source moved on since this generation's plan was fixed —
            // synthesis must never be invoked against a stale source.
            publish { self.phase = .finished(.staleSource) }
            return
        }
        do {
            try NotesIntegrityValidator.validateCoverage(analyses: analyses, generation: record, sourceSnapshot: preSynthesisSnapshot)
        } catch {
            // The source itself already matches (checked immediately
            // above), so a coverage failure here is a genuine canonical
            // integrity problem, never staleness — synthesis must not run.
            publish { self.phase = .finished(.damaged(reason: .coverageIntegrityViolation(error.localizedDescription))) }
            return
        }

        // Checkpoint: before generator invocation (mirrors the equivalent
        // checkpoint in `runSequentialGeneration`, immediately before the
        // generator call itself).
        guard !Task.isCancelled else {
            persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.cancelled) }
            return
        }

        publish { self.phase = .synthesizing }
        persistState(.running, stage: .synthesizing, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)

        let orderedAnalyses = analyses.sorted { $0.windowIndex < $1.windowIndex }
        let document: LectureNotesDocument
        do {
            document = try await generator.synthesize(analyses: orderedAnalyses, generation: record)
        } catch {
            // See the identical rationale in `runSequentialGeneration`: a
            // generator that throws because it observed cancellation must
            // still be reported as `.cancelled`, never as a failure.
            guard !Task.isCancelled else {
                persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.cancelled) }
                return
            }
            let description = "Synthesis failed: \(error.localizedDescription)"
            persistState(.failed, stage: .synthesizing, failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.failed(description: description)) }
            return
        }

        // Checkpoint: after synthesis — a cancelled run must never commit
        // a document the generator returns after the fact.
        guard !Task.isCancelled else {
            persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.cancelled) }
            return
        }

        let currentSnapshot: NotesTranscriptSourceSnapshot
        do {
            currentSnapshot = try await sourceLoader.loadCurrentSnapshot(sessionID: sessionID)
        } catch {
            let description = "Unable to reconfirm transcript source before document commit: \(error.localizedDescription)"
            persistState(.failed, stage: .synthesizing, failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.failed(description: description)) }
            return
        }

        do {
            try NotesIntegrityValidator.validateSourceMatchesGeneration(sourceSnapshot: currentSnapshot, generation: record)
        } catch {
            // The synthesized document is discarded, never committed, and
            // never attached to this now-stale generation.
            publish { self.phase = .finished(.staleSource) }
            return
        }

        // Checkpoint: immediately before validating/committing the document.
        guard !Task.isCancelled else {
            persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.cancelled) }
            return
        }

        do {
            try NotesIntegrityValidator.validate(document: document, generation: record, sourceSnapshot: currentSnapshot)
        } catch {
            let description = "Synthesized document failed validation: \(error.localizedDescription)"
            persistState(.failed, stage: .synthesizing, failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.failed(description: description)) }
            return
        }

        let commitOutcome: NotesDocumentCommitOutcome
        do {
            commitOutcome = try notesStore.commitDocument(document, paths: paths)
        } catch {
            let description = "Unable to commit document: \(error.localizedDescription)"
            persistState(.failed, stage: .synthesizing, failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.failed(description: description)) }
            return
        }

        switch commitOutcome {
        case .committed, .alreadyCommittedIdentical:
            persistState(.completed, stage: .synthesizing, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.completed(document: document)) }
        case .committedDurabilityUncertain:
            let description = "Document commit durability is uncertain; use Continue or Retry to confirm."
            persistState(.failed, stage: .synthesizing, failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.failed(description: description)) }
        case .conflict:
            let description = "A conflicting document already exists for this generation."
            persistState(.failed, stage: .synthesizing, failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.failed(description: description)) }
        }
    }

    // MARK: - Helpers

    private func sourceUnits(for window: NotesInputWindow, in snapshot: NotesTranscriptSourceSnapshot) -> [NotesTranscriptSourceUnit] {
        snapshot.units.filter { $0.sequenceNumber >= window.firstSequenceNumber && $0.sequenceNumber <= window.lastSequenceNumber }
    }

    /// Best-effort: operation-state is advisory-only (see
    /// `NotesGenerationOperationState`), so a failure persisting it must
    /// never abort or reinterpret the outcome of the run itself.
    private func persistState(
        _ lifecycle: NotesGenerationOperationLifecycle,
        stage: NotesGenerationOperationStage?,
        failureDescription: String?,
        record: LectureNotesGenerationRecord,
        paths: NotesArtifactPaths,
        runID: UUID,
        attemptCount: Int
    ) {
        let state = NotesGenerationOperationState(
            sessionID: record.sessionID,
            generationID: record.generationID,
            transcriptFingerprint: record.transcriptFingerprint,
            activeRunID: runID,
            runAttemptCount: attemptCount,
            lifecycle: lifecycle,
            currentStage: stage,
            failureDescription: failureDescription
        )
        try? operationStateStore.saveOperationState(state, paths: paths)
    }
}
