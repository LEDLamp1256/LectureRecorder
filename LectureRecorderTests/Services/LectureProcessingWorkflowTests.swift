import AVFoundation
import Combine
import XCTest
@testable import LectureRecorder

/// Holds every transcription call until `open()` — event-driven, so a test
/// can await `waitUntilEntered()` instead of polling. With
/// `honorsCancellation == false` the call ignores task cancellation and
/// returns a normal successful result once opened, which lets a test make
/// an operation the workflow already cancelled still release with a
/// durably *completed* transcript.
private actor GatedTranscriber: Transcribing {
    private let honorsCancellation: Bool
    private var isOpen = false
    private var hasEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    init(honorsCancellation: Bool) {
        self.honorsCancellation = honorsCancellation
    }

    func open() {
        isOpen = true
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
        callCount += 1
        hasEntered = true
        let waiters = enteredWaiters
        enteredWaiters = []
        waiters.forEach { $0.resume() }
        while !isOpen {
            if honorsCancellation { try Task.checkCancellation() }
            await Task.yield()
        }
        return FakeTranscriber.defaultFakeOutput
    }
}

private final class MutableAvailabilityChecker: NewLectureNotesGenerationAvailabilityChecking, @unchecked Sendable {
    var result: LectureNotesGenerationAvailability = .available
    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability { result }
}

/// Serves the real durable snapshot until `switchToChangedSource()`, then a
/// snapshot whose text (and therefore fingerprint) differs — models the
/// transcript source moving on mid-generation without touching files.
private final class SwitchableSourceLoader: NotesTranscriptSourceLoading, @unchecked Sendable {
    private let wrapped: any NotesTranscriptSourceLoading
    private let lock = NSLock()
    private var changed = false

    init(wrapped: any NotesTranscriptSourceLoading) {
        self.wrapped = wrapped
    }

    func switchToChangedSource() {
        lock.lock(); defer { lock.unlock() }
        changed = true
    }

    func loadCurrentSnapshot(sessionID: UUID) async throws -> NotesTranscriptSourceSnapshot {
        var snapshot = try await wrapped.loadCurrentSnapshot(sessionID: sessionID)
        lock.lock()
        let isChanged = changed
        lock.unlock()
        guard isChanged else { return snapshot }
        snapshot.units[0].text += " (revised)"
        snapshot.fingerprint = TranscriptSourceFingerprint.compute(sessionID: snapshot.sessionID, units: snapshot.units)
        return snapshot
    }
}

/// One ordered log of workflow states and service releases, so tests can
/// assert the exact cross-object ordering.
@MainActor
private final class WorkflowEventLog {
    enum Event: Equatable {
        case state(LectureProcessingWorkflow.State)
        case transcriptionReleased(generation: Int)
        case notesReleased(epoch: Int)
    }

    private(set) var events: [Event] = []
    private var cancellables: [AnyCancellable] = []

    init(workflow: LectureProcessingWorkflow, transcription: CompletedSessionTranscriptionService, notes: LectureNotesGenerationService) {
        cancellables.append(workflow.$state.sink { [weak self] in self?.events.append(.state($0)) })
        cancellables.append(transcription.$lastReleasedOperation.dropFirst().sink { [weak self] release in
            guard let release else { return }
            self?.events.append(.transcriptionReleased(generation: release.generation))
        })
        cancellables.append(notes.$lastReleasedOperation.dropFirst().sink { [weak self] release in
            guard let release else { return }
            self?.events.append(.notesReleased(epoch: release.operationEpoch))
        })
    }

    var states: [LectureProcessingWorkflow.State] {
        events.compactMap { if case .state(let state) = $0 { return state } else { return nil } }
    }
}

private extension LectureProcessingWorkflow.State {
    var isTerminal: Bool {
        switch self {
        case .finished, .stopped: return true
        case .idle, .transcribing, .generatingNotes: return false
        }
    }
}

@MainActor
final class LectureProcessingWorkflowTests: XCTestCase {
    private typealias Workflow = LectureProcessingWorkflow

    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!
    private var transcriptionStore: TranscriptionStore!
    private var notesStore: LectureNotesStore!
    private var operationStateStore: LectureNotesOperationStateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectureProcessingWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        sessionID = UUID()
        sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        transcriptionStore = TranscriptionStore()
        notesStore = LectureNotesStore()
        operationStateStore = LectureNotesOperationStateStore()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private struct Harness {
        let manager: SessionManager
        let transcription: CompletedSessionTranscriptionService
        let notes: LectureNotesGenerationService
        let generator: ControllableFakeLectureNotesGenerator
        let workflow: LectureProcessingWorkflow
        let log: WorkflowEventLog
    }

    private func makeHarness(
        transcriber: any Transcribing = FakeTranscriber(),
        transcriptionStore overrideTranscriptionStore: (any TranscriptionStoring)? = nil,
        generator: ControllableFakeLectureNotesGenerator = ControllableFakeLectureNotesGenerator(),
        availability: any NewLectureNotesGenerationAvailabilityChecking = AlwaysAvailableNewGenerationChecker(),
        sourceLoader overrideSourceLoader: (any NotesTranscriptSourceLoading)? = nil
    ) throws -> Harness {
        let root = tempDirectory!
        let manager = SessionManager(
            store: SessionStore(locator: TestLocator(root: root)),
            permissionService: MockMicrophonePermissionService(status: .granted),
            captureService: MockAudioCaptureService(
                formatToPrepare: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
            ),
            chunkWriterFactory: DefaultAudioChunkWriterFactory()
        )
        let transcription = CompletedSessionTranscriptionService(
            sessionManager: manager,
            transcriptionStore: overrideTranscriptionStore ?? transcriptionStore,
            transcriber: transcriber,
            sessionsRootResolver: { root }
        )
        let sourceLoader = overrideSourceLoader ?? makeRealSourceLoader()
        let notes = LectureNotesGenerationService(
            sourceLoader: sourceLoader,
            notesStore: notesStore,
            operationStateStore: operationStateStore,
            generator: generator,
            newGenerationAvailabilityChecker: availability,
            windowBudget: try oneUnitPerWindowBudget(),
            sessionsRootResolver: { root }
        )
        let workflow = LectureProcessingWorkflow(
            sessionManager: manager,
            transcriptionService: transcription,
            notesService: notes,
            notesStateLoader: SessionNotesStateLoader(
                notesStore: notesStore,
                operationStateStore: operationStateStore,
                sourceLoader: sourceLoader
            )
        )
        let log = WorkflowEventLog(workflow: workflow, transcription: transcription, notes: notes)
        return Harness(manager: manager, transcription: transcription, notes: notes, generator: generator, workflow: workflow, log: log)
    }

    private func makeRealSourceLoader() -> NotesTranscriptSourceLoader {
        let root = tempDirectory!
        return NotesTranscriptSourceLoader(transcriptionStore: transcriptionStore, sessionsRootResolver: { root })
    }

    private struct TestLocator: FileSystemLocating {
        let root: URL
        func sessionsRootDirectory() throws -> URL { root }
        func paths(for sessionID: UUID) throws -> SessionPaths {
            try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: sessionID)
        }
    }

    private func oneUnitPerWindowBudget() throws -> NotesWindowBudget {
        try NotesWindowBudget(maxUTF8BytesPerWindow: 1_000_000, maxUnitsPerWindow: 1)
    }

    // MARK: - Fixtures

    /// A completed, never-transcribed session with `chunkCount` chunks.
    @discardableResult
    private func writeUntranscribedSession(chunkCount: Int, sessionID overrideSessionID: UUID? = nil) throws -> CompletedSessionEntry {
        let id = overrideSessionID ?? sessionID!
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: id)
        var manifest = SessionManifest.newSession(
            id: id,
            audioFormat: AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32"),
            targetChunkDurationSeconds: 30
        )
        manifest.status = .completed
        manifest.endedCleanly = true
        manifest.chunks = (0..<chunkCount).map { seq in
            ChunkMetadata(
                sequenceNumber: seq,
                fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30,
                frameCount: 1_000,
                state: .completed
            )
        }
        try AtomicFileWriter.writeJSON(manifest, to: paths.manifestURL)
        for seq in 0..<chunkCount {
            let url = paths.chunksDirectory.appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: seq))
            try Data("placeholder".utf8).write(to: url)
        }
        return CompletedSessionEntry(manifest: manifest, sessionPaths: paths)
    }

    /// A completed session whose transcript is already durably complete,
    /// produced through the real `CompletedSessionTranscriptionService`.
    @discardableResult
    private func writeTranscribedSession(chunkCount: Int, sessionID overrideSessionID: UUID? = nil) async throws -> CompletedSessionEntry {
        let entry = try writeUntranscribedSession(chunkCount: chunkCount, sessionID: overrideSessionID)
        let harness = try makeHarness()
        let id = entry.manifest.sessionID
        XCTAssertEqual(harness.transcription.transcribe(sessionID: id), .admitted)
        _ = await awaitTranscriptionRelease(harness.transcription, generation: harness.transcription.generation)
        let status = await harness.transcription.peekStatus(sessionID: id, manifest: entry.manifest, sessionPaths: entry.sessionPaths)
        XCTAssertEqual(status, .completed, "fixture transcript must be complete")
        return entry
    }

    /// Persists a Notes generation for the default session directly through
    /// the real stores, with analyses committed for `committedWindowIndices`.
    @discardableResult
    private func persistNotesGeneration(
        provenance: LectureNotesGenerationProvenance = LectureNotesGenerationProvenance(recipeVersion: "t5-notes-v1"),
        committedWindowIndices: [Int]
    ) async throws -> UUID {
        let snapshot = try await makeRealSourceLoader().loadCurrentSnapshot(sessionID: sessionID)
        let plan = NotesWindowPlan(windows: NotesWindowPlanner.plan(units: snapshot.units, budget: try oneUnitPerWindowBudget()))
        let generationID = UUID()
        let record = LectureNotesGenerationRecord.newGeneration(
            generationID: generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowPlan: plan,
            provenance: provenance
        )
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try notesStore.createGenerationIfAbsent(record, paths: paths), .created)
        for windowIndex in committedWindowIndices {
            let window = try XCTUnwrap(plan.windows.first { $0.windowIndex == windowIndex })
            let units = snapshot.units.filter { $0.sequenceNumber >= window.firstSequenceNumber && $0.sequenceNumber <= window.lastSequenceNumber }
            let analysis = try await FakeLectureNotesGenerator().analyzeWindow(units: units, window: window, generation: record)
            XCTAssertEqual(try notesStore.commitWindowAnalysis(analysis, paths: paths), .committed)
        }
        return generationID
    }

    private func notesGenerationIDs() throws -> [UUID] {
        try notesStore.listGenerationIDs(sessionPaths: sessionPaths)
    }

    private func currentNotesState() async -> SessionNotesDisplayState {
        let loader = SessionNotesStateLoader(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: makeRealSourceLoader())
        return await loader.loadDefaultState(sessionID: sessionID, sessionPaths: sessionPaths)
    }

    // MARK: - Waiting (event-driven)

    private func awaitTerminal(_ workflow: Workflow) async -> Workflow.State {
        if workflow.state.isTerminal { return workflow.state }
        let reached = expectation(description: "workflow reached a terminal state")
        var fulfilled = false
        let cancellable = workflow.$state.sink { state in
            guard state.isTerminal, !fulfilled else { return }
            fulfilled = true
            reached.fulfill()
        }
        await fulfillment(of: [reached], timeout: 10)
        cancellable.cancel()
        return workflow.state
    }

    @discardableResult
    private func awaitTranscriptionRelease(_ service: CompletedSessionTranscriptionService, generation: Int) async -> CompletedSessionTranscriptionService.OperationRelease? {
        if let release = service.lastReleasedOperation, release.generation == generation { return release }
        let released = expectation(description: "transcription release \(generation)")
        var observed: CompletedSessionTranscriptionService.OperationRelease?
        let cancellable = service.$lastReleasedOperation.sink { release in
            guard let release, release.generation == generation, observed == nil else { return }
            observed = release
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 5)
        cancellable.cancel()
        return observed
    }

    @discardableResult
    private func awaitNotesRelease(_ service: LectureNotesGenerationService, epoch: Int) async -> LectureNotesGenerationService.OperationRelease? {
        if let release = service.lastReleasedOperation, release.operationEpoch == epoch { return release }
        let released = expectation(description: "notes release \(epoch)")
        var observed: LectureNotesGenerationService.OperationRelease?
        let cancellable = service.$lastReleasedOperation.sink { release in
            guard let release, release.operationEpoch == epoch, observed == nil else { return }
            observed = release
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 5)
        cancellable.cancel()
        return observed
    }

    /// The fake generator's gates expose only a flag; this mirrors the
    /// existing Notes service tests' yield loop (no sleeps).
    private func awaitWindowGate(_ generator: ControllableFakeLectureNotesGenerator, windowIndex: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await generator.hasEnteredGate(forWindowIndex: windowIndex) { return }
            await Task.yield()
        }
        XCTFail("window \(windowIndex) gate never entered", file: file, line: line)
    }

    // MARK: - Happy path

    func testUntouchedSessionTranscribesThenGeneratesNotesAndFinishes() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 2)
        let harness = try makeHarness()

        XCTAssertEqual(harness.workflow.processToNotes(entry: entry), .started)
        let terminal = await awaitTerminal(harness.workflow)

        let generationIDs = try notesGenerationIDs()
        XCTAssertEqual(generationIDs.count, 1)
        XCTAssertEqual(terminal, .finished(sessionID: sessionID, notesGenerationID: try XCTUnwrap(generationIDs.first)))
        XCTAssertEqual(harness.log.events, [
            .state(.idle),
            .state(.transcribing(sessionID: sessionID)),
            .transcriptionReleased(generation: 1),
            .state(.generatingNotes(sessionID: sessionID)),
            .notesReleased(epoch: 1),
            .state(terminal)
        ], "Notes starts only after the exact transcription release, and finishes only after the exact Notes release")
        let status = await harness.transcription.peekStatus(sessionID: sessionID, manifest: entry.manifest, sessionPaths: entry.sessionPaths)
        XCTAssertEqual(status, .completed)
        guard case .loaded(_, .completed, _) = await currentNotesState() else {
            return XCTFail("durable Notes must be completed")
        }
        let analyzeCalls = await harness.generator.analyzeCalls
        let synthesizeCount = await harness.generator.synthesizeCallCount
        XCTAssertEqual(analyzeCalls, [0, 1])
        XCTAssertEqual(synthesizeCount, 1)
    }

    func testCompletedTranscriptSkipsTranscriptionAndGeneratesNotes() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 2)
        let transcriber = FakeTranscriber()
        let harness = try makeHarness(transcriber: transcriber)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        let generationID = try XCTUnwrap(try notesGenerationIDs().first)
        XCTAssertEqual(terminal, .finished(sessionID: sessionID, notesGenerationID: generationID))
        XCTAssertEqual(harness.transcription.generation, 0, "transcription was never admitted")
        XCTAssertTrue(transcriber.recordedCalls.isEmpty)
        XCTAssertEqual(harness.notes.operationEpoch, 1)
    }

    func testExistingCompletedNotesSkipBothStagesWithoutDuplicateWork() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 2)
        let first = try makeHarness()
        first.workflow.processToNotes(entry: entry)
        guard case .finished(_, let existingGenerationID) = await awaitTerminal(first.workflow) else {
            return XCTFail("fixture workflow did not finish")
        }

        let harness = try makeHarness()
        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .finished(sessionID: sessionID, notesGenerationID: existingGenerationID))
        XCTAssertEqual(try notesGenerationIDs(), [existingGenerationID], "no duplicate generation")
        XCTAssertEqual(harness.transcription.generation, 0)
        XCTAssertEqual(harness.notes.operationEpoch, 0)
        let analyzeCalls = await harness.generator.analyzeCalls
        XCTAssertTrue(analyzeCalls.isEmpty)
    }

    // MARK: - Transcription stop cases

    func testTranscriptionServiceBusyStopsWithoutStartingNotes() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        let otherSessionID = UUID()
        try writeUntranscribedSession(chunkCount: 1, sessionID: otherSessionID)
        let gated = GatedTranscriber(honorsCancellation: true)
        let harness = try makeHarness(transcriber: gated)
        XCTAssertEqual(harness.transcription.transcribe(sessionID: otherSessionID), .admitted)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .transcription, reason: .serviceBusy))
        XCTAssertEqual(harness.transcription.generation, 1, "only the other session's operation was admitted")
        XCTAssertEqual(harness.notes.operationEpoch, 0)
        harness.transcription.cancel(sessionID: otherSessionID)
        await awaitTranscriptionRelease(harness.transcription, generation: 1)
    }

    func testRecordingActiveAtTranscriptionAdmissionStops() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        let harness = try makeHarness()
        await harness.manager.startSession()
        XCTAssertEqual(harness.manager.state, .recording)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .transcription, reason: .recordingActive))
        XCTAssertEqual(harness.transcription.generation, 0)
        XCTAssertEqual(harness.notes.operationEpoch, 0)
        await harness.manager.stopSession()
    }

    func testTranscriptionShuttingDownStops() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        let harness = try makeHarness()
        harness.transcription.beginShutdown()

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .transcription, reason: .serviceShuttingDown))
        XCTAssertEqual(harness.notes.operationEpoch, 0)
    }

    func testTranscriptionEndingIncompleteStopsWithoutStartingNotes() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 2)
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "boom", retryDisposition: .permanent),
            forSequenceNumber: 1
        )
        let harness = try makeHarness(transcriber: transcriber)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .transcription, reason: .transcriptionNotCompleted(.incomplete(completed: 1, total: 2))))
        XCTAssertEqual(harness.transcription.generation, 1)
        XCTAssertEqual(harness.notes.operationEpoch, 0)
        XCTAssertFalse(harness.log.states.contains(.generatingNotes(sessionID: sessionID)))
    }

    func testTranscriptionEndingWithRetryableFailureIsNotRetriedAutomatically() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 2)
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "transient", retryDisposition: .retryable),
            forSequenceNumber: 0
        )
        let harness = try makeHarness(transcriber: transcriber)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .transcription, reason: .transcriptionNotCompleted(.incomplete(completed: 0, total: 2))))
        XCTAssertEqual(transcriber.recordedCalls.map(\.sequenceNumber), [0], "the failed chunk is never retried automatically")
        XCTAssertEqual(harness.transcription.generation, 1, "no Continue/Retry was admitted")
        XCTAssertEqual(harness.notes.operationEpoch, 0)
    }

    func testTranscriptionEndingWithUnconfirmableCommitStops() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        let failingStore = FailingTranscriptionStore(wrapped: transcriptionStore)
        await failingStore.setFailNextCommitResult(true)
        let harness = try makeHarness(transcriptionStore: failingStore)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        guard case .stopped(sessionID, .transcription, .transcriptionNotCompleted(let status)) = terminal else {
            return XCTFail("expected a transcription stop, got \(terminal)")
        }
        XCTAssertNotEqual(status, .completed)
        XCTAssertEqual(harness.transcription.generation, 1, "no Continue/Retry was admitted")
        XCTAssertEqual(harness.notes.operationEpoch, 0)
    }

    func testPreexistingInterruptedTranscriptionIsNeverRecovered() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        // An ownerless `.running` job: a prior attempt was interrupted.
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: entry.manifest, sessionPaths: entry.sessionPaths)
        try await transcriptionStore.ensureDirectoriesExist(paths: artifactPaths)
        let chunk = entry.manifest.chunks[0]
        let source = TranscriptionSourceSnapshot(
            sessionID: sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: entry.manifest.audioFormat
        )
        var runningJob = TranscriptionJob.newQueued(source: source, now: Date())
        runningJob.state = .running
        runningJob.currentAttemptID = UUID()
        _ = try await transcriptionStore.createJobIfAbsent(runningJob, paths: artifactPaths)
        let transcriber = FakeTranscriber()
        let harness = try makeHarness(transcriber: transcriber)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        guard case .stopped(sessionID, .transcription, .transcriptionNotCompleted(.interrupted)) = terminal else {
            return XCTFail("expected an interrupted transcription stop, got \(terminal)")
        }
        XCTAssertEqual(harness.transcription.generation, 0, "recovery runs only under an explicit owner action")
        XCTAssertTrue(transcriber.recordedCalls.isEmpty)
        let job = try await transcriptionStore.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job?.state, .running, "durable state untouched")
        XCTAssertEqual(harness.notes.operationEpoch, 0)
    }

    func testPreexistingPartialTranscriptionIsNeverResumed() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 2)
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "transient", retryDisposition: .retryable),
            forSequenceNumber: 1
        )
        let manual = try makeHarness(transcriber: transcriber)
        XCTAssertEqual(manual.transcription.transcribe(sessionID: sessionID), .admitted)
        await awaitTranscriptionRelease(manual.transcription, generation: 1)
        let callsBefore = transcriber.recordedCalls.count

        let harness = try makeHarness(transcriber: transcriber)
        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .transcription, reason: .transcriptionNotCompleted(.incomplete(completed: 1, total: 2))))
        XCTAssertEqual(harness.transcription.generation, 0, "no Transcribe/Continue/Retry was admitted")
        XCTAssertEqual(transcriber.recordedCalls.count, callsBefore)
        XCTAssertEqual(harness.notes.operationEpoch, 0)
    }

    func testBlockedTranscriptionBeforeStartStops() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        // A result artifact that is not valid JSON is a genuine integrity
        // finding the read-only preflight blocks on.
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: entry.manifest, sessionPaths: entry.sessionPaths)
        try await transcriptionStore.ensureDirectoriesExist(paths: artifactPaths)
        try Data("not json".utf8).write(to: artifactPaths.resultURL(sequenceNumber: 0))
        let harness = try makeHarness()

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        guard case .stopped(sessionID, .transcription, .transcriptionNotCompleted(.blocked)) = terminal else {
            return XCTFail("expected a blocked transcription stop, got \(terminal)")
        }
        XCTAssertEqual(harness.transcription.generation, 0)
        XCTAssertEqual(harness.notes.operationEpoch, 0)
    }

    func testZeroChunkSessionStops() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 0)
        let harness = try makeHarness()

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        guard case .stopped(sessionID, .transcription, .transcriptionNotCompleted(let status)) = terminal else {
            return XCTFail("expected a transcription stop, got \(terminal)")
        }
        XCTAssertNotEqual(status, .completed)
        XCTAssertEqual(harness.transcription.generation, 0)
        XCTAssertEqual(harness.notes.operationEpoch, 0)
    }

    func testWorkflowCancelDuringTranscriptionCancelsServiceAndNeverStartsNotes() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 2)
        let gated = GatedTranscriber(honorsCancellation: true)
        let harness = try makeHarness(transcriber: gated)

        harness.workflow.processToNotes(entry: entry)
        await gated.waitUntilEntered()
        XCTAssertEqual(harness.transcription.activeSessionID, sessionID)

        harness.workflow.cancel()
        harness.workflow.cancel() // Idempotent.
        XCTAssertEqual(harness.workflow.state, .stopped(sessionID: sessionID, stage: .transcription, reason: .cancelled))
        XCTAssertEqual(harness.transcription.phase, .cancelling, "cancellation was forwarded to the transcription service")

        let release = await awaitTranscriptionRelease(harness.transcription, generation: 1)
        XCTAssertEqual(release?.status, .incomplete(completed: 0, total: 2))
        XCTAssertEqual(harness.workflow.state, .stopped(sessionID: sessionID, stage: .transcription, reason: .cancelled))
        XCTAssertEqual(harness.notes.operationEpoch, 0)
        XCTAssertEqual(harness.log.states.filter(\.isTerminal).count, 1, "exactly one terminal transition")
    }

    func testExternalTranscriptionCancelStopsWorkflow() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 2)
        let gated = GatedTranscriber(honorsCancellation: true)
        let harness = try makeHarness(transcriber: gated)

        harness.workflow.processToNotes(entry: entry)
        await gated.waitUntilEntered()
        harness.transcription.cancel(sessionID: sessionID) // The manual Cancel path.
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .transcription, reason: .transcriptionNotCompleted(.incomplete(completed: 0, total: 2))))
        XCTAssertEqual(harness.notes.operationEpoch, 0)
    }

    // MARK: - Notes stop cases

    func testNotesServiceBusyStops() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 1)
        let otherSessionID = UUID()
        try await writeTranscribedSession(chunkCount: 1, sessionID: otherSessionID)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let harness = try makeHarness(generator: generator)
        XCTAssertEqual(harness.notes.generate(sessionID: otherSessionID), .admitted)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .notes, reason: .serviceBusy))
        XCTAssertEqual(harness.notes.operationEpoch, 1, "only the other session's operation was admitted")
        XCTAssertTrue(try notesGenerationIDs().isEmpty)
        harness.notes.cancel(sessionID: otherSessionID)
        await awaitNotesRelease(harness.notes, epoch: 1)
    }

    func testNotesServiceShuttingDownStops() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 1)
        let harness = try makeHarness()
        harness.notes.beginShutdown()

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .notes, reason: .serviceShuttingDown))
        XCTAssertTrue(try notesGenerationIDs().isEmpty)
    }

    func testRecordingActiveBeforeNotesAdmissionStopsWithoutStartingNotes() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 1)
        let harness = try makeHarness()
        await harness.manager.startSession()
        XCTAssertEqual(harness.manager.state, .recording)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .notes, reason: .recordingActive))
        XCTAssertEqual(harness.notes.operationEpoch, 0, "Notes admission was never attempted")
        XCTAssertTrue(try notesGenerationIDs().isEmpty)
        await harness.manager.stopSession()
    }

    func testNotesBackendUnavailableStops() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 1)
        let availability = MutableAvailabilityChecker()
        availability.result = .unavailable(description: "Model not ready")
        let harness = try makeHarness(availability: availability)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .notes, reason: .notesGenerationNotCompleted(.backendUnavailable(description: "Model not ready"))))
        XCTAssertTrue(try notesGenerationIDs().isEmpty)
        let analyzeCalls = await harness.generator.analyzeCalls
        XCTAssertTrue(analyzeCalls.isEmpty)
    }

    func testWorkflowCancelDuringNotesCancelsServiceAndStops() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let harness = try makeHarness(generator: generator)

        harness.workflow.processToNotes(entry: entry)
        await awaitWindowGate(generator, windowIndex: 0)

        harness.workflow.cancel()
        harness.workflow.cancel() // Idempotent.
        XCTAssertEqual(harness.workflow.state, .stopped(sessionID: sessionID, stage: .notes, reason: .cancelled))
        XCTAssertEqual(harness.notes.phase, .cancelling, "cancellation was forwarded to the Notes service")

        let release = await awaitNotesRelease(harness.notes, epoch: 1)
        XCTAssertEqual(release?.outcome, .cancelled)
        XCTAssertEqual(harness.workflow.state, .stopped(sessionID: sessionID, stage: .notes, reason: .cancelled))
        XCTAssertEqual(harness.notes.operationEpoch, 1, "never retried or continued")
        let analyzeCalls = await generator.analyzeCalls
        XCTAssertEqual(analyzeCalls, [0])
    }

    func testNotesStaleSourceStops() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let sourceLoader = SwitchableSourceLoader(wrapped: makeRealSourceLoader())
        let harness = try makeHarness(generator: generator, sourceLoader: sourceLoader)

        harness.workflow.processToNotes(entry: entry)
        await awaitWindowGate(generator, windowIndex: 0)
        sourceLoader.switchToChangedSource()
        await generator.releaseGateSuccessfully(windowIndex: 0)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .notes, reason: .notesGenerationNotCompleted(.staleSource)))
        XCTAssertEqual(try notesGenerationIDs().count, 1, "no replacement generation was started")
        XCTAssertEqual(harness.notes.operationEpoch, 1)
    }

    func testNotesGeneratorFailureStopsAndIsNotRetried() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.setFailure(FakeGeneratorFailure(message: "model error"), forWindowIndex: 1)
        let harness = try makeHarness(generator: generator)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        guard case .stopped(sessionID, .notes, .notesGenerationNotCompleted(.failed?)) = terminal else {
            return XCTFail("expected a failed Notes stop, got \(terminal)")
        }
        let analyzeCalls = await generator.analyzeCalls
        XCTAssertEqual(analyzeCalls, [0, 1], "the failed window is never retried automatically")
        XCTAssertEqual(harness.notes.operationEpoch, 1)
        XCTAssertEqual(try notesGenerationIDs().count, 1)
    }

    func testPreexistingDamagedNotesGenerationStops() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 2)
        let generationID = try await persistNotesGeneration(committedWindowIndices: [1])
        let harness = try makeHarness()

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        guard case .stopped(sessionID, .notes, .notesRequireAttention(generationID, .damaged)) = terminal else {
            return XCTFail("expected a damaged Notes stop, got \(terminal)")
        }
        XCTAssertEqual(harness.notes.operationEpoch, 0)
        XCTAssertEqual(try notesGenerationIDs(), [generationID])
    }

    func testPreexistingIncompatibleNotesGenerationStops() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 2)
        let generationID = try await persistNotesGeneration(
            provenance: LectureNotesGenerationProvenance(recipeVersion: "retired-recipe", backendIdentifier: MLXNotesConfiguration.backendIdentifier),
            committedWindowIndices: [0]
        )
        let harness = try makeHarness()

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .notes, reason: .notesRequireAttention(generationID: generationID, classification: .incompatibleProvenance)))
        XCTAssertEqual(harness.notes.operationEpoch, 0)
        XCTAssertEqual(try notesGenerationIDs(), [generationID])
    }

    func testPreexistingResumableNotesGenerationIsNeverContinued() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 2)
        let generationID = try await persistNotesGeneration(committedWindowIndices: [0])
        let harness = try makeHarness()

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        XCTAssertEqual(terminal, .stopped(sessionID: sessionID, stage: .notes, reason: .notesRequireAttention(
            generationID: generationID,
            classification: .resumable(nextWindowIndex: 1, interruption: .notStarted)
        )))
        XCTAssertEqual(harness.notes.operationEpoch, 0, "no Generate/Continue/Retry was admitted")
        XCTAssertEqual(try notesGenerationIDs(), [generationID], "no generation was created around it")
        let analyzeCalls = await harness.generator.analyzeCalls
        XCTAssertTrue(analyzeCalls.isEmpty)
    }

    // MARK: - Race / identity

    func testOlderSameSessionTranscriptionReleaseCannotSatisfyTheWorkflowsOperation() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        let harness = try makeHarness()
        // Operation A: admitted and cancelled before its task ever runs, so
        // it releases while leaving the session durably untranscribed.
        XCTAssertEqual(harness.transcription.transcribe(sessionID: sessionID), .admitted)
        harness.transcription.cancel(sessionID: sessionID)
        let releaseA = await awaitTranscriptionRelease(harness.transcription, generation: 1)
        XCTAssertEqual(releaseA?.sessionID, sessionID)
        let status = await harness.transcription.peekStatus(sessionID: sessionID, manifest: entry.manifest, sessionPaths: entry.sessionPaths)
        XCTAssertEqual(status, .notTranscribed)

        // The workflow subscribes while A's release is the replayed current
        // value — same session, older token. Accepting it would re-read a
        // not-transcribed state and stop; matching only B lets it finish.
        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        guard case .finished = terminal else { return XCTFail("expected finished, got \(terminal)") }
        XCTAssertEqual(harness.transcription.generation, 2)
        let releaseIndex = try XCTUnwrap(harness.log.events.firstIndex(of: .transcriptionReleased(generation: 2)))
        let notesIndex = try XCTUnwrap(harness.log.events.firstIndex(of: .state(.generatingNotes(sessionID: sessionID))))
        XCTAssertLessThan(releaseIndex, notesIndex, "Notes waited for operation B's own release")
    }

    func testOlderSameSessionNotesReleaseCannotSatisfyTheWorkflowsOperation() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 1)
        let availability = MutableAvailabilityChecker()
        availability.result = .unavailable(description: "not yet")
        let harness = try makeHarness(availability: availability)
        // Operation A releases without creating any generation.
        XCTAssertEqual(harness.notes.generate(sessionID: sessionID), .admitted)
        let releaseA = await awaitNotesRelease(harness.notes, epoch: 1)
        XCTAssertEqual(releaseA?.outcome, .backendUnavailable(description: "not yet"))
        availability.result = .available

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        let generationID = try XCTUnwrap(try notesGenerationIDs().first)
        XCTAssertEqual(terminal, .finished(sessionID: sessionID, notesGenerationID: generationID))
        XCTAssertEqual(harness.notes.operationEpoch, 2)
        let releaseIndex = try XCTUnwrap(harness.log.events.firstIndex(of: .notesReleased(epoch: 2)))
        let finishedIndex = try XCTUnwrap(harness.log.events.firstIndex(of: .state(terminal)))
        XCTAssertLessThan(releaseIndex, finishedIndex)
    }

    func testDifferentSessionReleaseIsIgnored() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        let otherSessionID = UUID()
        let otherEntry = try writeUntranscribedSession(chunkCount: 1, sessionID: otherSessionID)
        let harness = try makeHarness()
        XCTAssertEqual(harness.transcription.transcribe(sessionID: otherSessionID), .admitted)
        await awaitTranscriptionRelease(harness.transcription, generation: 1)
        let otherStatus = await harness.transcription.peekStatus(sessionID: otherSessionID, manifest: otherEntry.manifest, sessionPaths: otherEntry.sessionPaths)
        XCTAssertEqual(otherStatus, .completed)

        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)

        guard case .finished(sessionID, _) = terminal else { return XCTFail("expected finished, got \(terminal)") }
        XCTAssertEqual(harness.transcription.generation, 2, "the workflow ran its own transcription for its own session")
    }

    func testCancelBeforeASuccessfulReleaseNeverAdvancesAndANewRunIsUnaffected() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        let gated = GatedTranscriber(honorsCancellation: false)
        let harness = try makeHarness(transcriber: gated)

        // Run A: cancelled while its operation is in flight.
        harness.workflow.processToNotes(entry: entry)
        await gated.waitUntilEntered()
        harness.workflow.cancel()
        XCTAssertEqual(harness.workflow.state, .stopped(sessionID: sessionID, stage: .transcription, reason: .cancelled))

        // The operation ignores cancellation and still commits, so its late
        // release reports a durably completed transcript.
        await gated.open()
        let lateRelease = await awaitTranscriptionRelease(harness.transcription, generation: 1)
        XCTAssertEqual(lateRelease?.status, .completed)
        let status = await harness.transcription.peekStatus(sessionID: sessionID, manifest: entry.manifest, sessionPaths: entry.sessionPaths)
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(harness.workflow.state, .stopped(sessionID: sessionID, stage: .transcription, reason: .cancelled))
        XCTAssertEqual(harness.notes.operationEpoch, 0, "a release after cancellation never starts Notes")

        // Run B on the same instance: its own state only.
        XCTAssertEqual(harness.workflow.processToNotes(entry: entry), .started)
        let terminal = await awaitTerminal(harness.workflow)
        guard case .finished = terminal else { return XCTFail("expected finished, got \(terminal)") }
        XCTAssertEqual(harness.notes.operationEpoch, 1)
        XCTAssertEqual(harness.log.states, [
            .idle,
            .transcribing(sessionID: sessionID),
            .stopped(sessionID: sessionID, stage: .transcription, reason: .cancelled),
            .transcribing(sessionID: sessionID),
            .generatingNotes(sessionID: sessionID),
            terminal
        ], "run A never advanced after cancellation")
    }

    func testCancelDuringNotesThenNewRunIgnoresTheOldRelease() async throws {
        let entry = try await writeTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let harness = try makeHarness(generator: generator)

        harness.workflow.processToNotes(entry: entry)
        await awaitWindowGate(generator, windowIndex: 0)
        harness.workflow.cancel()
        await awaitNotesRelease(harness.notes, epoch: 1)
        guard case .loaded(_, .resumable, _) = await currentNotesState() else {
            return XCTFail("cancelled generation should be resumable on disk")
        }

        // Run B sees run A's leftover generation and stops for the owner,
        // rather than generating around it or resuming it.
        harness.workflow.processToNotes(entry: entry)
        let terminal = await awaitTerminal(harness.workflow)
        guard case .stopped(sessionID, .notes, .notesRequireAttention(_, .resumable)) = terminal else {
            return XCTFail("expected a resumable Notes stop, got \(terminal)")
        }
        XCTAssertEqual(harness.notes.operationEpoch, 1)
        XCTAssertEqual(try notesGenerationIDs().count, 1)
    }

    // MARK: - Run ownership

    func testSecondStartWhileRunningIsRefusedWithoutSideEffects() async throws {
        let entry = try writeUntranscribedSession(chunkCount: 1)
        let gated = GatedTranscriber(honorsCancellation: true)
        let harness = try makeHarness(transcriber: gated)

        XCTAssertEqual(harness.workflow.processToNotes(entry: entry), .started)
        await gated.waitUntilEntered()
        XCTAssertEqual(harness.workflow.processToNotes(entry: entry), .alreadyRunning)
        XCTAssertEqual(harness.transcription.generation, 1)

        await gated.open()
        let terminal = await awaitTerminal(harness.workflow)
        guard case .finished = terminal else { return XCTFail("expected finished, got \(terminal)") }
        XCTAssertEqual(harness.log.states.filter(\.isTerminal).count, 1)
    }

    func testCancelWithoutActiveRunIsANoOp() throws {
        let harness = try makeHarness()
        harness.workflow.cancel()
        XCTAssertEqual(harness.workflow.state, .idle)
    }
}

// MARK: - OperationReleaseWaiter

@MainActor
final class OperationReleaseWaiterTests: XCTestCase {
    private struct Release: Equatable {
        let sessionID: UUID
        let token: Int
    }

    private let sessionID = UUID()

    private func makeWaiter(_ subject: CurrentValueSubject<Release?, Never>) -> OperationReleaseWaiter<Release> {
        OperationReleaseWaiter(releases: subject) { release, sessionID, token in
            release.sessionID == sessionID && release.token == token
        }
    }

    func testReleasePublishedImmediatelyAfterAdmissionIsObserved() async {
        // Models the fastest possible operation: its release is published
        // after subscription but before the synchronous token read.
        let subject = CurrentValueSubject<Release?, Never>(nil)
        let waiter = makeWaiter(subject)

        subject.send(Release(sessionID: sessionID, token: 1))
        waiter.expect(sessionID: sessionID, token: 1)

        XCTAssertFalse(waiter.isAwaitingRelease)
        let release = await waiter.wait()
        XCTAssertEqual(release, Release(sessionID: sessionID, token: 1))
    }

    func testReplayedOlderReleaseIsIgnored() async {
        let subject = CurrentValueSubject<Release?, Never>(Release(sessionID: sessionID, token: 1))
        let waiter = makeWaiter(subject)
        waiter.expect(sessionID: sessionID, token: 2)
        XCTAssertTrue(waiter.isAwaitingRelease)

        subject.send(Release(sessionID: sessionID, token: 2))
        let release = await waiter.wait()
        XCTAssertEqual(release?.token, 2)
    }

    func testWrongTokenAndDifferentSessionAreIgnoredWhileWaiting() async {
        let subject = CurrentValueSubject<Release?, Never>(nil)
        let waiter = makeWaiter(subject)
        waiter.expect(sessionID: sessionID, token: 5)

        subject.send(Release(sessionID: sessionID, token: 4))
        subject.send(Release(sessionID: sessionID, token: 6))
        subject.send(Release(sessionID: UUID(), token: 5))
        subject.send(nil)
        XCTAssertTrue(waiter.isAwaitingRelease)

        subject.send(Release(sessionID: sessionID, token: 5))
        let release = await waiter.wait()
        XCTAssertEqual(release, Release(sessionID: sessionID, token: 5))
    }

    func testDuplicateMatchingReleaseIsObservedOnlyOnce() async {
        let subject = CurrentValueSubject<Release?, Never>(nil)
        let waiter = makeWaiter(subject)
        waiter.expect(sessionID: sessionID, token: 1)

        let resumed = expectation(description: "wait resumed")
        var resumeCount = 0
        var first: Release?
        Task {
            first = await waiter.wait()
            resumeCount += 1
            resumed.fulfill()
        }
        await Task.yield()
        subject.send(Release(sessionID: sessionID, token: 1))
        subject.send(Release(sessionID: sessionID, token: 1))
        await fulfillment(of: [resumed], timeout: 5)

        XCTAssertEqual(first, Release(sessionID: sessionID, token: 1))
        XCTAssertEqual(resumeCount, 1)
        let again = await waiter.wait()
        XCTAssertEqual(again, first, "a completed wait keeps its one result")
    }

    func testAbandonWhileSuspendedResumesWithNilAndLaterReleasesAreIgnored() async {
        let subject = CurrentValueSubject<Release?, Never>(nil)
        let waiter = makeWaiter(subject)
        waiter.expect(sessionID: sessionID, token: 1)

        let resumed = expectation(description: "wait resumed")
        var result: Release?
        var didResume = false
        Task {
            result = await waiter.wait()
            didResume = true
            resumed.fulfill()
        }
        await Task.yield()
        waiter.abandon()
        waiter.abandon() // Idempotent.
        await fulfillment(of: [resumed], timeout: 5)
        XCTAssertTrue(didResume)
        XCTAssertNil(result)

        subject.send(Release(sessionID: sessionID, token: 1))
        let after = await waiter.wait()
        XCTAssertNil(after)
        XCTAssertFalse(waiter.isAwaitingRelease)
    }

    func testAbandonAfterMatchKeepsTheMatch() async {
        let subject = CurrentValueSubject<Release?, Never>(nil)
        let waiter = makeWaiter(subject)
        waiter.expect(sessionID: sessionID, token: 1)
        subject.send(Release(sessionID: sessionID, token: 1))
        waiter.abandon()
        let release = await waiter.wait()
        XCTAssertEqual(release?.token, 1)
    }
}
