import AVFoundation
import Combine
import XCTest
@testable import LectureRecorder

/// Records every call and, if armed for a specific sequence number, hangs
/// cooperatively (polling `Task.isCancelled`) instead of returning — lets
/// tests deterministically get a chunk genuinely in flight before
/// cancelling, without racing on timing.
private actor SequenceGatedTranscriber: Transcribing {
    private var gateSequenceNumber: Int?
    private var enteredGateSequenceNumbers: Set<Int> = []
    private var shouldReleaseSuccessfully = false
    private(set) var calls: [(sequenceNumber: Int, audioURL: URL)] = []

    func armGate(beforeSequenceNumber seq: Int) {
        gateSequenceNumber = seq
    }

    func hasEntered(_ seq: Int) -> Bool {
        enteredGateSequenceNumbers.contains(seq)
    }

    /// Releases the currently-gated call with a normal successful result
    /// (as opposed to cancellation) — used to deterministically prove a
    /// chunk durably completes even though cancellation was requested
    /// while it was still in flight, so a test can then observe that it is
    /// specifically the *next* loop iteration's cancellation check (not
    /// this chunk's own outcome) that stops the chunk after it.
    func releaseSuccessfully() {
        shouldReleaseSuccessfully = true
    }

    func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
        calls.append((source.chunkSequenceNumber, audioURL))
        if gateSequenceNumber == source.chunkSequenceNumber {
            enteredGateSequenceNumbers.insert(source.chunkSequenceNumber)
            while !Task.isCancelled && !shouldReleaseSuccessfully {
                await Task.yield()
            }
            if shouldReleaseSuccessfully {
                shouldReleaseSuccessfully = false
                return FakeTranscriber.defaultFakeOutput
            }
            try Task.checkCancellation()
        }
        return FakeTranscriber.defaultFakeOutput
    }
}

/// Hangs the *first* call to `loadAllJobArtifacts` (the preflight's own
/// first store read) until explicitly released — lets a test deterministically
/// observe the run genuinely paused before any transcriber could possibly be
/// invoked, then cancel from there.
private actor HangingStoreWrapper: TranscriptionStoring {
    private let wrapped: TranscriptionStore
    private var isGateArmed = true
    private var hasEnteredGateFlag = false
    private var hasHungOnce = false

    init(wrapped: TranscriptionStore) {
        self.wrapped = wrapped
    }

    var hasEnteredGate: Bool { hasEnteredGateFlag }

    func release() {
        isGateArmed = false
    }

    private func waitForGate() async {
        hasEnteredGateFlag = true
        while isGateArmed {
            await Task.yield()
        }
    }

    func ensureDirectoriesExist(paths: TranscriptionArtifactPaths) async throws {
        try await wrapped.ensureDirectoriesExist(paths: paths)
    }

    func loadJob(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptionJob? {
        try await wrapped.loadJob(sequenceNumber: sequenceNumber, paths: paths)
    }

    func createJobIfAbsent(_ job: TranscriptionJob, paths: TranscriptionArtifactPaths) async throws -> JobCreationOutcome {
        try await wrapped.createJobIfAbsent(job, paths: paths)
    }

    func replaceJob(_ job: TranscriptionJob, paths: TranscriptionArtifactPaths) async throws {
        try await wrapped.replaceJob(job, paths: paths)
    }

    func loadResult(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptResult? {
        try await wrapped.loadResult(sequenceNumber: sequenceNumber, paths: paths)
    }

    func commitResult(_ result: TranscriptResult, paths: TranscriptionArtifactPaths) async throws -> ResultCommitOutcome {
        try await wrapped.commitResult(result, paths: paths)
    }

    func confirmResultsDirectoryDurable(paths: TranscriptionArtifactPaths) async throws -> Bool {
        try await wrapped.confirmResultsDirectoryDurable(paths: paths)
    }

    func loadAllJobArtifacts(paths: TranscriptionArtifactPaths) async throws -> [ArtifactLoadResult<TranscriptionJob>] {
        if !hasHungOnce {
            hasHungOnce = true
            await waitForGate()
        }
        return try await wrapped.loadAllJobArtifacts(paths: paths)
    }

    func loadAllResultArtifacts(paths: TranscriptionArtifactPaths) async throws -> [ArtifactLoadResult<TranscriptResult>] {
        try await wrapped.loadAllResultArtifacts(paths: paths)
    }
}

@MainActor
final class CompletedSessionTranscriptionServiceTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSTServiceTests-\(UUID().uuidString)", isDirectory: true)
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
        // Deliberately out of sequence order on disk — execution must
        // still process in numeric order.
        manifest.chunks = (0..<chunkCount).reversed().map { seq in
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
        manifest.chunks.sort { $0.sequenceNumber < $1.sequenceNumber }
        return manifest
    }

    private func makeService(
        transcriber: any Transcribing,
        sessionManager: SessionManager? = nil,
        store: (any TranscriptionStoring)? = nil
    ) -> CompletedSessionTranscriptionService {
        let manager = sessionManager ?? makeSessionManager()
        let root = tempDirectory!
        return CompletedSessionTranscriptionService(
            sessionManager: manager,
            transcriptionStore: store ?? TranscriptionStore(),
            transcriber: transcriber,
            sessionsRootResolver: { root }
        )
    }

    private func makeSessionManager(permissionService: (any MicrophonePermissionServing)? = nil) -> SessionManager {
        SessionManager(
            store: SessionStore(locator: TestLocator(root: tempDirectory)),
            permissionService: permissionService ?? MockMicrophonePermissionService(status: .granted),
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
            let phase = await service.phase
            if case .finished = phase { return phase }
            await Task.yield()
        }
        return await service.phase
    }

    /// Polls until `gated` reports it has genuinely entered its gate for
    /// `sequenceNumber`, or fails the test after `timeout`.
    private func waitUntilGateEntered(
        _ gated: SequenceGatedTranscriber,
        sequenceNumber: Int,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let entered = await gated.hasEntered(sequenceNumber)
            if entered { return }
            await Task.yield()
        }
        XCTFail("gate for sequence \(sequenceNumber) was never entered", file: file, line: line)
    }

    // MARK: - Admission

    func testAdmissionSucceedsWhenRecordingIsIdle() async {
        let service = makeService(transcriber: FakeTranscriber())
        try? writeManifest(chunkCount: 1)
        let result = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(result, .admitted)
        _ = await waitUntilFinished(service)
    }

    func testAdmissionRejectedWhenRecordingAlreadyWonAdmission() async {
        let manager = makeSessionManager()
        let service = makeService(transcriber: FakeTranscriber(), sessionManager: manager)
        await manager.startSession()
        let stateAfterStart = manager.state
        XCTAssertEqual(stateAfterStart, .recording)

        let result = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(result, .recordingActive)

        await manager.stopSession()
    }

    func testTranscriptionAlreadyAdmittedContinuesAfterLaterRecordingStart() async throws {
        try writeManifest(chunkCount: 1)
        let gated = SequenceGatedTranscriber()
        await gated.armGate(beforeSequenceNumber: 0)
        let manager = makeSessionManager()
        let service = makeService(transcriber: gated, sessionManager: manager)

        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        await waitUntilGateEntered(gated, sequenceNumber: 0)

        // Recording Start is allowed even though transcription is
        // in-flight — the already-admitted operation may continue.
        await manager.startSession()
        let stateAfterStart = manager.state
        XCTAssertEqual(stateAfterStart, .recording)
        await manager.stopSession()

        await service.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service)
    }

    func testBusyWhenAnotherOperationIsAlreadyActive() async throws {
        try writeManifest(chunkCount: 1)
        let gated = SequenceGatedTranscriber()
        await gated.armGate(beforeSequenceNumber: 0)
        let service = makeService(transcriber: gated)

        let first = await service.transcribe(sessionID: sessionID)
        let second = await service.transcribe(sessionID: sessionID)
        let third = await service.transcribe(sessionID: UUID())
        XCTAssertEqual(first, .admitted)
        XCTAssertEqual(second, .busy)
        XCTAssertEqual(third, .busy)

        await service.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service)
    }

    // MARK: - Execution

    func testMultiChunkSuccessProcessesInNumericOrderAndPublishesCompletedSegments() async throws {
        try writeManifest(chunkCount: 3)
        let transcriber = FakeTranscriber()
        transcriber.setOutput(FakeTranscriber.defaultFakeOutput.withText("seg0"), forSequenceNumber: 0)
        transcriber.setOutput(FakeTranscriber.defaultFakeOutput.withText("seg1"), forSequenceNumber: 1)
        transcriber.setOutput(FakeTranscriber.defaultFakeOutput.withText("seg2"), forSequenceNumber: 2)
        let service = makeService(transcriber: transcriber)

        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.completed))

        XCTAssertEqual(transcriber.recordedCalls.map(\.sequenceNumber), [0, 1, 2])
        for call in transcriber.recordedCalls {
            XCTAssertEqual(call.audioURL.lastPathComponent, TranscriptionArtifactPaths.canonicalChunkFileName(for: call.sequenceNumber))
        }

        let segments = await service.displayedSegments
        XCTAssertEqual(segments.count, 3)
        for (index, expectedText) in ["seg0", "seg1", "seg2"].enumerated() {
            if case .completed(let text) = segments[index].state {
                XCTAssertEqual(text, expectedText)
            } else {
                XCTFail("expected completed segment at \(index), got \(segments[index])")
            }
        }
    }

    func testFirstFailedChunkStopsSchedulingLaterChunksAndPreservesSuccessfulPrefix() async throws {
        try writeManifest(chunkCount: 3)
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "boom", retryDisposition: .permanent),
            forSequenceNumber: 1
        )
        let service = makeService(transcriber: transcriber)

        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.incomplete(completed: 1, total: 3)))

        // Chunk 2 was never scheduled after chunk 1 failed.
        XCTAssertEqual(transcriber.recordedCalls.map(\.sequenceNumber), [0, 1])
    }

    func testCancellationDuringInferenceStopsSchedulingAndLeavesChunkRetryable() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let gated = SequenceGatedTranscriber()
        await gated.armGate(beforeSequenceNumber: 0)
        let service = makeService(transcriber: gated)

        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        await waitUntilGateEntered(gated, sequenceNumber: 0)

        await service.cancel(sessionID: sessionID)
        let finalPhase = await waitUntilFinished(service)

        // Chunk 0's cancellation is recorded as a durable, retryable
        // failure by the underlying coordinator (not left ownerless
        // `.running`) — so the truthful classification is `.incomplete`,
        // not `.interrupted`. Chunk 1 was never attempted.
        XCTAssertEqual(finalPhase, .finished(.incomplete(completed: 0, total: 2)))
        let calls = await gated.calls
        XCTAssertEqual(calls.map(\.sequenceNumber), [0])

        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        let job0 = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job0?.state, .failed)
        XCTAssertEqual(job0?.lastFailure?.category, .cancellation)
        XCTAssertEqual(job0?.lastFailure?.retryDisposition, .retryable)

        let job1 = try await store.loadJob(sequenceNumber: 1, paths: artifactPaths)
        XCTAssertEqual(job1?.state, .queued)
    }

    func testColdReloadAfterSuccessDoesNotRerunInference() async throws {
        let manifest = try writeManifest(chunkCount: 2)

        // Simulate a prior, already-completed run by writing jobs/results
        // directly, bypassing any transcriber call.
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        for chunk in manifest.chunks {
            let source = TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID,
                chunkSequenceNumber: chunk.sequenceNumber,
                chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount,
                startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds,
                audioFormat: manifest.audioFormat
            )
            let attemptID = UUID()
            _ = try await store.createJobIfAbsent(
                TranscriptionJob(
                    schemaVersion: TranscriptionJob.currentSchemaVersion,
                    source: source, state: .completed, currentAttemptID: nil,
                    attemptCount: 1, lastFailure: nil, createdDate: Date(), updatedDate: Date()
                ),
                paths: artifactPaths
            )
            _ = try await store.commitResult(
                TranscriptResult(
                    schemaVersion: TranscriptResult.legacySchemaVersion,
                    source: source,
                    output: TranscriptionEngineOutput(text: "prior", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                    attemptID: attemptID,
                    completedDate: Date()
                ),
                paths: artifactPaths
            )
        }

        let service = makeService(transcriber: FailIfCalledTranscriber())
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.completed))
    }

    // MARK: - Recording independence

    func testRecordingStartAndStopDoNotWaitForInFlightTranscription() async throws {
        try writeManifest(chunkCount: 1)
        let gated = SequenceGatedTranscriber()
        await gated.armGate(beforeSequenceNumber: 0)
        let manager = makeSessionManager()
        let service = makeService(transcriber: gated, sessionManager: manager)

        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        await waitUntilGateEntered(gated, sequenceNumber: 0)

        let recordingStart = Date()
        await manager.startSession()
        await manager.stopSession()
        let recordingElapsed = Date().timeIntervalSince(recordingStart)

        // Bounded and fast — recording never awaited the still-hanging
        // transcription task.
        XCTAssertLessThan(recordingElapsed, 3.0)
        let finalRecordingState = manager.state
        XCTAssertEqual(finalRecordingState, .completed)

        await service.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service)
    }

    // MARK: - continueOrRetry

    func testContinueOrRetryRetriesEligibleFailedJobAndProcessesItSuccessfully() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        for chunk in manifest.chunks {
            let source = TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
            )
            var job = TranscriptionJob.newQueued(source: source, now: Date())
            if chunk.sequenceNumber == 0 {
                job.state = .failed
                job.lastFailure = TranscriptionFailure(
                    category: .engineThrew, message: "prior attempt", retryDisposition: .retryable,
                    failureDate: Date(), attemptNumber: 1
                )
            }
            _ = try await store.createJobIfAbsent(job, paths: artifactPaths)
        }

        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        let admission = await service.continueOrRetry(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.completed))
        XCTAssertEqual(transcriber.recordedCalls.map(\.sequenceNumber), [0, 1])
    }

    func testContinueOrRetryDoesNotRetryPermanentlyFailedJob() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        let chunk = manifest.chunks[0]
        let source = TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
        )
        var job = TranscriptionJob.newQueued(source: source, now: Date())
        job.state = .failed
        job.lastFailure = TranscriptionFailure(
            category: .engineThrew, message: "permanent", retryDisposition: .permanent, failureDate: Date(), attemptNumber: 1
        )
        _ = try await store.createJobIfAbsent(job, paths: artifactPaths)

        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        let admission = await service.continueOrRetry(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.incomplete(completed: 0, total: 1)))
        XCTAssertTrue(transcriber.recordedCalls.isEmpty, "a permanently-failed job must never be retried")
    }

    // MARK: - Source-snapshot mismatch blocks the whole operation (correction item 2)

    func testMismatchedPersistedJobBlocksOperationWithZeroTranscriberCalls() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        let chunk = manifest.chunks[0]
        var mismatchedSource = TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
        )
        mismatchedSource.frameCount += 1
        let job = TranscriptionJob.newQueued(source: mismatchedSource, now: Date())
        _ = try await store.createJobIfAbsent(job, paths: artifactPaths)
        // Read back from disk (not the in-memory constructed value) so the
        // before/after comparison isn't confounded by JSON round-trip date
        // precision — both sides go through the same serialization.
        let beforeLoad = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)

        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        if case .finished(.blocked) = finalPhase {} else { XCTFail("expected .blocked, got \(finalPhase)") }
        XCTAssertTrue(transcriber.recordedCalls.isEmpty)

        let afterLoad = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(afterLoad, beforeLoad, "the mismatched job must remain completely untouched")
    }

    // MARK: - peekStatus preserves integrity evidence without mutation (correction item 4)

    func testPeekStatusReportsCorruptJobAsBlockedWithoutMutation() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        try Data("not json".utf8).write(to: artifactPaths.jobURL(sequenceNumber: 0))

        let service = makeService(transcriber: FakeTranscriber(), store: store)
        let status = await service.peekStatus(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        if case .blocked = status {} else { XCTFail("expected .blocked for a corrupt job artifact, got \(status)") }

        let stillCorrupt = try? Data(contentsOf: artifactPaths.jobURL(sequenceNumber: 0))
        XCTAssertEqual(stillCorrupt.map { String(data: $0, encoding: .utf8) }, "not json")
    }

    func testPeekStatusReportsOrphanResultAsBlocked() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        let chunk = manifest.chunks[0]
        let source = TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
        )
        _ = try await store.commitResult(
            TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion, source: source,
                output: TranscriptionEngineOutput(text: "x", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                attemptID: UUID(), completedDate: Date()
            ),
            paths: artifactPaths
        )

        let service = makeService(transcriber: FakeTranscriber(), store: store)
        let status = await service.peekStatus(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        if case .blocked = status {} else { XCTFail("expected .blocked for an orphan result, got \(status)") }
    }

    func testPeekStatusDoesNotCreateTranscriptionDirectoriesWhileBrowsing() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let service = makeService(transcriber: FakeTranscriber())
        _ = await service.peekStatus(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        let transcriptionDirectory = sessionPaths.sessionDirectory.appendingPathComponent("transcription", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptionDirectory.path))
    }

    // MARK: - Error propagation (correction item 6)

    func testEnqueueStorageFailureIsSurfacedAsBlockedNotFalseIncomplete() async throws {
        try writeManifest(chunkCount: 1)
        let failingStore = FailingTranscriptionStore(wrapped: TranscriptionStore())
        await failingStore.setFailNextCreateJobIfAbsent(true)
        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: failingStore)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        if case .finished(.blocked) = finalPhase {} else { XCTFail("expected .blocked, got \(finalPhase)") }
        XCTAssertTrue(transcriber.recordedCalls.isEmpty)
    }

    func testTerminalReconciliationLoadFailureIsSurfacedAsBlockedNotFalseCompleted() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let realStore = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await realStore.ensureDirectoriesExist(paths: artifactPaths)
        let chunk = manifest.chunks[0]
        let source = TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
        )
        var completedJob = TranscriptionJob.newQueued(source: source, now: Date())
        completedJob.state = .completed
        _ = try await realStore.createJobIfAbsent(completedJob, paths: artifactPaths)
        _ = try await realStore.commitResult(
            TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion, source: source,
                output: TranscriptionEngineOutput(text: "hi", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                attemptID: UUID(), completedDate: Date()
            ),
            paths: artifactPaths
        )

        let failingStore = FailingTranscriptionStore(wrapped: realStore)
        // Call order for an already-complete session: (1) preflight, (2)
        // recovery `reconcileState`, (3) this service's own post-enqueue
        // `loadAllJobs`, (4) terminal `reconcileState`. Fail only the
        // terminal one so the earlier stages genuinely succeed first.
        await failingStore.setFailLoadAllJobArtifacts(onCallNumber: 4)
        let service = makeService(transcriber: FailIfCalledTranscriber(), store: failingStore)

        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        if case .finished(.blocked) = finalPhase {} else { XCTFail("expected .blocked, never a false .completed, got \(finalPhase)") }
    }

    // MARK: - Source preservation (correction item 5: success / failure / cancellation, each byte-verified)

    private func readSourceBytes(_ manifest: SessionManifest) throws -> (manifest: Data, chunks: [Data]) {
        let manifestBytes = try Data(contentsOf: sessionPaths.manifestURL)
        let chunkBytes = try manifest.chunks.map {
            try Data(contentsOf: sessionPaths.chunksDirectory.appendingPathComponent($0.fileName))
        }
        return (manifestBytes, chunkBytes)
    }

    func testSourcePreservationOnCompleteSuccess() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let before = try readSourceBytes(manifest)

        let service = makeService(transcriber: FakeTranscriber())
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.completed))

        let after = try readSourceBytes(manifest)
        XCTAssertEqual(before.manifest, after.manifest)
        XCTAssertEqual(before.chunks, after.chunks)
    }

    func testSourcePreservationOnFailure() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let before = try readSourceBytes(manifest)

        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "boom", retryDisposition: .permanent),
            forSequenceNumber: 1
        )
        let service = makeService(transcriber: transcriber)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.incomplete(completed: 1, total: 2)))

        let after = try readSourceBytes(manifest)
        XCTAssertEqual(before.manifest, after.manifest)
        XCTAssertEqual(before.chunks, after.chunks)
    }

    func testSourcePreservationOnCancellation() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let before = try readSourceBytes(manifest)

        let gated = SequenceGatedTranscriber()
        await gated.armGate(beforeSequenceNumber: 0)
        let service = makeService(transcriber: gated)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        await waitUntilGateEntered(gated, sequenceNumber: 0)
        await service.cancel(sessionID: sessionID)
        _ = await waitUntilFinished(service)

        let after = try readSourceBytes(manifest)
        XCTAssertEqual(before.manifest, after.manifest)
        XCTAssertEqual(before.chunks, after.chunks)
    }

    // MARK: - Cancellation boundaries (correction item 6: made deterministic)

    func testCancellationBeforeWorkerLaunchPreventsAnyProcessing() async throws {
        try writeManifest(chunkCount: 1)
        let hangingStore = HangingStoreWrapper(wrapped: TranscriptionStore())
        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: hangingStore)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, await !hangingStore.hasEnteredGate {
            await Task.yield()
        }
        let enteredGate = await hangingStore.hasEnteredGate
        XCTAssertTrue(enteredGate, "the run never reached its first store read")

        // Cancellation is requested strictly before the preflight's own
        // first store read has even returned — deterministically before
        // any chunk could possibly have been claimed or transcribed.
        await service.cancel(sessionID: sessionID)
        await hangingStore.release()
        _ = await waitUntilFinished(service)

        XCTAssertTrue(transcriber.recordedCalls.isEmpty, "cancellation observed before worker launch must prevent every transcriber call")
    }

    func testCancellationBetweenChunksStopsBeforeSecondChunkStarts() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        let gated = SequenceGatedTranscriber()
        await gated.armGate(beforeSequenceNumber: 0)
        let service = makeService(transcriber: gated)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        await waitUntilGateEntered(gated, sequenceNumber: 0)

        // Release chunk 0 to succeed *first*, then cancel immediately with
        // no intervening poll. `SequenceGatedTranscriber.transcribe` checks
        // `shouldReleaseSuccessfully` before `Task.checkCancellation()`, so
        // once `releaseSuccessfully()` has returned, chunk 0's own success
        // is deterministic regardless of when cancellation is next
        // observed. The production path from "chunk 0's transcribe()
        // returns" to "chunk 1's cancellation guard" additionally requires
        // several real, awaited store writes (`commitResult`,
        // `replaceJob`), while this call pair is two bare actor/MainActor
        // hops — that latency gap is what makes cancellation reliably land
        // before chunk 1's iteration, without needing to poll first (a
        // poll here would only add latency on our side of the race).
        await gated.releaseSuccessfully()
        await service.cancel(sessionID: sessionID)

        let store = TranscriptionStore()
        let finalPhase = await waitUntilFinished(service)
        let calls = await gated.calls
        XCTAssertEqual(calls.map(\.sequenceNumber), [0], "chunk 1 must never be attempted once cancellation is observed between chunks")

        let job0 = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job0?.state, .completed, "chunk 0 must have durably completed despite the mid-flight cancellation request")
        _ = finalPhase
    }

    func testAdmissionRemainsBusyUntilCleanupActuallyFinishes() async throws {
        try writeManifest(chunkCount: 1)
        let gated = SequenceGatedTranscriber()
        await gated.armGate(beforeSequenceNumber: 0)
        let service = makeService(transcriber: gated)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        await waitUntilGateEntered(gated, sequenceNumber: 0)

        await service.cancel(sessionID: sessionID)
        // Immediately after requesting cancellation — before cleanup has
        // actually finished — a new admission attempt must still see Busy.
        let raceAdmission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(raceAdmission, .busy)

        _ = await waitUntilFinished(service)
    }

    // MARK: - requestingPermission blocks admission

    func testRequestingPermissionStateBlocksNewTranscriptionAdmission() async throws {
        let hangingPermission = HangingPermissionService()
        let manager = makeSessionManager(permissionService: hangingPermission)
        let service = makeService(transcriber: FakeTranscriber(), sessionManager: manager)

        let startTask = Task { await manager.startSession() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, manager.state != .requestingPermission {
            await Task.yield()
        }
        XCTAssertEqual(manager.state, .requestingPermission)

        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .recordingActive)

        await hangingPermission.release(.granted)
        _ = await startTask.value
        await manager.stopSession()
    }

    // MARK: - Root/session-directory symlink safety (correction item 1)

    func testSymlinkedSessionsRootIsBlockedAndExternalTargetUntouched() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let manifestBytesBefore = try Data(contentsOf: sessionPaths.manifestURL)

        // `tempDirectory` (the would-be Sessions root) becomes a symlink to
        // a *different* real directory that itself contains this same
        // session layout — proving the target is never read/touched.
        let realRoot = tempDirectory!
        let externalRoot = realRoot.deletingLastPathComponent()
            .appendingPathComponent("ExternalRootCanary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: realRoot, to: externalRoot)
        try FileManager.default.createSymbolicLink(at: realRoot, withDestinationURL: externalRoot)
        defer { try? FileManager.default.removeItem(at: externalRoot) }

        let service = makeService(transcriber: FailIfCalledTranscriber())
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        if case .finished(.blocked) = finalPhase {} else { XCTFail("expected .blocked for a symlinked Sessions root, got \(finalPhase)") }

        let externalManifestURL = externalRoot.appendingPathComponent(sessionID.uuidString).appendingPathComponent("session.json")
        let manifestBytesAfter = try Data(contentsOf: externalManifestURL)
        XCTAssertEqual(manifestBytesBefore, manifestBytesAfter)
        _ = manifest
    }

    func testSymlinkedSelectedSessionDirectoryIsBlockedAndExternalTargetUntouched() async throws {
        try writeManifest(chunkCount: 1)
        let manifestBytesBefore = try Data(contentsOf: sessionPaths.manifestURL)

        let externalSessionDir = tempDirectory.appendingPathComponent("ExternalSessionCanary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: sessionPaths.sessionDirectory, to: externalSessionDir)
        try FileManager.default.createSymbolicLink(at: sessionPaths.sessionDirectory, withDestinationURL: externalSessionDir)
        defer { try? FileManager.default.removeItem(at: externalSessionDir) }

        let service = makeService(transcriber: FailIfCalledTranscriber())
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        if case .finished(.blocked) = finalPhase {} else { XCTFail("expected .blocked for a symlinked session directory, got \(finalPhase)") }

        let manifestBytesAfter = try Data(contentsOf: externalSessionDir.appendingPathComponent("session.json"))
        XCTAssertEqual(manifestBytesBefore, manifestBytesAfter)
    }

    // MARK: - Job/result relationship integration (correction item 2)

    private func writeJobAndResult(
        manifest: SessionManifest,
        store: TranscriptionStore,
        artifactPaths: TranscriptionArtifactPaths,
        sequenceNumber: Int,
        jobState: TranscriptionJobState,
        jobAttemptID: UUID?,
        resultAttemptID: UUID,
        lastFailure: TranscriptionFailure? = nil
    ) async throws {
        let chunk = manifest.chunks[sequenceNumber]
        let source = TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
        )
        var job = TranscriptionJob.newQueued(source: source, now: Date())
        job.state = jobState
        job.currentAttemptID = jobAttemptID
        job.lastFailure = lastFailure
        _ = try await store.createJobIfAbsent(job, paths: artifactPaths)
        _ = try await store.commitResult(
            TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion, source: source,
                output: TranscriptionEngineOutput(text: "x", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                attemptID: resultAttemptID, completedDate: Date()
            ),
            paths: artifactPaths
        )
    }

    func testRunningJobWithWrongResultAttemptBlocksWithZeroMutationAndZeroCalls() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        let jobAttemptID = UUID()
        try await writeJobAndResult(
            manifest: manifest, store: store, artifactPaths: artifactPaths, sequenceNumber: 0,
            jobState: .running, jobAttemptID: jobAttemptID, resultAttemptID: UUID() // deliberately different
        )
        let beforeJob = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)

        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        if case .finished(.blocked) = finalPhase {} else { XCTFail("expected .blocked, got \(finalPhase)") }
        XCTAssertTrue(transcriber.recordedCalls.isEmpty)

        let afterJob = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(beforeJob, afterJob, "the attempt-mismatched job must remain completely untouched")
    }

    func testQueuedJobWithResultBlocksWithZeroMutationAndZeroCalls() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        try await writeJobAndResult(
            manifest: manifest, store: store, artifactPaths: artifactPaths, sequenceNumber: 0,
            jobState: .queued, jobAttemptID: nil, resultAttemptID: UUID()
        )

        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        if case .finished(.blocked) = finalPhase {} else { XCTFail("expected .blocked, got \(finalPhase)") }
        XCTAssertTrue(transcriber.recordedCalls.isEmpty)
    }

    func testContinueOrRetryDoesNotRetryFailedJobThatAlreadyHasAResult() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        try await writeJobAndResult(
            manifest: manifest, store: store, artifactPaths: artifactPaths, sequenceNumber: 0,
            jobState: .failed, jobAttemptID: nil, resultAttemptID: UUID(),
            lastFailure: TranscriptionFailure(category: .engineThrew, message: "x", retryDisposition: .retryable, failureDate: Date(), attemptNumber: 1)
        )

        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        let admission = await service.continueOrRetry(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        if case .finished(.blocked) = finalPhase {} else { XCTFail("expected .blocked, got \(finalPhase)") }
        XCTAssertTrue(transcriber.recordedCalls.isEmpty, "a failed job with an immutable result artifact must never be retried")
    }

    // MARK: - Post-enqueue reload failure (correction item 4)

    func testPostEnqueueJobReloadFailureIsSurfacedAsBlockedNotFalseState() async throws {
        try writeManifest(chunkCount: 1)
        let failingStore = FailingTranscriptionStore(wrapped: TranscriptionStore())
        // Call order for a fresh session: (1) preflight's own
        // `loadAllJobArtifacts`, (2) recovery `reconcileState`'s, (3) this
        // service's own post-enqueue reload. Fail only the third.
        await failingStore.setFailLoadAllJobArtifacts(onCallNumber: 3)
        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber, store: failingStore)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        if case .finished(.blocked) = finalPhase {} else { XCTFail("expected .blocked, got \(finalPhase)") }
        XCTAssertTrue(transcriber.recordedCalls.isEmpty, "no speculative work must be processed after a failed post-enqueue reload")
    }

    // MARK: - Service-level durability recovery (correction item 7)

    func testDurabilityConfirmationFailureThenSuccessPromotesToCompletedWithoutDuplicateInference() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let realStore = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await realStore.ensureDirectoriesExist(paths: artifactPaths)
        let chunk = manifest.chunks[0]
        let source = TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
        )
        let attemptID = UUID()
        var runningJob = TranscriptionJob.newQueued(source: source, now: Date())
        runningJob.state = .running
        runningJob.currentAttemptID = attemptID
        _ = try await realStore.createJobIfAbsent(runningJob, paths: artifactPaths)
        _ = try await realStore.commitResult(
            TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion, source: source,
                output: TranscriptionEngineOutput(text: "hi", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                attemptID: attemptID, completedDate: Date()
            ),
            paths: artifactPaths
        )

        let failingStore = FailingTranscriptionStore(wrapped: realStore)
        await failingStore.setForcedConfirmResultsDirectoryDurable(false)
        let transcriber = FailIfCalledTranscriber()
        let service = makeService(transcriber: transcriber, store: failingStore)

        let admission1 = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission1, .admitted)
        let phase1 = await waitUntilFinished(service)
        XCTAssertEqual(phase1, .finished(.recoveryPending), "durability-unconfirmed must never report Completed")

        let resultBeforePromotion = try await realStore.loadResult(sequenceNumber: 0, paths: artifactPaths)

        // Durability confirmation now succeeds.
        await failingStore.setForcedConfirmResultsDirectoryDurable(true)
        let admission2 = await service.continueOrRetry(sessionID: sessionID)
        XCTAssertEqual(admission2, .admitted)
        let phase2 = await waitUntilFinished(service)
        XCTAssertEqual(phase2, .finished(.completed))

        let resultAfterPromotion = try await realStore.loadResult(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(resultBeforePromotion, resultAfterPromotion, "the canonical result must remain unchanged across recovery")
    }

    // MARK: - peekOrderedSegments (T4-B: reopening a saved transcript without inference)

    func testPeekOrderedSegmentsReturnsNilForANonCompletedSession() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let service = makeService(transcriber: FailIfCalledTranscriber())
        let segments = await service.peekOrderedSegments(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertNil(segments)
    }

    func testPeekOrderedSegmentsAssemblesCorrectOrderWithZeroInferenceCalls() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        for (index, chunk) in manifest.chunks.enumerated() {
            let source = TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
            )
            var job = TranscriptionJob.newQueued(source: source, now: Date())
            job.state = .completed
            _ = try await store.createJobIfAbsent(job, paths: artifactPaths)
            // Chunk 0 has genuinely empty (silent) transcript text — a
            // valid, non-vacuous completed result.
            let text = index == 0 ? "" : "seg\(index)"
            _ = try await store.commitResult(
                TranscriptResult(
                    schemaVersion: TranscriptResult.legacySchemaVersion, source: source,
                    output: TranscriptionEngineOutput(text: text, engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                    attemptID: UUID(), completedDate: Date()
                ),
                paths: artifactPaths
            )
        }

        let transcriber = FailIfCalledTranscriber()
        let service = makeService(transcriber: transcriber, store: store)
        let segments = await service.peekOrderedSegments(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        guard let segments else { return XCTFail("expected non-nil ordered segments for a completed session") }
        XCTAssertEqual(segments.map(\.sequenceNumber), [0, 1])
        if case .completed(let text0) = segments[0].state {
            XCTAssertEqual(text0, "", "an empty transcript is a valid completed result, not a missing one")
        } else {
            XCTFail("expected chunk 0 completed with empty text, got \(segments[0])")
        }
        if case .completed(let text1) = segments[1].state {
            XCTAssertEqual(text1, "seg1")
        } else {
            XCTFail("expected chunk 1 completed, got \(segments[1])")
        }
    }

    func testPeekingStatusAndSegmentsMutatesNothingOnDisk() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        let chunk = manifest.chunks[0]
        let source = TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
        )
        var job = TranscriptionJob.newQueued(source: source, now: Date())
        job.state = .completed
        _ = try await store.createJobIfAbsent(job, paths: artifactPaths)
        _ = try await store.commitResult(
            TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion, source: source,
                output: TranscriptionEngineOutput(text: "hi", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                attemptID: UUID(), completedDate: Date()
            ),
            paths: artifactPaths
        )
        let jobBytesBefore = try Data(contentsOf: artifactPaths.jobURL(sequenceNumber: 0))
        let resultBytesBefore = try Data(contentsOf: artifactPaths.resultURL(sequenceNumber: 0))

        let service = makeService(transcriber: FailIfCalledTranscriber(), store: store)
        _ = await service.peekStatus(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        _ = await service.peekOrderedSegments(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)

        let jobBytesAfter = try Data(contentsOf: artifactPaths.jobURL(sequenceNumber: 0))
        let resultBytesAfter = try Data(contentsOf: artifactPaths.resultURL(sequenceNumber: 0))
        XCTAssertEqual(jobBytesBefore, jobBytesAfter, "peeking status/segments must never mutate the job artifact")
        XCTAssertEqual(resultBytesBefore, resultBytesAfter, "peeking status/segments must never mutate the result artifact")
    }

    // MARK: - Shared-observation coherence across independent presentation observers (items 3, 14, 22)

    func testTwoIndependentObserversSeeTheSameSharedServicePhaseUpdatesCoherently() async throws {
        try writeManifest(chunkCount: 1)
        let gated = SequenceGatedTranscriber()
        await gated.armGate(beforeSequenceNumber: 0)
        let service = makeService(transcriber: gated)

        var observerA: [CompletedSessionTranscriptionService.OperationPhase] = []
        var observerB: [CompletedSessionTranscriptionService.OperationPhase] = []
        var cancellables: Set<AnyCancellable> = []
        service.$phase.sink { observerA.append($0) }.store(in: &cancellables)
        service.$phase.sink { observerB.append($0) }.store(in: &cancellables)

        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        await waitUntilGateEntered(gated, sequenceNumber: 0)
        await service.cancel(sessionID: sessionID)
        await gated.releaseSuccessfully()
        _ = await waitUntilFinished(service)

        // Both independent subscribers observed the exact same sequence of
        // published phase transitions from the one shared service — one
        // window's view is never out of sync with another's, and a
        // transient mid-operation phase is never independently
        // reinterpreted as corruption by a second observer, since both
        // read the identical published value.
        XCTAssertEqual(observerA.count, observerB.count)
        XCTAssertEqual(observerA, observerB)
        XCTAssertTrue(observerA.contains(.preparing))
        cancellables.removeAll()
    }

    // MARK: - Correction 1: ownership must not outlive actual cleanup

    func testActiveSessionIDIsClearedAfterCleanupActuallyFinishes() async throws {
        try writeManifest(chunkCount: 1)
        let service = makeService(transcriber: FakeTranscriber())
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        _ = await waitUntilFinished(service)

        let activeAfterFinish = await service.activeSessionID
        XCTAssertNil(activeAfterFinish, "activeSessionID must not still claim ownership after the operation has released it")
    }

    func testCancelIsANoOpAfterOwnershipHasAlreadyBeenReleased() async throws {
        try writeManifest(chunkCount: 1)
        let service = makeService(transcriber: FakeTranscriber())
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finishedPhase = await waitUntilFinished(service)

        await service.cancel(sessionID: sessionID)
        // Cancel after release must not disturb the already-terminal phase.
        let phaseAfterLateCancel = await service.phase
        XCTAssertEqual(phaseAfterLateCancel, finishedPhase)
    }

    func testTerminalIncompleteSessionShowsEligibleForContinueAfterOwnershipReleases() async throws {
        try writeManifest(chunkCount: 3)
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "boom", retryDisposition: .permanent),
            forSequenceNumber: 1
        )
        let service = makeService(transcriber: transcriber)
        let admission = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admission, .admitted)
        let finalPhase = await waitUntilFinished(service)
        XCTAssertEqual(finalPhase, .finished(.incomplete(completed: 1, total: 3)))

        // Ownership released, so the pure availability calculator now
        // reports this session eligible for Continue/Retry — exactly the
        // workflow Correction 1 restores.
        let activeSessionID = await service.activeSessionID
        let ownership = SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: activeSessionID, sessionID: sessionID)
        XCTAssertEqual(ownership, .none)
        let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: .incomplete(completed: 1, total: 3), ownership: ownership)
        XCTAssertTrue(availability.canContinueOrRetry)
        XCTAssertFalse(availability.canCancel)
    }

    // MARK: - Correction 3: no cross-session transcript leakage

    func testStartingANewOperationSynchronouslyClearsThePreviousSessionsDisplayedSegments() async throws {
        let manifestA = try writeManifest(chunkCount: 1)
        let transcriberA = FakeTranscriber()
        transcriberA.setOutput(FakeTranscriber.defaultFakeOutput.withText("a-text"), forSequenceNumber: 0)
        let service = makeService(transcriber: transcriberA)

        let admissionA = await service.transcribe(sessionID: sessionID)
        XCTAssertEqual(admissionA, .admitted)
        _ = await waitUntilFinished(service)
        let segmentsAfterA = await service.displayedSegments
        XCTAssertFalse(segmentsAfterA.isEmpty, "setup: session A must have produced a displayed transcript")

        // Start a different session B (a nonexistent one is sufficient —
        // admission itself, synchronously, must already have cleared A's
        // leftover segments before B's own run() even begins).
        let sessionBID = UUID()
        let admissionB = await service.transcribe(sessionID: sessionBID)
        XCTAssertEqual(admissionB, .admitted)
        let segmentsImmediatelyAfterBAdmitted = await service.displayedSegments
        XCTAssertTrue(segmentsImmediatelyAfterBAdmitted.isEmpty, "A's transcript must never remain visible once B is the active session")

        _ = await waitUntilFinished(service)
    }
}

/// A permission service whose `requestPermission()` hangs until explicitly
/// released — lets a test deterministically observe `SessionManager` in
/// `.requestingPermission` before it resolves.
private actor HangingPermissionService: MicrophonePermissionServing {
    private var continuation: CheckedContinuation<PermissionStatus, Never>?

    nonisolated func currentStatus() -> PermissionStatus { .undetermined }

    func requestPermission() async -> PermissionStatus {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ status: PermissionStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}

private extension TranscriptionEngineOutput {
    func withText(_ text: String) -> TranscriptionEngineOutput {
        var copy = self
        copy.text = text
        return copy
    }
}

/// A transcriber that fails the test if ever invoked — used to prove a
/// cold reload of an already-completed session never re-runs inference.
private final class FailIfCalledTranscriber: Transcribing, @unchecked Sendable {
    func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
        XCTFail("transcriber must not be invoked for an already-completed session")
        throw UnclassifiedFakeError()
    }
}
