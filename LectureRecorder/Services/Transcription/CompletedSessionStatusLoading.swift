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
}

extension CompletedSessionTranscriptionService: CompletedSessionStatusLoading {}
