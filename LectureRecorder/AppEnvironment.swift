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
    let lectureNotesGenerationService: LectureNotesGenerationService

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

        let transcriptionStore = TranscriptionStore()
        self.completedSessionCatalog = CompletedSessionCatalog()
        self.completedSessionTranscriptionService = CompletedSessionTranscriptionService(
            sessionManager: sessionManager,
            transcriptionStore: transcriptionStore,
            transcriber: WhisperProcessTranscriber()
        )

        let notesConfiguration = OpenAINotesConfigurationSource.processEnvironment()
        let notesGenerator = OpenAILectureNotesGenerator(
            configurationSource: notesConfiguration,
            transport: URLSessionNotesHTTPTransport()
        )
        // Deterministic, conservative grouping: at most ~48 KB of transcript
        // text or 24 canonical chunks (roughly 12 minutes) per provider call.
        // The orchestration service persists this exact plan per generation.
        let notesWindowBudget = try! NotesWindowBudget(
            maxUTF8BytesPerWindow: 48_000,
            maxUnitsPerWindow: 24
        )
        self.lectureNotesGenerationService = LectureNotesGenerationService(
            sourceLoader: NotesTranscriptSourceLoader(transcriptionStore: transcriptionStore),
            notesStore: LectureNotesStore(),
            operationStateStore: LectureNotesOperationStateStore(),
            generator: notesGenerator,
            windowBudget: notesWindowBudget,
            generationProvenance: notesConfiguration.generationProvenance
        )
    }
}
