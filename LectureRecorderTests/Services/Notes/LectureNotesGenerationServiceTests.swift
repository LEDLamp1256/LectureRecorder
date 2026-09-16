import XCTest
@testable import LectureRecorder

/// Deterministically returns a different `NotesTranscriptSourceSnapshot`
/// once its call count passes `switchAfterCallCount` — lets a test change
/// "the current durable transcript source" at an exact, controlled point
/// in a run (e.g. precisely between the last window commit and the
/// pre-synthesis reload) without touching real files or using sleeps.
private final class SwitchableSourceSnapshotLoader: NotesTranscriptSourceLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let switchAfterCallCount: Int
    private let before: NotesTranscriptSourceSnapshot
    private let after: NotesTranscriptSourceSnapshot

    init(before: NotesTranscriptSourceSnapshot, switchAfterCallCount: Int, after: NotesTranscriptSourceSnapshot) {
        self.before = before
        self.switchAfterCallCount = switchAfterCallCount
        self.after = after
    }

    func loadCurrentSnapshot(sessionID: UUID) async throws -> NotesTranscriptSourceSnapshot {
        lock.lock()
        callCount += 1
        let count = callCount
        lock.unlock()
        return count <= switchAfterCallCount ? before : after
    }
}

@MainActor
final class LectureNotesGenerationServiceTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!
    private var transcriptionStore: TranscriptionStore!
    private var notesStore: LectureNotesStore!
    private var operationStateStore: LectureNotesOperationStateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LNGenServiceTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Fixtures

    private func makeAudioFormat() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
    }

    /// Writes a fully `.completed`, transcription-eligible session directly
    /// to disk via the real `TranscriptionStore` — the same durable shape
    /// `NotesTranscriptSourceLoader` reads through the established
    /// transcription persistence path. No fakes stand in for
    /// transcription itself; only notes generation is faked.
    @discardableResult
    private func writeCompletedTranscribedSession(
        chunkCount: Int,
        textForChunk: (Int) -> String = { "chunk text \($0)" }
    ) async throws -> SessionManifest {
        var manifest = SessionManifest.newSession(id: sessionID, audioFormat: makeAudioFormat(), targetChunkDurationSeconds: 30)
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
        try AtomicFileWriter.writeJSON(manifest, to: sessionPaths.manifestURL)
        for seq in 0..<chunkCount {
            let url = sessionPaths.chunksDirectory.appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: seq))
            try Data("placeholder".utf8).write(to: url)
        }

        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await transcriptionStore.ensureDirectoriesExist(paths: artifactPaths)
        for seq in 0..<chunkCount {
            let chunk = manifest.chunks[seq]
            let source = TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
            )
            var job = TranscriptionJob.newQueued(source: source, now: Date())
            job.state = .completed
            _ = try await transcriptionStore.createJobIfAbsent(job, paths: artifactPaths)
            _ = try await transcriptionStore.commitResult(
                TranscriptResult(
                    schemaVersion: TranscriptResult.legacySchemaVersion, source: source,
                    output: TranscriptionEngineOutput(text: textForChunk(seq), engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                    attemptID: UUID(), completedDate: Date()
                ),
                paths: artifactPaths
            )
        }
        return manifest
    }

    /// One unit per window, deterministically.
    private func oneUnitPerWindowBudget() throws -> NotesWindowBudget {
        try NotesWindowBudget(maxUTF8BytesPerWindow: 1_000_000, maxUnitsPerWindow: 1)
    }

    private func makeService(
        generator: any LectureNotesGenerating,
        notesStore: (any LectureNotesStoring)? = nil,
        operationStateStore: (any LectureNotesOperationStateStoring)? = nil,
        windowBudget: NotesWindowBudget,
        generationProvenance: LectureNotesGenerationProvenance = LectureNotesGenerationProvenance(recipeVersion: "t5-notes-v1"),
        generationIDProvider: (@Sendable () -> UUID)? = nil,
        sourceLoader: (any NotesTranscriptSourceLoading)? = nil
    ) -> LectureNotesGenerationService {
        let root = tempDirectory!
        return LectureNotesGenerationService(
            sourceLoader: sourceLoader ?? NotesTranscriptSourceLoader(transcriptionStore: transcriptionStore, sessionsRootResolver: { root }),
            notesStore: notesStore ?? self.notesStore,
            operationStateStore: operationStateStore ?? self.operationStateStore,
            generator: generator,
            windowBudget: windowBudget,
            generationProvenance: generationProvenance,
            sessionsRootResolver: { root },
            generationIDProvider: generationIDProvider ?? { UUID() }
        )
    }

    private func waitUntilFinished(
        _ service: LectureNotesGenerationService,
        timeout: TimeInterval = 5
    ) async -> LectureNotesGenerationService.OperationPhase {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .finished = service.phase { return service.phase }
            await Task.yield()
        }
        return service.phase
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    private func onlyGenerationID() throws -> UUID {
        let ids = try notesStore.listGenerationIDs(sessionPaths: sessionPaths)
        guard ids.count == 1 else { throw XCTSkip("expected exactly one generation, found \(ids.count)") }
        return ids[0]
    }

    // MARK: - Single-owner behavior

    func testSecondOperationRefusedWhileOneActive() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 0) }
        XCTAssertEqual(service.generate(sessionID: sessionID), .busy)
        XCTAssertEqual(service.generate(sessionID: UUID()), .busy)

        service.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service)
    }

    func testActiveIdentityClearedOnEveryExitPath() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let service = makeService(generator: ControllableFakeLectureNotesGenerator(), windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        _ = await waitUntilFinished(service)

        XCTAssertNil(service.activeSessionID)
        XCTAssertNil(service.activeGenerationID)
        // Admission is available again immediately for a different session.
        XCTAssertEqual(service.generate(sessionID: UUID()), .admitted)
        _ = await waitUntilFinished(service)
    }

    // MARK: - Fresh generation

    func testMultiWindowGenerateCommitsWindowsSequentiallyThenDocument() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 3)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed(let document)) = finalPhase else {
            return XCTFail("expected completed, got \(finalPhase)")
        }
        XCTAssertEqual(document.sections.count, 3)

        let calls = await generator.analyzeCalls
        XCTAssertEqual(calls, [0, 1, 2])
        let synthCount = await generator.synthesizeCallCount
        XCTAssertEqual(synthCount, 1)

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let analyses = try notesStore.loadAllWindowAnalyses(paths: paths)
        XCTAssertEqual(analyses.count, 3)
    }

    func testSecondGenerationGetsNewIDAndPriorGenerationSurvives() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let service = makeService(generator: ControllableFakeLectureNotesGenerator(), windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        _ = await waitUntilFinished(service)
        let firstID = try onlyGenerationID()

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        _ = await waitUntilFinished(service)

        let ids = Set(try notesStore.listGenerationIDs(sessionPaths: sessionPaths))
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains(firstID))

        let firstPaths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: firstID)
        XCTAssertNotNil(try notesStore.loadDocument(paths: firstPaths))
    }

    func testGenerateFreezesConfiguredProviderAndModelProvenance() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let provenance = LectureNotesGenerationProvenance(
            recipeVersion: "recipe-a",
            generatorIdentifier: "openai-responses-api",
            generatorVersion: "gpt-5.6-sol",
            backendIdentifier: "openai"
        )
        let service = makeService(
            generator: ControllableFakeLectureNotesGenerator(),
            windowBudget: try oneUnitPerWindowBudget(),
            generationProvenance: provenance
        )

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        _ = await waitUntilFinished(service)

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try notesStore.loadGeneration(paths: paths)?.provenance, provenance)
        XCTAssertEqual(try notesStore.loadDocument(paths: paths)?.provenance, provenance)
    }

    func testContinuePreservesStoredProvenanceWhenCurrentConfigurationChanges() async throws {
        try await assertResumePreservesStoredProvenance(useRetry: false)
    }

    func testRetryPreservesStoredProvenanceWhenCurrentConfigurationChanges() async throws {
        try await assertResumePreservesStoredProvenance(useRetry: true)
    }

    private func assertResumePreservesStoredProvenance(useRetry: Bool) async throws {
        try await writeCompletedTranscribedSession(chunkCount: 2)
        let original = LectureNotesGenerationProvenance(
            recipeVersion: "recipe-a",
            generatorIdentifier: "openai-responses-api",
            generatorVersion: "gpt-5.6-sol",
            backendIdentifier: "openai"
        )
        let changed = LectureNotesGenerationProvenance(
            recipeVersion: "recipe-b",
            generatorIdentifier: "different-generator",
            generatorVersion: "different-model",
            backendIdentifier: "different-backend"
        )
        let firstGenerator = ControllableFakeLectureNotesGenerator()
        if useRetry {
            await firstGenerator.setFailure(FakeGeneratorFailure(message: "retry me"), forWindowIndex: 1)
        } else {
            await firstGenerator.armGate(beforeWindowIndex: 1)
        }
        let firstService = makeService(
            generator: firstGenerator,
            windowBudget: try oneUnitPerWindowBudget(),
            generationProvenance: original
        )
        XCTAssertEqual(firstService.generate(sessionID: sessionID), .admitted)
        if useRetry {
            _ = await waitUntilFinished(firstService)
        } else {
            await waitUntil { await firstGenerator.hasEnteredGate(forWindowIndex: 1) }
            firstService.cancel(sessionID: sessionID)
            _ = await waitUntilFinished(firstService)
        }

        let generationID = try onlyGenerationID()
        let secondService = makeService(
            generator: ControllableFakeLectureNotesGenerator(),
            windowBudget: try oneUnitPerWindowBudget(),
            generationProvenance: changed
        )
        let admission = useRetry
            ? secondService.retry(sessionID: sessionID, generationID: generationID)
            : secondService.continueGeneration(sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(admission, .admitted)
        guard case .finished(.completed) = await waitUntilFinished(secondService) else {
            return XCTFail("expected resumed generation to complete")
        }

        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try notesStore.loadGeneration(paths: paths)?.provenance, original)
        XCTAssertEqual(try notesStore.loadDocument(paths: paths)?.provenance, original)
    }

    func testGenerationPlanRemainsFixedAcrossContinue() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 1)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 1) }
        service.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service)

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let planBefore = try XCTUnwrap(notesStore.loadGeneration(paths: paths)).windowPlan

        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        _ = await waitUntilFinished(service)
        let planAfter = try XCTUnwrap(notesStore.loadGeneration(paths: paths)).windowPlan

        XCTAssertEqual(planBefore, planAfter)
    }

    // MARK: - Continue / recovery

    func testCleanPrefixResumesFromFirstMissingWindow() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 3)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 1)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 1) }
        service.cancel(sessionID: sessionID)
        let firstPhase = await waitUntilFinished(service)
        XCTAssertEqual(firstPhase, .finished(.cancelled))

        let generationID = try onlyGenerationID()
        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = finalPhase else { return XCTFail("expected completed, got \(finalPhase)") }

        let calls = await generator.analyzeCalls
        // Window 0 only analyzed once (during Generate); window 1 retried
        // after resuming; window 2 analyzed once during Continue.
        XCTAssertEqual(calls.filter { $0 == 0 }.count, 1)
        XCTAssertTrue(calls.contains(1))
        XCTAssertTrue(calls.contains(2))
    }

    func testCompleteAnalysesResumeDirectlyAtSynthesis() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let firstPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = firstPhase else { return XCTFail("expected completed, got \(firstPhase)") }
        let generationID = try onlyGenerationID()

        // Wipe the document only, simulating "all analyses committed, no
        // document yet" without ever re-invoking the generator for windows.
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        try FileManager.default.removeItem(at: paths.documentURL)

        let analyzeCallsBefore = await generator.analyzeCalls.count
        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = finalPhase else { return XCTFail("expected completed, got \(finalPhase)") }

        let analyzeCallsAfter = await generator.analyzeCalls.count
        XCTAssertEqual(analyzeCallsBefore, analyzeCallsAfter, "resuming from full coverage must go straight to synthesis")
        let synthCount = await generator.synthesizeCallCount
        XCTAssertEqual(synthCount, 2)
    }

    func testPersistedRunningStateAfterRelaunchIsInterruptedNotAutoRestarted() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        // No entry point called yet — simulates a fresh process after a
        // crash. Nothing should have invoked the generator.
        var calls = await generator.analyzeCalls
        XCTAssertEqual(calls, [])

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let firstPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = firstPhase else { return XCTFail("expected completed, got \(firstPhase)") }
        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let callsAfterFirstGenerate = await generator.analyzeCalls

        // Delete window 1's analysis and the document (simulating an
        // incomplete prior attempt), then write a `running` operation-state
        // directly — exactly what a crash mid-window-1 would leave behind.
        try FileManager.default.removeItem(at: paths.documentURL)
        try FileManager.default.removeItem(at: paths.windowAnalysisURL(windowIndex: 1))
        let generation = try XCTUnwrap(notesStore.loadGeneration(paths: paths))
        try operationStateStore.saveOperationState(
            NotesGenerationOperationState(
                sessionID: sessionID, generationID: generationID, transcriptFingerprint: generation.transcriptFingerprint,
                activeRunID: UUID(), runAttemptCount: 1, lifecycle: .running, currentStage: .analyzingWindow(windowIndex: 1)
            ),
            paths: paths
        )

        // Still no automatic invocation merely from writing this state —
        // unchanged from right after the original generate() completed.
        calls = await generator.analyzeCalls
        XCTAssertEqual(calls, callsAfterFirstGenerate)

        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = finalPhase else { return XCTFail("expected completed, got \(finalPhase)") }
        calls = await generator.analyzeCalls
        XCTAssertTrue(calls.contains(1))
    }

    func testCancelledGenerationCanExplicitlyContinue() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 0) }
        service.cancel(sessionID: sessionID)
        let cancelledPhase = await waitUntilFinished(service)
        XCTAssertEqual(cancelledPhase, .finished(.cancelled))

        let generationID = try onlyGenerationID()
        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = finalPhase else { return XCTFail("expected completed, got \(finalPhase)") }
    }

    // MARK: - Retry

    func testWindowFailurePreservesPriorPrefixAndRetryStartsAtFailedWindow() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 3)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.setFailure(FakeGeneratorFailure(message: "boom"), forWindowIndex: 1)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let failedPhase = await waitUntilFinished(service)
        guard case .finished(.failed) = failedPhase else { return XCTFail("expected failed, got \(failedPhase)") }
        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 1)

        // A fresh generator instance with no scripted failure stands in
        // for "the same backend, called again" on Retry.
        let retryGenerator = ControllableFakeLectureNotesGenerator()
        let retryService = makeService(generator: retryGenerator, windowBudget: try oneUnitPerWindowBudget())
        XCTAssertEqual(retryService.retry(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(retryService)
        guard case .finished(.completed) = finalPhase else { return XCTFail("expected completed, got \(finalPhase)") }
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 3)
        let retryCalls = await retryGenerator.analyzeCalls
        XCTAssertEqual(retryCalls, [1, 2])
    }

    func testSynthesisFailurePreservesEveryAnalysisAndRetryRunsSynthesisOnly() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.setSynthesisFailure(FakeGeneratorFailure(message: "synthesis boom"))
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let failedPhase = await waitUntilFinished(service)
        guard case .finished(.failed) = failedPhase else { return XCTFail("expected failed, got \(failedPhase)") }
        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 2)
        let firstAnalyzeCalls = await generator.analyzeCalls
        XCTAssertEqual(firstAnalyzeCalls, [0, 1])

        // A fresh generator instance with no scripted failure stands in for
        // "the same backend, called again" — Retry must reuse the
        // preserved analyses rather than re-invoking analysis at all.
        let secondGenerator = ControllableFakeLectureNotesGenerator()
        let secondService = makeService(generator: secondGenerator, windowBudget: try oneUnitPerWindowBudget())
        XCTAssertEqual(secondService.retry(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(secondService)
        guard case .finished(.completed) = finalPhase else { return XCTFail("expected completed, got \(finalPhase)") }

        let secondAnalyzeCalls = await secondGenerator.analyzeCalls
        let secondSynthCount = await secondGenerator.synthesizeCallCount
        XCTAssertEqual(secondAnalyzeCalls, [])
        XCTAssertEqual(secondSynthCount, 1)
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 2)
    }

    // MARK: - Prefix/integrity via the service

    func testValidCompleteArtifactsOutrankStaleOperationStateFlags() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let firstPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = firstPhase else { return XCTFail("expected completed, got \(firstPhase)") }
        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let generation = try XCTUnwrap(notesStore.loadGeneration(paths: paths))

        // Falsely claim `.failed` even though a valid, complete document
        // already exists.
        try operationStateStore.saveOperationState(
            NotesGenerationOperationState(
                sessionID: sessionID, generationID: generationID, transcriptFingerprint: generation.transcriptFingerprint,
                activeRunID: UUID(), runAttemptCount: 1, lifecycle: .failed, failureDescription: "stale claim"
            ),
            paths: paths
        )

        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = finalPhase else { return XCTFail("expected completed, got \(finalPhase)") }
        // No new generator work was needed at all.
        let analyzeCalls = await generator.analyzeCalls
        let synthCount = await generator.synthesizeCallCount
        XCTAssertEqual(analyzeCalls, [0])
        XCTAssertEqual(synthCount, 1)
    }

    // MARK: - Cancellation

    func testCancelBeforeFirstCommit() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 2)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 0) }
        service.cancel(sessionID: sessionID)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.cancelled))

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 0)
        XCTAssertNotNil(try notesStore.loadGeneration(paths: paths))
    }

    func testCancelBetweenWindows() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 3)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 1)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 1) }
        service.cancel(sessionID: sessionID)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.cancelled))

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 1)
    }

    func testCancelWhileGeneratorCallSuspended() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 0) }
        service.cancel(sessionID: sessionID)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.cancelled))
    }

    func testCancelDuringSynthesis() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armSynthesisGate()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredSynthesisGate }
        service.cancel(sessionID: sessionID)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.cancelled))

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertNil(try notesStore.loadDocument(paths: paths))
    }

    func testGeneratorReturningAfterCancellationCannotCausePostCancelCommit() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 0) }
        service.cancel(sessionID: sessionID)
        // Release the gate with a *normal successful* return, arriving
        // after cancellation was already requested — the service's
        // post-return checkpoint must still discard it, not commit it.
        await generator.releaseGateSuccessfully(windowIndex: 0)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.cancelled))

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 0)
    }

    // MARK: - Stale source

    func testStaleSourceRejectedBeforeResume() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 0) }
        service.cancel(sessionID: sessionID)
        let cancelledPhase = await waitUntilFinished(service)
        XCTAssertEqual(cancelledPhase, .finished(.cancelled))
        let generationID = try onlyGenerationID()
        let callsBeforeContinue = await generator.analyzeCalls

        // The transcript source grows after the generation was created —
        // its fingerprint/coverage no longer matches.
        try await writeCompletedTranscribedSession(chunkCount: 2)

        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.staleSource))
        // Rejected before ever reaching the generator again — no new calls
        // beyond whatever the earlier cancelled attempt already recorded.
        let callsAfterContinue = await generator.analyzeCalls
        XCTAssertEqual(callsAfterContinue, callsBeforeContinue)
    }

    func testSourceChangesWhileWindowCallInFlightDiscardsOutput() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 0) }

        // Grow the source while window 0's generator call is still
        // suspended, then let it return a normal, otherwise-valid analysis.
        try await writeCompletedTranscribedSession(chunkCount: 2)
        await generator.releaseGateSuccessfully(windowIndex: 0)

        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.staleSource))

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 0, "the returned analysis must never be committed once the source has moved on")
    }

    func testSourceChangesDuringSynthesisDocumentNotCommitted() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armSynthesisGate()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredSynthesisGate }

        try await writeCompletedTranscribedSession(chunkCount: 2)
        await generator.releaseSynthesisGateSuccessfully()

        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.staleSource))

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertNil(try notesStore.loadDocument(paths: paths))
    }

    // MARK: - Durability uncertainty

    func testUncertainWindowCommitPreventsNextWindowThenRecoversOnRetry() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 2)
        let spyFileSystem = SpyNotesExclusiveArtifactFileSystem()
        let spyNotesStore = LectureNotesStore(fileSystem: spyFileSystem)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, notesStore: spyNotesStore, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { service.activeGenerationID != nil }
        let generationID = try XCTUnwrap(service.activeGenerationID)
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        spyFileSystem.forceOutcome(.createdDurabilityUncertain, forURL: paths.windowAnalysisURL(windowIndex: 0))

        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.failed) = finalPhase else { return XCTFail("expected failed, got \(finalPhase)") }
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 0)
        let analyzeCalls = await generator.analyzeCalls
        XCTAssertEqual(analyzeCalls, [0])

        // Explicit recovery reloads real disk state (nothing was actually
        // committed, since the forced outcome bypassed the real write) and
        // proceeds correctly this time, without the forced outcome
        // (one-shot, already consumed).
        XCTAssertEqual(service.retry(sessionID: sessionID, generationID: generationID), .admitted)
        let recoveredPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = recoveredPhase else { return XCTFail("expected completed, got \(recoveredPhase)") }
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 2)
    }

    func testUncertainDocumentCommitDoesNotStartAnythingFurther() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let spyFileSystem = SpyNotesExclusiveArtifactFileSystem()
        let spyNotesStore = LectureNotesStore(fileSystem: spyFileSystem)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, notesStore: spyNotesStore, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { service.activeGenerationID != nil }
        let generationID = try XCTUnwrap(service.activeGenerationID)
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        spyFileSystem.forceOutcome(.createdDurabilityUncertain, forURL: paths.documentURL)

        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.failed) = finalPhase else { return XCTFail("expected failed, got \(finalPhase)") }
        XCTAssertNil(try notesStore.loadDocument(paths: paths))
        let synthCount = await generator.synthesizeCallCount
        XCTAssertEqual(synthCount, 1)

        XCTAssertEqual(service.retry(sessionID: sessionID, generationID: generationID), .admitted)
        let recoveredPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = recoveredPhase else { return XCTFail("expected completed, got \(recoveredPhase)") }
        XCTAssertNotNil(try notesStore.loadDocument(paths: paths))
    }

    // MARK: - Correction cluster 1: pre-synthesis source/coverage revalidation

    private func makeSnapshotAndFingerprint(unitCount: Int) -> NotesTranscriptSourceSnapshot {
        let units = (0..<unitCount).map { seq in
            NotesTranscriptSourceUnit(
                sequenceNumber: seq,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                text: "unit \(seq)",
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30
            )
        }
        let fingerprint = TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        return NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: fingerprint
        )
    }

    func testSourceChangeBetweenAnalysesCompleteAndSynthesisNeverInvokesSynthesis() async throws {
        let snapshotBefore = makeSnapshotAndFingerprint(unitCount: 1)
        let snapshotAfter = makeSnapshotAndFingerprint(unitCount: 2)
        // Calls: (1) top-of-run source load, (2) post-window-0-commit
        // staleness check — both must still see the original source so
        // window 0 actually commits; the pre-synthesis reload (call 3)
        // is the first to observe the change.
        let loader = SwitchableSourceSnapshotLoader(before: snapshotBefore, switchAfterCallCount: 2, after: snapshotAfter)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget(), sourceLoader: loader)

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.staleSource))

        let synthCount = await generator.synthesizeCallCount
        XCTAssertEqual(synthCount, 0, "synthesis must never be invoked once the pre-synthesis reload detects a source change")
        let analyzeCalls = await generator.analyzeCalls
        XCTAssertEqual(analyzeCalls, [0], "the single window was still analyzed and committed before the source changed")

        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertNil(try notesStore.loadDocument(paths: paths))
    }

    func testExactValidCoverageStillProceedsToSynthesisThroughPreSynthesisChecks() async throws {
        let snapshot = makeSnapshotAndFingerprint(unitCount: 1)
        // Never switches — the same snapshot is returned on every call,
        // exercising the new pre-synthesis checks on an unchanged source.
        let loader = SwitchableSourceSnapshotLoader(before: snapshot, switchAfterCallCount: .max, after: snapshot)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget(), sourceLoader: loader)

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = finalPhase else { return XCTFail("expected completed, got \(finalPhase)") }
        let synthCount = await generator.synthesizeCallCount
        XCTAssertEqual(synthCount, 1)
    }

    // MARK: - Correction cluster 2: operation-state fingerprint + overflow-safe attempt count

    func testMismatchedOperationStateFingerprintCausesControlledTerminalFailure() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 0) }
        service.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service)
        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)

        // Nothing committed yet — cancellation happened before window 0's
        // first commit.
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 0)
        XCTAssertNil(try notesStore.loadDocument(paths: paths))

        let foreignFingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "f", count: 64))
        try operationStateStore.saveOperationState(
            NotesGenerationOperationState(
                sessionID: sessionID, generationID: generationID, transcriptFingerprint: foreignFingerprint,
                activeRunID: UUID(), runAttemptCount: 500, lifecycle: .failed, failureDescription: "foreign"
            ),
            paths: paths
        )

        let secondGenerator = ControllableFakeLectureNotesGenerator()
        let secondService = makeService(generator: secondGenerator, windowBudget: try oneUnitPerWindowBudget())
        XCTAssertEqual(secondService.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(secondService)
        guard case .finished(.failed) = finalPhase else { return XCTFail("expected a controlled failed outcome, got \(finalPhase)") }

        let analyzeCalls = await secondGenerator.analyzeCalls
        let synthCount = await secondGenerator.synthesizeCallCount
        XCTAssertEqual(analyzeCalls, [], "a mismatched operation-state fingerprint must stop the run before any window is analyzed")
        XCTAssertEqual(synthCount, 0, "a mismatched operation-state fingerprint must stop the run before synthesis")

        // Canonical artifacts remain exactly as they were before this
        // attempt — untouched, never modified or deleted.
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 0)
        XCTAssertNil(try notesStore.loadDocument(paths: paths))
        XCTAssertNotNil(try notesStore.loadGeneration(paths: paths))

        // The mismatched operation-state artifact itself is never silently
        // rewritten or repaired.
        let stateAfter = try XCTUnwrap(operationStateStore.loadOperationState(paths: paths))
        XCTAssertEqual(stateAfter.transcriptFingerprint, foreignFingerprint)
        XCTAssertEqual(stateAfter.runAttemptCount, 500)
    }

    func testAbsentOperationStateStillFollowsNormalResumePath() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        await generator.armGate(beforeWindowIndex: 0)
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forWindowIndex: 0) }
        service.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service)
        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)

        // No operation-state artifact exists at all for this generation.
        // Checked via a plain POSIX path-existence query, not
        // `operationStateStore.loadOperationState` again on the same `URL`
        // value the store already read moments earlier — `URL.resourceValues`
        // caches per-instance, and immediately re-querying the identical
        // `URL` value right after deleting its target is not a reliable way
        // to observe the deletion from this test.
        try FileManager.default.removeItem(at: paths.operationStateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.operationStateURL.path))

        let secondGenerator = ControllableFakeLectureNotesGenerator()
        let secondService = makeService(generator: secondGenerator, windowBudget: try oneUnitPerWindowBudget())
        XCTAssertEqual(secondService.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(secondService)
        guard case .finished(.completed) = finalPhase else { return XCTFail("expected completed, got \(finalPhase)") }
        let calls = await secondGenerator.analyzeCalls
        XCTAssertEqual(calls, [0])
    }

    func testNegativeRunAttemptCountIsRejectedWithoutGeneratorInvocation() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let firstPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = firstPhase else { return XCTFail("expected completed, got \(firstPhase)") }
        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let generation = try XCTUnwrap(notesStore.loadGeneration(paths: paths))

        try FileManager.default.removeItem(at: paths.documentURL)
        try FileManager.default.removeItem(at: paths.windowAnalysisURL(windowIndex: 0))
        try operationStateStore.saveOperationState(
            NotesGenerationOperationState(
                sessionID: sessionID, generationID: generationID, transcriptFingerprint: generation.transcriptFingerprint,
                activeRunID: UUID(), runAttemptCount: -1, lifecycle: .failed, failureDescription: "bad"
            ),
            paths: paths
        )

        let secondGenerator = ControllableFakeLectureNotesGenerator()
        let secondService = makeService(generator: secondGenerator, windowBudget: try oneUnitPerWindowBudget())
        XCTAssertEqual(secondService.retry(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(secondService)
        guard case .finished(.failed) = finalPhase else { return XCTFail("expected failed, got \(finalPhase)") }
        let calls = await secondGenerator.analyzeCalls
        XCTAssertEqual(calls, [])
    }

    func testRunAttemptCountAtIntMaxIsRejectedWithoutTrapping() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(generator: generator, windowBudget: try oneUnitPerWindowBudget())

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let firstPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = firstPhase else { return XCTFail("expected completed, got \(firstPhase)") }
        let generationID = try onlyGenerationID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let generation = try XCTUnwrap(notesStore.loadGeneration(paths: paths))

        try FileManager.default.removeItem(at: paths.documentURL)
        try FileManager.default.removeItem(at: paths.windowAnalysisURL(windowIndex: 0))
        try operationStateStore.saveOperationState(
            NotesGenerationOperationState(
                sessionID: sessionID, generationID: generationID, transcriptFingerprint: generation.transcriptFingerprint,
                activeRunID: UUID(), runAttemptCount: Int.max, lifecycle: .failed, failureDescription: "bad"
            ),
            paths: paths
        )

        let secondGenerator = ControllableFakeLectureNotesGenerator()
        let secondService = makeService(generator: secondGenerator, windowBudget: try oneUnitPerWindowBudget())
        // Proves no Int trap occurs merely by reaching a normal, observed
        // `.failed` outcome instead of crashing the test process.
        XCTAssertEqual(secondService.retry(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(secondService)
        guard case .finished(.failed) = finalPhase else { return XCTFail("expected failed, got \(finalPhase)") }
        let calls = await secondGenerator.analyzeCalls
        XCTAssertEqual(calls, [])
    }

    // MARK: - Correction cluster 3: generation-record durability uncertainty

    func testGenerationRecordDurabilityUncertainPreventsAnyGeneratorInvocation() async throws {
        try await writeCompletedTranscribedSession(chunkCount: 1)
        let knownGenerationID = UUID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: knownGenerationID)

        let spyFileSystem = SpyNotesExclusiveArtifactFileSystem()
        spyFileSystem.forceOutcome(.createdDurabilityUncertain, forURL: paths.generationRecordURL)
        let spyNotesStore = LectureNotesStore(fileSystem: spyFileSystem)
        let generator = ControllableFakeLectureNotesGenerator()
        let service = makeService(
            generator: generator,
            notesStore: spyNotesStore,
            windowBudget: try oneUnitPerWindowBudget(),
            generationIDProvider: { knownGenerationID }
        )

        XCTAssertEqual(service.generate(sessionID: sessionID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.failed) = finalPhase else { return XCTFail("expected failed, got \(finalPhase)") }

        let analyzeCalls = await generator.analyzeCalls
        let synthCount = await generator.synthesizeCallCount
        XCTAssertEqual(analyzeCalls, [], "no window generator work may start after an uncertain generation-record commit")
        XCTAssertEqual(synthCount, 0)
        XCTAssertNil(try notesStore.loadGeneration(paths: paths))
        XCTAssertEqual(try notesStore.loadAllWindowAnalyses(paths: paths).count, 0)
        XCTAssertNil(try notesStore.loadDocument(paths: paths))

        // Explicit later recovery reloads real disk state (nothing was
        // actually durably written, since the forced outcome bypassed the
        // real create) rather than assuming the uncertain commit succeeded.
        XCTAssertEqual(service.retry(sessionID: sessionID, generationID: knownGenerationID), .admitted)
        let retryPhase = await waitUntilFinished(service)
        guard case .finished(.failed(let description)) = retryPhase else { return XCTFail("expected failed, got \(retryPhase)") }
        XCTAssertTrue(description.contains("No generation record"), "expected a 'no generation record' failure, got: \(description)")
    }
}
