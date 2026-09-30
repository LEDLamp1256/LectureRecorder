import Foundation

/// Read-only source of a completed session's transcript navigation
/// (`TranscriptPlaybackNavigation`) — lets `SessionTranscriptPresenter`
/// tests substitute a fake instead of real storage.
nonisolated protocol CompletedTranscriptNavigationLoading: Sendable {
    /// The navigation for a genuinely `.completed` transcript, or `nil` for
    /// any session that is not (ineligible, preflight-blocked, incomplete,
    /// or not placeable on a playback timeline).
    func loadNavigation(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> TranscriptPlaybackNavigation?
}

/// Production `CompletedTranscriptNavigationLoading`. Follows exactly the
/// read path `CompletedSessionTranscriptionService.peekOrderedSegments`
/// uses — `SessionTranscriptionEligibility.validate`, then
/// `SessionArtifactPreflight`, then
/// `SessionTranscriptionClassifier.isCompletionValid` — so a transcript is
/// navigable only when that path would display it as completed. It then
/// hands the canonical results' stored timing to
/// `TranscriptPlaybackNavigationBuilder`.
///
/// Never reconciles, enqueues, invokes a transcriber, or writes anything,
/// and needs no Whisper worker or model.
nonisolated struct CompletedTranscriptNavigationLoader: CompletedTranscriptNavigationLoading {
    private let transcriptionStore: any TranscriptionStoring

    init(transcriptionStore: any TranscriptionStoring) {
        self.transcriptionStore = transcriptionStore
    }

    func loadNavigation(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> TranscriptPlaybackNavigation? {
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
            store: transcriptionStore
        )
        guard report.blockingReasons.isEmpty else { return nil }

        let jobs = Array(report.jobsBySequence.values)
        let results = Array(report.resultsBySequence.values)
        guard SessionTranscriptionClassifier.isCompletionValid(manifest: validated.manifest, jobs: jobs, results: results),
              let timeline = try? LecturePlaybackTimeline(manifest: validated.manifest) else {
            return nil
        }

        return TranscriptPlaybackNavigationBuilder.build(timeline: timeline, results: results)
    }
}
