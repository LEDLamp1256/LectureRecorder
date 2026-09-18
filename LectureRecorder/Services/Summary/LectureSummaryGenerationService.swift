import Combine
import Foundation

/// The single, app-wide authoritative owner of Summary-generation operations
/// for completed sessions. Mirrors `LectureNotesGenerationService`'s
/// single-owner, epoch-guarded admission/cancellation shape, adapted for the
/// Summary domain. Owns its own independent admission slot — a Summary
/// operation and a Notes operation may run concurrently; this service never
/// consults or locks against `LectureNotesGenerationService`. Summary
/// correctness instead comes entirely from immutable committed source
/// artifacts plus provenance (see `LectureSummarySourceLoader`,
/// `LectureSummaryIntegrityValidator`), never from a shared admission lock.
///
/// `@MainActor` for the same reason `LectureNotesGenerationService` is:
/// published state must be safely observable by views without an
/// intervening suspension.
@MainActor
final class LectureSummaryGenerationService: ObservableObject {
    enum OperationPhase: Equatable {
        case idle
        case preparingSource
        case classifying
        /// Only reached for a brand-new generation (`generate`) — Continue/
        /// Retry always resume an already-persisted, already-planned
        /// generation and never reach this phase. Distinct from Notes,
        /// which computes its window plan with a local pure function;
        /// `LectureSummaryGenerating.makePlan(for:)` is backend-owned (batch
        /// sizing depends on the real model's context budget), so planning
        /// is itself an async generator call worth its own observable phase.
        case planning
        case analyzingBatch(batchIndex: Int, totalBatches: Int)
        case synthesizing
        case cancelling
        case finished(SummaryGenerationOutcome)
    }

    /// The terminal result of one Generate/Continue/Retry run. Never itself
    /// a source of truth — every case here is derived from, and consistent
    /// with, what `SummaryGenerationRecoveryClassifier` would independently
    /// compute from durable artifacts alone.
    enum SummaryGenerationOutcome: Equatable {
        case completed(document: LectureSummaryDocument)
        case cancelled
        case staleSource
        case damaged(reason: SummaryGenerationDamageReason)
        case failed(description: String)
        /// The backend a brand-new generation would use is not ready right
        /// now. Reached only for `generate(sessionID:notesGenerationID:)`,
        /// always before any Summary generation record is created and
        /// before any generator/network call.
        case backendUnavailable(description: String)
        /// The requested source Notes generation is not currently a valid
        /// Summary source (missing, incomplete, or failing Notes integrity
        /// validation). Reached only for `generate`, always before any
        /// Summary generation record is created — Notes is left completely
        /// untouched either way. Distinct from `.staleSource`, which is
        /// reached only once a Summary generation record already exists and
        /// its *own* previously-valid source has since stopped matching.
        case sourceNotesUnavailable(description: String)
    }

    enum AdmissionResult: Sendable, Equatable {
        case admitted
        /// Another Summary-generation operation is already active app-wide.
        /// Never consults, and is never consulted by,
        /// `LectureNotesGenerationService`'s own admission state.
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
    @Published private(set) var phase: OperationPhase = .idle {
        didSet {
            let description: String?
            switch phase {
            case .finished(.failed(let value)):
                description = value
            case .finished(.backendUnavailable(let value)):
                description = value
            case .finished(.sourceNotesUnavailable(let value)):
                description = value
            default:
                description = nil
            }
            guard let description, let activeSessionID else { return }
            lastFailureDescriptionBySessionID[activeSessionID] = description
        }
    }
    /// Transient, memory-only, session-keyed record of the most recent
    /// terminal-failure-shaped outcome for each session. Entirely separate
    /// storage from `LectureNotesGenerationService.lastFailureDescriptionBySessionID`
    /// — a Summary failure never reuses, reads, or overwrites Notes' own
    /// transient failure state, and vice versa. Cleared the instant a new
    /// operation is admitted for that same session (see `beginOperation`).
    /// Never persisted; not part of any Summary storage format.
    @Published private(set) var lastFailureDescriptionBySessionID: [UUID: String] = [:]

    private(set) var isShuttingDown = false
    private(set) var operationEpoch = 0

    private let sourceLoader: any LectureSummarySourceLoading
    private let summaryStore: any LectureSummaryStoring
    private let operationStateStore: any LectureSummaryOperationStateStoring
    private let generator: any LectureSummaryGenerating
    /// Consulted only when `generate(sessionID:notesGenerationID:)` is about
    /// to create a brand-new generation (never for Continue/Retry, which
    /// always resume an already-persisted generation).
    private let newGenerationAvailabilityChecker: any NewLectureNotesGenerationAvailabilityChecking
    /// Frozen into each new immutable generation record. Continue/Retry load
    /// the already-persisted record and therefore never consult this value.
    private let generationProvenance: LectureNotesGenerationProvenance
    private let sessionsRootResolver: @Sendable () throws -> URL
    /// Mints the identity for a brand-new generation (Generate only).
    /// Exposed only so tests can pre-target a known generation-record URL;
    /// production always uses a fresh random `UUID`.
    private let generationIDProvider: @Sendable () -> UUID

    private var currentTask: Task<Void, Never>?

    init(
        sourceLoader: any LectureSummarySourceLoading,
        summaryStore: any LectureSummaryStoring,
        operationStateStore: any LectureSummaryOperationStateStoring,
        generator: any LectureSummaryGenerating,
        newGenerationAvailabilityChecker: any NewLectureNotesGenerationAvailabilityChecking = AlwaysAvailableNewGenerationChecker(),
        generationProvenance: LectureNotesGenerationProvenance,
        sessionsRootResolver: @escaping @Sendable () throws -> URL = {
            try DefaultFileSystemLocator.resolveSessionsRootPathWithoutCreating()
        },
        generationIDProvider: @escaping @Sendable () -> UUID = { UUID() },
        shutdownPollInterval: TimeInterval = 0.02
    ) {
        self.sourceLoader = sourceLoader
        self.summaryStore = summaryStore
        self.operationStateStore = operationStateStore
        self.generator = generator
        self.newGenerationAvailabilityChecker = newGenerationAvailabilityChecker
        self.generationProvenance = generationProvenance
        self.sessionsRootResolver = sessionsRootResolver
        self.generationIDProvider = generationIDProvider
        self.shutdownPollInterval = shutdownPollInterval
    }

    // MARK: - Public entry points

    /// Starts a brand-new Summary generation for `sessionID`, sourced from
    /// exactly `notesGenerationID`. The caller (eventually the presentation
    /// layer in a later stage) supplies which Notes generation to summarize
    /// — this service never selects "the current/default" Notes generation
    /// itself, mirroring how `sessionID` is always caller-supplied rather
    /// than chosen internally. Always mints a fresh Summary generation ID
    /// and never overwrites or deletes any prior Summary generation for
    /// this session. Fails closed (`.sourceNotesUnavailable`) unless
    /// `notesGenerationID` currently has a valid, complete Notes document —
    /// never creates a Summary generation record otherwise, and never
    /// mutates the Notes generation it reads.
    @discardableResult
    func generate(sessionID: UUID, notesGenerationID: UUID) -> AdmissionResult {
        beginOperation(sessionID: sessionID, generationID: nil, notesGenerationID: notesGenerationID)
    }

    /// Resumes `generationID` after cancellation, interruption, or clean
    /// incompleteness. Never replans and never mints a new generation ID.
    @discardableResult
    func continueGeneration(sessionID: UUID, generationID: UUID) -> AdmissionResult {
        beginOperation(sessionID: sessionID, generationID: generationID, notesGenerationID: nil)
    }

    /// Resumes `generationID` after a recoverable failure. Uses the same
    /// resumption mechanics as `continueGeneration`, differing only in
    /// which case a caller invokes it from.
    @discardableResult
    func retry(sessionID: UUID, generationID: UUID) -> AdmissionResult {
        beginOperation(sessionID: sessionID, generationID: generationID, notesGenerationID: nil)
    }

    /// Requests cooperative cancellation of the active operation, if it
    /// belongs to `sessionID`. A no-op otherwise. Leaves every
    /// already-committed canonical Summary artifact untouched, and never
    /// touches Notes.
    func cancel(sessionID: UUID) {
        guard currentTask != nil, activeSessionID == sessionID else { return }
        phase = .cancelling
        currentTask?.cancel()
    }

    /// The most recent terminal-failure-shaped outcome recorded for
    /// `sessionID`, if any — see `lastFailureDescriptionBySessionID`'s own
    /// header comment.
    func lastFailureDescription(forSessionID sessionID: UUID) -> String? {
        lastFailureDescriptionBySessionID[sessionID]
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
    func shutdown(timeout: TimeInterval = LectureSummaryGenerationService.defaultShutdownTimeout) async -> ShutdownOutcome {
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

    private func beginOperation(sessionID: UUID, generationID: UUID?, notesGenerationID: UUID?) -> AdmissionResult {
        guard !isShuttingDown else { return .shuttingDown }
        guard currentTask == nil else { return .busy }

        lastFailureDescriptionBySessionID[sessionID] = nil

        operationEpoch += 1
        let myEpoch = operationEpoch
        activeSessionID = sessionID
        activeGenerationID = generationID
        phase = .preparingSource

        currentTask = Task { [weak self] in
            await self?.run(sessionID: sessionID, generationID: generationID, notesGenerationID: notesGenerationID, epoch: myEpoch)
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

    private func run(sessionID: UUID, generationID: UUID?, notesGenerationID: UUID?, epoch: Int) async {
        func publish(_ mutate: () -> Void) {
            guard epoch == self.operationEpoch else { return }
            mutate()
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
        let record: LectureSummaryGenerationRecord
        let initialSource: LectureSummarySourceSnapshot

        if let generationID {
            resolvedGenerationID = generationID
            let paths: SummaryArtifactPaths
            do {
                paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
            } catch {
                publish { self.phase = .finished(.failed(description: "Invalid generation paths: \(error.localizedDescription)")) }
                return
            }
            let loaded: LectureSummaryGenerationRecord?
            do {
                loaded = try summaryStore.loadGeneration(paths: paths)
            } catch {
                publish { self.phase = .finished(.failed(description: "Unable to load Summary generation record: \(error.localizedDescription)")) }
                return
            }
            guard let loaded else {
                publish { self.phase = .finished(.failed(description: "No Summary generation record exists for the given generation ID.")) }
                return
            }
            record = loaded

            guard !Task.isCancelled else {
                publish { self.phase = .finished(.cancelled) }
                return
            }

            // A record already exists. A genuine source-invalidity error
            // here means this generation's own previously-valid source (the
            // specific referenced Notes generation) is no longer obtainable
            // or valid — exactly what `.staleSource` means. An ordinary
            // operational failure (e.g. a transient I/O problem) is never
            // reported as staleness; it surfaces as `.failed` so the caller
            // knows a plain Retry is the appropriate next step, not "start
            // over" (T5-F3A correction: see `classifySourceLoadFailure`).
            do {
                initialSource = try await sourceLoader.loadSourceSnapshot(sessionID: sessionID, notesGenerationID: record.sourceNotesGenerationID)
            } catch {
                switch classifySourceLoadFailure(error) {
                case .sourceInvalid:
                    publish { self.phase = .finished(.staleSource) }
                case .operational(let description):
                    publish { self.phase = .finished(.failed(description: "Unable to reload Summary source: \(description)")) }
                }
                return
            }
        } else {
            guard let notesGenerationID else {
                // Unreachable given `generate`/`continueGeneration`/`retry`'s
                // own contracts (Generate always supplies notesGenerationID,
                // Continue/Retry always supply generationID) — defensive,
                // never trapped.
                publish { self.phase = .finished(.failed(description: "Internal error: Generate requires a source Notes generation ID.")) }
                return
            }

            // Admission-time availability precondition for a brand-new
            // generation only — Continue/Retry (the `if let generationID`
            // branch above) always resume an already-persisted generation
            // and never reach here.
            switch newGenerationAvailabilityChecker.availabilityForNewGeneration() {
            case .available:
                break
            case .unavailable(let description):
                publish { self.phase = .finished(.backendUnavailable(description: description)) }
                return
            }

            guard !Task.isCancelled else {
                publish { self.phase = .finished(.cancelled) }
                return
            }

            // Fail closed: no Summary generation record is ever created
            // unless the requested source Notes generation is currently
            // valid and complete. Notes itself is only ever read here, never
            // mutated.
            let sourceSnapshot: LectureSummarySourceSnapshot
            do {
                sourceSnapshot = try await sourceLoader.loadSourceSnapshot(sessionID: sessionID, notesGenerationID: notesGenerationID)
            } catch {
                switch classifySourceLoadFailure(error) {
                case .sourceInvalid(let description):
                    publish { self.phase = .finished(.sourceNotesUnavailable(description: description)) }
                case .operational(let description):
                    publish { self.phase = .finished(.failed(description: "Unable to load Summary source: \(description)")) }
                }
                return
            }

            guard !Task.isCancelled else {
                publish { self.phase = .finished(.cancelled) }
                return
            }

            publish { self.phase = .planning }

            let plan: LectureSummaryPlan
            do {
                plan = try await generator.makePlan(for: sourceSnapshot)
            } catch {
                guard !Task.isCancelled else {
                    publish { self.phase = .finished(.cancelled) }
                    return
                }
                publish { self.phase = .finished(.failed(description: "Unable to plan Summary batches: \(error.localizedDescription)")) }
                return
            }

            guard !Task.isCancelled else {
                publish { self.phase = .finished(.cancelled) }
                return
            }

            resolvedGenerationID = generationIDProvider()
            let newRecord = LectureSummaryGenerationRecord.newGeneration(
                generationID: resolvedGenerationID,
                sessionID: sessionID,
                sourceNotesGenerationID: notesGenerationID,
                transcriptFingerprint: sourceSnapshot.transcriptFingerprint,
                sourceNotesDocumentFingerprint: sourceSnapshot.sourceNotesDocumentFingerprint,
                batchPlan: plan,
                provenance: generationProvenance
            )
            let paths: SummaryArtifactPaths
            do {
                paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: resolvedGenerationID)
            } catch {
                publish { self.phase = .finished(.failed(description: "Invalid generation paths: \(error.localizedDescription)")) }
                return
            }
            do {
                let outcome = try summaryStore.createGenerationIfAbsent(newRecord, paths: paths)
                switch outcome {
                case .created, .alreadyExistsIdentical:
                    break
                case .createdDurabilityUncertain:
                    publish {
                        self.phase = .finished(.failed(description: "Generation record commit durability is uncertain; use Continue or Retry to confirm."))
                    }
                    return
                case .conflict:
                    publish { self.phase = .finished(.failed(description: "A conflicting Summary generation record already exists at this generation ID.")) }
                    return
                }
            } catch {
                publish { self.phase = .finished(.failed(description: "Unable to persist Summary generation record: \(error.localizedDescription)")) }
                return
            }
            record = newRecord
            initialSource = sourceSnapshot
        }

        let paths: SummaryArtifactPaths
        do {
            paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: resolvedGenerationID)
        } catch {
            publish { self.phase = .finished(.failed(description: error.localizedDescription)) }
            return
        }

        publish {
            self.activeGenerationID = resolvedGenerationID
            self.phase = .classifying
        }

        let loadedAnalyses: [LectureSummaryAnalysis]
        do {
            let entries = try summaryStore.loadAllAnalyses(paths: paths)
            var values: [LectureSummaryAnalysis] = []
            for entry in entries {
                switch entry {
                case .success(_, let value):
                    values.append(value)
                case .failure(let batchIndex, let errorDescription):
                    publish { self.phase = .finished(.damaged(reason: .corruptOrInvalidAnalysis(batchIndex: batchIndex, underlying: errorDescription))) }
                    return
                }
            }
            loadedAnalyses = values
        } catch {
            publish { self.phase = .finished(.failed(description: "Unable to load Summary batch analyses: \(error.localizedDescription)")) }
            return
        }

        let document: LectureSummaryDocument?
        do {
            document = try summaryStore.loadDocument(paths: paths)
        } catch {
            publish { self.phase = .finished(.failed(description: "Unable to load Summary document: \(error.localizedDescription)")) }
            return
        }

        let loadedOperationState: SummaryGenerationOperationState?
        do {
            loadedOperationState = try operationStateStore.loadOperationState(paths: paths)
        } catch {
            publish { self.phase = .finished(.failed(description: "Unable to load Summary operation state: \(error.localizedDescription)")) }
            return
        }
        // Mirrors `LectureNotesGenerationService`'s own three-way handling:
        // "no operation-state artifact exists" and "one exists but
        // disagrees with this generation's own identity" are never
        // conflated. The latter stops the run before classification,
        // canonical artifacts, or the generator are ever touched.
        let operationState: SummaryGenerationOperationState?
        switch operationStateIdentity(of: loadedOperationState, forGeneration: record) {
        case .absent:
            operationState = nil
        case .matching(let state):
            operationState = state
        case .mismatchedIdentity:
            publish {
                self.phase = .finished(.failed(description: "Operation-state identity does not match this generation's; refusing to proceed."))
            }
            return
        }

        let classification = SummaryGenerationRecoveryClassifier.classify(
            generation: record,
            source: initialSource,
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
        case .resumable(let nextBatchIndex, _):
            switch nextRunAttemptCount(after: operationState) {
            case .failure(let error):
                publish { self.phase = .finished(.failed(description: "Operation-state run-attempt count is invalid: \(error.errorDescription ?? "unknown reason")")) }
            case .success(let attemptCount):
                await runSequentialGeneration(
                    record: record,
                    paths: paths,
                    sessionID: sessionID,
                    startingBatchIndex: nextBatchIndex,
                    source: initialSource,
                    existingAnalyses: loadedAnalyses,
                    runID: UUID(),
                    attemptCount: attemptCount,
                    publish: publish
                )
            }
        }
    }

    /// Every way `SummaryGenerationOperationState.runAttemptCount` can be
    /// invalid untrusted persisted input, or would overflow on increment.
    /// Never allowed to trap the process. Identical logic to
    /// `LectureNotesGenerationService`'s own, duplicated rather than shared
    /// since it is the entirety of what the two orchestration services would
    /// otherwise need a common base type for.
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

    private func nextRunAttemptCount(after operationState: SummaryGenerationOperationState?) -> Result<Int, RunAttemptCountError> {
        guard let previous = operationState?.runAttemptCount else { return .success(1) }
        guard previous >= 0 else { return .failure(.negativePersistedValue(previous)) }
        let (next, overflowed) = previous.addingReportingOverflow(1)
        guard !overflowed else { return .failure(.overflow) }
        return .success(next)
    }

    private enum OperationStateIdentity {
        case absent
        case matching(SummaryGenerationOperationState)
        /// `loaded` exists and already passed the store's own
        /// `sessionID`/`generationID` identity check (proving it belongs to
        /// the right *path*), but its own `sourceNotesGenerationID`/
        /// `transcriptFingerprint`/`sourceNotesDocumentFingerprint` disagree
        /// with `generation`'s — it does not describe the same source this
        /// generation was fixed against.
        case mismatchedIdentity
    }

    private func operationStateIdentity(
        of loaded: SummaryGenerationOperationState?,
        forGeneration generation: LectureSummaryGenerationRecord
    ) -> OperationStateIdentity {
        guard let loaded else { return .absent }
        guard
            loaded.sourceNotesGenerationID == generation.sourceNotesGenerationID,
            loaded.transcriptFingerprint == generation.transcriptFingerprint,
            loaded.sourceNotesDocumentFingerprint == generation.sourceNotesDocumentFingerprint
        else { return .mismatchedIdentity }
        return .matching(loaded)
    }

    /// Whether `source` still matches `generation`'s own frozen identity —
    /// the mid-run freshness re-check shared by every commit checkpoint
    /// below. Because the source Notes document is commit-once and
    /// immutable per generation ID, the only way this can legitimately fail
    /// mid-run is the *live transcript* diverging from what the referenced
    /// Notes generation recorded (e.g. the session was re-transcribed while
    /// a Summary run was in flight).
    private func sourceStillMatches(_ source: LectureSummarySourceSnapshot, generation: LectureSummaryGenerationRecord) -> Bool {
        source.sessionID == generation.sessionID
            && source.sourceNotesGenerationID == generation.sourceNotesGenerationID
            && source.transcriptFingerprint == generation.transcriptFingerprint
            && source.sourceNotesDocumentFingerprint == generation.sourceNotesDocumentFingerprint
    }

    /// Only `.sourceInvalid` may ever be reported as
    /// `.staleSource`/`.sourceNotesUnavailable`; `.operational` always
    /// surfaces as an ordinary `.failed(description:)`, never source
    /// staleness. See `SummarySourceLoadFailureClassification`'s own header
    /// comment — shared with `SessionSummaryPresenter` so the two layers can
    /// never diverge on this mapping.
    private func classifySourceLoadFailure(_ error: Error) -> SummarySourceLoadFailureClassification {
        SummarySourceLoadFailureClassification.classify(error)
    }

    // MARK: - Sequential batch generation

    private func runSequentialGeneration(
        record: LectureSummaryGenerationRecord,
        paths: SummaryArtifactPaths,
        sessionID: UUID,
        startingBatchIndex: Int,
        source sourceAtStart: LectureSummarySourceSnapshot,
        existingAnalyses: [LectureSummaryAnalysis],
        runID: UUID,
        attemptCount: Int,
        publish: (() -> Void) -> Void
    ) async {
        let orderedBatches = record.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        var analyses = existingAnalyses

        for batch in orderedBatches where batch.batchIndex >= startingBatchIndex {
            guard !Task.isCancelled else {
                persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.cancelled) }
                return
            }

            publish { self.phase = .analyzingBatch(batchIndex: batch.batchIndex, totalBatches: orderedBatches.count) }
            persistState(
                .running,
                stage: .analyzingBatch(batchIndex: batch.batchIndex),
                failureDescription: nil,
                record: record,
                paths: paths,
                runID: runID,
                attemptCount: attemptCount
            )

            guard !Task.isCancelled else {
                persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.cancelled) }
                return
            }

            let analysis: LectureSummaryAnalysis
            do {
                analysis = try await generator.generateAnalysis(for: batch, generation: record, source: sourceAtStart)
            } catch {
                // A generator that observes cancellation throws rather than
                // returning normally — that must still be reported as
                // `.cancelled`, never misreported as a genuine failure.
                guard !Task.isCancelled else {
                    persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                    publish { self.phase = .finished(.cancelled) }
                    return
                }
                let description = "Analysis for batch \(batch.batchIndex) failed: \(error.localizedDescription)"
                persistState(.failed, stage: .analyzingBatch(batchIndex: batch.batchIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
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

            let currentSource: LectureSummarySourceSnapshot
            do {
                currentSource = try await sourceLoader.loadSourceSnapshot(sessionID: sessionID, notesGenerationID: record.sourceNotesGenerationID)
            } catch {
                switch classifySourceLoadFailure(error) {
                case .sourceInvalid:
                    // The source this generation depends on is no longer
                    // obtainable/valid — the freshly generated analysis is
                    // discarded, never committed.
                    publish { self.phase = .finished(.staleSource) }
                case .operational(let description):
                    let failDescription = "Unable to reconfirm Summary source before commit: \(description)"
                    persistState(.failed, stage: .analyzingBatch(batchIndex: batch.batchIndex), failureDescription: failDescription, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                    publish { self.phase = .finished(.failed(description: failDescription)) }
                }
                return
            }
            guard sourceStillMatches(currentSource, generation: record) else {
                publish { self.phase = .finished(.staleSource) }
                return
            }

            guard !Task.isCancelled else {
                persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.cancelled) }
                return
            }

            do {
                try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: record, source: currentSource)
            } catch {
                let description = "Analysis for batch \(batch.batchIndex) failed validation: \(error.localizedDescription)"
                persistState(.failed, stage: .analyzingBatch(batchIndex: batch.batchIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: description)) }
                return
            }

            let commitOutcome: SummaryAnalysisCommitOutcome
            do {
                commitOutcome = try summaryStore.commitAnalysis(analysis, paths: paths)
            } catch {
                let description = "Unable to commit analysis for batch \(batch.batchIndex): \(error.localizedDescription)"
                persistState(.failed, stage: .analyzingBatch(batchIndex: batch.batchIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: description)) }
                return
            }

            switch commitOutcome {
            case .committed, .alreadyCommittedIdentical:
                analyses.append(analysis)
            case .committedDurabilityUncertain:
                let description = "Commit durability for batch \(batch.batchIndex) is uncertain; use Continue or Retry to confirm."
                persistState(.failed, stage: .analyzingBatch(batchIndex: batch.batchIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: description)) }
                return
            case .conflict:
                let description = "Batch \(batch.batchIndex) already has a conflicting committed analysis."
                persistState(.failed, stage: .analyzingBatch(batchIndex: batch.batchIndex), failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
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
        record: LectureSummaryGenerationRecord,
        paths: SummaryArtifactPaths,
        sessionID: UUID,
        analyses: [LectureSummaryAnalysis],
        runID: UUID,
        attemptCount: Int,
        publish: (() -> Void) -> Void
    ) async {
        guard !Task.isCancelled else {
            persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.cancelled) }
            return
        }

        // Revalidate the source and this generation's exact committed batch
        // coverage immediately before synthesis — a generation can sit at
        // "ready for synthesis" for an arbitrary amount of time (e.g. across
        // a Continue) before this ever runs, so both are reconfirmed fresh
        // here too, not only after synthesis.
        let preSynthesisSource: LectureSummarySourceSnapshot
        do {
            preSynthesisSource = try await sourceLoader.loadSourceSnapshot(sessionID: sessionID, notesGenerationID: record.sourceNotesGenerationID)
        } catch {
            switch classifySourceLoadFailure(error) {
            case .sourceInvalid:
                publish { self.phase = .finished(.staleSource) }
            case .operational(let description):
                let failDescription = "Unable to reconfirm Summary source before synthesis: \(description)"
                persistState(.failed, stage: .synthesizing, failureDescription: failDescription, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: failDescription)) }
            }
            return
        }
        guard sourceStillMatches(preSynthesisSource, generation: record) else {
            publish { self.phase = .finished(.staleSource) }
            return
        }

        let orderedAnalyses = analyses.sorted { $0.batchIndex < $1.batchIndex }
        let expectedIndices = record.batchPlan.batches.map(\.batchIndex).sorted()
        guard orderedAnalyses.map(\.batchIndex) == expectedIndices else {
            // The source itself already matches (checked immediately
            // above), so a coverage mismatch here is a genuine canonical
            // integrity problem, never staleness — synthesis must not run.
            publish { self.phase = .finished(.damaged(reason: .nonPrefixCoverage(presentIndices: orderedAnalyses.map(\.batchIndex)))) }
            return
        }
        for analysis in orderedAnalyses {
            do {
                try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: record, source: preSynthesisSource)
            } catch {
                publish { self.phase = .finished(.damaged(reason: .corruptOrInvalidAnalysis(batchIndex: analysis.batchIndex, underlying: error.localizedDescription))) }
                return
            }
        }

        guard !Task.isCancelled else {
            persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.cancelled) }
            return
        }

        publish { self.phase = .synthesizing }
        persistState(.running, stage: .synthesizing, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)

        let document: LectureSummaryDocument
        do {
            document = try await generator.generateDocument(from: orderedAnalyses, generation: record, source: preSynthesisSource)
        } catch {
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

        guard !Task.isCancelled else {
            persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.cancelled) }
            return
        }

        let currentSource: LectureSummarySourceSnapshot
        do {
            currentSource = try await sourceLoader.loadSourceSnapshot(sessionID: sessionID, notesGenerationID: record.sourceNotesGenerationID)
        } catch {
            switch classifySourceLoadFailure(error) {
            case .sourceInvalid:
                publish { self.phase = .finished(.staleSource) }
            case .operational(let description):
                let failDescription = "Unable to reconfirm Summary source before document commit: \(description)"
                persistState(.failed, stage: .synthesizing, failureDescription: failDescription, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
                publish { self.phase = .finished(.failed(description: failDescription)) }
            }
            return
        }
        guard sourceStillMatches(currentSource, generation: record) else {
            publish { self.phase = .finished(.staleSource) }
            return
        }

        guard !Task.isCancelled else {
            persistState(.cancelled, stage: nil, failureDescription: nil, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.cancelled) }
            return
        }

        do {
            try LectureSummaryIntegrityValidator.validate(document: document, generation: record, source: currentSource)
        } catch {
            let description = "Synthesized Summary document failed validation: \(error.localizedDescription)"
            persistState(.failed, stage: .synthesizing, failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.failed(description: description)) }
            return
        }

        let commitOutcome: SummaryDocumentCommitOutcome
        do {
            commitOutcome = try summaryStore.commitDocument(document, paths: paths)
        } catch {
            let description = "Unable to commit Summary document: \(error.localizedDescription)"
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
            let description = "A conflicting Summary document already exists for this generation."
            persistState(.failed, stage: .synthesizing, failureDescription: description, record: record, paths: paths, runID: runID, attemptCount: attemptCount)
            publish { self.phase = .finished(.failed(description: description)) }
        }
    }

    // MARK: - Helpers

    /// Best-effort: operation-state is advisory-only (see
    /// `SummaryGenerationOperationState`), so a failure persisting it must
    /// never abort or reinterpret the outcome of the run itself.
    private func persistState(
        _ lifecycle: SummaryGenerationOperationLifecycle,
        stage: SummaryGenerationOperationStage?,
        failureDescription: String?,
        record: LectureSummaryGenerationRecord,
        paths: SummaryArtifactPaths,
        runID: UUID,
        attemptCount: Int
    ) {
        let state = SummaryGenerationOperationState(
            sessionID: record.sessionID,
            generationID: record.generationID,
            sourceNotesGenerationID: record.sourceNotesGenerationID,
            transcriptFingerprint: record.transcriptFingerprint,
            sourceNotesDocumentFingerprint: record.sourceNotesDocumentFingerprint,
            activeRunID: runID,
            runAttemptCount: attemptCount,
            lifecycle: lifecycle,
            currentStage: stage,
            failureDescription: failureDescription
        )
        try? operationStateStore.saveOperationState(state, paths: paths)
    }
}
