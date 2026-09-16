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
    /// The same read-only Notes durable-state collaborators wired into
    /// `lectureNotesGenerationService` above, exposed separately so
    /// `SessionNotesPresenter` can perform its own read-only durable-state
    /// reconstruction (T5-D) without the generation service needing to
    /// expose its private stores. All three are stateless filesystem
    /// wrappers, so sharing these exact instances is equivalent to
    /// constructing fresh ones — this just avoids the redundant construction.
    let notesStore: LectureNotesStore
    let notesOperationStateStore: LectureNotesOperationStateStore
    let notesTranscriptSourceLoader: NotesTranscriptSourceLoader

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
        let notesStore = LectureNotesStore()
        let notesOperationStateStore = LectureNotesOperationStateStore()
        let notesTranscriptSourceLoader = NotesTranscriptSourceLoader(transcriptionStore: transcriptionStore)
        self.notesStore = notesStore
        self.notesOperationStateStore = notesOperationStateStore
        self.notesTranscriptSourceLoader = notesTranscriptSourceLoader

        self.lectureNotesGenerationService = LectureNotesGenerationService(
            sourceLoader: notesTranscriptSourceLoader,
            notesStore: notesStore,
            operationStateStore: notesOperationStateStore,
            generator: notesGenerator,
            windowBudget: notesWindowBudget,
            generationProvenance: notesConfiguration.generationProvenance
        )
    }
}
