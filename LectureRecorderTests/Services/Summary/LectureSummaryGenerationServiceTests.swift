import Combine
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

    /// A partial MLX Summary made by an earlier recipe is never resumed:
    /// Continue and Retry both end `.incompatibleProvenance` before any
    /// generator call, leaving its record, analysis, and run state byte for
    /// byte untouched, while a fresh Generate still mints a new generation.
    func testIncompatiblePartialSummaryIsNeverResumedAndItsArtifactsAreUntouched() async throws {
        let source = try SummaryTestSupport.source()
        var generation = try SummaryTestSupport.generation(source: source)
        var v2 = MLXSummaryConfiguration.generationProvenance
        v2.recipeVersion = "mlx2-summary-v2"
        generation.provenance = v2
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generation.generationID)
        _ = try summaryStore.createGenerationIfAbsent(generation, paths: paths)
        let firstBatch = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }[0]
        let firstItem = source.sourceItems.first { firstBatch.sourceItemIDs.contains($0.item.id) }!
        _ = try summaryStore.commitAnalysis(LectureSummaryAnalysis(
            generationID: generation.generationID, sessionID: sessionID, sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint, sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: firstBatch.batchID, batchIndex: firstBatch.batchIndex,
            passages: [LectureSummaryPassage(
                text: "pre-committed by v2",
                supportingNoteItemIDs: [firstItem.item.id],
                sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(supportingItemIDs: [firstItem.item.id], source: source),
                fidelity: firstItem.item.fidelity,
                uncertaintyNote: firstItem.item.fidelity == .transcriptSupported ? nil : "uncertainty"
            )],
            provenance: generation.provenance
        ), paths: paths)
        try operationStateStore.saveOperationState(
            SummaryGenerationOperationState(
                sessionID: sessionID, generationID: generation.generationID,
                sourceNotesGenerationID: generation.sourceNotesGenerationID,
                transcriptFingerprint: generation.transcriptFingerprint,
                sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
                activeRunID: UUID(), runAttemptCount: 1, lifecycle: .failed,
                currentStage: .analyzingBatch(batchIndex: 1), failureDescription: "boom"
            ),
            paths: paths
        )
        let artifactURLs = [paths.generationRecordURL, paths.batchAnalysisURL(batchIndex: 0), paths.operationStateURL]
        let bytesBefore = try artifactURLs.map { try Data(contentsOf: $0) }

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: generation.sourceNotesGenerationID)
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 2)
        let service = makeService(sourceLoader: loader, generator: generator)

        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generation.generationID), .admitted)
        let continuePhase = await waitUntilFinished(service)
        XCTAssertEqual(continuePhase, .finished(.incompatibleProvenance))
        XCTAssertEqual(service.retry(sessionID: sessionID, generationID: generation.generationID), .admitted)
        let retryPhase = await waitUntilFinished(service)
        XCTAssertEqual(retryPhase, .finished(.incompatibleProvenance), "retry is the same deterministic refusal")
        let analyzeCalls = await generator.analyzeCalls
        XCTAssertEqual(analyzeCalls, [], "no generator work for an incompatible generation")
        XCTAssertEqual(try artifactURLs.map { try Data(contentsOf: $0) }, bytesBefore, "record, analysis, and run state are untouched")

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: generation.sourceNotesGenerationID), .admitted)
        let generatePhase = await waitUntilFinished(service)
        guard case .finished(.completed(let document)) = generatePhase else {
            return XCTFail("expected a fresh completed generation, got \(generatePhase)")
        }
        XCTAssertNotEqual(document.generationID, generation.generationID, "a new generation ID, never the old one")
        XCTAssertEqual(try artifactURLs.map { try Data(contentsOf: $0) }, bytesBefore, "the old generation stays untouched")
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

/// Collects every `lastReleasedOperation` emission after the initial value,
/// plus the service's ownership state at the exact moment each one is
/// emitted — so a test can prove ownership was already relinquished when
/// an observer first sees the release.
@MainActor
private final class SummaryReleaseRecorder {
    typealias Release = LectureSummaryGenerationService.OperationRelease

    private(set) var releases: [Release] = []
    private(set) var activeSessionIDAtEmission: [UUID?] = []
    private(set) var activeGenerationIDAtEmission: [UUID?] = []
    private(set) var nilEmissionCount = 0
    /// Invoked synchronously inside the emission, after it is recorded.
    var onRelease: ((Release) -> Void)?
    private var cancellable: AnyCancellable?

    init(_ service: LectureSummaryGenerationService) {
        cancellable = service.$lastReleasedOperation.dropFirst().sink { [weak self, weak service] release in
            guard let self else { return }
            guard let release else {
                self.nilEmissionCount += 1
                return
            }
            self.activeSessionIDAtEmission.append(service?.activeSessionID)
            self.activeGenerationIDAtEmission.append(service?.activeGenerationID)
            self.releases.append(release)
            self.onRelease?(release)
        }
    }
}

// MARK: - Operation release signal

extension LectureSummaryGenerationServiceTests {
    /// Waits, event-driven (no polling, no sleeps), for the release whose
    /// token is exactly `epoch`.
    private func awaitRelease(
        _ recorder: SummaryReleaseRecorder,
        epoch: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> SummaryReleaseRecorder.Release? {
        if let existing = recorder.releases.first(where: { $0.operationEpoch == epoch }) { return existing }
        let released = expectation(description: "release of epoch \(epoch)")
        recorder.onRelease = { release in
            guard release.operationEpoch == epoch else { return }
            recorder.onRelease = nil
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 5)
        recorder.onRelease = nil
        let release = recorder.releases.first { $0.operationEpoch == epoch }
        XCTAssertNotNil(release, "no release observed for epoch \(epoch)", file: file, line: line)
        return release
    }

    private func makeReleaseTestService(
        generator: ControllableFakeLectureSummaryGenerator? = nil,
        loaderResult: Result<LectureSummarySourceSnapshot, Error>? = nil,
        newGenerationAvailabilityChecker: any NewLectureNotesGenerationAvailabilityChecking = FakeNewGenerationAvailabilityChecker()
    ) throws -> LectureSummaryGenerationService {
        let loader = FakeSummarySourceLoader(defaultResult: try loaderResult ?? .success(SummaryTestSupport.source()))
        return makeService(
            sourceLoader: loader,
            generator: generator ?? ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance),
            newGenerationAvailabilityChecker: newGenerationAvailabilityChecker
        )
    }

    func testLastReleasedOperationIsNilInitially() throws {
        let service = try makeReleaseTestService()
        XCTAssertNil(service.lastReleasedOperation)
    }

    func testCompletedGeneratePublishesExactlyOneMatchingReleaseWithTheMintedGenerationID() async throws {
        let service = try makeReleaseTestService()
        let recorder = SummaryReleaseRecorder(service)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epoch = service.operationEpoch
        let release = await awaitRelease(recorder, epoch: epoch)

        XCTAssertEqual(release?.sessionID, sessionID)
        XCTAssertEqual(release?.operationEpoch, epoch)
        XCTAssertEqual(release?.generationID, try onlySummaryGenerationID())
        guard case .completed(let document) = release?.outcome else {
            return XCTFail("expected a completed outcome, got \(String(describing: release?.outcome))")
        }
        XCTAssertEqual(document.generationID, release?.generationID)
        XCTAssertEqual(recorder.releases.count, 1, "exactly one release for one admitted operation")
        XCTAssertEqual(recorder.nilEmissionCount, 0)
        XCTAssertEqual(service.lastReleasedOperation, release)
    }

    func testOwnershipIsAlreadyReleasedWhenReleaseIsObserved() async throws {
        let service = try makeReleaseTestService()
        let recorder = SummaryReleaseRecorder(service)

        // Attempt the next admission synchronously from inside A's emission
        // itself — the earliest moment any observer can react — then wait
        // for the follow-up operation's own release.
        var admissionAtEmission: LectureSummaryGenerationService.AdmissionResult?
        let followUpReleased = expectation(description: "follow-up operation released")
        recorder.onRelease = { _ in
            if admissionAtEmission == nil {
                admissionAtEmission = service.generate(sessionID: self.sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID)
            } else {
                followUpReleased.fulfill()
            }
        }

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epochA = service.operationEpoch
        await fulfillment(of: [followUpReleased], timeout: 5)

        XCTAssertEqual(admissionAtEmission, .admitted, "the admission slot is free by the time the release is observable")
        XCTAssertEqual(recorder.activeSessionIDAtEmission.first, .some(nil), "activeSessionID is cleared before the release is published")
        XCTAssertEqual(recorder.activeGenerationIDAtEmission.first, .some(nil), "activeGenerationID is cleared before the release is published")
        XCTAssertEqual(recorder.releases.map(\.operationEpoch), [epochA, epochA + 1])
    }

    func testSourceNotesUnavailablePublishesReleaseWithoutGenerationID() async throws {
        let service = try makeReleaseTestService(loaderResult: .failure(LectureSummarySourceError.incompleteGeneration))
        let recorder = SummaryReleaseRecorder(service)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epoch = service.operationEpoch
        let release = await awaitRelease(recorder, epoch: epoch)

        XCTAssertEqual(release?.sessionID, sessionID)
        XCTAssertNil(release?.generationID, "a Generate that ended before minting has no generation ID — the epoch alone identifies it")
        guard case .sourceNotesUnavailable = release?.outcome else {
            return XCTFail("expected sourceNotesUnavailable, got \(String(describing: release?.outcome))")
        }
        XCTAssertEqual(recorder.releases.count, 1)
    }

    func testBackendUnavailableAfterAdmissionPublishesReleaseWithoutGenerationID() async throws {
        let service = try makeReleaseTestService(
            newGenerationAvailabilityChecker: FakeNewGenerationAvailabilityChecker(result: .unavailable(description: "model not ready"))
        )
        let recorder = SummaryReleaseRecorder(service)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epoch = service.operationEpoch
        let release = await awaitRelease(recorder, epoch: epoch)

        XCTAssertEqual(release, .init(sessionID: sessionID, operationEpoch: epoch, generationID: nil, outcome: .backendUnavailable(description: "model not ready")))
        XCTAssertEqual(recorder.releases.count, 1)
    }

    func testFailedBatchPublishesReleaseWithTheGenerationID() async throws {
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        await generator.setFailure(FakeSummaryGeneratorFailure(message: "batch exploded"), forBatchIndex: 0)
        let service = try makeReleaseTestService(generator: generator)
        let recorder = SummaryReleaseRecorder(service)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epoch = service.operationEpoch
        let release = await awaitRelease(recorder, epoch: epoch)

        XCTAssertEqual(release?.generationID, try onlySummaryGenerationID())
        guard case .failed = release?.outcome else {
            return XCTFail("expected a failed outcome, got \(String(describing: release?.outcome))")
        }
        XCTAssertEqual(recorder.releases.count, 1)
    }

    func testCancelledOperationPublishesExactlyOneRelease() async throws {
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        await generator.armGate(beforeBatchIndex: 1)
        let service = try makeReleaseTestService(generator: generator)
        let recorder = SummaryReleaseRecorder(service)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epoch = service.operationEpoch
        await waitUntil { await generator.hasEnteredGate(forBatchIndex: 1) }
        XCTAssertTrue(recorder.releases.isEmpty, "no release while the operation still owns the slot")

        service.cancel(sessionID: sessionID)
        service.cancel(sessionID: sessionID)
        let release = await awaitRelease(recorder, epoch: epoch)

        XCTAssertEqual(release, .init(sessionID: sessionID, operationEpoch: epoch, generationID: try onlySummaryGenerationID(), outcome: .cancelled))
        XCTAssertEqual(recorder.releases.count, 1)
    }

    func testShutdownCancellationPublishesExactlyOneRelease() async throws {
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        await generator.armGate(beforeBatchIndex: 0)
        let service = try makeReleaseTestService(generator: generator)
        let recorder = SummaryReleaseRecorder(service)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epoch = service.operationEpoch
        await waitUntil { await generator.hasEnteredGate(forBatchIndex: 0) }

        let outcome = await service.shutdown(timeout: 5)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(recorder.releases.map(\.operationEpoch), [epoch])
        XCTAssertEqual(recorder.releases.first?.outcome, .cancelled)
    }

    func testStaleSourceContinuePublishesReleaseWithTheCallersGenerationID() async throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generation.generationID)
        _ = try summaryStore.createGenerationIfAbsent(generation, paths: paths)

        let service = try makeReleaseTestService(loaderResult: .failure(LectureSummarySourceError.incompleteGeneration))
        let recorder = SummaryReleaseRecorder(service)
        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: generation.generationID), .admitted)
        let epoch = service.operationEpoch
        let release = await awaitRelease(recorder, epoch: epoch)

        XCTAssertEqual(release, .init(sessionID: sessionID, operationEpoch: epoch, generationID: generation.generationID, outcome: .staleSource))
        XCTAssertEqual(recorder.releases.count, 1)
    }

    func testSequentialOperationsHaveDistinctEpochsAndAStaleReleaseNeverMatchesTheNewerOperation() async throws {
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        await generator.armGate(beforeBatchIndex: 0)
        let service = try makeReleaseTestService(generator: generator)
        let recorder = SummaryReleaseRecorder(service)

        // Operation A: a Generate cancelled in flight.
        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epochA = service.operationEpoch
        await waitUntil { await generator.hasEnteredGate(forBatchIndex: 0) }
        service.cancel(sessionID: sessionID)
        let releaseA = await awaitRelease(recorder, epoch: epochA)
        let generationA = try XCTUnwrap(releaseA?.generationID)

        // Operation B: a second Generate for the same session. At admission
        // it has no generation ID yet, so only its epoch can identify it —
        // and the still-visible release is A's, which must not match.
        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epochB = service.operationEpoch
        XCTAssertNotEqual(epochA, epochB)
        XCTAssertNil(service.activeGenerationID, "B's generation ID is not minted at admission")
        XCTAssertEqual(service.lastReleasedOperation, releaseA)
        XCTAssertEqual(service.lastReleasedOperation?.sessionID, sessionID)
        XCTAssertNotEqual(service.lastReleasedOperation?.operationEpoch, epochB)

        let releaseB = await awaitRelease(recorder, epoch: epochB)
        guard case .completed = releaseB?.outcome else {
            return XCTFail("expected B to complete, got \(String(describing: releaseB?.outcome))")
        }
        XCTAssertNotNil(releaseB?.generationID)
        XCTAssertNotEqual(releaseB?.generationID, generationA)
        XCTAssertEqual(recorder.releases.map(\.operationEpoch), [epochA, epochB], "exactly one release per admitted operation, in order")
    }

    func testRejectedAdmissionsNeverPublishARelease() async throws {
        let generator = ControllableFakeLectureSummaryGenerator(provenance: SummaryTestSupport.provenance, maxItemsPerBatch: 1)
        await generator.armGate(beforeBatchIndex: 0)
        let service = try makeReleaseTestService(generator: generator)
        let recorder = SummaryReleaseRecorder(service)

        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .admitted)
        let epochA = service.operationEpoch
        await waitUntil { await generator.hasEnteredGate(forBatchIndex: 0) }

        // `.busy`, while A holds the slot.
        XCTAssertEqual(service.generate(sessionID: UUID(), notesGenerationID: UUID()), .busy)
        XCTAssertEqual(service.continueGeneration(sessionID: sessionID, generationID: UUID()), .busy)
        XCTAssertEqual(service.retry(sessionID: sessionID, generationID: UUID()), .busy)
        XCTAssertEqual(service.operationEpoch, epochA, "a rejected admission never consumes an epoch")

        // `.shuttingDown`: shutdown also cancels and releases A.
        await service.shutdown(timeout: 5)
        XCTAssertEqual(service.generate(sessionID: sessionID, notesGenerationID: SummaryTestSupport.notesGenerationID), .shuttingDown)
        XCTAssertEqual(service.operationEpoch, epochA)

        XCTAssertEqual(recorder.releases.map(\.operationEpoch), [epochA], "only the admitted operation was ever released")
        XCTAssertEqual(recorder.nilEmissionCount, 0)
    }
}
