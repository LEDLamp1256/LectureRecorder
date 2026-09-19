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
        // `RealFoundationModelsSessionDriver`. `diagnosticRecorder` below is
        // purely additive (see the type's own doc comment) — it only
        // forwards already-computed preflight metadata into
        // `AcceptanceDiagnosticLogger`. Supplied only when acceptance
        // diagnostics are actually enabled, so a normal disabled run never
        // even constructs a diagnostic-event value or invokes a callback
        // merely to reach a no-op logger.
        let notesDiagnosticRecorder: (@Sendable (FoundationModelsNotesDiagnosticEvent) -> Void)?
        if AcceptanceDiagnosticLogger.isEnabled {
            notesDiagnosticRecorder = { (event: FoundationModelsNotesDiagnosticEvent) in
                AcceptanceDiagnosticLogger.shared.log(
                    AcceptanceDiagnosticEvent.Notes.preflight,
                    metadata: [
                        "stage": .string(event.stage.description),
                        "estimatedInputTokens": .int(event.estimatedInputTokens),
                        "tokenCountAvailable": .bool(event.estimatedInputTokens != nil),
                        "responseReserve": .int(event.responseReserve),
                        "contextLimit": .int(event.contextLimit),
                        "fitDirectly": .bool(event.fitDirectly),
                        "frameworkOverflow": .bool(event.frameworkOverflow)
                    ]
                )
            }
        } else {
            notesDiagnosticRecorder = nil
        }
        let appleNotesGenerator = FoundationModelsLectureNotesGenerator(
            diagnosticRecorder: notesDiagnosticRecorder
        )
        // MLX-1: local Qwen3-8B-4bit backend, the new default for every
        // brand-new Notes generation. `RealMLXSessionDriver` owns model
        // verification/loading, tokenizer access, and grammar-constrained
        // generation; constructing it here never loads the (multi-GB) model
        // — that happens lazily on first real request, gated by
        // `MLXModelVerifier`.
        let mlxNotesGenerator = MLXLectureNotesGenerator()
        let notesGeneratorRouter = LectureNotesGeneratorRouter(
            appleGenerator: appleNotesGenerator,
            openAIGenerator: openAINotesGenerator,
            mlxGenerator: mlxNotesGenerator
        )
        // MLX's operational context ceiling is far larger than Apple's
        // on-device ~4,096 — this budget only ever governs planning a
        // *brand-new* generation; already-persisted generations (OpenAI,
        // Apple, or MLX) keep their own frozen `NotesWindowPlan` regardless
        // of this value.
        let notesWindowBudget = MLXNotesConfiguration.windowBudget
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
        // Both recorder closures below are purely additive, mirroring
        // `notesDiagnosticRecorder` above — and, likewise, supplied only
        // when acceptance diagnostics are actually enabled.
        let summaryDiagnosticRecorder: (@Sendable (FoundationModelsSummaryDiagnosticEvent) -> Void)?
        if AcceptanceDiagnosticLogger.isEnabled {
            summaryDiagnosticRecorder = { (event: FoundationModelsSummaryDiagnosticEvent) in
                AcceptanceDiagnosticLogger.shared.log(
                    AcceptanceDiagnosticEvent.Summary.generatedOutputAttemptFailed,
                    metadata: [
                        "stage": .string(event.stage.rawValue),
                        "attempt": .int(event.attempt),
                        // Case name only — never `errorDescription`, which
                        // can carry framework-provided free-text payloads
                        // this diagnostic facility must never assume are
                        // lecture-content-free.
                        "errorCategory": .string(event.error.diagnosticCategory),
                        "willRetry": .bool(event.willRetry)
                    ]
                )
            }
        } else {
            summaryDiagnosticRecorder = nil
        }
        let summaryPreflightRecorder: (@Sendable (FoundationModelsSummaryPreflightEvent) -> Void)?
        if AcceptanceDiagnosticLogger.isEnabled {
            summaryPreflightRecorder = { (event: FoundationModelsSummaryPreflightEvent) in
                AcceptanceDiagnosticLogger.shared.log(
                    AcceptanceDiagnosticEvent.Summary.preflight,
                    metadata: [
                        "stage": .string(event.stage.rawValue),
                        "estimatedInputTokens": .int(event.estimatedInputTokens),
                        "tokenCountAvailable": .bool(event.estimatedInputTokens != nil),
                        "responseReserve": .int(event.responseReserve),
                        "contextLimit": .int(event.contextLimit),
                        "fitsDirectly": .bool(event.fitsDirectly)
                    ]
                )
            }
        } else {
            summaryPreflightRecorder = nil
        }
        let summarySynthesisRecorder: (@Sendable (FoundationModelsSummarySynthesisEvent) -> Void)?
        if AcceptanceDiagnosticLogger.isEnabled {
            summarySynthesisRecorder = { (event: FoundationModelsSummarySynthesisEvent) in
                let baseMetadata: [String: AcceptanceDiagnosticValue] = [
                    "sessionID": .uuid(event.sessionID),
                    "generationID": .uuid(event.generationID)
                ]
                switch event.boundary {
                case .reductionGroupStarted(let level, let groupIndex, let totalGroups, let inputCarrierCount):
                    AcceptanceDiagnosticLogger.shared.log(
                        AcceptanceDiagnosticEvent.Summary.reductionGroupStarted,
                        metadata: baseMetadata.merging([
                            "level": .int(level), "groupIndex": .int(groupIndex),
                            "totalGroups": .int(totalGroups), "inputCarrierCount": .int(inputCarrierCount)
                        ]) { _, new in new }
                    )
                case .reductionGroupCompleted(let level, let groupIndex, let outputCarrierCount):
                    AcceptanceDiagnosticLogger.shared.log(
                        AcceptanceDiagnosticEvent.Summary.reductionGroupCompleted,
                        metadata: baseMetadata.merging([
                            "level": .int(level), "groupIndex": .int(groupIndex),
                            "outputCarrierCount": .int(outputCarrierCount)
                        ]) { _, new in new },
                        elapsedSeconds: event.elapsedSeconds
                    )
                case .finalStructureStarted(let inputCarrierCount):
                    AcceptanceDiagnosticLogger.shared.log(
                        AcceptanceDiagnosticEvent.Summary.finalStructureStarted,
                        metadata: baseMetadata.merging([
                            "inputCarrierCount": .int(inputCarrierCount)
                        ]) { _, new in new }
                    )
                case .finalStructureCompleted(let sectionCount):
                    AcceptanceDiagnosticLogger.shared.log(
                        AcceptanceDiagnosticEvent.Summary.finalStructureCompleted,
                        metadata: baseMetadata.merging([
                            "sectionCount": .int(sectionCount)
                        ]) { _, new in new },
                        elapsedSeconds: event.elapsedSeconds
                    )
                case .finalSectionStarted(let sectionIndex, let totalSections, let inputCarrierCount):
                    AcceptanceDiagnosticLogger.shared.log(
                        AcceptanceDiagnosticEvent.Summary.finalSectionStarted,
                        metadata: baseMetadata.merging([
                            "sectionIndex": .int(sectionIndex), "totalSections": .int(totalSections),
                            "inputCarrierCount": .int(inputCarrierCount)
                        ]) { _, new in new }
                    )
                case .finalSectionCompleted(let sectionIndex, let passageCount):
                    AcceptanceDiagnosticLogger.shared.log(
                        AcceptanceDiagnosticEvent.Summary.finalSectionCompleted,
                        metadata: baseMetadata.merging([
                            "sectionIndex": .int(sectionIndex), "passageCount": .int(passageCount)
                        ]) { _, new in new },
                        elapsedSeconds: event.elapsedSeconds
                    )
                }
            }
        } else {
            summarySynthesisRecorder = nil
        }
        let summaryGenerator = FoundationModelsLectureSummaryGenerator(
            diagnosticRecorder: summaryDiagnosticRecorder,
            preflightRecorder: summaryPreflightRecorder,
            synthesisRecorder: summarySynthesisRecorder
        )
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
