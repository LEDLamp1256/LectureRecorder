import AVFoundation
import XCTest
@testable import LectureRecorder

/// T7-C: read-only failed-part visibility (`peekFailureOverview`) and the
/// explicit permanent-failure retry, exercised against a real
/// `TranscriptionStore` in an isolated temporary sessions root.
@MainActor
final class TranscriptionFailureRecoveryTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T7CFailureRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        sessionID = UUID()
        sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func writeManifest(chunkCount: Int) throws -> SessionManifest {
        var manifest = SessionManifest.newSession(
            id: sessionID,
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
        try AtomicFileWriter.writeJSON(manifest, to: sessionPaths.manifestURL)
        for seq in 0..<chunkCount {
            let url = sessionPaths.chunksDirectory.appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: seq))
            try Data("placeholder".utf8).write(to: url)
        }
        return manifest
    }

    private func source(_ manifest: SessionManifest, _ sequenceNumber: Int) -> TranscriptionSourceSnapshot {
        let chunk = manifest.chunks.first { $0.sequenceNumber == sequenceNumber }!
        return TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
        )
    }

    private func failure(
        _ category: TranscriptionFailureCategory,
        _ disposition: RetryDisposition,
        message: String = "diagnostic text that must never reach the UI: /private/var/secret/path"
    ) -> TranscriptionFailure {
        TranscriptionFailure(category: category, message: message, retryDisposition: disposition, failureDate: Date(), attemptNumber: 1)
    }

    /// Writes one job per entry with the given state and failure record.
    @discardableResult
    private func writeJobs(
        _ manifest: SessionManifest,
        store: TranscriptionStore,
        _ jobs: [(sequenceNumber: Int, state: TranscriptionJobState, failure: TranscriptionFailure?)]
    ) async throws -> TranscriptionArtifactPaths {
        let paths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: paths)
        for entry in jobs {
            var job = TranscriptionJob.newQueued(source: source(manifest, entry.sequenceNumber), now: Date())
            job.state = entry.state
            job.lastFailure = entry.failure
            if entry.failure != nil { job.attemptCount = 1 }
            _ = try await store.createJobIfAbsent(job, paths: paths)
        }
        return paths
    }

    private func commitResult(_ manifest: SessionManifest, store: TranscriptionStore, paths: TranscriptionArtifactPaths, sequenceNumber: Int) async throws {
        _ = try await store.commitResult(
            TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion, source: source(manifest, sequenceNumber),
                output: TranscriptionEngineOutput(text: "done \(sequenceNumber)", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                attemptID: UUID(), completedDate: Date()
            ),
            paths: paths
        )
    }

    private func makeService(transcriber: any Transcribing, store: any TranscriptionStoring) -> CompletedSessionTranscriptionService {
        let root = tempDirectory!
        let manager = SessionManager(
            store: SessionStore(locator: TestLocator(root: root)),
            permissionService: MockMicrophonePermissionService(status: .granted),
            captureService: MockAudioCaptureService(
                formatToPrepare: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
            ),
            chunkWriterFactory: DefaultAudioChunkWriterFactory()
        )
        return CompletedSessionTranscriptionService(
            sessionManager: manager,
            transcriptionStore: store,
            transcriber: transcriber,
            sessionsRootResolver: { root }
        )
    }

    private struct TestLocator: FileSystemLocating {
        let root: URL
        func sessionsRootDirectory() throws -> URL { root }
        func paths(for sessionID: UUID) throws -> SessionPaths {
            try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: sessionID)
        }
    }

    /// Every file under the session's jobs/results directories, by relative
    /// path, with its bytes.
    private func transcriptionSnapshot(_ paths: TranscriptionArtifactPaths) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for directory in [paths.jobsDirectory, paths.resultsDirectory] {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                snapshot[directory.lastPathComponent + "/" + url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return snapshot
    }

    // MARK: - C1: read-only failed-part peek

    func testPeekFailureOverviewReportsSequenceCategoryAndDisposition() async throws {
        let manifest = try writeManifest(chunkCount: 4)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [
            (0, .completed, nil),
            (1, .failed, failure(.sourceMissing, .retryable)),
            (2, .failed, failure(.unknown, .permanent)),
            (3, .failed, failure(.cancellation, .retryable)),
        ])
        try await commitResult(manifest, store: store, paths: paths, sequenceNumber: 0)

        let service = makeService(transcriber: FakeTranscriber(), store: store)
        let peeked = await service.peekFailureOverview(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        let overview = try XCTUnwrap(peeked)

        XCTAssertEqual(overview.failedParts, [
            TranscriptionFailedPart(sequenceNumber: 1, category: .sourceMissing, retryDisposition: .retryable),
            TranscriptionFailedPart(sequenceNumber: 2, category: .unknown, retryDisposition: .permanent),
            TranscriptionFailedPart(sequenceNumber: 3, category: .cancellation, retryDisposition: .retryable),
        ])
        XCTAssertTrue(overview.hasAutomaticWork)
        XCTAssertTrue(overview.hasManualRetryEligibleParts)
        XCTAssertEqual(overview.failedParts.map(\.isAutomaticallyRetryable), [true, false, true])
        XCTAssertEqual(overview.failedParts.map(\.isEligibleForManualRetry), [false, true, false])
    }

    func testPeekFailureOverviewLeavesJobAndResultBytesIdentical() async throws {
        let manifest = try writeManifest(chunkCount: 3)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [
            (0, .completed, nil),
            (1, .failed, failure(.engineThrew, .permanent)),
            (2, .running, nil),
        ])
        try await commitResult(manifest, store: store, paths: paths, sequenceNumber: 0)
        let before = try transcriptionSnapshot(paths)

        let service = makeService(transcriber: FailIfCalledTranscriber(), store: store)
        _ = await service.peekFailureOverview(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        _ = await service.peekFailureOverview(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)

        XCTAssertEqual(try transcriptionSnapshot(paths), before, "peeking failed parts must never mutate jobs/results")
        XCTAssertEqual(before.count, 4)
    }

    func testPeekFailureOverviewNeverCreatesTranscriptionDirectories() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let service = makeService(transcriber: FailIfCalledTranscriber(), store: TranscriptionStore())
        let overview = await service.peekFailureOverview(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertEqual(overview, TranscriptionFailureOverview(failedParts: [], hasAutomaticWork: true))
        let paths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.transcriptionDirectory.path))
    }

    func testCompletedSessionHasNoFailedParts() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [(0, .completed, nil), (1, .completed, nil)])
        try await commitResult(manifest, store: store, paths: paths, sequenceNumber: 0)
        try await commitResult(manifest, store: store, paths: paths, sequenceNumber: 1)

        let service = makeService(transcriber: FailIfCalledTranscriber(), store: store)
        let status = await service.peekStatus(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertEqual(status, .completed)
        let overview = await service.peekFailureOverview(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertEqual(overview, TranscriptionFailureOverview(failedParts: [], hasAutomaticWork: false))
    }

    func testBlockedSessionIsNeverPresentedAsOrdinaryFailedParts() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        // A failed job with a result next to it is a preflight integrity
        // conflict, not an ordinary failure.
        let paths = try await writeJobs(manifest, store: store, [(0, .failed, failure(.engineThrew, .permanent))])
        try await commitResult(manifest, store: store, paths: paths, sequenceNumber: 0)

        let service = makeService(transcriber: FailIfCalledTranscriber(), store: store)
        let status = await service.peekStatus(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        guard case .blocked = status else { return XCTFail("expected blocked, got \(status)") }
        let overview = await service.peekFailureOverview(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertNil(overview)
    }

    func testCorruptJobArtifactIsBlockedNotAFailedPart() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let paths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: paths)
        try Data("{not json".utf8).write(to: paths.jobURL(sequenceNumber: 0))

        let service = makeService(transcriber: FailIfCalledTranscriber(), store: store)
        let overview = await service.peekFailureOverview(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertNil(overview)
    }

    func testAllPermanentFailuresMeanNoAutomaticWorkAndContinueIsDisabled() async throws {
        let manifest = try writeManifest(chunkCount: 3)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [
            (0, .completed, nil),
            (1, .failed, failure(.engineThrew, .permanent)),
            (2, .failed, failure(.unknown, .permanent)),
        ])
        try await commitResult(manifest, store: store, paths: paths, sequenceNumber: 0)

        let service = makeService(transcriber: FailIfCalledTranscriber(), store: store)
        let status = await service.peekStatus(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertEqual(status, .incomplete(completed: 1, total: 3))
        let peeked = await service.peekFailureOverview(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        let overview = try XCTUnwrap(peeked)
        XCTAssertFalse(overview.hasAutomaticWork)
        XCTAssertTrue(overview.hasManualRetryEligibleParts)
        XCTAssertFalse(
            SessionActionAvailabilityCalculator.availability(peekedStatus: status, failureOverview: overview, ownership: .none).canContinueOrRetry
        )
    }

    // MARK: - C2: explicit permanent-failure retry (service)

    /// Waits for the release of the operation admitted under `generation`
    /// (default: the most recent admission).
    private func waitUntilReleased(
        _ service: CompletedSessionTranscriptionService,
        generation: Int? = nil,
        timeout: TimeInterval = 5
    ) async -> SessionTranscriptionStatus? {
        let target = generation ?? service.generation
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if service.activeSessionID == nil, let release = service.lastReleasedOperation, release.generation == target {
                return release.status
            }
            await Task.yield()
        }
        XCTFail("operation \(target) never released")
        return nil
    }

    private func loadJob(_ store: TranscriptionStore, _ paths: TranscriptionArtifactPaths, _ seq: Int) async throws -> TranscriptionJob? {
        try await store.loadJob(sequenceNumber: seq, paths: paths)
    }

    func testContinueStillNeverRequeuesPermanentFailureButHandlesRetryableOnes() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [
            (0, .failed, failure(.unknown, .permanent)),
            (1, .failed, failure(.engineThrew, .retryable)),
        ])
        let permanentBytes = try Data(contentsOf: paths.jobURL(sequenceNumber: 0))

        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        XCTAssertEqual(service.continueOrRetry(sessionID: sessionID), .admitted)
        let status = await waitUntilReleased(service)

        XCTAssertEqual(status, .incomplete(completed: 1, total: 2))
        XCTAssertEqual(transcriber.recordedCalls.map(\.sequenceNumber), [1], "Continue retries only the retryable part")
        XCTAssertEqual(try Data(contentsOf: paths.jobURL(sequenceNumber: 0)), permanentBytes, "the permanent job is untouched by Continue")
    }

    func testExplicitRetryRequeuesEveryPermanentNoResultJobAndCompletesThem() async throws {
        let manifest = try writeManifest(chunkCount: 3)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [
            (0, .completed, nil),
            (1, .failed, failure(.unknown, .permanent)),
            (2, .failed, failure(.engineThrew, .permanent)),
        ])
        try await commitResult(manifest, store: store, paths: paths, sequenceNumber: 0)
        let completedJobBytes = try Data(contentsOf: paths.jobURL(sequenceNumber: 0))
        let completedResultBytes = try Data(contentsOf: paths.resultURL(sequenceNumber: 0))

        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        XCTAssertEqual(service.retryPermanentlyFailedParts(sessionID: sessionID), .admitted)
        let status = await waitUntilReleased(service)

        XCTAssertEqual(status, .completed)
        XCTAssertEqual(transcriber.recordedCalls.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(try Data(contentsOf: paths.jobURL(sequenceNumber: 0)), completedJobBytes, "an existing completed job is never rewritten")
        XCTAssertEqual(try Data(contentsOf: paths.resultURL(sequenceNumber: 0)), completedResultBytes, "an existing result is never overwritten")
        for seq in [1, 2] {
            let job = try await loadJob(store, paths, seq)
            XCTAssertEqual(job?.state, .completed)
            XCTAssertEqual(job?.attemptCount, 2)
        }
    }

    func testExplicitRetryLeavesRetryableFailuresForContinue() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [
            (0, .failed, failure(.unknown, .permanent)),
            (1, .failed, failure(.engineThrew, .retryable)),
        ])
        let retryableBytes = try Data(contentsOf: paths.jobURL(sequenceNumber: 1))

        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        XCTAssertEqual(service.retryPermanentlyFailedParts(sessionID: sessionID), .admitted)
        let status = await waitUntilReleased(service)

        XCTAssertEqual(status, .incomplete(completed: 1, total: 2))
        XCTAssertEqual(transcriber.recordedCalls.map(\.sequenceNumber), [0])
        XCTAssertEqual(try Data(contentsOf: paths.jobURL(sequenceNumber: 1)), retryableBytes)
    }

    func testExplicitRetryOfFailedJobWithResultIsBlockedWithZeroMutationAndZeroCalls() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [(0, .failed, failure(.unknown, .permanent))])
        try await commitResult(manifest, store: store, paths: paths, sequenceNumber: 0)
        let before = try transcriptionSnapshot(paths)

        let transcriber = FailIfCalledTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        XCTAssertEqual(service.retryPermanentlyFailedParts(sessionID: sessionID), .admitted)
        let status = await waitUntilReleased(service)

        guard case .blocked = status else { return XCTFail("expected blocked, got \(String(describing: status))") }
        XCTAssertEqual(try transcriptionSnapshot(paths), before)
    }

    func testExplicitRetryNeverTouchesABlockedIntegrityConflict() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [(0, .failed, failure(.unknown, .permanent))])
        // A permanent failure whose job snapshot no longer matches the
        // manifest: preflight must block before any mutation.
        var stale = TranscriptionJob.newQueued(source: source(manifest, 1), now: Date())
        stale.source.frameCount += 1
        stale.state = .failed
        stale.lastFailure = failure(.unknown, .permanent)
        _ = try await store.createJobIfAbsent(stale, paths: paths)
        let before = try transcriptionSnapshot(paths)

        let service = makeService(transcriber: FailIfCalledTranscriber(), store: store)
        let peeked = await service.peekFailureOverview(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertNil(peeked, "a blocked session never offers the manual retry")
        XCTAssertEqual(service.retryPermanentlyFailedParts(sessionID: sessionID), .admitted)
        let status = await waitUntilReleased(service)

        guard case .blocked = status else { return XCTFail("expected blocked, got \(String(describing: status))") }
        XCTAssertEqual(try transcriptionSnapshot(paths), before, "no job/result artifact is changed, created, or deleted")
    }

    func testExplicitRetryDeterministicReFailurePersistsAndIsNeverRetriedAgainAutomatically() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [(0, .failed, failure(.engineThrew, .permanent))])

        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "still unreadable", retryDisposition: .permanent),
            forSequenceNumber: 0
        )
        let service = makeService(transcriber: transcriber, store: store)
        XCTAssertEqual(service.retryPermanentlyFailedParts(sessionID: sessionID), .admitted)
        let status = await waitUntilReleased(service)

        XCTAssertEqual(status, .incomplete(completed: 0, total: 1))
        XCTAssertEqual(transcriber.recordedCalls.count, 1)
        let job = try await loadJob(store, paths, 0)
        XCTAssertEqual(job?.state, .failed)
        XCTAssertEqual(job?.lastFailure?.retryDisposition, .permanent)
        XCTAssertEqual(job?.attemptCount, 2)
        let resultExists = FileManager.default.fileExists(atPath: paths.resultURL(sequenceNumber: 0).path)
        XCTAssertFalse(resultExists)

        // No automatic follow-up: nothing re-admits work on its own, and a
        // later Continue still leaves the permanent failure alone.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(transcriber.recordedCalls.count, 1)
        XCTAssertNil(service.activeSessionID)
        XCTAssertEqual(service.continueOrRetry(sessionID: sessionID), .admitted)
        let continueStatus = await waitUntilReleased(service, generation: service.generation)
        XCTAssertEqual(continueStatus, .incomplete(completed: 0, total: 1))
        XCTAssertEqual(transcriber.recordedCalls.count, 1)
    }

    func testExplicitRetryStopsAtFirstReFailureLeavingLaterPartsQueuedForAnExplicitContinue() async throws {
        let manifest = try writeManifest(chunkCount: 3)
        let store = TranscriptionStore()
        let paths = try await writeJobs(manifest, store: store, [
            (0, .failed, failure(.unknown, .permanent)),
            (1, .failed, failure(.unknown, .permanent)),
            (2, .failed, failure(.unknown, .permanent)),
        ])
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "again", retryDisposition: .permanent),
            forSequenceNumber: 0
        )
        let service = makeService(transcriber: transcriber, store: store)
        XCTAssertEqual(service.retryPermanentlyFailedParts(sessionID: sessionID), .admitted)
        _ = await waitUntilReleased(service)

        // Existing fail-fast: one attempt, then scheduling stops.
        XCTAssertEqual(transcriber.recordedCalls.map(\.sequenceNumber), [0])
        let first = try await loadJob(store, paths, 0)
        XCTAssertEqual(first?.state, .failed)
        for seq in [1, 2] {
            let job = try await loadJob(store, paths, seq)
            XCTAssertEqual(job?.state, .queued, "requeued by the explicit action; nothing runs it until the user acts again")
            XCTAssertEqual(job?.attemptCount, 1)
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(transcriber.recordedCalls.count, 1, "no automatic follow-up")
    }

    func testExplicitRetryIsRefusedWithTheSameAdmissionRulesAsContinue() async throws {
        _ = try writeManifest(chunkCount: 1)
        let gated = CancellationAwareFakeTranscriber()
        gated.armGate()
        let service = makeService(transcriber: gated, store: TranscriptionStore())
        XCTAssertEqual(service.transcribe(sessionID: sessionID), .admitted)
        XCTAssertEqual(service.retryPermanentlyFailedParts(sessionID: sessionID), .busy)
        service.beginShutdown()
        _ = await waitUntilReleased(service)
        XCTAssertEqual(service.retryPermanentlyFailedParts(sessionID: sessionID), .shuttingDown)
    }
}

/// Fails the test if inference is ever attempted.
private final class FailIfCalledTranscriber: Transcribing, @unchecked Sendable {
    func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
        XCTFail("transcriber must not be called")
        return FakeTranscriber.defaultFakeOutput
    }
}
