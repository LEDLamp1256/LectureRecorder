import XCTest
@testable import LectureRecorder

/// Pure, fast tests for `SessionNotesGenerationSelection` — no filesystem
/// I/O, no presenter involved.
final class SessionNotesGenerationSelectionTests: XCTestCase {
    private func makeRecord(generationID: UUID, createdDate: Date) -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord.newGeneration(
            generationID: generationID,
            sessionID: UUID(),
            transcriptFingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "a", count: 64)),
            windowPlan: NotesWindowPlan(windows: []),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            now: createdDate
        )
    }

    func testEmptyRecordsReturnsNil() {
        XCTAssertNil(SessionNotesGenerationSelection.chooseDefault(records: []))
    }

    func testChoosesNewestCreatedDate() {
        let older = makeRecord(generationID: UUID(), createdDate: Date(timeIntervalSince1970: 1_000))
        let newer = makeRecord(generationID: UUID(), createdDate: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(SessionNotesGenerationSelection.chooseDefault(records: [older, newer])?.generationID, newer.generationID)
        XCTAssertEqual(SessionNotesGenerationSelection.chooseDefault(records: [newer, older])?.generationID, newer.generationID)
    }

    func testTieBreaksByGreaterGenerationIDUUIDString() {
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let a = makeRecord(generationID: lowerID, createdDate: sameDate)
        let b = makeRecord(generationID: higherID, createdDate: sameDate)
        XCTAssertEqual(SessionNotesGenerationSelection.chooseDefault(records: [a, b])?.generationID, higherID)
        XCTAssertEqual(SessionNotesGenerationSelection.chooseDefault(records: [b, a])?.generationID, higherID)
    }
}

/// A `NotesTranscriptSourceLoading` test double that returns a fixed
/// snapshot per session ID, and can optionally suspend indefinitely for a
/// given session ID until the test explicitly releases it — lets
/// `testStaleAsyncLoadCannotOverwriteNewerSelection` deterministically get
/// the presenter's sole `await` point genuinely in flight before a newer
/// selection completes, with no sleeps or polling. Mirrors the gating
/// pattern already established by `ControllableFakeLectureNotesGenerator`.
private actor StubNotesTranscriptSourceLoader: NotesTranscriptSourceLoading {
    private var snapshotsBySessionID: [UUID: NotesTranscriptSourceSnapshot]
    private var gatedSessionIDs: Set<UUID>
    private var pendingContinuation: CheckedContinuation<Void, Never>?
    private var hasEnteredGateFlag = false

    init(snapshotsBySessionID: [UUID: NotesTranscriptSourceSnapshot] = [:], gatedSessionIDs: Set<UUID> = []) {
        self.snapshotsBySessionID = snapshotsBySessionID
        self.gatedSessionIDs = gatedSessionIDs
    }

    func setSnapshot(_ snapshot: NotesTranscriptSourceSnapshot, forSessionID sessionID: UUID) {
        snapshotsBySessionID[sessionID] = snapshot
    }

    var hasEnteredGate: Bool { hasEnteredGateFlag }

    func releaseGate() {
        pendingContinuation?.resume()
        pendingContinuation = nil
    }

    func loadCurrentSnapshot(sessionID: UUID) async throws -> NotesTranscriptSourceSnapshot {
        if gatedSessionIDs.contains(sessionID) {
            hasEnteredGateFlag = true
            await withCheckedContinuation { continuation in
                self.pendingContinuation = continuation
            }
        }
        guard let snapshot = snapshotsBySessionID[sessionID] else {
            throw NotesTranscriptSourceLoadError.sourceBuildFailed("no stub snapshot registered for session \(sessionID)")
        }
        return snapshot
    }
}

@MainActor
final class SessionNotesPresenterTests: XCTestCase {
    private var tempDirectory: URL!
    private var notesStore: LectureNotesStore!
    private var operationStateStore: LectureNotesOperationStateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionNotesPresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
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

    private func makeEntry(sessionID: UUID) -> CompletedSessionEntry {
        let audioFormat = AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
        var manifest = SessionManifest.newSession(id: sessionID, audioFormat: audioFormat, targetChunkDurationSeconds: 30)
        manifest.status = .completed
        manifest.endedCleanly = true
        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: tempDirectory, sessionID: sessionID)
        return CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)
    }

    private func makeUnit(_ sequenceNumber: Int) -> NotesTranscriptSourceUnit {
        NotesTranscriptSourceUnit(
            sequenceNumber: sequenceNumber,
            chunkFileName: "chunk_\(sequenceNumber).caf",
            text: "unit \(sequenceNumber) text",
            startOffsetSeconds: Double(sequenceNumber) * 30,
            durationSeconds: 30
        )
    }

    private func makeSnapshot(sessionID: UUID, unitCount: Int) -> NotesTranscriptSourceSnapshot {
        let units = (0..<unitCount).map(makeUnit)
        return NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        )
    }

    private func makeWindows(count: Int) -> [NotesInputWindow] {
        (0..<count).map { index in
            NotesInputWindow(windowIndex: index, firstSequenceNumber: index, lastSequenceNumber: index, unitCount: 1, isOversizedSingleUnit: false)
        }
    }

    @discardableResult
    private func writeGeneration(
        sessionID: UUID,
        sessionPaths: SessionPaths,
        generationID: UUID = UUID(),
        windowCount: Int,
        fingerprint: TranscriptSourceFingerprint,
        createdDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> LectureNotesGenerationRecord {
        let record = LectureNotesGenerationRecord.newGeneration(
            generationID: generationID,
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            windowPlan: NotesWindowPlan(windows: makeWindows(count: windowCount)),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            now: createdDate
        )
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        let outcome = try notesStore.createGenerationIfAbsent(record, paths: paths)
        XCTAssertTrue(outcome == .created || outcome == .alreadyExistsIdentical)
        return record
    }

    private func makeAnalysis(windowIndex: Int, generation: LectureNotesGenerationRecord) -> LectureNotesWindowAnalysis {
        LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: windowIndex,
            ownedRange: NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: windowIndex),
            items: [
                LectureNoteItem(
                    kind: .explanation,
                    body: "body for window \(windowIndex)",
                    fidelity: .transcriptSupported,
                    sourceReferences: [NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: windowIndex)]
                )
            ]
        )
    }

    @discardableResult
    private func commitAnalysis(_ analysis: LectureNotesWindowAnalysis, sessionPaths: SessionPaths, generation: LectureNotesGenerationRecord) throws -> NotesWindowAnalysisCommitOutcome {
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: generation.sessionID, generationID: generation.generationID)
        return try notesStore.commitWindowAnalysis(analysis, paths: paths)
    }

    private func makeDocument(generation: LectureNotesGenerationRecord, analyses: [LectureNotesWindowAnalysis]) -> LectureNotesDocument {
        LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            createdDate: Date(timeIntervalSince1970: 1_700_000_000),
            overview: "Overview covering \(analyses.count) section(s).",
            sections: analyses.map {
                LectureNoteSection(heading: "Window \($0.windowIndex)", items: $0.items)
            }
        )
    }

    @discardableResult
    private func commitDocument(_ document: LectureNotesDocument, sessionPaths: SessionPaths, generation: LectureNotesGenerationRecord) throws -> NotesDocumentCommitOutcome {
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: generation.sessionID, generationID: generation.generationID)
        return try notesStore.commitDocument(document, paths: paths)
    }

    private func saveOperationState(
        lifecycle: NotesGenerationOperationLifecycle,
        failureDescription: String? = nil,
        sessionPaths: SessionPaths,
        generation: LectureNotesGenerationRecord
    ) throws {
        let paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: generation.sessionID, generationID: generation.generationID)
        let state = NotesGenerationOperationState(
            sessionID: generation.sessionID,
            generationID: generation.generationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            activeRunID: UUID(),
            runAttemptCount: 1,
            lifecycle: lifecycle,
            failureDescription: failureDescription
        )
        try operationStateStore.saveOperationState(state, paths: paths)
    }

    // MARK: - No existing generation

    func testNoExistingGenerationPublishesNoGeneration() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let presenter = SessionNotesPresenter(
            notesStore: notesStore,
            operationStateStore: operationStateStore,
            sourceLoader: StubNotesTranscriptSourceLoader()
        )

        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.displayedSessionID, sessionID)
        XCTAssertEqual(presenter.displayState, .noGeneration)
    }

    // MARK: - Completed document

    func testCompletedGenerationPublishesDocument() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 1)
        let generation = try! writeGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, windowCount: 1, fingerprint: snapshot.fingerprint)
        let analysis = makeAnalysis(windowIndex: 0, generation: generation)
        try! commitAnalysis(analysis, sessionPaths: entry.sessionPaths, generation: generation)
        let document = makeDocument(generation: generation, analyses: [analysis])
        try! commitDocument(document, sessionPaths: entry.sessionPaths, generation: generation)

        let loader = StubNotesTranscriptSourceLoader()
        await loader.setSnapshot(snapshot, forSessionID: sessionID)
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(let loadedRecord, .completed(let loadedDocument), let advisoryStateIntegrity) = presenter.displayState else {
            return XCTFail("expected .loaded(.completed), got \(presenter.displayState)")
        }
        XCTAssertEqual(loadedRecord.generationID, generation.generationID)
        XCTAssertEqual(loadedDocument, document)
        XCTAssertEqual(advisoryStateIntegrity, .normal)
    }

    // MARK: - Relaunch / resumable state

    func testResumableGenerationReportsInterruptionFromAdvisoryState() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = try! writeGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, windowCount: 2, fingerprint: snapshot.fingerprint)
        let firstAnalysis = makeAnalysis(windowIndex: 0, generation: generation)
        try! commitAnalysis(firstAnalysis, sessionPaths: entry.sessionPaths, generation: generation)
        try! saveOperationState(lifecycle: .failed, failureDescription: "provider timed out", sessionPaths: entry.sessionPaths, generation: generation)

        let loader = StubNotesTranscriptSourceLoader()
        await loader.setSnapshot(snapshot, forSessionID: sessionID)
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(_, .resumable(let nextWindowIndex, let interruption), let advisoryStateIntegrity) = presenter.displayState else {
            return XCTFail("expected .loaded(.resumable), got \(presenter.displayState)")
        }
        XCTAssertEqual(nextWindowIndex, 1)
        XCTAssertEqual(interruption, .recoverableFailure(description: "provider timed out"))
        XCTAssertEqual(advisoryStateIntegrity, .normal)
    }

    /// Correction #1: a matching-fingerprint operation state is honored
    /// exactly as before — this is the control case distinguishing
    /// `testResumableWithMismatchedFingerprintDisablesContinueButIsNotHidden`
    /// below.
    func testMismatchedOperationStateFingerprintIsNotSilentlyTreatedAsAbsent() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = try! writeGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, windowCount: 2, fingerprint: snapshot.fingerprint)
        let firstAnalysis = makeAnalysis(windowIndex: 0, generation: generation)
        try! commitAnalysis(firstAnalysis, sessionPaths: entry.sessionPaths, generation: generation)

        // An operation-state record whose own transcriptFingerprint does
        // not match this generation's — the exact condition
        // `LectureNotesGenerationService.run()`'s `operationStateIdentity`
        // treats as `.mismatchedFingerprint` and refuses to proceed on.
        let mismatchedFingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "9", count: 64))
        let paths = try! NotesArtifactPaths.validated(sessionPaths: entry.sessionPaths, sessionID: sessionID, generationID: generation.generationID)
        try! operationStateStore.saveOperationState(
            NotesGenerationOperationState(
                sessionID: sessionID,
                generationID: generation.generationID,
                transcriptFingerprint: mismatchedFingerprint,
                activeRunID: UUID(),
                runAttemptCount: 1,
                lifecycle: .failed,
                failureDescription: "this failure describes a different transcript entirely"
            ),
            paths: paths
        )

        let loader = StubNotesTranscriptSourceLoader()
        await loader.setSnapshot(snapshot, forSessionID: sessionID)
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(_, .resumable(let nextWindowIndex, let interruption), let advisoryStateIntegrity) = presenter.displayState else {
            return XCTFail("expected .loaded(.resumable), got \(presenter.displayState)")
        }
        // Canonical coverage alone still proves this is resumable from
        // window 1 — completely unaffected by the mismatched advisory
        // record.
        XCTAssertEqual(nextWindowIndex, 1)
        // The mismatched record's own lifecycle/failureDescription must
        // never leak into the displayed interruption reason — it does not
        // describe this generation's transcript content at all.
        XCTAssertEqual(interruption, .notStarted)
        guard case .problem = advisoryStateIntegrity else {
            return XCTFail("expected advisoryStateIntegrity == .problem, got \(advisoryStateIntegrity)")
        }
    }

    func testUnreadableOperationStateDoesNotHideACompletedDocument() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 1)
        let generation = try! writeGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, windowCount: 1, fingerprint: snapshot.fingerprint)
        let analysis = makeAnalysis(windowIndex: 0, generation: generation)
        try! commitAnalysis(analysis, sessionPaths: entry.sessionPaths, generation: generation)
        let document = makeDocument(generation: generation, analyses: [analysis])
        try! commitDocument(document, sessionPaths: entry.sessionPaths, generation: generation)

        // Corrupt operation-state.json written directly, bypassing the
        // store's own save API — simulates on-disk corruption of the
        // advisory artifact only; the canonical generation/analysis/
        // document artifacts above are untouched.
        let paths = try! NotesArtifactPaths.validated(sessionPaths: entry.sessionPaths, sessionID: sessionID, generationID: generation.generationID)
        try! Data("not valid json".utf8).write(to: paths.operationStateURL)

        let loader = StubNotesTranscriptSourceLoader()
        await loader.setSnapshot(snapshot, forSessionID: sessionID)
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(let loadedRecord, .completed(let loadedDocument), let advisoryStateIntegrity) = presenter.displayState else {
            return XCTFail("expected .loaded(.completed) despite the corrupt advisory record, got \(presenter.displayState)")
        }
        XCTAssertEqual(loadedRecord.generationID, generation.generationID)
        XCTAssertEqual(loadedDocument, document)
        guard case .problem = advisoryStateIntegrity else {
            return XCTFail("expected advisoryStateIntegrity == .problem, got \(advisoryStateIntegrity)")
        }
    }

    // MARK: - Stale source

    func testStaleSourcePublishedWhenFingerprintNoLongerMatches() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let originalSnapshot = makeSnapshot(sessionID: sessionID, unitCount: 1)
        let generation = try! writeGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, windowCount: 1, fingerprint: originalSnapshot.fingerprint)

        // The transcript changed since this generation's plan was fixed —
        // a different current snapshot (different fingerprint) for the
        // same session.
        let changedSnapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let loader = StubNotesTranscriptSourceLoader()
        await loader.setSnapshot(changedSnapshot, forSessionID: sessionID)
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(let loadedRecord, .staleSource, _) = presenter.displayState else {
            return XCTFail("expected .loaded(.staleSource), got \(presenter.displayState)")
        }
        XCTAssertEqual(loadedRecord.generationID, generation.generationID)
    }

    // MARK: - Damaged state

    func testDamagedStatePublishedForNonPrefixCoverage() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = try! writeGeneration(sessionID: sessionID, sessionPaths: entry.sessionPaths, windowCount: 2, fingerprint: snapshot.fingerprint)
        // Commit only window 1's analysis, skipping window 0 — a
        // non-prefix set of committed windows, which the classifier must
        // report as damaged rather than treat as resumable from window 0.
        let secondAnalysis = makeAnalysis(windowIndex: 1, generation: generation)
        try! commitAnalysis(secondAnalysis, sessionPaths: entry.sessionPaths, generation: generation)

        let loader = StubNotesTranscriptSourceLoader()
        await loader.setSnapshot(snapshot, forSessionID: sessionID)
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(_, .damaged(let reason), _) = presenter.displayState else {
            return XCTFail("expected .loaded(.damaged), got \(presenter.displayState)")
        }
        XCTAssertEqual(reason, .nonPrefixCoverage(presentIndices: [1]))
    }

    // MARK: - Multiple-generation display selection

    func testMultipleGenerationsChooseNewestCreatedDate() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 1)
        _ = try! writeGeneration(
            sessionID: sessionID, sessionPaths: entry.sessionPaths, windowCount: 1,
            fingerprint: snapshot.fingerprint, createdDate: Date(timeIntervalSince1970: 1_000)
        )
        let newer = try! writeGeneration(
            sessionID: sessionID, sessionPaths: entry.sessionPaths, windowCount: 1,
            fingerprint: snapshot.fingerprint, createdDate: Date(timeIntervalSince1970: 2_000)
        )

        let loader = StubNotesTranscriptSourceLoader()
        await loader.setSnapshot(snapshot, forSessionID: sessionID)
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loaded(let loadedRecord, _, _) = presenter.displayState else {
            return XCTFail("expected .loaded, got \(presenter.displayState)")
        }
        XCTAssertEqual(loadedRecord.generationID, newer.generationID)
    }

    // MARK: - Fail-closed generation enumeration (correction #2)

    /// One valid older generation plus one candidate generation whose
    /// `generation.json` is corrupt: the newest-`createdDate` selection
    /// policy must never silently fall back to the older, readable
    /// generation just because the true newest one could not be read —
    /// that could display stale/wrong content as if it were current.
    func testUnreadableNewestCandidateGenerationDoesNotSilentlyFallBackToOlderGeneration() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 1)
        let older = try! writeGeneration(
            sessionID: sessionID, sessionPaths: entry.sessionPaths, windowCount: 1,
            fingerprint: snapshot.fingerprint, createdDate: Date(timeIntervalSince1970: 1_000)
        )

        // A second, newer-looking generation directory whose
        // generation.json is corrupt — written directly to disk, bypassing
        // the store's own commit API, to simulate on-disk corruption
        // rather than anything the store itself would ever produce.
        let corruptGenerationID = UUID()
        let corruptPaths = try! NotesArtifactPaths.validated(sessionPaths: entry.sessionPaths, sessionID: sessionID, generationID: corruptGenerationID)
        try! FileManager.default.createDirectory(at: corruptPaths.generationDirectory, withIntermediateDirectories: true)
        try! Data("not valid json".utf8).write(to: corruptPaths.generationRecordURL)

        let loader = StubNotesTranscriptSourceLoader()
        await loader.setSnapshot(snapshot, forSessionID: sessionID)
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        await presenter.refresh(for: entry)

        guard case .loadError = presenter.displayState else {
            return XCTFail("expected .loadError (never a silent fall-back to the older generation \(older.generationID)), got \(presenter.displayState)")
        }
    }

    /// `listGenerationIDs` enumerated a generation directory, but it has
    /// no `generation.json` inside it at all — an explicit, unexpected
    /// inconsistency that must become a controlled presentation error,
    /// never be silently treated as "this generation doesn't exist".
    func testGenerationDirectoryWithoutRecordProducesControlledLoadError() async {
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let generationID = UUID()
        let paths = try! NotesArtifactPaths.validated(sessionPaths: entry.sessionPaths, sessionID: sessionID, generationID: generationID)
        try! FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)

        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: StubNotesTranscriptSourceLoader())

        await presenter.refresh(for: entry)

        guard case .loadError = presenter.displayState else {
            return XCTFail("expected .loadError, got \(presenter.displayState)")
        }
    }

    // MARK: - Explicit-generation safety

    /// Constructs the presenter alongside the *real*
    /// `LectureNotesGenerationService` (wired to a spy generator, exactly
    /// as `AppEnvironment` wires the production one) and refreshes durable
    /// state repeatedly — including for a no-generation session, a
    /// completed session, and a resumable session, simulating relaunch,
    /// session-switch, and pane-switch — proving at the actual production
    /// service boundary that none of this ever starts a generation:
    /// `service.activeSessionID` stays `nil`, `service.phase` stays
    /// `.idle`, and the generator records zero calls.
    func testRefreshingDurableStateNeverTriggersGeneration() async throws {
        let sessionA = UUID() // no generation
        let sessionB = UUID() // completed generation
        let entryA = makeEntry(sessionID: sessionA)
        let entryB = makeEntry(sessionID: sessionB)

        let snapshotB = makeSnapshot(sessionID: sessionB, unitCount: 1)
        let generationB = try writeGeneration(sessionID: sessionB, sessionPaths: entryB.sessionPaths, windowCount: 1, fingerprint: snapshotB.fingerprint)
        let analysisB = makeAnalysis(windowIndex: 0, generation: generationB)
        try commitAnalysis(analysisB, sessionPaths: entryB.sessionPaths, generation: generationB)
        try commitDocument(makeDocument(generation: generationB, analyses: [analysisB]), sessionPaths: entryB.sessionPaths, generation: generationB)

        let loader = StubNotesTranscriptSourceLoader()
        await loader.setSnapshot(snapshotB, forSessionID: sessionB)

        let generator = ControllableFakeLectureNotesGenerator()
        let service = LectureNotesGenerationService(
            sourceLoader: loader,
            notesStore: notesStore,
            operationStateStore: operationStateStore,
            generator: generator,
            windowBudget: try NotesWindowBudget(maxUTF8BytesPerWindow: 1_000_000, maxUnitsPerWindow: 1),
            sessionsRootResolver: { [tempDirectory] in tempDirectory! }
        )
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        // Relaunch-style loads, a session switch, and a repeat "reopen"
        // load simulating a pane/mode switch — none of these are Notes
        // actions.
        await presenter.refresh(for: entryA)
        await presenter.refresh(for: entryB)
        await presenter.refresh(for: entryA)
        await presenter.refresh(for: entryB)

        XCTAssertNil(service.activeSessionID)
        XCTAssertNil(service.activeGenerationID)
        XCTAssertEqual(service.phase, .idle)
        let analyzeCalls = await generator.analyzeCalls
        let synthesizeCallCount = await generator.synthesizeCallCount
        XCTAssertEqual(analyzeCalls, [])
        XCTAssertEqual(synthesizeCallCount, 0)
    }

    // MARK: - Stale async load protection

    func testStaleAsyncLoadCannotOverwriteNewerSelection() async {
        let sessionA = UUID()
        let sessionB = UUID()
        let entryA = makeEntry(sessionID: sessionA)
        let entryB = makeEntry(sessionID: sessionB)

        // Session A has a real generation, so its refresh reaches the sole
        // `await` point (loadCurrentSnapshot) — where it will be gated.
        let snapshotA = makeSnapshot(sessionID: sessionA, unitCount: 1)
        _ = try! writeGeneration(sessionID: sessionA, sessionPaths: entryA.sessionPaths, windowCount: 1, fingerprint: snapshotA.fingerprint)

        // Session B has no generation at all, so its refresh completes
        // synchronously without ever touching the source loader.
        let loader = StubNotesTranscriptSourceLoader(gatedSessionIDs: [sessionA])
        await loader.setSnapshot(snapshotA, forSessionID: sessionA)
        let presenter = SessionNotesPresenter(notesStore: notesStore, operationStateStore: operationStateStore, sourceLoader: loader)

        let staleLoad = Task { await presenter.refresh(for: entryA) }

        // Wait deterministically until the stale load has actually entered
        // the gate before starting the newer selection — no sleeps.
        while await !loader.hasEnteredGate {
            await Task.yield()
        }

        await presenter.refresh(for: entryB)
        XCTAssertEqual(presenter.displayedSessionID, sessionB)
        XCTAssertEqual(presenter.displayState, .noGeneration)

        await loader.releaseGate()
        _ = await staleLoad.value

        // The now-stale session-A load must never have overwritten
        // session B's newer, already-published result.
        XCTAssertEqual(presenter.displayedSessionID, sessionB)
        XCTAssertEqual(presenter.displayState, .noGeneration)
    }
}
