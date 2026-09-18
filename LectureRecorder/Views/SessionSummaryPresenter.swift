import Combine
import Foundation

/// One completed-session window's presentation state for Summary: whether a
/// currently usable Notes source exists, which Summary generation (if any)
/// is currently displayed, and its recovery classification. A thin wrapper
/// around already-existing durable state, `SummaryNotesSourceSelection`, and
/// `SummaryGenerationRecoveryClassifier` — never a second Summary state
/// machine. `.loaded`'s `classification` is always produced by
/// `SummaryGenerationRecoveryClassifier`, never re-derived here.
nonisolated enum SessionSummaryDisplayState: Equatable {
    /// No `refresh(for:)` has completed yet for the currently displayed
    /// session.
    case loading
    /// No Notes generation is currently usable as a fresh-Generate source —
    /// either no Notes generation exists yet, or the current/default one
    /// (`SessionNotesGenerationSelection.chooseDefault`) has no completed
    /// document — *and* no existing Summary generation exists for this
    /// session either. Never falls back to an older completed Notes
    /// generation. An unusable current Notes source alone does not imply
    /// this case: an existing Summary generation, if any, is always
    /// reported via `.loaded` regardless (see
    /// `currentUsableNotesGenerationID`'s own header comment).
    case noValidNotesSource
    /// A currently usable Notes generation exists, but no Summary
    /// generation has ever been created for this session yet.
    case noGeneration(notesGenerationID: UUID)
    case loaded(
        record: LectureSummaryGenerationRecord,
        classification: SummaryGenerationRecoveryClassification,
        advisoryStateIntegrity: SummaryAdvisoryStateIntegrity
    )
    /// A durable read, or a Summary source-loading operation, failed for a
    /// reason that is an ordinary operational problem — never Notes/Summary
    /// staleness or invalidity, which are represented inside `.loaded`'s own
    /// `classification` instead. See `SummarySourceLoadFailureClassification`.
    case loadError(String)
}

/// Whether the advisory `operation-state.json` this Summary generation's
/// classification was computed against could be trusted. Mirrors
/// `NotesAdvisoryStateIntegrity` exactly, adapted for the Summary domain.
/// Canonical artifacts (and therefore `.completed`/`.readyForSynthesis`/
/// `.staleSource`/`.damaged`) are never affected by operation-state
/// problems — operation state is only ever consulted by the classifier to
/// explain a `.resumable` classification's `interruption`, never to
/// determine completeness.
nonisolated enum SummaryAdvisoryStateIntegrity: Equatable {
    case normal
    case problem(reason: String)
}

/// Every way `SummaryNotesSourceSelection` can fail to determine the
/// currently applicable Notes generation. Distinct from "no valid Notes
/// generation exists" (`nil`, not an error) — this represents a durable read
/// actually failing/being inconsistent.
nonisolated enum SummaryNotesSourceSelectionError: LocalizedError, Sendable, Equatable {
    case generationListedButMissing(UUID)

    var errorDescription: String? {
        switch self {
        case .generationListedButMissing(let id):
            return "Notes generation \(id.uuidString) is listed but has no generation record."
        }
    }
}

/// Pure, deterministically-testable selection of the Notes generation F3B
/// currently considers the applicable Summary source — entirely independent
/// of `SessionNotesPresenter`/`SessionNotesDisplayState` (which are
/// view-instance-local and may not even be mounted, e.g. on a narrow
/// completed-session layout currently showing Transcript). Reuses exactly
/// the same deterministic default-generation policy
/// `SessionNotesGenerationSelection.chooseDefault(records:)` already applies
/// for the Notes UI's own display, so a fresh Summary Generate always uses
/// the same Notes generation the Notes pane itself would currently show.
///
/// Deliberately shallow: this never runs full Notes provenance/recovery
/// validation (`NotesGenerationRecoveryClassifier`) — it only asks whether
/// the chosen generation has a committed document. The authoritative
/// semantic validation of that Notes generation as a Summary source remains
/// entirely inside `LectureSummaryGenerationService.generate(sessionID:
/// notesGenerationID:)` via `LectureSummarySourceLoading`. Never falls back
/// to an older completed generation merely because the current/default one
/// is incomplete — an incomplete current generation means Summary has no
/// currently valid Notes source, full stop.
nonisolated enum SummaryNotesSourceSelection {
    static func currentUsableNotesGeneration(
        notesStore: any LectureNotesStoring,
        sessionPaths: SessionPaths,
        sessionID: UUID
    ) throws -> UUID? {
        let generationIDs = try notesStore.listGenerationIDs(sessionPaths: sessionPaths)
        guard !generationIDs.isEmpty else { return nil }

        var records: [LectureNotesGenerationRecord] = []
        for generationID in generationIDs {
            let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
            guard let record = try notesStore.loadGeneration(paths: paths) else {
                throw SummaryNotesSourceSelectionError.generationListedButMissing(generationID)
            }
            records.append(record)
        }

        guard let chosen = SessionNotesGenerationSelection.chooseDefault(records: records) else {
            return nil
        }

        let chosenPaths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: chosen.generationID)
        guard try notesStore.loadDocument(paths: chosenPaths) != nil else {
            // The current/default Notes generation is not yet complete —
            // never silently substitute an older completed generation.
            return nil
        }
        return chosen.generationID
    }
}

/// Pure, deterministic default-generation selection among every Summary
/// generation ever created for a session — the Summary-domain analog of
/// `SessionNotesGenerationSelection`. Exists because `generate` always mints
/// a fresh generation ID and never overwrites a prior one, so a session can
/// accumulate multiple Summary generations over time (e.g. after a stale
/// source forced a fresh Generate).
nonisolated enum SessionSummaryGenerationSelection {
    /// Newest `createdDate` first; ties broken by the greater
    /// `generationID.uuidString` so the result is fully deterministic even
    /// when two generations were created within the same persisted
    /// millisecond. `nil` only when `records` is empty.
    static func chooseDefault(records: [LectureSummaryGenerationRecord]) -> LectureSummaryGenerationRecord? {
        records.sorted { lhs, rhs in
            if lhs.createdDate != rhs.createdDate { return lhs.createdDate > rhs.createdDate }
            return lhs.generationID.uuidString > rhs.generationID.uuidString
        }.first
    }
}

/// One window's read-only Summary presentation coordinator for the currently
/// selected completed session — the Summary-domain analog of
/// `SessionNotesPresenter`. Reconstructs `SessionSummaryDisplayState`
/// entirely from already-persisted durable artifacts via
/// `LectureSummaryStoring`/`LectureSummaryOperationStateStoring`/
/// `LectureNotesStoring`/`LectureSummarySourceLoading` plus
/// `SummaryGenerationRecoveryClassifier` — it never calls
/// `LectureSummaryGenerationService.generate`/`continueGeneration`/`retry`/
/// `cancel` itself, never mints a generation ID, never writes any artifact,
/// and never re-derives recovery/lifecycle rules the classifier or service
/// already own. Deliberately independent of `SessionNotesPresenter`: it
/// performs its own Notes-source lookup (`SummaryNotesSourceSelection`)
/// rather than observing a Notes presenter instance, which may not even be
/// mounted at the same time as this one (see `CompletedSessionDetailView`'s
/// narrow-layout segmented picker).
///
/// An existing Summary generation's own pinned `sourceNotesGenerationID` is
/// never replaced by whatever `SummaryNotesSourceSelection` currently
/// selects — that would silently repin an existing generation to a
/// different source. Its recovery classification is always computed against
/// its own frozen source identity, obtained fresh via
/// `LectureSummarySourceLoading` exactly as
/// `LectureSummaryGenerationService` itself would on a Continue/Retry.
///
/// Stale-load protection mirrors `SessionNotesPresenter` exactly: an
/// explicit generation counter, incremented up front and re-checked by
/// every `publish` call after the sole `await` point, so a load already in
/// flight when the selection changes can never overwrite a newer
/// selection's result.
@MainActor
final class SessionSummaryPresenter: ObservableObject {
    private let summaryStore: any LectureSummaryStoring
    private let summaryOperationStateStore: any LectureSummaryOperationStateStoring
    private let notesStore: any LectureNotesStoring
    private let summarySourceLoader: any LectureSummarySourceLoading
    private var generation = 0

    @Published private(set) var displayedSessionID: UUID?
    @Published private(set) var displayState: SessionSummaryDisplayState = .loading
    /// The Notes generation ID a fresh Generate should use right now, or
    /// `nil` when no Notes generation is currently usable as a source.
    /// Independent of `displayState`'s `.loaded` case: an existing Summary
    /// generation can be `.loaded` (and fully classified against its own
    /// pinned source) while this is `nil`, if the current/default Notes
    /// generation is not itself usable — an existing Summary generation's
    /// own pinned source (inside `.loaded`'s `record`) is never substituted
    /// for this, and this value never substitutes for it either.
    @Published private(set) var currentUsableNotesGenerationID: UUID?

    init(
        summaryStore: any LectureSummaryStoring,
        summaryOperationStateStore: any LectureSummaryOperationStateStoring,
        notesStore: any LectureNotesStoring,
        summarySourceLoader: any LectureSummarySourceLoading
    ) {
        self.summaryStore = summaryStore
        self.summaryOperationStateStore = summaryOperationStateStore
        self.notesStore = notesStore
        self.summarySourceLoader = summarySourceLoader
    }

    func refresh(for entry: CompletedSessionEntry) async {
        generation += 1
        let myGeneration = generation
        let sessionID = entry.manifest.sessionID
        let sessionPaths = entry.sessionPaths

        func publish(_ state: SessionSummaryDisplayState, notesGenerationID: UUID?) {
            guard myGeneration == generation else { return }
            displayedSessionID = sessionID
            displayState = state
            currentUsableNotesGenerationID = notesGenerationID
        }

        let currentNotesGenerationID: UUID?
        do {
            currentNotesGenerationID = try SummaryNotesSourceSelection.currentUsableNotesGeneration(
                notesStore: notesStore,
                sessionPaths: sessionPaths,
                sessionID: sessionID
            )
        } catch {
            publish(.loadError(error.localizedDescription), notesGenerationID: nil)
            return
        }

        // Current-Notes selection and existing-Summary recovery are
        // independent questions — an unusable current Notes source never
        // hides an existing Summary generation, which is always classified
        // against its own pinned source regardless of what is currently
        // usable for a fresh Generate.
        let summaryGenerationIDs: [UUID]
        do {
            summaryGenerationIDs = try summaryStore.listGenerationIDs(sessionPaths: sessionPaths)
        } catch {
            publish(.loadError(error.localizedDescription), notesGenerationID: currentNotesGenerationID)
            return
        }

        guard !summaryGenerationIDs.isEmpty else {
            if let currentNotesGenerationID {
                publish(.noGeneration(notesGenerationID: currentNotesGenerationID), notesGenerationID: currentNotesGenerationID)
            } else {
                publish(.noValidNotesSource, notesGenerationID: nil)
            }
            return
        }

        // Fail closed: mirrors `SessionNotesPresenter.refresh(for:)` — an
        // unreadable candidate is never silently dropped before applying
        // the newest-`createdDate` selection policy below.
        var summaryRecords: [LectureSummaryGenerationRecord] = []
        for generationID in summaryGenerationIDs {
            let candidatePaths: SummaryArtifactPaths
            do {
                candidatePaths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
            } catch {
                publish(.loadError("Summary generation \(generationID.uuidString) could not be validated: \(error.localizedDescription)"), notesGenerationID: currentNotesGenerationID)
                return
            }
            do {
                guard let record = try summaryStore.loadGeneration(paths: candidatePaths) else {
                    publish(.loadError("Summary generation \(generationID.uuidString) is listed but has no generation record."), notesGenerationID: currentNotesGenerationID)
                    return
                }
                summaryRecords.append(record)
            } catch {
                publish(.loadError("Summary generation \(generationID.uuidString) could not be loaded: \(error.localizedDescription)"), notesGenerationID: currentNotesGenerationID)
                return
            }
        }

        guard let chosen = SessionSummaryGenerationSelection.chooseDefault(records: summaryRecords) else {
            // `summaryGenerationIDs` was proven non-empty above and every ID
            // loaded successfully in the loop above — unreachable in
            // practice; kept only as a defensive fallback, never as a
            // reordering policy of its own.
            publish(.loadError("Unable to determine the Summary generation to display for this session."), notesGenerationID: currentNotesGenerationID)
            return
        }

        let paths: SummaryArtifactPaths
        do {
            paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: chosen.generationID)
        } catch {
            publish(.loadError(error.localizedDescription), notesGenerationID: currentNotesGenerationID)
            return
        }

        let analysisResults: [SummaryArtifactLoadResult<LectureSummaryAnalysis>]
        do {
            analysisResults = try summaryStore.loadAllAnalyses(paths: paths)
        } catch {
            publish(.loadError(error.localizedDescription), notesGenerationID: currentNotesGenerationID)
            return
        }

        var analyses: [LectureSummaryAnalysis] = []
        for result in analysisResults {
            switch result {
            case .success(_, let value):
                analyses.append(value)
            case .failure(let batchIndex, let underlying):
                // Mirrors `LectureSummaryGenerationService`'s own handling
                // of this exact case: a corrupt committed analysis is
                // reported as damaged, never silently dropped from
                // coverage.
                publish(.loaded(
                    record: chosen,
                    classification: .damaged(reason: .corruptOrInvalidAnalysis(batchIndex: batchIndex, underlying: underlying)),
                    advisoryStateIntegrity: .normal
                ), notesGenerationID: currentNotesGenerationID)
                return
            }
        }

        let document: LectureSummaryDocument?
        do {
            document = try summaryStore.loadDocument(paths: paths)
        } catch {
            publish(.loadError(error.localizedDescription), notesGenerationID: currentNotesGenerationID)
            return
        }

        // Advisory-only (see `SummaryGenerationOperationState`'s own header
        // comment): a problem here must never be treated as equivalent to a
        // canonical read failure, and must never suppress an otherwise-valid
        // canonical classification (`.completed` in particular never
        // consults operation state at all).
        let operationStateForClassification: SummaryGenerationOperationState?
        let advisoryStateIntegrity: SummaryAdvisoryStateIntegrity
        do {
            if let loadedOperationState = try summaryOperationStateStore.loadOperationState(paths: paths) {
                if loadedOperationState.sourceNotesGenerationID == chosen.sourceNotesGenerationID
                    && loadedOperationState.transcriptFingerprint == chosen.transcriptFingerprint
                    && loadedOperationState.sourceNotesDocumentFingerprint == chosen.sourceNotesDocumentFingerprint {
                    operationStateForClassification = loadedOperationState
                    advisoryStateIntegrity = .normal
                } else {
                    operationStateForClassification = nil
                    advisoryStateIntegrity = .problem(reason: "recovery metadata for this generation does not match its source")
                }
            } else {
                operationStateForClassification = nil
                advisoryStateIntegrity = .normal
            }
        } catch {
            operationStateForClassification = nil
            advisoryStateIntegrity = .problem(reason: "recovery metadata could not be read: \(error.localizedDescription)")
        }

        // `chosen`'s own pinned `sourceNotesGenerationID` — never
        // `currentNotesGenerationID` — is what its recovery classification
        // must be evaluated against. A genuine identity/staleness
        // disagreement is exactly what `SummaryGenerationRecoveryClassifier`
        // itself detects, once given this generation's own real, current
        // source snapshot.
        let source: LectureSummarySourceSnapshot
        do {
            source = try await summarySourceLoader.loadSourceSnapshot(
                sessionID: sessionID,
                notesGenerationID: chosen.sourceNotesGenerationID
            )
        } catch {
            switch SummarySourceLoadFailureClassification.classify(error) {
            case .sourceInvalid:
                // The pinned Notes generation this Summary generation was
                // built from is no longer a valid/current source — exactly
                // `.staleSource`, never a generic load failure.
                publish(
                    .loaded(record: chosen, classification: .staleSource, advisoryStateIntegrity: advisoryStateIntegrity),
                    notesGenerationID: currentNotesGenerationID
                )
            case .operational(let description):
                publish(.loadError(description), notesGenerationID: currentNotesGenerationID)
            }
            return
        }

        let classification = SummaryGenerationRecoveryClassifier.classify(
            generation: chosen,
            source: source,
            analyses: analyses,
            document: document,
            operationState: operationStateForClassification
        )
        publish(
            .loaded(record: chosen, classification: classification, advisoryStateIntegrity: advisoryStateIntegrity),
            notesGenerationID: currentNotesGenerationID
        )
    }
}
