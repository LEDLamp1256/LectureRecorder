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
    let lectureSummaryGenerationService: LectureSummaryGenerationService
    /// The same read-only Summary durable-state collaborators wired into
    /// `lectureSummaryGenerationService` above, exposed separately for the
    /// same reason `notesStore`/`notesOperationStateStore` are: a future
    /// Summary presenter can perform its own read-only durable-state
    /// reconstruction without the generation service needing to expose its
    /// private stores.
    let summaryStore: LectureSummaryStore
    let summaryOperationStateStore: LectureSummaryOperationStateStore
    /// The same source-loading collaborator wired into
    /// `lectureSummaryGenerationService` above, exposed separately so
    /// `SessionSummaryPresenter` can obtain a real, current
    /// `LectureSummarySourceSnapshot` for an existing Summary generation's
    /// own pinned source identity (see `SummaryGenerationRecoveryClassifier`)
    /// without the generation service needing to expose its private
    /// dependency. Sharing this exact instance — rather than constructing a
    /// second one elsewhere — keeps exactly one production source-loading
    /// configuration in play.
    let summarySourceLoader: LectureSummarySourceLoader

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

        // Legacy backend, retained only for Continue/Retry of pre-existing
        // OpenAI generations (and possible future explicit opt-in) — no
        // longer the default for brand-new generations. Constructing it
        // never reads OPENAI_API_KEY; that is resolved lazily per explicitly
        // admitted operation, same as before.
        let openAINotesConfiguration = OpenAINotesConfigurationSource.processEnvironment()
        let openAINotesGenerator = OpenAILectureNotesGenerator(
            configurationSource: openAINotesConfiguration,
            transport: URLSessionNotesHTTPTransport()
        )
        // Local, $0 default backend for every brand-new generation. All
        // real FoundationModels/LanguageModelSession calls stay inside
        // `RealFoundationModelsSessionDriver`.
        let appleNotesGenerator = FoundationModelsLectureNotesGenerator()
        let notesGeneratorRouter = LectureNotesGeneratorRouter(
            appleGenerator: appleNotesGenerator,
            openAIGenerator: openAINotesGenerator
        )
        // Apple's on-device session context is far smaller than OpenAI's —
        // this budget only ever governs planning a *brand-new* generation;
        // already-persisted generations (OpenAI or Apple) keep their own
        // frozen `NotesWindowPlan` regardless of this value.
        let notesWindowBudget = FoundationModelsNotesConfiguration.windowBudget
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
            generator: notesGeneratorRouter,
            newGenerationAvailabilityChecker: notesGeneratorRouter,
            windowBudget: notesWindowBudget,
            generationProvenance: FoundationModelsNotesConfiguration.generationProvenance
        )

        // T5-F3A: Summary orchestration. Deliberately its own independent
        // admission slot and generator — never routed through, or gated by,
        // `lectureNotesGenerationService` above (see
        // `LectureSummaryGenerationService`'s own header comment). Apple
        // Foundation Models is the only Summary backend F1/F2 defines; there
        // is no OpenAI equivalent to route between here.
        let summaryStore = LectureSummaryStore()
        let summaryOperationStateStore = LectureSummaryOperationStateStore()
        let summarySourceLoader = LectureSummarySourceLoader(
            notesStore: notesStore,
            transcriptLoader: notesTranscriptSourceLoader
        )
        let summaryGenerator = FoundationModelsLectureSummaryGenerator()
        self.summaryStore = summaryStore
        self.summaryOperationStateStore = summaryOperationStateStore
        self.summarySourceLoader = summarySourceLoader
        self.lectureSummaryGenerationService = LectureSummaryGenerationService(
            sourceLoader: summarySourceLoader,
            summaryStore: summaryStore,
            operationStateStore: summaryOperationStateStore,
            generator: summaryGenerator,
            newGenerationAvailabilityChecker: summaryGenerator,
            generationProvenance: FoundationModelsSummaryConfiguration.generationProvenance
        )
    }
}
