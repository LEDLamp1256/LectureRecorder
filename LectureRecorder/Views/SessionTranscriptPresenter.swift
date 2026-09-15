import Combine
import Foundation

/// One window's presentation state for the currently-selected completed
/// session: the last successfully-loaded status/transcript, guarded against
/// a stale (superseded-by-a-later-selection) load ever overwriting a newer
/// one.
///
/// This is a thin presentation helper, not a second operation owner: it
/// never touches `TranscriptionCoordinator`, never enqueues/retries/
/// transcribes anything itself, and owns no persistent background `Task` —
/// it only calls the injected, already-read-only `CompletedSessionStatusLoading`
/// (in production, the single shared `CompletedSessionTranscriptionService`)
/// and remembers the result. Transcribe/Continue/Retry/Cancel remain calls
/// straight through to that same shared service, made directly by the view.
///
/// Stale-load protection does **not** rely solely on SwiftUI cancelling a
/// superseded `.task(id:)` — `generation` is an explicit, deterministic
/// guard: `refresh(for:)` increments it up front, and every subsequent
/// publication point re-checks it before writing, so a load that was
/// already in flight when the selection changed can never overwrite the
/// newer selection's result, regardless of whether the underlying `Task`
/// was actually cancelled in time.
@MainActor
final class SessionTranscriptPresenter: ObservableObject {
    private let loader: any CompletedSessionStatusLoading
    private var generation = 0

    @Published private(set) var displayedSessionID: UUID?
    @Published private(set) var status: SessionTranscriptionStatus?
    @Published private(set) var segments: [OrderedSegment] = []

    init(loader: any CompletedSessionStatusLoading) {
        self.loader = loader
    }

    func refresh(for entry: CompletedSessionEntry) async {
        generation += 1
        let myGeneration = generation
        let sessionID = entry.manifest.sessionID

        let loadedStatus = await loader.peekStatus(
            sessionID: sessionID,
            manifest: entry.manifest,
            sessionPaths: entry.sessionPaths
        )
        guard myGeneration == generation else { return }

        var loadedSegments: [OrderedSegment] = []
        if case .completed = loadedStatus {
            let fetchedSegments = await loader.peekOrderedSegments(
                sessionID: sessionID,
                manifest: entry.manifest,
                sessionPaths: entry.sessionPaths
            )
            guard myGeneration == generation else { return }
            loadedSegments = fetchedSegments ?? []
        }

        displayedSessionID = sessionID
        status = loadedStatus
        segments = loadedSegments
    }
}
