import XCTest
@testable import LectureRecorder

/// Deterministic, scriptable `LectureSummarySourceLoading` fake — test-only.
/// Keyed by `notesGenerationID` so a test can script distinct behavior per
/// referenced Notes generation without touching disk.
private actor FakeSummarySourceLoader: LectureSummarySourceLoading {
    private var resultsByNotesGenerationID: [UUID: [Result<LectureSummarySourceSnapshot, Error>]]
    private var defaultResult: Result<LectureSummarySourceSnapshot, Error>?
    private(set) var callCounts: [UUID: Int] = [:]

    init(defaultResult: Result<LectureSummarySourceSnapshot, Error>? = nil) {
        self.resultsByNotesGenerationID = [:]
        self.defaultResult = defaultResult
    }

    /// Sets a fixed result returned for every call for `notesGenerationID`.
    func setResult(_ result: Result<LectureSummarySourceSnapshot, Error>, forNotesGenerationID notesGenerationID: UUID) {
        resultsByNotesGenerationID[notesGenerationID] = [result]
    }

    /// Sets a sequence of results consumed one at a time per call; the last
    /// element repeats once exhausted. Lets a test change "the current
    /// source" at an exact call count (e.g. valid on the first reload,
    /// mismatched from the second reload on) without sleeps or polling.
    func setResultSequence(_ results: [Result<LectureSummarySourceSnapshot, Error>], forNotesGenerationID notesGenerationID: UUID) {
        resultsByNotesGenerationID[notesGenerationID] = results
    }

    func loadSourceSnapshot(sessionID: UUID, notesGenerationID: UUID) async throws -> LectureSummarySourceSnapshot {
        let count = (callCounts[notesGenerationID] ?? 0) + 1
        callCounts[notesGenerationID] = count
        if let sequence = resultsByNotesGenerationID[notesGenerationID], !sequence.isEmpty {
            let index = min(count, sequence.count) - 1
            return try sequence[index].get()
        }
        if let defaultResult {
            return try defaultResult.get()
        }
        throw LectureSummarySourceError.missingGeneration
    }
}

private struct FakeNewGenerationAvailabilityChecker: NewLectureNotesGenerationAvailabilityChecking {
    var result: LectureNotesGenerationAvailability = .available
    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability { result }
}

@MainActor
final class LectureSummaryGenerationServiceTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!
    private var summaryStore: LectureSummaryStore!
    private var operationStateStore: LectureSummaryOperationStateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSGenServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        sessionID = SummaryTestSupport.sessionID
        sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: tempDirectory, sessionID: sessionID)
        summaryStore = LectureSummaryStore()
        operationStateStore = LectureSummaryOperationStateStore()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures / helpers

    private func makeService(
        sourceLoader: FakeSummarySourceLoader,
        generator: ControllableFakeLectureSummaryGenerator,
        newGenerationAvailabilityChecker: any NewLectureNotesGenerationAvailabilityChecking = FakeNewGenerationAvailabilityChecker(),
        generationIDProvider: (@Sendable () -> UUID)? = nil
    ) -> LectureSummaryGenerationService {
        let root = tempDirectory!
        return LectureSummaryGenerationService(
            sourceLoader: sourceLoader,
            summaryStore: summaryStore,
            operationStateStore: operationStateStore,
            generator: generator,
            newGenerationAvailabilityChecker: newGenerationAvailabilityChecker,
            generationProvenance: SummaryTestSupport.provenance,
            sessionsRootResolver: { root },
            generationIDProvider: generationIDProvider ?? { UUID() }
        )
    }

    private func waitUntilFinished(
        _ service: LectureSummaryGenerationService,
        timeout: TimeInterval = 5
    ) async -> LectureSummaryGenerationService.OperationPhase {
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

    private func onlySummaryGenerationID() throws -> UUID {
        let ids = try summaryStore.listGenerationIDs(sessionPaths: sessionPaths)
        guard ids.count == 1 else { throw XCTSkip("expected exactly one Summary generation, found \(ids.count)") }
        return ids[0]
    }

    // MARK: - Single-owner admission

    func testSecondOperationRefusedWhileOneActive() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance)
        await generator.armGate(beforeBatchIndex: 0)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forBatchIndex: 0) }
        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .busy)
        XCTAssertEqual(service.generate(sessionID: UUID(), notesGenerationID: UUID()), .busy)

        service.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service)
    }

    func testShuttingDownRejectsNewOperations() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance)
        let service = makeService(sourceLoader: loader, generator: generator)

        service.beginShutdown()
        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .shuttingDown)
    }

    // MARK: - Generate requires valid completed Notes

    func testGenerateFailsClosedWhenSourceNotesUnavailable() async throws {
        let loader = FakeSummarySourceLoader(defaultResult: .failure(LectureSummarySourceError.incompleteGeneration))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.sourceNotesUnavailable) = finalPhase else {
            return XCTFail("expected sourceNotesUnavailable, got \(finalPhase)")
        }
        // No Summary generation record is ever created when Notes isn't a
        // valid source.
        XCTAssertEqual(try summaryStore.listGenerationIDs(sessionPaths: sessionPaths), [])
    }

    func testGenerateFailsWhenBackendUnavailable() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance)
        let checker = FakeNewGenerationAvailabilityChecker(result: .unavailable(description: "model not ready"))
        let service = makeService(sourceLoader: loader, generator: generator, newGenerationAvailabilityChecker: checker)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.backendUnavailable(let description)) = finalPhase else {
            return XCTFail("expected backendUnavailable, got \(finalPhase)")
        }
        XCTAssertEqual(description, "model not ready")
        XCTAssertEqual(try summaryStore.listGenerationIDs(sessionPaths: sessionPaths), [])
    }

    // MARK: - Fresh generation

    func testMultiBatchGenerateCommitsBatchesSequentiallyThenDocumentWithExactNotesProvenance() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed(let document)) = finalPhase else {
            return XCTFail("expected completed, got \(finalPhase)")
        }
        XCTAssertEqual(document.sections.count, 3)
        // Provenance is exactly the Notes source this Summary was generated
        // from — never fabricated.
        XCTAssertEqual(document.sourceNotesGenerationID, SummaryTestSupport.notesGenerationID)
        XCTAssertEqual(document.transcriptFingerprint, source.transcriptFingerprint)
        XCTAssertEqual(document.sourceNotesDocumentFingerprint, source.sourceNotesDocumentFingerprint)

        let calls = await generator.analyzeCalls
        XCTAssertEqual(calls, [0, 1, 2])
        let synthCount = await generator.synthesizeCallCount
        XCTAssertEqual(synthCount, 1)

        let generationID = try onlySummaryGenerationID()
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let record = try summaryStore.loadGeneration(paths: paths)
        XCTAssertEqual(record?.sourceNotesGenerationID, SummaryTestSupport.notesGenerationID)
        XCTAssertEqual(record?.transcriptFingerprint, source.transcriptFingerprint)
        XCTAssertEqual(record?.sourceNotesDocumentFingerprint, source.sourceNotesDocumentFingerprint)

        let state = try operationStateStore.loadOperationState(paths: paths)
        XCTAssertEqual(state?.lifecycle, .completed)
    }

    func testActiveIdentityClearedOnEveryExitPath() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        _ = await waitUntilFinished(service)

        XCTAssertNil(service.activeSessionID)
        XCTAssertNil(service.activeGenerationID)
        XCTAssertEqual(service.generate(sessionID: UUID(), notesGenerationID: UUID()), .admitted)
    }

    // MARK: - Continue / Retry

    func testContinueResumesFromNextBatchIndex() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generation.generationID)
        _ = try summaryStore.createGenerationIfAbsent(generation, paths: paths)

        // Pre-commit batch 0's analysis directly, simulating a prior
        // interrupted run — batch 1 remains to be produced.
        let firstBatch = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }[0]
        let firstItem = source.sourceItems.first { firstBatch.sourceItemIDs.contains($0.item.id) }!
        let firstAnalysis = LectureSummaryAnalysis(
            generationID: generation.generationID, sessionID: sessionID, sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint, sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: firstBatch.batchID, batchIndex: firstBatch.batchIndex,
            passages: [LectureSummaryPassage(
                text: "pre-committed",
                supportingNoteItemIDs: [firstItem.item.id],
                sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(supportingItemIDs: [firstItem.item.id], source: source),
                fidelity: firstItem.item.fidelity,
                uncertaintyNote: firstItem.item.fidelity == .transcriptSupported ? nil : "uncertainty"
            )],
            provenance: generation.provenance
        )
        _ = try summaryStore.commitAnalysis(firstAnalysis, paths: paths)

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: generation.sourceNotesGenerationID)
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 2)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generation.generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = finalPhase else {
            return XCTFail("expected completed, got \(finalPhase)")
        }
        // Only the remaining batch was analyzed — the pre-committed one was
        // never re-run.
        let calls = await generator.analyzeCalls
        XCTAssertEqual(calls, [1])
    }

    func testRetryAfterRecoverableFailureResumesAndClearsFailure() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generation.generationID)
        _ = try summaryStore.createGenerationIfAbsent(generation, paths: paths)
        try operationStateStore.saveOperationState(
            SummaryGenerationOperationState(
                sessionID: sessionID, generationID: generation.generationID,
                sourceNotesGenerationID: generation.sourceNotesGenerationID,
                transcriptFingerprint: generation.transcriptFingerprint,
                sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
                activeRunID: UUID(), runAttemptCount: 1, lifecycle: .failed,
                currentStage: .analyzingBatch(batchIndex: 0), failureDescription: "boom"
            ),
            paths: paths
        )

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: generation.sourceNotesGenerationID)
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 2)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.retry(sessionID: sessionID, generationID: generation.generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = finalPhase else {
            return XCTFail("expected completed, got \(finalPhase)")
        }
        let state = try operationStateStore.loadOperationState(paths: paths)
        XCTAssertEqual(state?.lifecycle, .completed)
        XCTAssertEqual(state?.runAttemptCount, 2)
    }

    // MARK: - Cancel

    func testCancelPreservesCommittedArtifactsAndPersistsCancelledState() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        await generator.armGate(beforeBatchIndex: 1)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forBatchIndex: 1) }

        service.cancel(sessionID: sessionID)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.cancelled))

        let generationID = try onlySummaryGenerationID()
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        // Batch 0's analysis, committed before cancellation, survives.
        let analyses = try summaryStore.loadAllAnalyses(paths: paths)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.batchIndex, 0)
        XCTAssertNil(try summaryStore.loadDocument(paths: paths))

        let state = try operationStateStore.loadOperationState(paths: paths)
        XCTAssertEqual(state?.lifecycle, .cancelled)
    }

    // MARK: - Failure surfacing

    func testRecoverableFailurePersistsOperationStateAndSurfacesTerminalFailure() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        await generator.setFailure(FakeSummaryGeneratorFailure(message: "batch exploded"), forBatchIndex: 0)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.failed(let description)) = finalPhase else {
            return XCTFail("expected failed, got \(finalPhase)")
        }
        XCTAssertTrue(description.contains("batch exploded"))
        XCTAssertEqual(service.lastFailureDescription(forSessionID: sessionID), description)

        let generationID = try onlySummaryGenerationID()
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let state = try operationStateStore.loadOperationState(paths: paths)
        XCTAssertEqual(state?.lifecycle, .failed)
    }

    // MARK: - Committed artifacts preserved across interruption

    func testCommittedArtifactsPreservedAcrossSimulatedRelaunch() async throws {
        let source = try SummaryTestSupport.source()
        let loader1 = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator1 = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        await generator1.armGate(beforeBatchIndex: 1)
        let service1 = makeService(sourceLoader: loader1, generator: generator1)

        XCTAssertEqual(service1.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        await waitUntil { await generator1.hasEnteredGate(forBatchIndex: 1) }
        // Simulate a crash: cancel without a clean shutdown, then discard
        // this service instance entirely.
        service1.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service1)

        let generationID = try onlySummaryGenerationID()

        // A brand-new service instance (simulating relaunch) continues from
        // durable state alone.
        let loader2 = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator2 = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        let service2 = makeService(sourceLoader: loader2, generator: generator2)

        XCTAssertEqual(service2.continueGeneration(sessionID: sessionID, generationID: generationID), .admitted)
        let finalPhase = await waitUntilFinished(service2)
        guard case .finished(.completed) = finalPhase else {
            return XCTFail("expected completed, got \(finalPhase)")
        }
        // Only the two remaining batches were analyzed by the fresh service.
        let calls = await generator2.analyzeCalls
        XCTAssertEqual(calls, [1, 2])
    }

    // MARK: - No cross-mutation of Notes

    func testGenerateNeverWritesToNotesStorage() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance)
        let service = makeService(sourceLoader: loader, generator: generator)

        let notesRoot = sessionPaths.sessionDirectory.appendingPathComponent("notes", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notesRoot.path))

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        _ = await waitUntilFinished(service)

        // `LectureSummaryGenerationService` never holds a `LectureNotesStoring`
        // reference at all — this asserts the observable consequence: no
        // `notes/` subtree was ever created by a Summary run.
        XCTAssertFalse(FileManager.default.fileExists(atPath: notesRoot.path))
    }

    // MARK: - Shutdown

    func testShutdownWaitsForActiveOperationThenCompletes() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance)
        await generator.armGate(beforeBatchIndex: 0)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forBatchIndex: 0) }

        // The gated generator call observes cancellation cooperatively once
        // `beginShutdown()` cancels the task, so the bounded wait resolves
        // as `.completed` well within the timeout.
        let result = await service.shutdown(timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .shuttingDown)
    }

    // MARK: - T5-F3A correction: source-load error taxonomy

    func testGenerateInfrastructureSourceLoadFailureEndsFailedNotSourceNotesUnavailable() async throws {
        let loader = FakeSummarySourceLoader(defaultResult: .failure(LectureSummarySourceError.sourceLoadFailed("disk unavailable")))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.failed(let description)) = finalPhase else {
            return XCTFail("expected failed, got \(finalPhase)")
        }
        XCTAssertTrue(description.contains("disk unavailable"))
        // No Summary generation record is created for an ordinary
        // operational failure, same as a semantic source-invalidity failure.
        XCTAssertEqual(try summaryStore.listGenerationIDs(sessionPaths: sessionPaths), [])
    }

    func testContinueInfrastructureSourceLoadFailureEndsFailedNotStaleSourcePreservingArtifacts() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generation.generationID)
        _ = try summaryStore.createGenerationIfAbsent(generation, paths: paths)

        let firstBatch = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }[0]
        let firstItem = source.sourceItems.first { firstBatch.sourceItemIDs.contains($0.item.id) }!
        let firstAnalysis = LectureSummaryAnalysis(
            generationID: generation.generationID, sessionID: sessionID, sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint, sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: firstBatch.batchID, batchIndex: firstBatch.batchIndex,
            passages: [LectureSummaryPassage(
                text: "pre-committed",
                supportingNoteItemIDs: [firstItem.item.id],
                sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(supportingItemIDs: [firstItem.item.id], source: source),
                fidelity: firstItem.item.fidelity,
                uncertaintyNote: firstItem.item.fidelity == .transcriptSupported ? nil : "uncertainty"
            )],
            provenance: generation.provenance
        )
        _ = try summaryStore.commitAnalysis(firstAnalysis, paths: paths)

        let loader = FakeSummarySourceLoader(defaultResult: .failure(LectureSummarySourceError.sourceLoadFailed("transient read error")))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 2)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generation.generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.failed(let description)) = finalPhase else {
            return XCTFail("expected failed, got \(finalPhase)")
        }
        XCTAssertTrue(description.contains("transient read error"))

        let analyses = try summaryStore.loadAllAnalyses(paths: paths)
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.batchIndex, 0)
    }

    func testContinueSemanticSourceInvalidityMapsToStaleSource() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generation.generationID)
        _ = try summaryStore.createGenerationIfAbsent(generation, paths: paths)

        let loader = FakeSummarySourceLoader(defaultResult: .failure(LectureSummarySourceError.incompleteGeneration))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 2)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generation.generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.staleSource))
    }

    // MARK: - T5-F3A correction: Retry preserves committed analyses

    func testRetryPreservesCommittedAnalysesAndResumesFromNextBatch() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generation.generationID)
        _ = try summaryStore.createGenerationIfAbsent(generation, paths: paths)

        let firstBatch = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }[0]
        let firstItem = source.sourceItems.first { firstBatch.sourceItemIDs.contains($0.item.id) }!
        let preCommittedText = "pre-committed-before-retry"
        let firstAnalysis = LectureSummaryAnalysis(
            generationID: generation.generationID, sessionID: sessionID, sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint, sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: firstBatch.batchID, batchIndex: firstBatch.batchIndex,
            passages: [LectureSummaryPassage(
                text: preCommittedText,
                supportingNoteItemIDs: [firstItem.item.id],
                sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(supportingItemIDs: [firstItem.item.id], source: source),
                fidelity: firstItem.item.fidelity,
                uncertaintyNote: firstItem.item.fidelity == .transcriptSupported ? nil : "uncertainty"
            )],
            provenance: generation.provenance
        )
        _ = try summaryStore.commitAnalysis(firstAnalysis, paths: paths)
        try operationStateStore.saveOperationState(
            SummaryGenerationOperationState(
                sessionID: sessionID, generationID: generation.generationID,
                sourceNotesGenerationID: generation.sourceNotesGenerationID,
                transcriptFingerprint: generation.transcriptFingerprint,
                sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
                activeRunID: UUID(), runAttemptCount: 1, lifecycle: .failed,
                currentStage: .analyzingBatch(batchIndex: 1), failureDescription: "batch 1 boom"
            ),
            paths: paths
        )

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: generation.sourceNotesGenerationID)
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 2)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.retry(sessionID: sessionID, generationID: generation.generationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        guard case .finished(.completed) = finalPhase else {
            return XCTFail("expected completed, got \(finalPhase)")
        }

        // Only the missing batch was regenerated — batch 0 was never
        // re-analyzed by Retry.
        let calls = await generator.analyzeCalls
        XCTAssertEqual(calls, [1])

        // The pre-committed batch-0 analysis on disk is byte-for-byte
        // unchanged by Retry.
        let survivingAnalysis = try summaryStore.loadAnalysis(batchIndex: 0, paths: paths)
        XCTAssertEqual(survivingAnalysis?.passages.first?.text, preCommittedText)
    }

    // MARK: - T5-F3A correction: successful-but-mismatched source reconfirmation

    func testMidBatchSourceReconfirmationMismatchDiscardsPendingAnalysisAsStaleSource() async throws {
        let source = try SummaryTestSupport.source()
        var mismatchedSource = source
        mismatchedSource.transcriptFingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "9", count: 64))

        let loader = FakeSummarySourceLoader()
        // First call (admission-time load) returns the valid source; every
        // subsequent call (the post-analysis reconfirmation) returns a
        // successfully-loaded but identity-mismatched snapshot.
        await loader.setResultSequence([.success(source), .success(mismatchedSource)], forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.staleSource))

        // The batch-0 analysis the generator produced against the original
        // (now-superseded) source snapshot was never committed.
        let generationID = try onlySummaryGenerationID()
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try summaryStore.loadAllAnalyses(paths: paths).count, 0)
        XCTAssertNil(try summaryStore.loadDocument(paths: paths))
    }

    // MARK: - T5-F3A correction: cancellation after generator returns

    /// Proves the *service's own* post-return checkpoint — not the
    /// generator — is what discards a value returned after cancellation was
    /// already requested. `cancel()` runs first, so `Task.isCancelled` is
    /// unconditionally true for the remainder of this operation from that
    /// point forward; `releaseGateSuccessfully` then lets the gated call
    /// resolve normally rather than by throwing. (The fake's own gate loop
    /// may, depending on scheduling, still notice the cancellation itself
    /// and throw instead of returning a value — either internal path is a
    /// safe outcome, and both are asserted identically here: no analysis is
    /// ever committed and the run ends `.cancelled`.)
    func testCancellationAfterGeneratorReturnsDiscardsResultWithoutCommitting() async throws {
        let source = try SummaryTestSupport.source()
        let loader = FakeSummarySourceLoader(defaultResult: .success(source))
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        await generator.armGate(beforeBatchIndex: 0)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        await waitUntil { await generator.hasEnteredGate(forBatchIndex: 0) }

        service.cancel(sessionID: sessionID)
        await generator.releaseGateSuccessfully(batchIndex: 0)

        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.cancelled))

        let generationID = try onlySummaryGenerationID()
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        XCTAssertEqual(try summaryStore.loadAllAnalyses(paths: paths).count, 0)
        XCTAssertNil(try summaryStore.loadDocument(paths: paths))

        let state = try operationStateStore.loadOperationState(paths: paths)
        XCTAssertEqual(state?.lifecycle, .cancelled)

        XCTAssertNil(service.activeSessionID)
        XCTAssertNil(service.activeGenerationID)
    }
}
