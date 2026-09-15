import AVFoundation
import XCTest
@testable import LectureRecorder

/// A `Transcribing` fake that never returns and never observes
/// cancellation — used to prove `shutdown(timeout:)` is genuinely bounded
/// even when the in-flight work never cooperates. Deliberately built on a
/// bare `withCheckedContinuation` that is never resumed, and NOT wrapped in
/// `withTaskCancellationHandler` — so cancelling the enclosing `Task`
/// cannot make this call return. This differs on purpose from
/// `CancellationAwareFakeTranscriber` (which polls `Task.isCancelled` and
/// therefore does cooperate): that type proves the cooperative path;
/// this type proves the bound holds even when cooperation never happens.
/// The suspended continuation costs no CPU and blocks no OS thread (it is
/// not a busy-spin and not a blocking call), so leaving it permanently
/// unresumed for the rest of the test process's life is harmless to any
/// other test.
private final class UncooperativeFakeTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var hasBeenCalledFlag = false

    var hasBeenCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return hasBeenCalledFlag
    }

    func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
        lock.lock()
        hasBeenCalledFlag = true
        lock.unlock()
        return await withCheckedContinuation { (_: CheckedContinuation<TranscriptionEngineOutput, Never>) in
            // Deliberately never resumed.
        }
    }
}

/// A transcriber that fails the test if ever invoked — used to prove idle
/// shutdown never starts any worker.
private final class ShutdownFailIfCalledTranscriber: Transcribing, @unchecked Sendable {
    func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
        XCTFail("transcriber must not be invoked merely because shutdown() was called")
        throw UnclassifiedFakeError()
    }
}

@MainActor
final class CompletedSessionTranscriptionServiceShutdownTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSTServiceShutdownTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeAudioFormat() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
    }

    @discardableResult
    private func writeManifest(chunkCount: Int) throws -> SessionManifest {
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
        return manifest
    }

    private func makeService(
        transcriber: any Transcribing,
        sessionManager: SessionManager? = nil,
        shutdownPollInterval: TimeInterval = 0.005
    ) -> CompletedSessionTranscriptionService {
        let manager = sessionManager ?? makeSessionManager()
        let root = tempDirectory!
        return CompletedSessionTranscriptionService(
            sessionManager: manager,
            transcriptionStore: TranscriptionStore(),
            transcriber: transcriber,
            sessionsRootResolver: { root },
            shutdownPollInterval: shutdownPollInterval
        )
    }

    private func makeSessionManager() -> SessionManager {
        SessionManager(
            store: SessionStore(locator: TestLocator(root: tempDirectory)),
            permissionService: MockMicrophonePermissionService(status: .granted),
            captureService: MockAudioCaptureService(
                formatToPrepare: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
            ),
            chunkWriterFactory: DefaultAudioChunkWriterFactory()
        )
    }

    private struct TestLocator: FileSystemLocating {
        let root: URL
        func sessionsRootDirectory() throws -> URL { root }
        func paths(for sessionID: UUID) throws -> SessionPaths {
            try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: sessionID)
        }
    }

    private func waitUntilFinished(
        _ service: CompletedSessionTranscriptionService,
        timeout: TimeInterval = 5
    ) async -> CompletedSessionTranscriptionService.OperationPhase {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let phase = service.phase
            if case .finished = phase { return phase }
            await Task.yield()
        }
        return service.phase
    }

    // MARK: - Idle quit

    func testShutdownWithNoActiveTranscriptionCompletesImmediatelyAndInvokesNoWorker() async throws {
        let service = makeService(transcriber: ShutdownFailIfCalledTranscriber())

        let start = Date()
        let outcome = await service.shutdown()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome, .completed)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertTrue(service.isShuttingDown)

        // `setUpWithError` (via `DefaultFileSystemLocator.buildPaths`)
        // already creates `sessionDirectory` itself, so the meaningful
        // proof that shutdown started no work is the absence of the
        // transcription-operation-only `transcription/` subdirectory
        // (created by `TranscriptionCoordinator.enqueueEligibleChunks`'s
        // `store.ensureDirectoriesExist`), never touched by `shutdown()`.
        let transcriptionDirectory = sessionPaths.sessionDirectory.appendingPathComponent("transcription", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptionDirectory.path))
    }

    // MARK: - Active cooperative quit

    func testShutdownDuringCooperativeCancellationCompletesWithinBoundAndPreservesDurablePrefix() async throws {
        try writeManifest(chunkCount: 2)
        let gated = CancellationAwareFakeTranscriber()
        gated.armGate()
        let service = makeService(transcriber: gated)

        let admission = service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)

        let gateDeadline = Date().addingTimeInterval(5)
        while Date() < gateDeadline, !gated.hasEnteredGate { await Task.yield() }
        XCTAssertTrue(gated.hasEnteredGate)

        let outcome = await service.shutdown(timeout: 5)

        XCTAssertEqual(outcome, .completed)
        XCTAssertNil(service.activeSessionID, "ownership must be fully released once shutdown reports .completed")
        XCTAssertEqual(service.phase, .finished(.incomplete(completed: 0, total: 2)))

        // No later chunk was scheduled, and the coordinator's own durable
        // cancellation classification stands untouched.
        let store = TranscriptionStore()
        let manifest = try AtomicFileWriter.readJSON(SessionManifest.self, from: sessionPaths.manifestURL)
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        let job0 = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job0?.state, .failed)
        XCTAssertEqual(job0?.lastFailure?.category, .cancellation)
        let job1 = try await store.loadJob(sequenceNumber: 1, paths: artifactPaths)
        XCTAssertEqual(job1?.state, .queued)
    }

    // MARK: - Hung/uncooperative work

    func testShutdownIsBoundedWhenActiveWorkNeverCooperates() async throws {
        try writeManifest(chunkCount: 1)
        let transcriber = UncooperativeFakeTranscriber()
        let service = makeService(transcriber: transcriber)

        let admission = service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)

        let calledDeadline = Date().addingTimeInterval(5)
        while Date() < calledDeadline, !transcriber.hasBeenCalled { await Task.yield() }
        XCTAssertTrue(transcriber.hasBeenCalled)

        let start = Date()
        let outcome = await service.shutdown(timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome, .timedOut)
        // Generous versus the 0.2s bound requested — this is what proves
        // the test itself never hung waiting on the uncooperative work.
        XCTAssertLessThan(elapsed, 3.0)
        XCTAssertTrue(service.isShuttingDown)
    }

    // MARK: - Admission closure

    func testAdmissionClosesSynchronouslyAtTheStartOfShutdownBeforeCancellationCompletes() async throws {
        try writeManifest(chunkCount: 1)
        let gated = CancellationAwareFakeTranscriber()
        gated.armGate()
        let service = makeService(transcriber: gated)

        let admission = service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)

        let gateDeadline = Date().addingTimeInterval(5)
        while Date() < gateDeadline, !gated.hasEnteredGate { await Task.yield() }
        XCTAssertTrue(gated.hasEnteredGate)

        async let shutdownOutcome: CompletedSessionTranscriptionService.ShutdownOutcome = service.shutdown(timeout: 5)

        let flagDeadline = Date().addingTimeInterval(5)
        while Date() < flagDeadline, !service.isShuttingDown { await Task.yield() }
        XCTAssertTrue(service.isShuttingDown, "isShuttingDown must flip before shutdown's cooperative wait resolves")

        // Another window attempting Transcribe *while shutdown is still in
        // flight* must be refused truthfully, never silently queued.
        let raceTranscribe = service.transcribe(sessionID: UUID())
        XCTAssertEqual(raceTranscribe, .shuttingDown)
        let raceContinue = service.continueOrRetry(sessionID: UUID())
        XCTAssertEqual(raceContinue, .shuttingDown)

        let outcome = await shutdownOutcome
        XCTAssertEqual(outcome, .completed)

        // Still refused after shutdown has fully resolved — no hidden queue.
        let afterTranscribe = service.transcribe(sessionID: UUID())
        XCTAssertEqual(afterTranscribe, .shuttingDown)
    }

    // MARK: - Repeated shutdown

    func testRepeatedShutdownIsIdempotentWhenIdle() async throws {
        let service = makeService(transcriber: ShutdownFailIfCalledTranscriber())

        let first = await service.shutdown()
        let second = await service.shutdown()

        XCTAssertEqual(first, .completed)
        XCTAssertEqual(second, .completed)
    }

    func testRepeatedShutdownIsIdempotentWhileActiveAndNeverDoubleInvokesTheWorker() async throws {
        try writeManifest(chunkCount: 1)
        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber)

        let admission = service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)

        async let first = service.shutdown(timeout: 5)
        async let second = service.shutdown(timeout: 5)
        let (firstOutcome, secondOutcome) = await (first, second)

        XCTAssertEqual(firstOutcome, .completed)
        XCTAssertEqual(secondOutcome, .completed)
        // Cancellation races the ungated `FakeTranscriber`, so whether the
        // worker was invoked before cancellation won is not itself
        // deterministic (see `testCancellationBeforeWorkerLaunchPreventsAnyProcessing`
        // in the sibling suite for that already-covered race) — what this
        // test actually proves is idempotency: two overlapping `shutdown`
        // calls never cause a *second*, duplicate invocation.
        XCTAssertLessThanOrEqual(transcriber.recordedCalls.count, 1)
    }

    // MARK: - Synchronous shutdown initiation (beginShutdown)

    /// Proves the exact defect this fixes: `AppTerminationDelegate` now
    /// calls `beginShutdown()` synchronously — no `await` anywhere before
    /// it returns — specifically so admission is closed before AppKit's
    /// `applicationShouldTerminate` can return `.terminateLater`. This
    /// proves that synchronous call alone, with no subsequent `await`, is
    /// already sufficient to close admission and request cancellation.
    func testBeginShutdownSynchronouslyClosesAdmissionBeforeAnyAwait() async throws {
        try writeManifest(chunkCount: 1)
        let gated = CancellationAwareFakeTranscriber()
        gated.armGate()
        let service = makeService(transcriber: gated)

        let admission = service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)

        let gateDeadline = Date().addingTimeInterval(5)
        while Date() < gateDeadline, !gated.hasEnteredGate { await Task.yield() }
        XCTAssertTrue(gated.hasEnteredGate)

        service.beginShutdown()

        // No `await` occurred between `beginShutdown()` and these calls —
        // admission must already be closed and cancellation already
        // requested, synchronously.
        XCTAssertTrue(service.isShuttingDown)
        XCTAssertEqual(service.phase, .cancelling)
        XCTAssertEqual(service.transcribe(sessionID: UUID()), .shuttingDown)
        XCTAssertEqual(service.continueOrRetry(sessionID: UUID()), .shuttingDown)

        // Drain: `shutdown(timeout:)`'s own internal `beginShutdown()` call
        // is a no-op here (already shut down); it proceeds straight to the
        // bounded wait.
        let outcome = await service.shutdown(timeout: 5)
        XCTAssertEqual(outcome, .completed)
    }

    func testBeginShutdownIsIdempotent() async throws {
        try writeManifest(chunkCount: 1)
        let gated = CancellationAwareFakeTranscriber()
        gated.armGate()
        let service = makeService(transcriber: gated)

        let admission = service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)

        let gateDeadline = Date().addingTimeInterval(5)
        while Date() < gateDeadline, !gated.hasEnteredGate { await Task.yield() }
        XCTAssertTrue(gated.hasEnteredGate)

        service.beginShutdown()
        XCTAssertTrue(service.isShuttingDown)
        // Repeat calls must be pure no-ops: never re-publish `.cancelling`
        // over a phase that may have already moved on, and never attempt a
        // second cancellation.
        service.beginShutdown()
        service.beginShutdown()

        XCTAssertTrue(service.isShuttingDown)
        XCTAssertEqual(service.transcribe(sessionID: UUID()), .shuttingDown)

        let outcome = await service.shutdown(timeout: 5)
        XCTAssertEqual(outcome, .completed)
    }

    /// Exactly the production call sequence `AppTerminationDelegate` now
    /// uses: a synchronous `beginShutdown()` first, then `shutdown(timeout:)`.
    /// Reuses the same uncooperative fake as the "Hung/uncooperative work"
    /// case above to prove `shutdown(timeout:)`'s bound still applies
    /// correctly, and that it performs only the bounded wait — it does not
    /// re-cancel or duplicate anything `beginShutdown()` already did.
    func testShutdownAfterPriorBeginShutdownPerformsOnlyTheBoundedWait() async throws {
        try writeManifest(chunkCount: 1)
        let transcriber = UncooperativeFakeTranscriber()
        let service = makeService(transcriber: transcriber)

        let admission = service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)

        let calledDeadline = Date().addingTimeInterval(5)
        while Date() < calledDeadline, !transcriber.hasBeenCalled { await Task.yield() }
        XCTAssertTrue(transcriber.hasBeenCalled)

        service.beginShutdown()
        XCTAssertTrue(service.isShuttingDown)

        let start = Date()
        let outcome = await service.shutdown(timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(elapsed, 3.0)
    }

    // MARK: - Completed operation

    func testShutdownAfterTranscriptionAlreadyCompletedDoesNotAlterDurableArtifacts() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let service = makeService(transcriber: FakeTranscriber())

        let admission = service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.completed))

        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        let jobBefore = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        let resultBefore = try await store.loadResult(sequenceNumber: 0, paths: artifactPaths)

        let outcome = await service.shutdown()
        XCTAssertEqual(outcome, .completed)

        let jobAfter = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        let resultAfter = try await store.loadResult(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(jobBefore, jobAfter)
        XCTAssertEqual(resultBefore, resultAfter)
        XCTAssertEqual(service.displayedSegments.count, 1)
    }

    // MARK: - Recording invariants

    func testShutdownOfTranscriptionServiceDoesNotAffectRecordingStartStop() async throws {
        let manager = makeSessionManager()
        let service = makeService(transcriber: FakeTranscriber(), sessionManager: manager)

        let outcome = await service.shutdown()
        XCTAssertEqual(outcome, .completed)

        await manager.startSession()
        XCTAssertEqual(manager.state, .recording)
        await manager.stopSession()
    }
}
