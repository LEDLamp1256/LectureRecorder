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
/// For a completed transcript it also asks the optional, equally read-only
/// `CompletedTranscriptNavigationLoading` for playback navigation targets,
/// published together with the status and segments.
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
    private let navigationLoader: (any CompletedTranscriptNavigationLoading)?
    private var generation = 0

    @Published private(set) var displayedSessionID: UUID?
    @Published private(set) var status: SessionTranscriptionStatus?
    @Published private(set) var segments: [OrderedSegment] = []
    /// Non-`nil` only for a completed transcript whose navigation loaded.
    @Published private(set) var navigation: TranscriptPlaybackNavigation?

    init(
        loader: any CompletedSessionStatusLoading,
        navigationLoader: (any CompletedTranscriptNavigationLoading)? = nil
    ) {
        self.loader = loader
        self.navigationLoader = navigationLoader
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
        var loadedNavigation: TranscriptPlaybackNavigation?
        if case .completed = loadedStatus {
            let fetchedSegments = await loader.peekOrderedSegments(
                sessionID: sessionID,
                manifest: entry.manifest,
                sessionPaths: entry.sessionPaths
            )
            guard myGeneration == generation else { return }
            loadedSegments = fetchedSegments ?? []

            if let navigationLoader, !loadedSegments.isEmpty {
                let fetchedNavigation = await navigationLoader.loadNavigation(
                    sessionID: sessionID,
                    manifest: entry.manifest,
                    sessionPaths: entry.sessionPaths
                )
                guard myGeneration == generation else { return }
                loadedNavigation = fetchedNavigation?.sessionID == sessionID ? fetchedNavigation : nil
            }
        }

        displayedSessionID = sessionID
        status = loadedStatus
        segments = loadedSegments
        navigation = loadedNavigation
    }
}
