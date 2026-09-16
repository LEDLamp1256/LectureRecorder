import Combine
import Foundation

/// One completed-session window's presentation state for Notes: which
/// generation (if any) is currently displayed, and its recovery
/// classification. A thin wrapper around already-existing durable state and
/// `NotesGenerationRecoveryClassification` — never a second Notes state
/// machine. `.loaded`'s `classification` is always produced by
/// `NotesGenerationRecoveryClassifier`, never re-derived here.
nonisolated enum SessionNotesDisplayState: Equatable {
    /// No `refresh(for:)` has completed yet for the currently displayed
    /// session.
    case loading
    /// `listGenerationIDs` returned no generations for this session yet.
    case noGeneration
    case loaded(record: LectureNotesGenerationRecord, classification: NotesGenerationRecoveryClassification, advisoryStateIntegrity: NotesAdvisoryStateIntegrity)
    /// A durable read failed (corrupt store, unreadable transcript source,
    /// etc.) — distinct from any `NotesGenerationRecoveryClassification`
    /// case, since the classifier was never reached.
    case loadError(String)
}

/// Whether the advisory `operation-state.json` this generation's
/// classification was computed against could be trusted. Deliberately kept
/// separate from `NotesGenerationRecoveryClassification` itself: canonical
/// artifacts (and therefore `.completed`/`.readyForSynthesis`/`.staleSource`
/// /`.damaged`) are never affected by operation-state problems — operation
/// state is only ever consulted by the classifier to explain a
/// `.resumable` classification's `interruption`, never to determine
/// completeness. `.problem` exists only so the UI can refuse to offer
/// Continue/Retry in exactly the two cases
/// `LectureNotesGenerationService.run()` would itself deterministically
/// refuse before ever reaching classification — see its own
/// `operationStateIdentity` switch and its `loadOperationState` catch
/// block — without ever hiding an otherwise-valid canonical result.
nonisolated enum NotesAdvisoryStateIntegrity: Equatable {
    case normal
    case problem(reason: String)
}

/// Pure, deterministic default-generation selection among every generation
/// T5-A/B/C ever persisted for a session. T5-A intentionally keeps every
/// generation on disk — this policy exists only to pick *which one* T5-D
/// displays by default; it never deletes, hides, or reorders anything in
/// storage, and `LectureNotesStoring.listGenerationIDs` remains UUID-string
/// ordered regardless of this policy.
nonisolated enum SessionNotesGenerationSelection {
    /// Newest `createdDate` first; ties broken by the greater
    /// `generationID.uuidString` so the result is fully deterministic even
    /// when two generations were created within the same persisted
    /// millisecond. `nil` only when `records` is empty.
    static func chooseDefault(records: [LectureNotesGenerationRecord]) -> LectureNotesGenerationRecord? {
        records.sorted { lhs, rhs in
            if lhs.createdDate != rhs.createdDate { return lhs.createdDate > rhs.createdDate }
            return lhs.generationID.uuidString > rhs.generationID.uuidString
        }.first
    }
}

/// One window's read-only Notes presentation coordinator for the currently
/// selected completed session — the Notes-domain analog of
/// `SessionTranscriptPresenter`. Reconstructs `SessionNotesDisplayState`
/// entirely from already-persisted durable artifacts via
/// `LectureNotesStoring`/`LectureNotesOperationStateStoring`/
/// `NotesTranscriptSourceLoading` plus `NotesGenerationRecoveryClassifier` —
/// it never calls `LectureNotesGenerationService.generate`/
/// `continueGeneration`/`retry`/`cancel` itself, never mints a generation
/// ID, never writes any artifact, and never re-derives recovery/lifecycle
/// rules the classifier or service already own. Constructing this type, or
/// calling `refresh(for:)`, performs no network request and starts no
/// generation.
///
/// Stale-load protection mirrors `SessionTranscriptPresenter` exactly: an
/// explicit generation counter, incremented up front and re-checked after
/// the sole `await` point, so a load already in flight when the selection
/// changes can never overwrite a newer selection's result.
@MainActor
final class SessionNotesPresenter: ObservableObject {
    private let notesStore: any LectureNotesStoring
    private let operationStateStore: any LectureNotesOperationStateStoring
    private let sourceLoader: any NotesTranscriptSourceLoading
    private var generation = 0

    @Published private(set) var displayedSessionID: UUID?
    @Published private(set) var displayState: SessionNotesDisplayState = .loading

    init(
        notesStore: any LectureNotesStoring,
        operationStateStore: any LectureNotesOperationStateStoring,
        sourceLoader: any NotesTranscriptSourceLoading
    ) {
        self.notesStore = notesStore
        self.operationStateStore = operationStateStore
        self.sourceLoader = sourceLoader
    }

    func refresh(for entry: CompletedSessionEntry) async {
        generation += 1
        let myGeneration = generation
        let sessionID = entry.manifest.sessionID
        let sessionPaths = entry.sessionPaths

        func publish(_ state: SessionNotesDisplayState) {
            guard myGeneration == generation else { return }
            displayedSessionID = sessionID
            displayState = state
        }

        let generationIDs: [UUID]
        do {
            generationIDs = try notesStore.listGenerationIDs(sessionPaths: sessionPaths)
        } catch {
            publish(.loadError(error.localizedDescription))
            return
        }

        guard !generationIDs.isEmpty else {
            publish(.noGeneration)
            return
        }

        // Fail closed: `listGenerationIDs` already proved every one of
        // these IDs exists on disk, so an unreadable candidate is never
        // silently dropped from consideration before applying the
        // newest-`createdDate` selection policy below — doing so could
        // make an older, readable generation appear to be "the newest"
        // purely because the actual newest one happened to be unreadable.
        var records: [LectureNotesGenerationRecord] = []
        for generationID in generationIDs {
            let candidatePaths: NotesArtifactPaths
            do {
                candidatePaths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
            } catch {
                publish(.loadError("Notes generation \(generationID.uuidString) could not be validated: \(error.localizedDescription)"))
                return
            }
            do {
                guard let record = try notesStore.loadGeneration(paths: candidatePaths) else {
                    // `listGenerationIDs` enumerated this generation's
                    // directory, but no generation record exists inside
                    // it — an explicit, unexpected inconsistency, never
                    // silently treated as "this generation doesn't exist".
                    publish(.loadError("Notes generation \(generationID.uuidString) is listed but has no generation record."))
                    return
                }
                records.append(record)
            } catch {
                publish(.loadError("Notes generation \(generationID.uuidString) could not be loaded: \(error.localizedDescription)"))
                return
            }
        }

        guard let chosen = SessionNotesGenerationSelection.chooseDefault(records: records) else {
            // `generationIDs` was proven non-empty above and every ID
            // loaded successfully in the loop above — unreachable in
            // practice; kept only as a defensive fallback, never as a
            // reordering policy of its own.
            publish(.loadError("Unable to determine the Notes generation to display for this session."))
            return
        }

        let paths: NotesArtifactPaths
        do {
            paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: chosen.generationID)
        } catch {
            publish(.loadError(error.localizedDescription))
            return
        }

        let analysisResults: [NotesArtifactLoadResult<LectureNotesWindowAnalysis>]
        do {
            analysisResults = try notesStore.loadAllWindowAnalyses(paths: paths)
        } catch {
            publish(.loadError(error.localizedDescription))
            return
        }

        var analyses: [LectureNotesWindowAnalysis] = []
        for result in analysisResults {
            switch result {
            case .success(_, let value):
                analyses.append(value)
            case .failure(let windowIndex, let underlying):
                // Mirrors `LectureNotesGenerationService.run()`'s own
                // handling of this exact case: a corrupt committed analysis
                // is reported as damaged, never silently dropped from
                // coverage.
                publish(.loaded(
                    record: chosen,
                    classification: .damaged(reason: .corruptOrInvalidAnalysis(windowIndex: windowIndex, underlying: underlying)),
                    advisoryStateIntegrity: .normal
                ))
                return
            }
        }

        let document: LectureNotesDocument?
        do {
            document = try notesStore.loadDocument(paths: paths)
        } catch {
            publish(.loadError(error.localizedDescription))
            return
        }

        // Advisory-only (see `NotesGenerationOperationState`'s own header
        // comment): a problem here — unreadable, or readable but
        // identity-mismatched — must never be treated as equivalent to a
        // canonical read failure, and must never suppress an otherwise-
        // valid canonical classification (`.completed` in particular never
        // consults operation state at all). It is instead folded into
        // `advisoryStateIntegrity`, which `NotesActionAvailabilityCalculator`
        // uses to withhold Continue/Retry in exactly the two situations
        // `LectureNotesGenerationService.run()` would itself deterministically
        // refuse before ever reaching classification — see its own
        // `operationStateIdentity` switch (mismatched fingerprint) and its
        // `loadOperationState` catch block (unreadable) — never a second,
        // independently-invented policy.
        let operationStateForClassification: NotesGenerationOperationState?
        let advisoryStateIntegrity: NotesAdvisoryStateIntegrity
        do {
            if let loadedOperationState = try operationStateStore.loadOperationState(paths: paths) {
                if loadedOperationState.transcriptFingerprint == chosen.transcriptFingerprint {
                    operationStateForClassification = loadedOperationState
                    advisoryStateIntegrity = .normal
                } else {
                    operationStateForClassification = nil
                    advisoryStateIntegrity = .problem(reason: "recovery metadata for this generation does not match its transcript")
                }
            } else {
                operationStateForClassification = nil
                advisoryStateIntegrity = .normal
            }
        } catch {
            operationStateForClassification = nil
            advisoryStateIntegrity = .problem(reason: "recovery metadata could not be read: \(error.localizedDescription)")
        }

        let sourceSnapshot: NotesTranscriptSourceSnapshot
        do {
            sourceSnapshot = try await sourceLoader.loadCurrentSnapshot(sessionID: sessionID)
        } catch {
            publish(.loadError(error.localizedDescription))
            return
        }

        let classification = NotesGenerationRecoveryClassifier.classify(
            generation: chosen,
            sourceSnapshot: sourceSnapshot,
            analyses: analyses,
            document: document,
            operationState: operationStateForClassification
        )
        publish(.loaded(record: chosen, classification: classification, advisoryStateIntegrity: advisoryStateIntegrity))
    }
}
