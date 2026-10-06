import Foundation

/// The read-only status/transcript surface `SessionTranscriptPresenter`
/// depends on — lets tests substitute a controllable fake loader instead of
/// the real `CompletedSessionTranscriptionService`, to make stale-load
/// protection deterministically testable without touching real storage or
/// the transcription pipeline.
@MainActor
protocol CompletedSessionStatusLoading: AnyObject {
    func peekStatus(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> SessionTranscriptionStatus
    func peekOrderedSegments(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> [OrderedSegment]?
    func peekFailureOverview(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> TranscriptionFailureOverview?
}

extension CompletedSessionStatusLoading {
    /// A loader with no failed-part view reports none, which leaves action
    /// availability exactly as the status alone decides it.
    func peekFailureOverview(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> TranscriptionFailureOverview? {
        nil
    }
}

extension CompletedSessionTranscriptionService: CompletedSessionStatusLoading {}
