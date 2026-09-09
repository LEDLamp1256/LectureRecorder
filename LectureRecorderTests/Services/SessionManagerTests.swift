import AVFoundation
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
        sessionManager = SessionManager(
            store: failingStore,
            permissionService: permissionService,
            captureService: captureService
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
    /// be caught by this assertion alone. The stronger claim — that no
    /// capture operation of any kind is invoked anywhere in
    /// `SessionManager`'s construction — is established structurally:
    /// `SessionManager.swift` contains zero `captureService.` references
    /// outside the stored-property assignment (verified by direct source
    /// inspection, not runtime behavior).
    func testConstructionInvokesNoCaptureOperation() throws {
        XCTAssertNoThrow(try captureService.prepare())
    }
}
