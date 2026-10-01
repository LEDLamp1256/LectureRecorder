import Combine
import Foundation

/// One window's read-only Notes presentation coordinator for the currently
/// selected completed session — the Notes-domain analog of
/// `SessionTranscriptPresenter`. Reconstructs `SessionNotesDisplayState`
/// through `SessionNotesStateLoader`, entirely from already-persisted durable
/// artifacts via
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
/// changes can never overwrite a newer selection's result. The counter is
/// shared by `refresh(for:)` and `refresh(for:generationID:)`, so a newer
/// request of either kind supersedes any older one.
@MainActor
final class SessionNotesPresenter: ObservableObject {
    private let stateLoader: SessionNotesStateLoader
    private var generation = 0

    @Published private(set) var displayedSessionID: UUID?
    @Published private(set) var displayState: SessionNotesDisplayState = .loading

    init(
        notesStore: any LectureNotesStoring,
        operationStateStore: any LectureNotesOperationStateStoring,
        sourceLoader: any NotesTranscriptSourceLoading
    ) {
        self.stateLoader = SessionNotesStateLoader(
            notesStore: notesStore,
            operationStateStore: operationStateStore,
            sourceLoader: sourceLoader
        )
    }

    func refresh(for entry: CompletedSessionEntry) async {
        generation += 1
        let myGeneration = generation
        let sessionID = entry.manifest.sessionID
        let state = await stateLoader.loadDefaultState(sessionID: sessionID, sessionPaths: entry.sessionPaths)
        publish(state, sessionID: sessionID, ifCurrent: myGeneration)
    }

    /// Displays exactly the Notes generation `generationID` — for navigation
    /// that must show the generation a Summary was derived from, even when a
    /// newer one exists. Never falls back to another generation: a missing,
    /// unreadable, or mismatched record publishes `.loadError`. Once the
    /// record loads, classification is identical to `refresh(for:)`.
    func refresh(for entry: CompletedSessionEntry, generationID: UUID) async {
        generation += 1
        let myGeneration = generation
        let sessionID = entry.manifest.sessionID
        let state = await stateLoader.loadState(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: generationID)
        publish(state, sessionID: sessionID, ifCurrent: myGeneration)
    }

    private func publish(_ state: SessionNotesDisplayState, sessionID: UUID, ifCurrent myGeneration: Int) {
        guard myGeneration == generation else { return }
        displayedSessionID = sessionID
        displayState = state
    }
}
