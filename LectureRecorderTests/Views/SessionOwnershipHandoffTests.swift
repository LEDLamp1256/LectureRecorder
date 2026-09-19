import AVFoundation
import XCTest
@testable import LectureRecorder

/// Proves the live-service-to-durable-presenter handoff that fires when
/// `SessionTranscriptView` observes `service.activeSessionID` transitioning
/// away from this session — using the real `CompletedSessionTranscriptionService`
/// (which conforms to `CompletedSessionStatusLoading`) and a real
/// `SessionTranscriptPresenter`, with a fake transcriber/hardware-free
/// `SessionManager` so no microphone/model execution occurs.
@MainActor
final class SessionOwnershipHandoffTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionOwnershipHandoffTests-\(UUID().uuidString)", isDirectory: true)
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
                sequenceNumber: seq, fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq) * 30, durationSeconds: 30, frameCount: 1_000, state: .completed
            )
        }
        try AtomicFileWriter.writeJSON(manifest, to: sessionPaths.manifestURL)
        for seq in 0..<chunkCount {
            let url = sessionPaths.chunksDirectory.appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: seq))
            try Data("placeholder".utf8).write(to: url)
        }
        return manifest
    }

    private func makeService(transcriber: any Transcribing) -> CompletedSessionTranscriptionService {
        let manager = SessionManager(
            store: SessionStore(locator: TestLocator(root: tempDirectory)),
            permissionService: MockMicrophonePermissionService(status: .granted),
            captureService: MockAudioCaptureService(
                formatToPrepare: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
            ),
            chunkWriterFactory: DefaultAudioChunkWriterFactory()
        )
        let root = tempDirectory!
        return CompletedSessionTranscriptionService(
            sessionManager: manager,
            transcriptionStore: TranscriptionStore(),
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

    private func waitUntilFinished(_ service: CompletedSessionTranscriptionService, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .finished = service.phase { return }
            await Task.yield()
        }
    }

    /// Simulates exactly what `SessionTranscriptView`'s
    /// `.onChange(of: service.activeSessionID)` does: apply the pure
    /// predicate, and if it fires, refresh the presenter — proving the
    /// production refresh *path*, not just the predicate in isolation.
    private func applyOwnershipTransitionRefreshIfNeeded(
        old: UUID?,
        new: UUID?,
        sessionID: UUID,
        entry: CompletedSessionEntry,
        presenter: SessionTranscriptPresenter
    ) async {
        guard SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: old, newActiveSessionID: new, sessionID: sessionID) else { return }
        await presenter.refresh(for: entry)
    }

    // MARK: - Completed-operation handoff

    func testPresenterReflectsCompletedStateAfterOwnershipReleases() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let entry = CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)
        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber)
        let presenter = SessionTranscriptPresenter(loader: service)

        // 1. Initial peek: not transcribed.
        await presenter.refresh(for: entry)
        XCTAssertEqual(presenter.status, .notTranscribed)

        // 2. Transcribe.
        let activeBefore = service.activeSessionID
        XCTAssertEqual(service.transcribe(sessionID: sessionID), .admitted)
        await waitUntilFinished(service)
        let activeAfter = service.activeSessionID

        // 3 & 4. Apply the exact production ownership-transition refresh.
        await applyOwnershipTransitionRefreshIfNeeded(old: sessionID, new: activeAfter, sessionID: sessionID, entry: entry, presenter: presenter)
        XCTAssertNotEqual(activeBefore, sessionID, "sanity: service started idle")
        XCTAssertNil(activeAfter, "sanity: ownership was actually released")

        // 5 & 6. Presenter now reports Completed with A's durable transcript.
        XCTAssertEqual(presenter.status, .completed)
        XCTAssertEqual(presenter.segments.count, 1)

        // 7. Action availability offers no Transcribe/Continue/Cancel.
        let ownership = SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: service.activeSessionID, sessionID: sessionID)
        let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: presenter.status, ownership: ownership)
        XCTAssertFalse(availability.canTranscribe)
        XCTAssertFalse(availability.canContinueOrRetry)
        XCTAssertFalse(availability.canCancel)
    }

    // MARK: - Cancel/incomplete handoff

    func testPresenterReflectsResumableStateAfterCancellationReleasesOwnership() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let entry = CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)

        actor GatedTranscriber: Transcribing {
            private var hasEnteredFlag = false
            var hasEntered: Bool { hasEnteredFlag }
            func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
                hasEnteredFlag = true
                while !Task.isCancelled { await Task.yield() }
                throw CancellationError()
            }
        }
        let gated = GatedTranscriber()
        let service = makeService(transcriber: gated)
        let presenter = SessionTranscriptPresenter(loader: service)

        await presenter.refresh(for: entry)
        XCTAssertEqual(presenter.status, .notTranscribed)

        XCTAssertEqual(service.transcribe(sessionID: sessionID), .admitted)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, await !gated.hasEntered { await Task.yield() }
        let entered = await gated.hasEntered
        XCTAssertTrue(entered)

        service.cancel(sessionID: sessionID)
        await waitUntilFinished(service)
        let activeAfter = service.activeSessionID
        XCTAssertNil(activeAfter)

        await applyOwnershipTransitionRefreshIfNeeded(old: sessionID, new: activeAfter, sessionID: sessionID, entry: entry, presenter: presenter)

        // Whatever the exact durable classification (incomplete/interrupted),
        // it must be a genuinely resumable one, not the stale pre-operation
        // `.notTranscribed` snapshot, and Continue/Retry must be available
        // while Cancel is not.
        XCTAssertNotEqual(presenter.status, .notTranscribed)
        let ownership = SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: service.activeSessionID, sessionID: sessionID)
        let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: presenter.status, ownership: ownership)
        XCTAssertTrue(availability.canContinueOrRetry, "expected resumable, got \(String(describing: presenter.status))")
        XCTAssertFalse(availability.canCancel)
    }

    // MARK: - Cross-service handoff: transcription completion refreshes Notes availability

    /// Proves the cross-service refresh cue `SessionNotesView` performs:
    /// when `CompletedSessionTranscriptionService.activeSessionID` releases
    /// ownership of this session (transcription just finished), the
    /// completely separate Notes presenter/service pair must be refreshed
    /// so `NotesActionAvailabilityCalculator` flips Generate from disabled
    /// to enabled — exercising the real `NotesTranscriptSourceLoader`
    /// production implementation end to end, not a stub, so the
    /// transcript-eligibility check itself is genuinely proven, not merely
    /// assumed.
    func testNotesGenerateBecomesAvailableAfterTranscriptionOwnershipReleases() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let entry = CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)
        let transcriber = FakeTranscriber()
        let transcriptionService = makeService(transcriber: transcriber)

        let notesStore = LectureNotesStore()
        let notesOperationStateStore = LectureNotesOperationStateStore()
        let root = tempDirectory!
        let notesSourceLoader = NotesTranscriptSourceLoader(
            transcriptionStore: TranscriptionStore(),
            sessionsRootResolver: { root }
        )
        let notesPresenter = SessionNotesPresenter(
            notesStore: notesStore,
            operationStateStore: notesOperationStateStore,
            sourceLoader: notesSourceLoader
        )

        // Before transcription: no Notes generation exists yet and the
        // transcript is not eligible input — Generate must be disabled.
        await notesPresenter.refresh(for: entry)
        XCTAssertEqual(notesPresenter.displayState, .noGeneration(transcriptSourceReady: false))
        let before = NotesActionAvailabilityCalculator.availability(displayState: notesPresenter.displayState, ownership: .none)
        XCTAssertFalse(before.canGenerate)

        // Transcribe for real, then apply the exact production
        // ownership-release cue `SessionNotesView`'s
        // `.onChange(of: transcriptionService.activeSessionID)` performs.
        XCTAssertEqual(transcriptionService.transcribe(sessionID: sessionID), .admitted)
        await waitUntilFinished(transcriptionService)
        let activeAfter = transcriptionService.activeSessionID
        XCTAssertNil(activeAfter, "sanity: transcription ownership was actually released")

        let shouldRefresh = SessionOwnershipTransition.shouldRefreshDurableState(
            oldActiveSessionID: sessionID,
            newActiveSessionID: activeAfter,
            sessionID: sessionID
        )
        XCTAssertTrue(shouldRefresh, "expected the ownership-release predicate to fire")
        await notesPresenter.refresh(for: entry)

        XCTAssertEqual(notesPresenter.displayState, .noGeneration(transcriptSourceReady: true))
        let after = NotesActionAvailabilityCalculator.availability(displayState: notesPresenter.displayState, ownership: .none)
        XCTAssertTrue(after.canGenerate)
    }

    // MARK: - No cross-session regression (retained)

    func testHistoricalTranscriptRemainsReopenableAfterHandoff() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let entry = CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)
        let transcriber = FakeTranscriber()
        let service = makeService(transcriber: transcriber)

        XCTAssertEqual(service.transcribe(sessionID: sessionID), .admitted)
        await waitUntilFinished(service)

        // Reopen independently, as a fresh window would, via the read-only
        // peek path — must reflect the same durable truth without any
        // further inference.
        let freshPresenter = SessionTranscriptPresenter(loader: service)
        await freshPresenter.refresh(for: entry)
        XCTAssertEqual(freshPresenter.status, .completed)
        XCTAssertEqual(freshPresenter.segments.count, 1)
    }
}
