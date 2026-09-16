import Foundation

/// Production `NotesTranscriptSourceLoading`. Reuses transcription's own
/// established completed-session loading path end to end
/// (`SessionTranscriptionEligibility.validate`, `SessionArtifactPreflight`,
/// `TranscriptionStoring`) rather than reimplementing any of its path
/// safety, identity, or coverage checks — see T5-B contract §3. Never
/// creates, enqueues, retries, or otherwise mutates any transcription
/// artifact; a symlinked or wrong-type ancestor is rejected before it is
/// ever read, exactly mirroring
/// `CompletedSessionTranscriptionService.run`'s own ordering.
nonisolated struct NotesTranscriptSourceLoader: NotesTranscriptSourceLoading {
    private let transcriptionStore: any TranscriptionStoring
    private let sessionsRootResolver: @Sendable () throws -> URL

    init(
        transcriptionStore: any TranscriptionStoring,
        sessionsRootResolver: @escaping @Sendable () throws -> URL = {
            try DefaultFileSystemLocator.resolveSessionsRootPathWithoutCreating()
        }
    ) {
        self.transcriptionStore = transcriptionStore
        self.sessionsRootResolver = sessionsRootResolver
    }

    func loadCurrentSnapshot(sessionID: UUID) async throws -> NotesTranscriptSourceSnapshot {
        let root: URL
        do {
            root = try sessionsRootResolver()
        } catch {
            throw NotesTranscriptSourceLoadError.sessionsRootUnavailable(error.localizedDescription)
        }

        guard CompletedSessionPathSafety.checkExistingDirectory(root) == .safe else {
            throw NotesTranscriptSourceLoadError.unsafeSessionsRoot
        }

        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)

        guard CompletedSessionPathSafety.checkExistingDirectory(sessionPaths.sessionDirectory) == .safe else {
            throw NotesTranscriptSourceLoadError.unsafeSessionDirectory
        }

        guard CompletedSessionPathSafety.checkExistingRegularFile(sessionPaths.manifestURL) == .safe else {
            throw NotesTranscriptSourceLoadError.unsafeManifest
        }

        let manifest: SessionManifest
        do {
            manifest = try AtomicFileWriter.readJSON(SessionManifest.self, from: sessionPaths.manifestURL)
        } catch {
            throw NotesTranscriptSourceLoadError.manifestUndecodable(error.localizedDescription)
        }

        let validated: ValidatedCompletedSession
        do {
            validated = try SessionTranscriptionEligibility.validate(
                expectedSessionID: sessionID,
                manifest: manifest,
                sessionPaths: sessionPaths
            )
        } catch {
            throw NotesTranscriptSourceLoadError.ineligible(error.localizedDescription)
        }

        let preflightReport = await SessionArtifactPreflight.run(
            manifest: validated.manifest,
            sessionPaths: validated.sessionPaths,
            artifactPaths: validated.artifactPaths,
            store: transcriptionStore
        )
        guard preflightReport.blockingReasons.isEmpty else {
            throw NotesTranscriptSourceLoadError.preflightBlocked(reasons: preflightReport.blockingReasons)
        }

        do {
            return try NotesTranscriptSourceBuilder.build(
                manifest: validated.manifest,
                jobs: Array(preflightReport.jobsBySequence.values),
                results: Array(preflightReport.resultsBySequence.values)
            )
        } catch {
            throw NotesTranscriptSourceLoadError.sourceBuildFailed(error.localizedDescription)
        }
    }
}
