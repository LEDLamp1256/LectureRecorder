import AVFoundation
import Combine
import XCTest
@testable import LectureRecorder

private struct TemporaryDirectoryFileSystemLocator: FileSystemLocating {
    let rootDirectory: URL

    func sessionsRootDirectory() throws -> URL {
        try DefaultFileSystemLocator.ensureDirectoryExists(rootDirectory)
        return rootDirectory
    }

    func paths(for sessionID: UUID) throws -> SessionPaths {
        try DefaultFileSystemLocator.buildPaths(rootDirectory: try sessionsRootDirectory(), sessionID: sessionID)
    }
}

private enum TestInjectedError: Error, LocalizedError, Sendable {
    case injected

    var errorDescription: String? { "Injected test failure" }
}

/// Wraps a real `SessionStore` and lets individual tests force specific
/// operations to fail, so `SessionManager`'s failure-handling paths can be
/// exercised deterministically.
private actor FailingSessionStore: SessionStoring {
    private let wrapped: SessionStore
    private var failCreateDirectories = false
    private var failCreateLogger = false
    private var writeManifestFailureQueue: [Bool] = []

    init(wrapped: SessionStore) {
        self.wrapped = wrapped
    }

    func setFailCreateDirectoriesFlag(_ value: Bool) {
        failCreateDirectories = value
    }

    func setFailCreateLoggerFlag(_ value: Bool) {
        failCreateLogger = value
    }

    /// Each call to `writeManifest` pops one entry from the front of this
    /// queue: `true` forces that call to fail, `false` lets it delegate to
    /// the wrapped real store. Once the queue is empty, all further calls
    /// succeed normally.
    func setWriteManifestFailureQueue(_ values: [Bool]) {
        writeManifestFailureQueue = values
    }

    func createSessionDirectories(sessionID: UUID) async throws -> SessionPaths {
        if failCreateDirectories {
            throw TestInjectedError.injected
        }
        return try await wrapped.createSessionDirectories(sessionID: sessionID)
    }

    func writeManifest(_ manifest: SessionManifest, paths: SessionPaths) async throws {
        if !writeManifestFailureQueue.isEmpty {
            let shouldFail = writeManifestFailureQueue.removeFirst()
            if shouldFail {
                throw TestInjectedError.injected
            }
        }
        try await wrapped.writeManifest(manifest, paths: paths)
    }

    func readManifest(paths: SessionPaths) async throws -> SessionManifest {
        try await wrapped.readManifest(paths: paths)
    }

    func createSessionLogger(paths: SessionPaths) async throws -> SessionFileLogger {
        if failCreateLogger {
            throw TestInjectedError.injected
        }
        return try await wrapped.createSessionLogger(paths: paths)
    }

    func sessionsRootDirectory() async throws -> URL {
        try await wrapped.sessionsRootDirectory()
    }
}

@MainActor
final class SessionManagerTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionManager: SessionManager!
    private var permissionService: MockMicrophonePermissionService!
    private var failingStore: FailingSessionStore!
    private var captureService: MockAudioCaptureService!
    private var chunkWriterFactory: FakeAudioChunkWriterFactory!

    private func makeTestAudioFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        )!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let locator = TemporaryDirectoryFileSystemLocator(rootDirectory: tempDirectory)
        let realStore = SessionStore(locator: locator)
        failingStore = FailingSessionStore(wrapped: realStore)
        permissionService = MockMicrophonePermissionService(status: .granted)
        captureService = MockAudioCaptureService(formatToPrepare: makeTestAudioFormat())
        chunkWriterFactory = FakeAudioChunkWriterFactory()
        sessionManager = SessionManager(
            store: failingStore,
            permissionService: permissionService,
            captureService: captureService,
            chunkWriterFactory: chunkWriterFactory
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    /// Reads back the persisted manifest for `sessionID` directly from
    /// disk, bypassing `SessionManager` entirely, so tests can confirm
    /// what was actually written rather than trusting in-memory state.
    private func readPersistedManifest(sessionID: UUID) throws -> SessionManifest {
        let manifestURL = tempDirectory
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathComponent("session.json")
        return try AtomicFileWriter.readJSON(SessionManifest.self, from: manifestURL)
    }

    // MARK: - Happy path

    func testStartSessionTransitionsToRecordingAndCreatesDirectories() async throws {
        await sessionManager.startSession()

        XCTAssertEqual(sessionManager.state, .recording)
        let session = try XCTUnwrap(sessionManager.activeSession)
        XCTAssertNil(sessionManager.lastCompletedSession)

        let sessionDirectory = tempDirectory.appendingPathComponent(session.sessionID.uuidString)
        let manifestURL = sessionDirectory.appendingPathComponent("session.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        let persisted: SessionManifest = try AtomicFileWriter.readJSON(SessionManifest.self, from: manifestURL)
        XCTAssertEqual(persisted.sessionID, session.sessionID)
        XCTAssertEqual(persisted.status, .recording)
    }

    func testStopSessionTransitionsToCompletedAndMovesToLastCompleted() async throws {
        await sessionManager.startSession()
        await sessionManager.stopSession()

        XCTAssertEqual(sessionManager.state, .completed)
        XCTAssertNil(sessionManager.activeSession)

        let session = try XCTUnwrap(sessionManager.lastCompletedSession)
        XCTAssertEqual(session.status, .completed)
        XCTAssertTrue(session.endedCleanly)
        XCTAssertEqual(session.endReason, .userStopped)
        XCTAssertNotNil(session.endDate)
    }

    func testStartSessionIgnoredWhenAlreadyRecording() async throws {
        await sessionManager.startSession()
        let firstSessionID = sessionManager.activeSession?.sessionID

        await sessionManager.startSession()
        let secondSessionID = sessionManager.activeSession?.sessionID

        XCTAssertEqual(sessionManager.state, .recording)
        XCTAssertEqual(firstSessionID, secondSessionID)
    }

    func testStopSessionIgnoredWhenNotRecording() async throws {
        await sessionManager.stopSession()
        XCTAssertEqual(sessionManager.state, .idle)
    }

    func testRepeatedStartAndStopCycles() async throws {
        await sessionManager.startSession()
        await sessionManager.stopSession()
        let firstSessionID = sessionManager.lastCompletedSession?.sessionID

        // .completed permits starting directly, without an explicit reset,
        // because a clean stop leaves no resources needing cleanup.
        await sessionManager.startSession()
        await sessionManager.stopSession()
        let secondSessionID = sessionManager.lastCompletedSession?.sessionID

        XCTAssertEqual(sessionManager.state, .completed)
        XCTAssertNotEqual(firstSessionID, secondSessionID)
    }

    // MARK: - Permission failure

    func testStartSessionFailsWhenPermissionDeniedAndResetsCleanly() async throws {
        permissionService.status = .denied

        await sessionManager.startSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed state, got \(sessionManager.state)")
            return
        }
        XCTAssertNil(sessionManager.unresolvedIssue)
        XCTAssertTrue(sessionManager.canReset)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertTrue(contents.isEmpty)

        sessionManager.resetAfterFailure()
        XCTAssertEqual(sessionManager.state, .idle)
        XCTAssertTrue(sessionManager.canStart)
    }

    // MARK: - Preparation failure

    func testPreparationFailureResolvesAutomaticallyWhenFailureRecordCanBePersisted() async throws {
        await failingStore.setFailCreateLoggerFlag(true)

        await sessionManager.startSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed state, got \(sessionManager.state)")
            return
        }
        XCTAssertNil(sessionManager.unresolvedIssue, "Failure record was persisted successfully; nothing should remain unresolved")
        XCTAssertNil(sessionManager.activeSession)
        XCTAssertTrue(sessionManager.canReset)
        XCTAssertFalse(sessionManager.canStart)

        sessionManager.resetAfterFailure()
        XCTAssertEqual(sessionManager.state, .idle)
        XCTAssertTrue(sessionManager.canStart)
    }

    /// Case 1: the initial `.recording` manifest write succeeds, logger
    /// creation fails, and the subsequent attempt to persist the
    /// `.failed` failure record also fails. `activeSession` must be the
    /// original, confirmed-persisted `.recording` manifest — never the
    /// unconfirmed `.failed` one.
    func testPreparationFailureRemainsUnresolvedWhenFailureManifestCannotBePersisted() async throws {
        await failingStore.setFailCreateLoggerFlag(true)
        // First write (initial "recording" manifest) succeeds; second
        // write (the failure record written during cleanup) fails.
        await failingStore.setWriteManifestFailureQueue([false, true])

        await sessionManager.startSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed state, got \(sessionManager.state)")
            return
        }
        let issue = try XCTUnwrap(sessionManager.unresolvedIssue)
        XCTAssertTrue(issue.canRetry)
        XCTAssertFalse(sessionManager.canStart, "Must not be able to start a new session while unresolved")
        XCTAssertFalse(sessionManager.canReset, "Must not be able to reset while unresolved")

        // activeSession must be the original prepared .recording manifest
        // (confirmed persisted), not the unconfirmed .failed one.
        let active = try XCTUnwrap(sessionManager.activeSession)
        XCTAssertEqual(active.sessionID, issue.sessionID)
        XCTAssertEqual(active.status, .recording)
        XCTAssertNil(active.failureDescription)
        XCTAssertNil(active.endDate)

        // Confirm the .recording manifest that IS on disk still matches
        // what's exposed as activeSession (i.e. we didn't just get lucky
        // with in-memory state).
        let onDisk = try readPersistedManifest(sessionID: issue.sessionID)
        XCTAssertEqual(onDisk.status, .recording)

        // Retry must persist the pending .failed manifest.
        await sessionManager.retryResolution()
        XCTAssertNil(sessionManager.unresolvedIssue)
        XCTAssertTrue(sessionManager.canReset)

        let afterRetry = try readPersistedManifest(sessionID: issue.sessionID)
        XCTAssertEqual(afterRetry.status, .failed)
        XCTAssertNotNil(afterRetry.failureDescription)
    }

    /// Case 2: the initial `.recording` manifest write itself fails, and
    /// the subsequent attempt to persist the `.failed` failure record
    /// also fails. Since the initial write was never confirmed
    /// persisted, `activeSession` must be `nil`.
    func testPreparationFailureWhenInitialManifestNeverPersistedLeavesActiveSessionNil() async throws {
        // First write (the initial "recording" manifest) fails; second
        // write (the failure record written during cleanup) fails too.
        await failingStore.setWriteManifestFailureQueue([true, true])

        await sessionManager.startSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed state, got \(sessionManager.state)")
            return
        }
        let issue = try XCTUnwrap(sessionManager.unresolvedIssue)
        XCTAssertTrue(issue.canRetry)

        XCTAssertNil(sessionManager.activeSession, "Initial manifest write was never confirmed persisted, so activeSession must be nil")
        XCTAssertFalse(sessionManager.canStart, "Must not be able to start a new session while unresolved")
        XCTAssertFalse(sessionManager.canReset, "Must not be able to reset while unresolved")

        // Retry must persist the pending .failed manifest.
        await sessionManager.retryResolution()
        XCTAssertNil(sessionManager.unresolvedIssue)
        XCTAssertNil(sessionManager.activeSession)
        XCTAssertTrue(sessionManager.canReset)

        let afterRetry = try readPersistedManifest(sessionID: issue.sessionID)
        XCTAssertEqual(afterRetry.status, .failed)
        XCTAssertNotNil(afterRetry.failureDescription)
    }

    func testStartingNewSessionIsBlockedWhileUnresolvedPreparationFailureExists() async throws {
        await failingStore.setFailCreateLoggerFlag(true)
        await failingStore.setWriteManifestFailureQueue([false, true])
        await sessionManager.startSession()

        let unresolvedSessionID = sessionManager.unresolvedIssue?.sessionID
        XCTAssertNotNil(sessionManager.unresolvedIssue)

        await sessionManager.startSession()

        XCTAssertEqual(
            sessionManager.unresolvedIssue?.sessionID, unresolvedSessionID,
            "A blocked start must not replace the unresolved session"
        )
        guard case .failed = sessionManager.state else {
            XCTFail("Expected state to remain .failed, got \(sessionManager.state)")
            return
        }
    }

    func testRetryResolvesPreparationFailureAndAllowsReset() async throws {
        await failingStore.setFailCreateLoggerFlag(true)
        await failingStore.setWriteManifestFailureQueue([false, true])
        await sessionManager.startSession()
        XCTAssertNotNil(sessionManager.unresolvedIssue)

        // The retried write is no longer forced to fail (queue is empty by now).
        await sessionManager.retryResolution()

        XCTAssertNil(sessionManager.unresolvedIssue)
        XCTAssertNil(sessionManager.activeSession)
        guard case .failed = sessionManager.state else {
            XCTFail("Expected state to remain .failed after a resolved preparation failure, got \(sessionManager.state)")
            return
        }
        XCTAssertTrue(sessionManager.canReset)

        sessionManager.resetAfterFailure()
        XCTAssertEqual(sessionManager.state, .idle)
    }

    // MARK: - Stop finalization failure

    func testStopFinalizationFailureKeepsSessionUnresolvedAndBlocksNewSession() async throws {
        await sessionManager.startSession()
        let sessionID = try XCTUnwrap(sessionManager.activeSession?.sessionID)

        await failingStore.setWriteManifestFailureQueue([true])
        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed state, got \(sessionManager.state)")
            return
        }
        let issue = try XCTUnwrap(sessionManager.unresolvedIssue)
        XCTAssertEqual(issue.sessionID, sessionID)
        XCTAssertTrue(issue.canRetry)

        // activeSession must be the last CONFIRMED state (.recording),
        // not the unconfirmed .completed attempt.
        XCTAssertEqual(sessionManager.activeSession?.sessionID, sessionID)
        XCTAssertEqual(sessionManager.activeSession?.status, .recording)
        XCTAssertNil(sessionManager.lastCompletedSession)
        XCTAssertFalse(sessionManager.canStart)

        await sessionManager.startSession()
        XCTAssertEqual(
            sessionManager.activeSession?.sessionID, sessionID,
            "Must not start a new session while the previous one is unresolved"
        )
    }

    func testRetryAfterStopFinalizationFailureCompletesSessionAndAllowsNewStart() async throws {
        await sessionManager.startSession()
        let firstSessionID = try XCTUnwrap(sessionManager.activeSession?.sessionID)

        await failingStore.setWriteManifestFailureQueue([true])
        await sessionManager.stopSession()
        XCTAssertNotNil(sessionManager.unresolvedIssue)

        await sessionManager.retryResolution()

        XCTAssertNil(sessionManager.unresolvedIssue)
        XCTAssertNil(sessionManager.activeSession)
        XCTAssertEqual(sessionManager.state, .completed)
        XCTAssertEqual(sessionManager.lastCompletedSession?.sessionID, firstSessionID)
        XCTAssertTrue(sessionManager.canStart)

        await sessionManager.startSession()
        let secondSessionID = sessionManager.activeSession?.sessionID
        XCTAssertNotEqual(secondSessionID, firstSessionID)
        XCTAssertEqual(sessionManager.state, .recording)
    }

    func testDiscardUnresolvedStopFailureAllowsResetWithoutMarkingCompleted() async throws {
        await sessionManager.startSession()
        let sessionID = try XCTUnwrap(sessionManager.activeSession?.sessionID)

        await failingStore.setWriteManifestFailureQueue([true])
        await sessionManager.stopSession()
        XCTAssertNotNil(sessionManager.unresolvedIssue)

        await sessionManager.discardUnresolvedSession()

        XCTAssertNil(sessionManager.unresolvedIssue)
        XCTAssertNil(sessionManager.activeSession)
        XCTAssertNil(sessionManager.lastCompletedSession, "Discarding must not fabricate a completed session")
        guard case .failed = sessionManager.state else {
            XCTFail("Expected state to remain .failed, got \(sessionManager.state)")
            return
        }

        sessionManager.resetAfterFailure()
        XCTAssertEqual(sessionManager.state, .idle)
        XCTAssertTrue(sessionManager.canStart)

        // The originally-troubled session's ID must not leak into the next session.
        await sessionManager.startSession()
        XCTAssertNotEqual(sessionManager.activeSession?.sessionID, sessionID)
    }

    // MARK: - Stage B: inert capture dependency injection

    func testConstructionWithCaptureServiceLeavesInitialStateUnchanged() {
        XCTAssertEqual(sessionManager.state, .idle)
        XCTAssertNil(sessionManager.activeSession)
        XCTAssertNil(sessionManager.lastCompletedSession)
        XCTAssertNil(sessionManager.unresolvedIssue)
        XCTAssertTrue(sessionManager.canStart)
    }

    /// A successful `prepare()` on the injected mock is only possible if
    /// its cycle state is still exactly `.idle` — `prepare()` throws
    /// `prepareCalledFromInvalidState` from any other state, and the only
    /// way to leave `.idle` is a *successful* `prepare()` call. This test
    /// therefore deterministically proves `prepare()` itself was never
    /// called during `SessionManager`'s construction, using only the
    /// mock's existing public API — no new seam.
    ///
    /// It does not, on its own, distinguish "start() was never called"
    /// from "start() was called but threw" — a `start()` attempt from
    /// `.idle` throws `startCalledFromInvalidState` without mutating
    /// `cycleState`, so a hypothetical swallowed `start()` call would not
    /// be caught by this assertion alone. As of Stage C, `SessionManager`
    /// does call `captureService` from `startSession()`/shutdown — this
    /// test only proves construction itself (`init`) touches nothing.
    func testConstructionInvokesNoCaptureOperation() throws {
        XCTAssertNoThrow(try captureService.prepare())
    }

    // MARK: - Stage C: helpers

    private func makeChunkMetadata(sequenceNumber: Int) -> ChunkMetadata {
        ChunkMetadata(
            sequenceNumber: sequenceNumber,
            fileName: "chunk_\(sequenceNumber).caf",
            startOffsetSeconds: Double(sequenceNumber) * 30.0,
            durationSeconds: 30.0,
            frameCount: 240_000,
            state: .completed
        )
    }

    private func makeTestBuffer(frameCount: AVAudioFrameCount = 10) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: makeTestAudioFormat(), frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        return buffer
    }

    // MARK: - Stage C: Start wiring

    func testStartSessionPersistsNegotiatedFormatNotDefault() async throws {
        await sessionManager.startSession()

        XCTAssertEqual(sessionManager.state, .recording)
        let session = try XCTUnwrap(sessionManager.activeSession)
        XCTAssertEqual(session.audioFormat.sampleRate, makeTestAudioFormat().sampleRate)
        XCTAssertNotEqual(session.audioFormat, AudioFormatDescriptor.defaultTarget)
    }

    func testStartSessionConstructsWriterWithSessionChunksDirectoryNegotiatedFormatAndThirtySecondDuration() async throws {
        await sessionManager.startSession()

        let calls = chunkWriterFactory.recordedCalls
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.targetChunkDurationSeconds, 30.0)
        XCTAssertEqual(call.format.sampleRate, makeTestAudioFormat().sampleRate)
        XCTAssertTrue(call.chunksDirectory.path.hasSuffix("chunks"))
    }

    func testBufferInjectedAfterStartReachesWriter() async throws {
        let writer = FakeAudioChunkWriter()
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        captureService.injectBuffer(makeTestBuffer())

        XCTAssertEqual(writer.acceptBufferCallCount, 1)
    }

    // MARK: - Stage C: Start-callback race safety

    func testBufferCallbackInvokedBeforeMockStartReturnsReachesWriter() async throws {
        let writer = FakeAudioChunkWriter()
        chunkWriterFactory.setWriterToReturn(writer)

        struct SendableBufferBox: @unchecked Sendable {
            let buffer: AVAudioPCMBuffer
        }
        let box = SendableBufferBox(buffer: makeTestBuffer())

        captureService.setStartCommitHookForTesting { onBuffer, _ in
            onBuffer(box.buffer)
        }

        await sessionManager.startSession()

        XCTAssertEqual(sessionManager.state, .recording)
        XCTAssertEqual(
            writer.acceptBufferCallCount, 1,
            "a buffer delivered synchronously during start(), before it returns, must still reach the already-installed writer"
        )
    }

    func testFailureCallbackInvokedBeforeMockStartReturnsIsCallable() async throws {
        final class InvocationBox: @unchecked Sendable {
            var invoked = false
        }
        let box = InvocationBox()

        captureService.setStartCommitHookForTesting { _, onFailure in
            onFailure(TestInjectedError.injected)
            box.invoked = true
        }

        await sessionManager.startSession()

        XCTAssertTrue(
            box.invoked,
            "onFailure must be safely invocable before start() returns to its caller, without touching half-installed state"
        )
    }

    /// Full round-trip for the same race as above: proves the failure
    /// claimed synchronously inside start()'s call frame is not merely
    /// invocable but actually drives SessionManager out of `.recording`
    /// and into `.failed` once its scheduled MainActor Task gets a turn.
    /// The gate is a Combine subscription on `$state` fulfilling an
    /// expectation on the first non-`.recording` value observed after
    /// Start — deterministic in that it reacts to the real state change
    /// whenever the runtime schedules it, not a fixed delay.
    func testFailureCallbackClaimedDuringStartEventuallyReachesFailed() async throws {
        captureService.setStartCommitHookForTesting { _, onFailure in
            onFailure(TestInjectedError.injected)
        }

        let reachedTerminalState = XCTestExpectation(description: "left .recording")
        var cancellable: AnyCancellable?
        cancellable = sessionManager.$state
            .dropFirst()
            .sink { state in
                if case .failed = state {
                    reachedTerminalState.fulfill()
                }
            }

        await sessionManager.startSession()
        await fulfillment(of: [reachedTerminalState], timeout: 5.0)
        cancellable?.cancel()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected a failure claimed synchronously during start() to eventually reach .failed, got \(sessionManager.state)")
            return
        }
    }

    // MARK: - Stage C: steady-state event consumption

    func testFinalizedEventsUpdateInMemoryAndOnDiskManifestInOrder() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        let sessionID = try XCTUnwrap(sessionManager.activeSession?.sessionID)

        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 0)))
        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 1)))
        writer.finishStream()

        await sessionManager.stopSession()

        XCTAssertEqual(sessionManager.state, .completed)
        let completed = try XCTUnwrap(sessionManager.lastCompletedSession)
        XCTAssertEqual(completed.chunks.map(\.sequenceNumber), [0, 1])

        let onDisk = try readPersistedManifest(sessionID: sessionID)
        XCTAssertEqual(onDisk.chunks.map(\.sequenceNumber), [0, 1])
    }

    func testFinalPartialEventIsConsumedBeforeFinalSessionPersistence() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()

        // finishRecording() does not auto-terminate this fake's stream —
        // the test simulates the writer finalizing one last partial chunk
        // only after finishRecording() is called, then terminating.
        let stopTask = Task { await sessionManager.stopSession() }

        // Deterministic gate: wait for finishRecording() to actually be
        // called (proving capture has already been drained) before
        // yielding the final event and terminating the stream.
        while writer.finishRecordingCallCount == 0 {
            await Task.yield()
        }
        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 0)))
        writer.finishStream()

        await stopTask.value

        XCTAssertEqual(sessionManager.state, .completed)
        XCTAssertEqual(sessionManager.lastCompletedSession?.chunks.map(\.sequenceNumber), [0])
    }

    func testSequenceGapIsTerminal() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 2)))
        writer.finishStream()

        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed after a sequence gap, got \(sessionManager.state)")
            return
        }
    }

    func testDuplicateSequenceIsTerminal() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 0)))
        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 0)))
        writer.finishStream()

        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed after a duplicate sequence number, got \(sessionManager.state)")
            return
        }
    }

    func testOutOfOrderSequenceIsTerminal() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 1)))
        writer.finishStream()

        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed after an out-of-order sequence number, got \(sessionManager.state)")
            return
        }
    }

    // MARK: - Stage C: interior manifest persistence failure

    func testInteriorManifestFailureBecomesTerminalAndLeavesRecording() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        await failingStore.setWriteManifestFailureQueue([true])

        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 0)))
        writer.finishStream()

        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed after an interior manifest persistence failure, got \(sessionManager.state)")
            return
        }
    }

    func testInteriorManifestFailureContinuesMemoryOnlyDrainOfSubsequentValidEvents() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        // The first interior write fails; the second (final, at Stop)
        // succeeds, carrying the complete accumulated list.
        await failingStore.setWriteManifestFailureQueue([true])

        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 0)))
        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 1)))
        writer.finishStream()

        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed, got \(sessionManager.state)")
            return
        }
        XCTAssertNil(sessionManager.unresolvedIssue, "the final write succeeded, so nothing should remain unresolved")
    }

    /// Directly exercises the non-self-awaiting design: an interior
    /// manifest failure is signaled from inside the event-consumer loop
    /// itself, and the shared shutdown (a *different* task) must still be
    /// able to await that same consumer task's completion without
    /// hanging.
    func testNoEventConsumerSelfAwaitDeadlockOnInteriorFailure() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        await failingStore.setWriteManifestFailureQueue([true])

        writer.yield(.finalized(makeChunkMetadata(sequenceNumber: 0)))
        writer.finishStream()

        // If the consumer ever awaited itself or the shutdown task it
        // signals, this would hang forever; XCTest's own timeout is the
        // backstop, but reaching a terminal state at all is the proof.
        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected shutdown to complete (not hang) and reach .failed, got \(sessionManager.state)")
            return
        }
    }

    // MARK: - Stage C: capture/writer failures

    func testCapturePrepareFailure() async throws {
        captureService.setShouldFailNextPrepare(true)

        await sessionManager.startSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed, got \(sessionManager.state)")
            return
        }
        XCTAssertNil(sessionManager.activeSession)
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertTrue(contents.isEmpty, "prepare() failing before any directory/manifest exists must leave nothing on disk")
    }

    func testCaptureStartFailureCallsStopAndPersistsFailure() async throws {
        captureService.setShouldFailNextStart(true)

        await sessionManager.startSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed, got \(sessionManager.state)")
            return
        }
        XCTAssertEqual(
            captureService.stopCallCountForTesting, 1,
            "captureService.stop() must be called even though start() itself threw"
        )
    }

    func testWriterConstructionFailureStopsPreparedCaptureAndRewritesSessionAsFailed() async throws {
        chunkWriterFactory.setErrorToThrow(TestInjectedError.injected)

        await sessionManager.startSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed, got \(sessionManager.state)")
            return
        }
        XCTAssertEqual(captureService.stopCallCountForTesting, 1)
    }

    func testCaptureRuntimeFailureEntersSharedShutdown() async throws {
        await sessionManager.startSession()
        XCTAssertEqual(sessionManager.state, .recording)

        captureService.simulateAsyncFailure(TestInjectedError.injected)

        // simulateAsyncFailure schedules delivery on FailureCoordinator's
        // own delivery queue, which then hops to MainActor via a Task.
        // stopSession(), called next, deterministically joins whatever
        // shutdown that delivery already started (or starts its own
        // .userStopped-triggered shutdown if delivery hasn't landed yet —
        // either way the retained operational failure, once recorded,
        // always wins the final status).
        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected a retained capture failure to force .failed, got \(sessionManager.state)")
            return
        }
    }

    func testCaptureStopOutcomeFailureForcesFailedEvenOnCleanUserStop() async throws {
        await sessionManager.startSession()

        // Claim a failure that is retained but not yet delivered before
        // stop() begins draining — CaptureStopOutcome.failure will carry
        // it even though the user is about to call a clean stopSession().
        captureService.simulateAsyncFailure(TestInjectedError.injected)
        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("A retained CaptureStopOutcome failure must prevent .completed even on a user-initiated Stop, got \(sessionManager.state)")
            return
        }
    }

    func testWriterStreamFailureEntersSharedShutdown() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        writer.failStream(TestInjectedError.injected)

        // The consumer's catch branch signals shutdown without awaiting
        // it; stopSession() joins that same shutdown deterministically.
        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed after a writer stream failure, got \(sessionManager.state)")
            return
        }
    }

    // MARK: - Stage C: shutdown ordering and exactly-once discipline

    func testCaptureDrainBeforeWriterFinish() async throws {
        let writer = FakeAudioChunkWriter()
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()

        var observedFinishBeforeStopReturned = false
        captureService.setDidEnterStoppingHookForTesting {
            observedFinishBeforeStopReturned = writer.finishRecordingCallCount > 0
        }

        await sessionManager.stopSession()

        XCTAssertFalse(
            observedFinishBeforeStopReturned,
            "finishRecording() must not be called until captureService.stop()'s drain has completed"
        )
        XCTAssertEqual(writer.finishRecordingCallCount, 1)
    }

    func testExactlyOnceCaptureStopAndWriterFinish() async throws {
        let writer = FakeAudioChunkWriter()
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        await sessionManager.stopSession()

        XCTAssertEqual(captureService.stopCallCountForTesting, 1)
        XCTAssertEqual(writer.finishRecordingCallCount, 1)
    }

    func testTwoConcurrentStopCallersJoinTheSameShutdown() async throws {
        let writer = FakeAudioChunkWriter()
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()

        async let first: Void = sessionManager.stopSession()
        async let second: Void = sessionManager.stopSession()
        _ = await (first, second)

        XCTAssertEqual(sessionManager.state, .completed)
        XCTAssertEqual(captureService.stopCallCountForTesting, 1, "two racing Stop callers must share one shutdown, not run it twice")
        XCTAssertEqual(writer.finishRecordingCallCount, 1)
    }

    func testRepeatedStopAfterCompletionRemainsHarmless() async throws {
        await sessionManager.startSession()
        await sessionManager.stopSession()
        XCTAssertEqual(sessionManager.state, .completed)

        await sessionManager.stopSession()

        XCTAssertEqual(sessionManager.state, .completed)
        XCTAssertEqual(captureService.stopCallCountForTesting, 1)
    }

    func testNoBufferProcessingAfterStop() async throws {
        let writer = FakeAudioChunkWriter()
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        await sessionManager.stopSession()

        captureService.injectBuffer(makeTestBuffer())

        XCTAssertEqual(writer.acceptBufferCallCount, 0, "no buffer may reach the writer once capture has been drained and stopped")
    }

    /// Proves the final terminal state is never observed before shutdown
    /// has actually finished draining the writer's stream: while the
    /// stream is deliberately held open, `state` must still be
    /// `.stopping`, not `.completed`.
    func testNoPrematureCompletedBeforeStreamTerminates() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()

        let stopTask = Task { await sessionManager.stopSession() }

        while writer.finishRecordingCallCount == 0 {
            await Task.yield()
        }
        // finishRecording() has been called, but the fake's stream is
        // still deliberately open (auto-terminate disabled) — the final
        // manifest must not have been persisted as .completed yet.
        XCTAssertEqual(sessionManager.state, .stopping)

        writer.finishStream()
        await stopTask.value

        XCTAssertEqual(sessionManager.state, .completed)
    }

    // MARK: - Stage C: multiple operational failures and precedence

    func testMultipleOperationalFailuresFormatPrimaryAndSecondaryDeterministically() async throws {
        let writer = FakeAudioChunkWriter(finishRecordingAutoTerminatesStream: false)
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        captureService.simulateAsyncFailure(TestInjectedError.injected)
        writer.failStream(TestInjectedError.injected)

        await sessionManager.stopSession()

        guard case .failed(let message) = sessionManager.state else {
            XCTFail("Expected .failed, got \(sessionManager.state)")
            return
        }
        XCTAssertTrue(message.contains("additional error during shutdown"), "a second, distinct operational failure must appear as a secondary diagnostic")
    }

    // MARK: - Stage C: retry correction

    func testFailedStatusFinalManifestRetryRemainsFailedNotCompleted() async throws {
        let writer = FakeAudioChunkWriter()
        chunkWriterFactory.setWriterToReturn(writer)

        await sessionManager.startSession()
        captureService.simulateAsyncFailure(TestInjectedError.injected)
        await failingStore.setWriteManifestFailureQueue([true])

        await sessionManager.stopSession()

        guard case .failed = sessionManager.state else {
            XCTFail("Expected .failed before retry, got \(sessionManager.state)")
            return
        }
        XCTAssertNotNil(sessionManager.unresolvedIssue)

        await sessionManager.retryResolution()

        guard case .failed = sessionManager.state else {
            XCTFail("A successfully retried .failed manifest must remain .failed, got \(sessionManager.state)")
            return
        }
        XCTAssertNil(sessionManager.unresolvedIssue)
        XCTAssertNil(sessionManager.lastCompletedSession, "retrying a failed session's final write must never populate lastCompletedSession")
    }

    // MARK: - Stage C: stale-generation safety and lifetime cleanup

    func testStaleRuntimeGenerationFailureSignalIsIgnored() async throws {
        final class ClosureBox: @unchecked Sendable {
            var onFailure: (@Sendable (Error) -> Void)?
        }
        let box = ClosureBox()
        captureService.setStartCommitHookForTesting { _, onFailure in
            box.onFailure = onFailure
        }

        await sessionManager.startSession()
        await sessionManager.stopSession()
        XCTAssertEqual(sessionManager.state, .completed)

        await sessionManager.startSession()
        XCTAssertEqual(sessionManager.state, .recording)

        box.onFailure?(TestInjectedError.injected)
        await Task.yield()

        XCTAssertEqual(sessionManager.state, .recording, "a stale failure signal from an already-torn-down cycle must not affect a new cycle")
    }

    func testRuntimeAndWriterAreReleasedAfterShutdownCompletes() async throws {
        weak var weakWriter: AnyObject?

        do {
            // A factory scoped to this block, not the shared
            // `chunkWriterFactory` from setUp: the shared factory would
            // itself keep a strong reference to `writer` in its own
            // configured-return-value state for the rest of the test
            // method, which would make this assertion meaningless
            // regardless of what SessionManager does.
            let scopedFactory = FakeAudioChunkWriterFactory()
            let writer = FakeAudioChunkWriter()
            weakWriter = writer
            scopedFactory.setWriterToReturn(writer)

            let scopedManager = SessionManager(
                store: failingStore,
                permissionService: permissionService,
                captureService: captureService,
                chunkWriterFactory: scopedFactory
            )

            await scopedManager.startSession()
            await scopedManager.stopSession()
        }

        XCTAssertNil(weakWriter, "the writer must not be retained anywhere once its recording cycle's shutdown has completed")
    }

    // MARK: - Stage C: production-adapter integration

    func testRealAudioChunkWriterAdapterProducesFinalizedChunkOnDisk() async throws {
        chunkWriterFactory = FakeAudioChunkWriterFactory()
        let defaultFactory = DefaultAudioChunkWriterFactory()
        sessionManager = SessionManager(
            store: failingStore,
            permissionService: permissionService,
            captureService: captureService,
            chunkWriterFactory: defaultFactory
        )

        await sessionManager.startSession()
        let paths = try XCTUnwrap(sessionManager.activeSession).sessionID

        let format = makeTestAudioFormat()
        // One second at 8kHz mono, well over one real 30s-target chunk's
        // worth is unnecessary here — the point is only to prove the
        // real adapter wires up and can write real audio, not to
        // exercise chunk-rotation math (already covered exhaustively by
        // AudioChunkWriterTests). A partial chunk finalized at Stop is
        // sufficient proof of end-to-end wiring.
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        if let channel = buffer.floatChannelData {
            for frame in 0..<Int(buffer.frameLength) {
                channel[0][frame] = 0
            }
        }
        captureService.injectBuffer(buffer)

        await sessionManager.stopSession()

        XCTAssertEqual(sessionManager.state, .completed)
        let completed = try XCTUnwrap(sessionManager.lastCompletedSession)
        XCTAssertEqual(completed.chunks.count, 1)
        XCTAssertEqual(completed.chunks.first?.frameCount, 8_000)

        let chunkFileURL = tempDirectory
            .appendingPathComponent(paths.uuidString)
            .appendingPathComponent("chunks")
            .appendingPathComponent(completed.chunks[0].fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunkFileURL.path))
    }
}
