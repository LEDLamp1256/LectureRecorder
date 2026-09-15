import Combine

/// Composition root for the app's dependency graph. Keeps object
/// construction in one place so future phases have a single, obvious spot
/// to wire in new dependencies.
///
/// `sessionManager` remains entirely independent of transcription:
/// `completedSessionTranscriptionService` never touches it except to read
/// its already-public `state` for admission (see
/// `CompletedSessionTranscriptionService.beginOperation`), and recording
/// Start/Stop never waits on transcription in any way.
///
/// Constructing `WhisperProcessTranscriber()` here is cheap and lazy — it
/// does not launch a worker process or load the model; that only happens
/// the first time an actual transcription attempt runs. Nothing here
/// initializes Whisper merely because the app launched.
@MainActor
final class AppEnvironment: ObservableObject {
    let sessionManager: SessionManager
    let completedSessionCatalog: CompletedSessionCatalog
    let completedSessionTranscriptionService: CompletedSessionTranscriptionService

    init() {
        let store = SessionStore()
        let permissionService = MicrophonePermissionService()
        let captureService = AudioCaptureService()
        let chunkWriterFactory = DefaultAudioChunkWriterFactory()
        let sessionManager = SessionManager(
            store: store,
            permissionService: permissionService,
            captureService: captureService,
            chunkWriterFactory: chunkWriterFactory
        )
        self.sessionManager = sessionManager

        self.completedSessionCatalog = CompletedSessionCatalog()
        self.completedSessionTranscriptionService = CompletedSessionTranscriptionService(
            sessionManager: sessionManager,
            transcriptionStore: TranscriptionStore(),
            transcriber: WhisperProcessTranscriber()
        )
    }
}
