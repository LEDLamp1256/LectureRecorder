import XCTest
@testable import LectureRecorder

/// Deterministic, scriptable `LectureSummarySourceLoading` fake — test-only.
/// Keyed by `notesGenerationID` so a test can script distinct behavior per
/// referenced Notes generation without touching disk, and can gate one
/// specific key's call indefinitely so
/// `testStaleAsyncLoadCannotOverwriteNewerSelection` can deterministically
/// get the presenter's sole `await` point genuinely in flight before a
/// newer selection completes. Mirrors `FakeSummarySourceLoader` from
/// `LectureSummaryGenerationServiceTests.swift` (private to that file, so
/// re-declared here) plus the gating pattern from
/// `SessionNotesPresenterTests.StubNotesTranscriptSourceLoader`.
private actor FakeSummarySourceLoader: LectureSummarySourceLoading {
    private var resultsByNotesGenerationID: [UUID: Result<LectureSummarySourceSnapshot, Error>] = [:]
    private var gatedNotesGenerationIDs: Set<UUID> = []
    private var pendingContinuation: CheckedContinuation<Void, Never>?
    private var hasEnteredGateFlag = false

    func setResult(_ result: Result<LectureSummarySourceSnapshot, Error>, forNotesGenerationID notesGenerationID: UUID) {
        resultsByNotesGenerationID[notesGenerationID] = result
    }

    func setGated(_ notesGenerationID: UUID) {
        gatedNotesGenerationIDs.insert(notesGenerationID)
    }

    var hasEnteredGate: Bool { hasEnteredGateFlag }

    func releaseGate() {
        pendingContinuation?.resume()
        pendingContinuation = nil
    }

    func loadSourceSnapshot(sessionID: UUID, notesGenerationID: UUID) async throws -> LectureSummarySourceSnapshot {
        if gatedNotesGenerationIDs.contains(notesGenerationID) {
            hasEnteredGateFlag = true
            await withCheckedContinuation { continuation in
                self.pendingContinuation = continuation
            }
        }
        guard let result = resultsByNotesGenerationID[notesGenerationID] else {
            throw LectureSummarySourceError.missingGeneration
        }
        return try result.get()
    }
}

@MainActor
final class SessionSummaryPresenterTests: XCTestCase {
    private var tempDirectory: URL!
    private var notesStore: LectureNotesStore!
    private var summaryStore: LectureSummaryStore!
    private var summaryOperationStateStore: LectureSummaryOperationStateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummaryPresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        notesStore = LectureNotesStore()
        summaryStore = LectureSummaryStore()
        summaryOperationStateStore = LectureSummaryOperationStateStore()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures / helpers

    private func makeEntry(sessionID: UUID) -> CompletedSessionEntry {
        let audioFormat = AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
        var manifest = SessionManifest.newSession(id: sessionID, audioFormat: audioFormat, targetChunkDurationSeconds: 30)
        manifest.status = .completed
        manifest.endedCleanly = true
        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: tempDirectory, sessionID: sessionID)
        return CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)
    }

    private func makePresenter(sourceLoader: any LectureSummarySourceLoading) -> SessionSummaryPresenter {
        SessionSummaryPresenter(
            summaryStore: summaryStore,
            summaryOperationStateStore: summaryOperationStateStore,
            notesStore: notesStore,
            summarySourceLoader: sourceLoader
        )
    }

    /// Commits a minimal Notes generation record — content beyond identity
    /// fields is irrelevant to `SummaryNotesSourceSelection`, which only
    /// checks generation existence/`createdDate` ordering and whether a
    /// document has been committed.
    @discardableResult
    private func commitNotesGeneration(
        sessionID: UUID,
        sessionPaths: SessionPaths,
        generationID: UUID,
        createdDate: Date,
        fingerprint: TranscriptSourceFingerprint = TranscriptSourceFingerprint(algorithmVersion: TranscriptSourceFingerprint.currentAlgorithmVersion, digestHex: String(repeating: "b", count: 64))
    ) throws -> LectureNotesGenerationRecord {
        let record = LectureNotesGenerationRecord.newGeneration(
            generationID: generationID,
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            windowPlan: NotesWindowPlan(windows: [
                NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 0, unitCount: 1, isOversizedSingleUnit: false)
            ]),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            now: createdDate
        )
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let outcome = try notesStore.createGenerationIfAbsent(record, paths: paths)
        XCTAssertTrue(outcome == .created || outcome == .alreadyExistsIdentical)
        return record
    }

    @discardableResult
    private func commitNotesDocument(
        record: LectureNotesGenerationRecord,
        sessionPaths: SessionPaths
    ) throws -> LectureNotesDocument {
        let document = LectureNotesDocument(
            generationID: record.generationID,
            sessionID: record.sessionID,
            transcriptFingerprint: record.transcriptFingerprint,
            provenance: record.provenance,
            createdDate: record.createdDate,
            overview: "Overview.",
            sections: [
                LectureNoteSection(heading: "Section", items: [
                    LectureNoteItem(kind: .explanation, body: "body", fidelity: .transcriptSupported, sourceReferences: [])
                ])
            ]
        )
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: record.sessionID, generationID: record.generationID)
        _ = try notesStore.commitDocument(document, paths: paths)
        return document
    }

    /// Commits the exact Notes evidence `SummaryTestSupport` builds Summary
    /// fixtures against, so `SummaryNotesSourceSelection` resolves
    /// `SummaryTestSupport.notesGenerationID` as the current usable Notes
    /// generation for `SummaryTestSupport.sessionID`.
    @discardableResult
    private func commitSummaryTestSupportNotesEvidence(sessionPaths: SessionPaths) throws -> (LectureNotesGenerationRecord, LectureNotesDocument) {
        let evidence = SummaryTestSupport.notesEvidence()
        let paths = try NotesArtifactPaths.validated(
            sessionPaths: sessionPaths,
            sessionID: SummaryTestSupport.sessionID,
            generationID: SummaryTestSupport.notesGenerationID
        )
        _ = try notesStore.createGenerationIfAbsent(evidence.0, paths: paths)
        _ = try notesStore.commitDocument(evidence.1, paths: paths)
        return (evidence.0, evidence.1)
    }

    @discardableResult
    private func commitSummaryGeneration(
        _ record: LectureSummaryGenerationRecord,
        sessionPaths: SessionPaths
    ) throws -> SummaryArtifactPaths {
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: record.sessionID, generationID: record.generationID)
        let outcome = try summaryStore.createGenerationIfAbsent(record, paths: paths)
        XCTAssertTrue(outcome == .created || outcome == .alreadyExistsIdentical)
        return paths
    }

    /// Commits one valid, fully-grounded analysis per `batches`, each
    /// passage using `.uncertain` fidelity with a nonempty explanation so it
    /// satisfies `LectureSummaryIntegrityValidator`'s fidelity-rank
    /// requirement regardless of which source items the planner assigned to
    /// that particular batch.
    @discardableResult
    private func commitAnalyses(
        batches: [LectureSummaryBatch],
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot,
        sessionPaths: SessionPaths
    ) throws -> [LectureSummaryAnalysis] {
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: generation.sessionID, generationID: generation.generationID)
        var result: [LectureSummaryAnalysis] = []
        for batch in batches {
            let passage = try SummaryTestSupport.passage(
                id: UUID(),
                support: batch.sourceItemIDs,
                fidelity: .uncertain,
                uncertaintyNote: "test uncertainty",
                source: source
            )
            let analysis = LectureSummaryAnalysis(
                generationID: generation.generationID,
                sessionID: generation.sessionID,
                sourceNotesGenerationID: generation.sourceNotesGenerationID,
                transcriptFingerprint: generation.transcriptFingerprint,
                sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
                batchID: batch.batchID,
                batchIndex: batch.batchIndex,
                passages: [passage],
                provenance: generation.provenance
            )
            _ = try summaryStore.commitAnalysis(analysis, paths: paths)
            result.append(analysis)
        }
        return result
    }

    private func makeSummaryDocument(
        generation: LectureSummaryGenerationRecord,
        analyses: [LectureSummaryAnalysis],
        createdDate: Date = Date(timeIntervalSince1970: 1_700_000_100)
    ) -> LectureSummaryDocument {
        LectureSummaryDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: generation.provenance,
            createdDate: createdDate,
            sections: [
                LectureSummarySection(
                    heading: "Summary",
                    passages: analyses.sorted { $0.batchIndex < $1.batchIndex }.flatMap(\.passages)
                )
            ]
        )
    }

    @discardableResult
    private func commitSummaryDocument(
        _ document: LectureSummaryDocument,
        sessionPaths: SessionPaths
    ) throws -> SummaryDocumentCommitOutcome {
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: document.sessionID, generationID: document.generationID)
        return try summaryStore.commitDocument(document, paths: paths)
    }

    private func saveSummaryOperationState(
        lifecycle: SummaryGenerationOperationLifecycle,
        failureDescription: String? = nil,
        matchingIdentityOf generation: LectureSummaryGenerationRecord,
        sessionPaths: SessionPaths,
        mismatchedSourceNotesGenerationID: UUID? = nil
    ) throws {
        let paths = try SummaryArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: generation.sessionID, generationID: generation.generationID)
        let state = SummaryGenerationOperationState(
            sessionID: generation.sessionID,
            generationID: generation.generationID,
            sourceNotesGenerationID: mismatchedSourceNotesGenerationID ?? generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            activeRunID: UUID(),
            runAttemptCount: 1,
            lifecycle: lifecycle,
            failureDescription: failureDescription
        )
        try summaryOperationStateStore.saveOperationState(state, paths: paths)
    }

    // MARK: - Initial state

    func testInitialStateIsLoading() {
        let presenter = makePresenter(sourceLoader: FakeSummarySourceLoader())
        XCTAssertEqual(presenter.displayState, .loading)
        XCTAssertNil(presenter.currentUsableNotesGenerationID)
    }

    // MARK: - Notes-source selection (independent of any Summary generation)

    func testNoNotesGenerationsPublishesNoValidNotesSource() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let presenter = makePresenter(sourceLoader: FakeSummarySourceLoader())

        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.displayedSessionID, sessionID)
        XCTAssertEqual(presenter.displayState, .noValidNotesSource)
        XCTAssertNil(presenter.currentUsableNotesGenerationID)
    }

    func testCurrentNotesGenerationWithoutCompletedDocumentPublishesNoValidNotesSource() async throws {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        _ = try commitNotesGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: UUID(), createdDate: Date(timeIntervalSince1970: 1_700_000_000))
        // Deliberately no document committed.
        let presenter = makePresenter(sourceLoader: FakeSummarySourceLoader())

        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.displayState, .noValidNotesSource)
        XCTAssertNil(presenter.currentUsableNotesGenerationID)
    }

    func testCompletedCurrentNotesGenerationWithNoSummaryPublishesNoGeneration() async throws {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let generationID = UUID()
        let record = try commitNotesGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: generationID, createdDate: Date(timeIntervalSince1970: 1_700_000_000))
        try commitNotesDocument(record: record, sessionPaths: entry.sessionPaths)
        let presenter = makePresenter(sourceLoader: FakeSummarySourceLoader())

        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.displayState, .noGeneration(notesGenerationID: generationID))
        XCTAssertEqual(presenter.currentUsableNotesGenerationID, generationID)
    }

    func testChoosesNewestNotesGenerationAsCurrent() async throws {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let older = try commitNotesGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: UUID(), createdDate: Date(timeIntervalSince1970: 1_000))
        try commitNotesDocument(record: older, sessionPaths: entry.sessionPaths)
        let newer = try commitNotesGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: UUID(), createdDate: Date(timeIntervalSince1970: 2_000))
        try commitNotesDocument(record: newer, sessionPaths: entry.sessionPaths)
        let presenter = makePresenter(sourceLoader: FakeSummarySourceLoader())

        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.currentUsableNotesGenerationID, newer.generationID)
    }

    func testNotesGenerationTieBreaksByGreaterUUIDString() async throws {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let a = try commitNotesGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: lowerID, createdDate: sameDate)
        try commitNotesDocument(record: a, sessionPaths: entry.sessionPaths)
        let b = try commitNotesGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: higherID, createdDate: sameDate)
        try commitNotesDocument(record: b, sessionPaths: entry.sessionPaths)
        let presenter = makePresenter(sourceLoader: FakeSummarySourceLoader())

        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.currentUsableNotesGenerationID, higherID)
    }

    func testNoFallbackToOlderCompletedNotesGenerationWhenCurrentIsIncomplete() async throws {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let older = try commitNotesGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: UUID(), createdDate: Date(timeIntervalSince1970: 1_000))
        try commitNotesDocument(record: older, sessionPaths: entry.sessionPaths)
        // Newer generation is current by createdDate but has no document —
        // must never silently fall back to `older`.
        _ = try commitNotesGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, generationID: UUID(), createdDate: Date(timeIntervalSince1970: 2_000))
        let presenter = makePresenter(sourceLoader: FakeSummarySourceLoader())

        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.displayState, .noValidNotesSource)
        XCTAssertNil(presenter.currentUsableNotesGenerationID)
    }

    func testNotesGenerationListedButMissingRecordPublishesLoadError() async throws {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let phantomID = UUID()
        let paths = try NotesArtifactPaths.validated(sessionPaths: entry.sessionPaths, sessionID: sessionID, generationID: phantomID)
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)
        let presenter = makePresenter(sourceLoader: FakeSummarySourceLoader())

        await presenter.refresh(for: entry)

        guard case .loadError = presenter.displayState else {
            return XCTFail("expected .loadError, got \(presenter.displayState)")
        }
    }

    // MARK: - Existing Summary generation recovery classification

    func testCompatibleCompletedSummaryPublishesCompleted() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)
        let orderedBatches = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        let analyses = try commitAnalyses(batches: orderedBatches, generation: generation, source: source, sessionPaths: entry.sessionPaths)
        let document = makeSummaryDocument(generation: generation, analyses: analyses)
        _ = try commitSummaryDocument(document, sessionPaths: entry.sessionPaths)

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        XCTAssertEqual(
            presenter.displayState,
            .loaded(record: generation, classification: .completed(document: document), advisoryStateIntegrity: .normal)
        )
        XCTAssertEqual(presenter.currentUsableNotesGenerationID, SummaryTestSupport.notesGenerationID)
    }

    func testReadyForSynthesisPublishesReadyForSynthesis() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)
        let orderedBatches = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        let analyses = try commitAnalyses(batches: orderedBatches, generation: generation, source: source, sessionPaths: entry.sessionPaths)
        // No document committed.

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(let loadedRecord, .readyForSynthesis(let loadedAnalyses), .normal) = presenter.displayState else {
            return XCTFail("expected .loaded(.readyForSynthesis), got \(presenter.displayState)")
        }
        XCTAssertEqual(loadedRecord, generation)
        XCTAssertEqual(Set(loadedAnalyses.map(\.batchIndex)), Set(analyses.map(\.batchIndex)))
    }

    func testResumableInterruptedGenerationWithAbsentAdvisoryStateIsNormal() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)
        let orderedBatches = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        try XCTSkipUnless(orderedBatches.count >= 2, "test requires at least two planned batches")
        _ = try commitAnalyses(batches: [orderedBatches[0]], generation: generation, source: source, sessionPaths: entry.sessionPaths)
        // No operation state committed — advisory state is absent, not a problem.

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        XCTAssertEqual(
            presenter.displayState,
            .loaded(record: generation, classification: .resumable(nextBatchIndex: 1, interruption: .notStarted), advisoryStateIntegrity: .normal)
        )
    }

    func testResumableWithRecoverableFailureAdvisoryStateMatchingIsNormal() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)
        let orderedBatches = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        try XCTSkipUnless(orderedBatches.count >= 2, "test requires at least two planned batches")
        _ = try commitAnalyses(batches: [orderedBatches[0]], generation: generation, source: source, sessionPaths: entry.sessionPaths)
        try saveSummaryOperationState(lifecycle: .failed, failureDescription: "boom", matchingIdentityOf: generation, sessionPaths: entry.sessionPaths)

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        XCTAssertEqual(
            presenter.displayState,
            .loaded(
                record: generation,
                classification: .resumable(nextBatchIndex: 1, interruption: .recoverableFailure(description: "boom")),
                advisoryStateIntegrity: .normal
            )
        )
    }

    func testMismatchedAdvisoryStateIsProblemAndFallsBackToNotStarted() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)
        let orderedBatches = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        try XCTSkipUnless(orderedBatches.count >= 2, "test requires at least two planned batches")
        _ = try commitAnalyses(batches: [orderedBatches[0]], generation: generation, source: source, sessionPaths: entry.sessionPaths)
        try saveSummaryOperationState(
            lifecycle: .failed,
            failureDescription: "boom",
            matchingIdentityOf: generation,
            sessionPaths: entry.sessionPaths,
            mismatchedSourceNotesGenerationID: UUID()
        )

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(let loadedRecord, let classification, let advisoryStateIntegrity) = presenter.displayState else {
            return XCTFail("expected .loaded, got \(presenter.displayState)")
        }
        XCTAssertEqual(loadedRecord, generation)
        XCTAssertEqual(classification, .resumable(nextBatchIndex: 1, interruption: .notStarted))
        guard case .problem = advisoryStateIntegrity else {
            return XCTFail("expected advisory .problem, got \(advisoryStateIntegrity)")
        }
    }

    func testDamagedClassificationForAnalysisOutsidePlan() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)
        let outsideBatchIndex = 999
        let passage = try SummaryTestSupport.passage(source: source)
        let analysis = LectureSummaryAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: LectureSummaryPlanner.batchID(outsideBatchIndex),
            batchIndex: outsideBatchIndex,
            passages: [passage],
            provenance: generation.provenance
        )
        _ = try summaryStore.commitAnalysis(analysis, paths: paths)

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        XCTAssertEqual(
            presenter.displayState,
            .loaded(record: generation, classification: .damaged(reason: .analysisOutsidePlan(batchIndex: outsideBatchIndex)), advisoryStateIntegrity: .normal)
        )
    }

    func testDamagedClassificationForCorruptCommittedAnalysis() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)
        let batchIndex = generation.batchPlan.batches.map(\.batchIndex).min()!
        try FileManager.default.createDirectory(at: paths.batchAnalysesDirectory, withIntermediateDirectories: true)
        let url = paths.batchAnalysisURL(batchIndex: batchIndex)
        try Data("not valid json".utf8).write(to: url)

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(let loadedRecord, .damaged(.corruptOrInvalidAnalysis(let damagedBatchIndex, _)), .normal) = presenter.displayState else {
            return XCTFail("expected .loaded(.damaged(.corruptOrInvalidAnalysis)), got \(presenter.displayState)")
        }
        XCTAssertEqual(loadedRecord, generation)
        XCTAssertEqual(damagedBatchIndex, batchIndex)
    }

    func testStaleSourceViaClassifierIdentityMismatch() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)
        let orderedBatches = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        _ = try commitAnalyses(batches: orderedBatches, generation: generation, source: source, sessionPaths: entry.sessionPaths)

        // The loader returns a *different*, structurally valid source
        // (mismatched document fingerprint) for the exact pinned Notes
        // generation ID — the load itself succeeds, but the classifier's
        // own identity guard must detect the disagreement.
        var mismatchedSource = source
        mismatchedSource.sourceNotesDocumentFingerprint = NotesDocumentFingerprint(
            algorithmVersion: NotesDocumentFingerprint.currentAlgorithmVersion,
            digestHex: String(repeating: "f", count: 64)
        )
        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(mismatchedSource), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        XCTAssertEqual(
            presenter.displayState,
            .loaded(record: generation, classification: .staleSource, advisoryStateIntegrity: .normal)
        )
    }

    func testStaleSourceViaSourceLoaderSemanticInvalidity() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.failure(LectureSummarySourceError.missingGeneration), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        XCTAssertEqual(
            presenter.displayState,
            .loaded(record: generation, classification: .staleSource, advisoryStateIntegrity: .normal)
        )
        // The presenter's own current-Notes selection is unaffected by the
        // existing Summary generation's pinned source becoming invalid.
        XCTAssertEqual(presenter.currentUsableNotesGenerationID, SummaryTestSupport.notesGenerationID)
    }

    func testInfrastructureSourceLoadFailurePublishesLoadErrorNotStale() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.failure(LectureSummarySourceError.sourceLoadFailed("disk hiccup")), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loadError = presenter.displayState else {
            return XCTFail("expected .loadError, got \(presenter.displayState)")
        }
    }

    // MARK: - Current-Notes selection independent of an existing stale Summary generation's pinned source

    func testStaleSummaryWithNewerCurrentNotesUsesNewerIDNotPinnedSource() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        // The Summary generation's own pinned Notes source.
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)
        // A second, newer Notes generation now exists and is current.
        let newerNotesID = UUID()
        let newerRecord = try commitNotesGeneration(
            sessionID: SummaryTestSupport.sessionID,
            sessionPaths: entry.sessionPaths,
            generationID: newerNotesID,
            createdDate: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try commitNotesDocument(record: newerRecord, sessionPaths: entry.sessionPaths)

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)

        // The existing Summary generation's own pinned Notes source has
        // itself become invalid (e.g. deleted/superseded upstream of this
        // fixture) — the loader reports semantic invalidity for exactly the
        // pinned ID.
        let loader = FakeSummarySourceLoader()
        await loader.setResult(.failure(LectureSummarySourceError.missingGeneration), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        XCTAssertEqual(
            presenter.displayState,
            .loaded(record: generation, classification: .staleSource, advisoryStateIntegrity: .normal)
        )
        // A fresh Generate must use the newer, currently-usable Notes
        // generation — never the stale generation's own pinned source.
        XCTAssertEqual(presenter.currentUsableNotesGenerationID, newerNotesID)
        XCTAssertNotEqual(presenter.currentUsableNotesGenerationID, generation.sourceNotesGenerationID)
    }

    func testExistingCompletedSummaryRemainsLoadedWhenCurrentNotesIsUnusable() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        // Older, completed Notes generation — the Summary generation's own
        // pinned source.
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entry.sessionPaths)
        // Newer Notes generation is selected by the default-generation
        // policy but has no completed document — the current usable Notes
        // source is therefore nil, and must never fall back to the older,
        // completed one for a fresh Generate.
        let newerNotesID = UUID()
        _ = try commitNotesGeneration(
            sessionID: SummaryTestSupport.sessionID,
            sessionPaths: entry.sessionPaths,
            generationID: newerNotesID,
            createdDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)
        let orderedBatches = generation.batchPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        let analyses = try commitAnalyses(batches: orderedBatches, generation: generation, source: source, sessionPaths: entry.sessionPaths)
        let document = makeSummaryDocument(generation: generation, analyses: analyses)
        _ = try commitSummaryDocument(document, sessionPaths: entry.sessionPaths)

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.success(source), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        // Current-Notes selection correctly finds no usable source (the "no
        // fallback to older Notes" policy from earlier tests remains
        // intact)...
        XCTAssertNil(presenter.currentUsableNotesGenerationID)
        // ...but the existing, still-valid Summary generation is displayed
        // regardless — an unusable current Notes source never hides it.
        XCTAssertEqual(
            presenter.displayState,
            .loaded(record: generation, classification: .completed(document: document), advisoryStateIntegrity: .normal)
        )
        if case .noValidNotesSource = presenter.displayState {
            XCTFail("an existing completed Summary generation must never be hidden behind .noValidNotesSource")
        }
    }

    func testExistingStaleSummaryRemainsClassifiableWithNoCurrentNotes() async throws {
        let entry = makeEntry(sessionID: SummaryTestSupport.sessionID)
        // Deliberately no Notes generation committed at all for this
        // session — `currentUsableNotesGeneration` resolves to `nil`.
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entry.sessionPaths)

        let loader = FakeSummarySourceLoader()
        await loader.setResult(.failure(LectureSummarySourceError.missingGeneration), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        await presenter.refresh(for: entry)

        XCTAssertNil(presenter.currentUsableNotesGenerationID)
        XCTAssertEqual(
            presenter.displayState,
            .loaded(record: generation, classification: .staleSource, advisoryStateIntegrity: .normal)
        )
    }

    // MARK: - Stale-load protection

    func testStaleAsyncLoadCannotOverwriteNewerSelection() async throws {
        let sessionA = SummaryTestSupport.sessionID
        let sessionB = UUID()
        let entryA = makeEntry(sessionID: sessionA)
        let entryB = makeEntry(sessionID: sessionB)

        // Session A has a real current Notes generation and an existing
        // Summary generation, so its refresh reaches the sole `await` point
        // (`loadSourceSnapshot`) — where it will be gated.
        try commitSummaryTestSupportNotesEvidence(sessionPaths: entryA.sessionPaths)
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        try commitSummaryGeneration(generation, sessionPaths: entryA.sessionPaths)

        // Session B has no Notes generation at all, so its refresh completes
        // synchronously without ever touching the source loader.
        let loader = FakeSummarySourceLoader()
        await loader.setGated(SummaryTestSupport.notesGenerationID)
        await loader.setResult(.success(source), forNotesGenerationID: SummaryTestSupport.notesGenerationID)
        let presenter = makePresenter(sourceLoader: loader)

        let staleLoad = Task { await presenter.refresh(for: entryA) }

        while await !loader.hasEnteredGate {
            await Task.yield()
        }

        await presenter.refresh(for: entryB)
        XCTAssertEqual(presenter.displayedSessionID, sessionB)
        XCTAssertEqual(presenter.displayState, .noValidNotesSource)

        await loader.releaseGate()
        _ = await staleLoad.value

        // The now-stale session-A load must never have overwritten session
        // B's newer, already-published result.
        XCTAssertEqual(presenter.displayedSessionID, sessionB)
        XCTAssertEqual(presenter.displayState, .noValidNotesSource)
    }
}
