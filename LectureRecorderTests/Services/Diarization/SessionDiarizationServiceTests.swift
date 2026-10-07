import Combine
import XCTest
@testable import LectureRecorder

/// Deterministic lifecycle coverage for `SessionDiarizationService` with a
/// fake backend over real on-disk sessions: no model, Core ML, network, or
/// microphone.
@MainActor
final class SessionDiarizationServiceTests: XCTestCase {
    private typealias S = SessionDiarizationTestSupport
    private typealias Service = SessionDiarizationService

    private var root: URL!
    /// Directories whose permissions a test lowered, restored before cleanup.
    private var lockedDirectories: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        root = try S.makeRoot()
    }

    override func tearDown() async throws {
        for directory in lockedDirectories {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeService(
        _ diarizer: FakeSpeakerDiarizer = FakeSpeakerDiarizer(),
        sourceLoader: (any SessionDiarizationSourceLoading)? = nil,
        sidecarCommitter: (any SessionDiarizationSidecarCommitting)? = nil
    ) -> Service {
        Service(
            diarizer: diarizer,
            sourceLoader: sourceLoader ?? S.loader(root: root),
            sidecarCommitter: sidecarCommitter,
            now: { S.createdDate },
            shutdownPollInterval: 0.005
        )
    }

    private func waitUntil(
        _ condition: () async -> Bool,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    /// The outcome of the release whose epoch is `epoch`.
    private func releasedOutcome(
        _ service: Service,
        epoch: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Service.DiarizationOperationOutcome? {
        await waitUntil({ service.lastReleasedOperation?.operationEpoch == epoch }, file: file, line: line)
        return service.lastReleasedOperation?.outcome
    }

    /// Admits one operation and returns its terminal outcome.
    private func run(
        _ service: Service,
        _ sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Service.DiarizationOperationOutcome? {
        XCTAssertEqual(service.diarize(sessionID: sessionID), .admitted, file: file, line: line)
        return await releasedOutcome(service, epoch: service.operationEpoch, file: file, line: line)
    }

    private func expectedResult(_ sessionID: UUID) async throws -> SpeakerDiarizationResult {
        let snapshot = try await S.loader(root: root).loadSourceSnapshot(sessionID: sessionID)
        return try SpeakerDiarizationResult(output: S.output(), source: snapshot.source, createdDate: S.createdDate)
    }

    private func storedOutcome(_ sessionID: UUID) async throws -> SpeakerDiarizationLoadOutcome {
        let snapshot = try await S.loader(root: root).loadSourceSnapshot(sessionID: sessionID)
        return SpeakerDiarizationStore().load(source: snapshot.source, sessionPaths: snapshot.sessionPaths)
    }

    // MARK: - A. Admission

    func testFirstOperationIsAdmittedWithOneEpochAndPublishedOwnership() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        XCTAssertEqual(service.operationEpoch, 0)
        XCTAssertEqual(service.phase, .idle)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        // Synchronous: published before any suspension.
        XCTAssertEqual(service.operationEpoch, 1)
        XCTAssertEqual(service.activeSessionID, manifest.sessionID)
        XCTAssertEqual(service.phase, .preparingSource)

        await waitUntil { diarizer.hasEntered }
        XCTAssertEqual(service.phase, .diarizing)
        diarizer.open()
        let outcome = await releasedOutcome(service, epoch: 1)
        guard case .completed? = outcome else { return XCTFail("expected completed, got \(String(describing: outcome))") }
        XCTAssertEqual(service.operationEpoch, 1)
    }

    func testOnlyOneOperationAppWideAndRejectedAdmissionChangesNothing() async throws {
        let (first, _) = try S.writeSession(root: root)
        let (second, _) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)

        XCTAssertEqual(service.diarize(sessionID: first.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }

        XCTAssertEqual(service.diarize(sessionID: second.sessionID), .busy)
        XCTAssertEqual(service.diarize(sessionID: first.sessionID), .busy)
        XCTAssertEqual(service.operationEpoch, 1)
        XCTAssertEqual(service.activeSessionID, first.sessionID)
        XCTAssertEqual(service.phase, .diarizing)
        XCTAssertNil(service.lastReleasedOperation)

        diarizer.open()
        _ = await releasedOutcome(service, epoch: 1)
        let callCount = diarizer.callCount
        XCTAssertEqual(callCount, 1, "a rejected admission never reaches the backend")
    }

    func testShutdownPermanentlyRejectsAdmission() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer()
        let service = makeService(diarizer)

        let shutdown = await service.shutdown(timeout: 1)
        XCTAssertEqual(shutdown, .completed)
        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .shuttingDown)
        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .shuttingDown)
        XCTAssertEqual(service.operationEpoch, 0)
        XCTAssertNil(service.activeSessionID)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertNil(service.lastReleasedOperation)
        let callCount = diarizer.callCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - B. Terminal eligibility

    /// No transcription is required: these sessions have no transcription,
    /// Notes, or Summary artifacts at all.
    func testCompletedInterruptedAndFailedSessionsCommit() async throws {
        let service = makeService()
        for status in [SessionStatus.completed, .interrupted, .failed] {
            let (manifest, paths) = try S.writeSession(root: root, status: status)
            let outcome = await run(service, manifest.sessionID)
            let expected = try await expectedResult(manifest.sessionID)
            XCTAssertEqual(outcome, .completed(expected), "\(status)")
            XCTAssertNotNil(S.sidecarData(paths), "\(status)")
        }
    }

    func testRecordingSessionIsRejectedBeforeTheBackend() async throws {
        let (manifest, paths) = try S.writeSession(root: root, status: .recording)
        let diarizer = FakeSpeakerDiarizer()
        let service = makeService(diarizer)

        let outcome = await run(service, manifest.sessionID)
        XCTAssertEqual(outcome, .sourceUnavailable(.notTerminal(.recording)))
        let callCount = diarizer.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DiarizationArtifactPaths.directory(sessionPaths: paths).path))
    }

    func testTerminalSessionsWithInvalidOrNoAudioAreRejectedBeforeTheBackend() async throws {
        let diarizer = FakeSpeakerDiarizer()
        let service = makeService(diarizer)

        for status in [SessionStatus.interrupted, .failed] {
            var (manifest, paths) = try S.writeSession(root: root, status: status)
            manifest.chunks[1].state = .failed
            try S.writeManifest(manifest, paths: paths)
            var outcome = await run(service, manifest.sessionID)
            XCTAssertEqual(outcome, .sourceUnavailable(.audioUnavailable(.sessionIneligible(.nonCompletedChunk(sequenceNumber: 1)))))

            (manifest, paths) = try S.writeSession(root: root, status: status)
            try FileManager.default.removeItem(at: paths.chunksDirectory.appendingPathComponent(manifest.chunks[0].fileName))
            outcome = await run(service, manifest.sessionID)
            XCTAssertEqual(outcome, .sourceUnavailable(.audioUnavailable(.chunkFileMissing(sequenceNumber: 0))))

            (manifest, _) = try S.writeSession(root: root, status: status, frameCounts: [])
            outcome = await run(service, manifest.sessionID)
            XCTAssertEqual(outcome, .sourceUnavailable(.audioUnavailable(.timeline(.noChunks))))
        }
        let missing = await run(service, UUID())
        XCTAssertEqual(missing, .sourceUnavailable(.sessionUnavailable))
        let callCount = diarizer.callCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - C. Source freshness

    func testSourceIsReadFreshAtOperationStart() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer()
        let service = makeService(diarizer)

        _ = await run(service, manifest.sessionID)
        // Change the session's audio between operations; the next run must
        // analyze (and bind its result to) the new audio.
        try S.writeSession(root: root, sessionID: manifest.sessionID, frameCounts: [16_000, 4_000])
        let outcome = await run(service, manifest.sessionID)

        let current = try await S.loader(root: root).loadSourceSnapshot(sessionID: manifest.sessionID)
        guard case .completed(let result)? = outcome else { return XCTFail("expected completed, got \(String(describing: outcome))") }
        XCTAssertEqual(result.audioSource, current.audioSource)
        let requests = diarizer.requests
        XCTAssertEqual(requests.last?.source, current.source)
        XCTAssertNotEqual(requests.first?.source, requests.last?.source)
    }

    private func assertSourceChangeDuringInferenceDiscardsOutput(
        expecting expected: Service.DiarizationOperationOutcome = .staleSource,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ change: (SessionManifest, SessionPaths) throws -> Void
    ) async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted, file: file, line: line)
        await waitUntil({ diarizer.hasEntered }, file: file, line: line)
        try change(manifest, paths)
        diarizer.open()

        let outcome = await releasedOutcome(service, epoch: 1, file: file, line: line)
        XCTAssertEqual(outcome, expected, file: file, line: line)
        XCTAssertEqual(S.sidecarData(paths), oldSidecar, "the previous sidecar is untouched", file: file, line: line)
    }

    func testAudioFingerprintChangeDuringInferenceIsStaleAndNothingIsSaved() async throws {
        let root = self.root!
        try await assertSourceChangeDuringInferenceDiscardsOutput { manifest, _ in
            try S.writeSession(root: root, sessionID: manifest.sessionID, frameCounts: [16_000, 4_000])
        }
    }

    func testSessionBecomingNonterminalDuringInferenceIsNotCommitted() async throws {
        try await assertSourceChangeDuringInferenceDiscardsOutput { manifest, paths in
            var recording = manifest
            recording.status = .recording
            try S.writeManifest(recording, paths: paths)
        }
    }

    /// A source that can no longer be loaded and validated at all is
    /// reported as unavailable (not stale); its output is still discarded.
    func testSourceBecomingStructurallyInvalidDuringInferenceIsNotCommitted() async throws {
        try await assertSourceChangeDuringInferenceDiscardsOutput(
            expecting: .sourceUnavailable(.audioUnavailable(.chunkFileMissing(sequenceNumber: 1)))
        ) { manifest, paths in
            try FileManager.default.removeItem(at: paths.chunksDirectory.appendingPathComponent(manifest.chunks[1].fileName))
        }
    }

    func testManifestBecomingUnreadableDuringInferenceIsNotCommitted() async throws {
        try await assertSourceChangeDuringInferenceDiscardsOutput(expecting: .sourceUnavailable(.manifestUnreadable)) { _, paths in
            try Data("not json".utf8).write(to: paths.manifestURL)
        }
    }

    func testStaleOutputIsNeverSavedWhenNoSidecarExisted() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }
        try S.writeSession(root: root, sessionID: manifest.sessionID, frameCounts: [8_000])
        diarizer.open()

        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .staleSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DiarizationArtifactPaths.directory(sessionPaths: paths).path))
    }

    // MARK: - D. Sidecar safety

    func testSuccessfulRunSavesTheNormalizedResult() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let outcome = await run(makeService(), manifest.sessionID)

        guard case .completed(let result)? = outcome else { return XCTFail("expected completed, got \(String(describing: outcome))") }
        // D1 normalization: first speech is numbered speaker_0.
        XCTAssertEqual(result.ranges.map(\.speakerID.rawValue), ["speaker_0", "speaker_1", "speaker_0"])
        XCTAssertEqual(result.provenance, S.provenance)
        XCTAssertEqual(result.createdDate, S.createdDate)
        let expected = try await expectedResult(manifest.sessionID)
        XCTAssertEqual(result, expected)
        let stored = try await storedOutcome(manifest.sessionID)
        XCTAssertEqual(stored, .loaded(result))
        XCTAssertEqual(S.sidecarURL(paths).path, paths.sessionDirectory.path + "/diarization/result.json")
    }

    func testSuccessfulRunAtomicallyReplacesAnOlderValidSidecar() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)

        let outcome = await run(makeService(), manifest.sessionID)

        let expected = try await expectedResult(manifest.sessionID)
        XCTAssertEqual(outcome, .completed(expected))
        XCTAssertNotEqual(S.sidecarData(paths), oldSidecar)
        let stored = try await storedOutcome(manifest.sessionID)
        XCTAssertEqual(stored, .loaded(expected))
        let entries = try FileManager.default.contentsOfDirectory(atPath: DiarizationArtifactPaths.directory(sessionPaths: paths).path)
        XCTAssertEqual(entries, ["result.json"], "no temporary or second artifact is left behind")
    }

    func testBackendFailurePreservesTheOldSidecar() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)
        let service = makeService(FakeSpeakerDiarizer(response: .failure(FakeDiarizerError())))

        let outcome = await run(service, manifest.sessionID)
        XCTAssertEqual(outcome, .failed(.backendFailed(description: "fake backend failure")))
        XCTAssertEqual(S.sidecarData(paths), oldSidecar)
    }

    func testInvalidBackendOutputPreservesTheOldSidecar() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)

        var emptyProvenance = S.provenance
        emptyProvenance.backendVersion = " "
        let malformed = SpeakerDiarizationOutput(
            provenance: S.provenance,
            segments: [DiarizationBackendSegment(label: "A", startSeconds: 1, endSeconds: 0.5)]
        )
        for output in [S.output(provenance: emptyProvenance), malformed] {
            let service = makeService(FakeSpeakerDiarizer(response: .success(output)))
            let outcome = await run(service, manifest.sessionID)
            XCTAssertEqual(outcome, .failed(.invalidBackendOutput))
            XCTAssertEqual(S.sidecarData(paths), oldSidecar)
        }
    }

    func testSaveFailureLeavesTheOldSidecarIntact() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)
        let directory = DiarizationArtifactPaths.directory(sessionPaths: paths)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        lockedDirectories.append(directory)

        let outcome = await run(makeService(), manifest.sessionID)

        guard case .failed(.saveFailed)? = outcome else { return XCTFail("expected saveFailed, got \(String(describing: outcome))") }
        XCTAssertEqual(S.sidecarData(paths), oldSidecar)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["result.json"])
    }

    func testUnsafeSidecarPathFailsTheSaveWithoutFollowingIt() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: DiarizationArtifactPaths.directory(sessionPaths: paths), withDestinationURL: elsewhere)

        let outcome = await run(makeService(), manifest.sessionID)

        XCTAssertEqual(outcome, .failed(.saveFailed(description: SpeakerDiarizationStoreError.unsafeSidecarPath.errorDescription!)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testTheOldSidecarIsNeverTouchedWhileARunIsInFlight() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }
        XCTAssertEqual(S.sidecarData(paths), oldSidecar, "admission and source loading never delete or rewrite the sidecar")

        service.cancel(sessionID: manifest.sessionID)
        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(S.sidecarData(paths), oldSidecar)
    }

    // MARK: - E. Peek / durable state

    private func assertPeek(
        _ service: Service,
        _ sessionID: UUID,
        _ expected: Service.DurableState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let before = try S.tree(root)
        let state = await service.peekState(sessionID: sessionID)
        XCTAssertEqual(state, expected, file: file, line: line)
        XCTAssertEqual(try S.tree(root), before, "peek never creates, repairs, or deletes anything", file: file, line: line)
    }

    func testPeekReportsEveryDurableStateReadOnlyAndWithoutTheBackend() async throws {
        let diarizer = FakeSpeakerDiarizer()
        let service = makeService(diarizer)
        let (manifest, paths) = try S.writeSession(root: root)
        let sessionID = manifest.sessionID
        let directory = DiarizationArtifactPaths.directory(sessionPaths: paths)

        try await assertPeek(service, sessionID, .sidecar(.absent))

        let seeded = try await S.seedSidecar(root: root, sessionID: sessionID)
        let seededResult = try AtomicFileWriter.defaultDecoder.decode(SpeakerDiarizationResult.self, from: seeded)
        try await assertPeek(service, sessionID, .sidecar(.loaded(seededResult)))

        try Data("{ not json".utf8).write(to: S.sidecarURL(paths))
        try await assertPeek(service, sessionID, .sidecar(.unavailable(.corrupt)))

        try Data(#"{"schemaVersion": 99}"#.utf8).write(to: S.sidecarURL(paths))
        try await assertPeek(service, sessionID, .sidecar(.unavailable(.unsupportedSchemaVersion(99))))

        try FileManager.default.removeItem(at: directory)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
        try await assertPeek(service, sessionID, .sidecar(.unavailable(.unsafePath)))
        try FileManager.default.removeItem(at: directory)

        // A valid sidecar for audio that has since changed is stale, and
        // stays stale (never deleted or regenerated) until an explicit run.
        _ = try await S.seedSidecar(root: root, sessionID: sessionID)
        try S.writeSession(root: root, sessionID: sessionID, frameCounts: [16_000, 4_000])
        try await assertPeek(service, sessionID, .sidecar(.unavailable(.audioSourceMismatch)))
        try await assertPeek(service, sessionID, .sidecar(.unavailable(.audioSourceMismatch)))

        var recording = try AtomicFileWriter.readJSON(SessionManifest.self, from: paths.manifestURL)
        recording.status = .recording
        try S.writeManifest(recording, paths: paths)
        try await assertPeek(service, sessionID, .sourceUnavailable(.notTerminal(.recording)))
        try await assertPeek(service, UUID(), .sourceUnavailable(.sessionUnavailable))

        let callCount = diarizer.callCount
        XCTAssertEqual(callCount, 0, "peek never invokes the backend")
        XCTAssertEqual(service.operationEpoch, 0, "peek never admits an operation")
        XCTAssertEqual(service.phase, .idle)
    }

    func testPeekAfterASuccessfulRunReportsTheCommittedResult() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let service = makeService()
        let outcome = await run(service, manifest.sessionID)
        guard case .completed(let result)? = outcome else { return XCTFail("expected completed") }
        try await assertPeek(service, manifest.sessionID, .sidecar(.loaded(result)))
    }

    func testPeekIsAvailableWhileAnOperationIsActive() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }

        try await assertPeek(service, manifest.sessionID, .sidecar(.absent))
        XCTAssertEqual(service.phase, .diarizing)

        service.cancel(sessionID: manifest.sessionID)
        _ = await releasedOutcome(service, epoch: 1)
    }

    // MARK: - F. Cancellation

    func testCancellingTheActiveSessionWhileTheBackendIsSuspendedCancelsWithoutSaving() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }
        service.cancel(sessionID: manifest.sessionID)
        XCTAssertEqual(service.phase, .cancelling)

        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(S.sidecarData(paths), oldSidecar)
    }

    func testCancellingADifferentSessionOrNoOperationIsANoOp() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)

        service.cancel(sessionID: manifest.sessionID)
        XCTAssertEqual(service.phase, .idle)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }
        service.cancel(sessionID: UUID())
        XCTAssertEqual(service.phase, .diarizing)

        diarizer.open()
        let outcome = await releasedOutcome(service, epoch: 1)
        guard case .completed? = outcome else { return XCTFail("expected completed, got \(String(describing: outcome))") }
    }

    func testCancellationBeforeTheRunStartsNeverReachesTheBackend() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer()
        let service = makeService(diarizer)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        service.cancel(sessionID: manifest.sessionID)

        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .cancelled)
        let callCount = diarizer.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(S.sidecarData(paths))
    }

    /// FluidAudio's final clustering step ignores cancellation; its output
    /// must still never be committed once cancellation was requested.
    func testBackendReturningAfterCancellationCannotCauseASave() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)
        let diarizer = FakeSpeakerDiarizer(gate: .uncooperative)
        let service = makeService(diarizer)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }
        service.cancel(sessionID: manifest.sessionID)
        await waitUntil { diarizer.sawCancellationWhileGated }
        XCTAssertEqual(service.activeSessionID, manifest.sessionID, "an uncooperative backend keeps ownership until it returns")
        diarizer.open()

        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(S.sidecarData(paths), oldSidecar)
    }

    // MARK: - Commit authorization boundary

    /// The run has finished inference, revalidated the current source, and
    /// is suspended for the last time before commit authorization (the
    /// held post-inference reload has fully loaded and validated). Result
    /// normalization and authorization then follow with no further
    /// suspension, so a cancel recorded here is the latest one that can
    /// precede authorization — and it wins.
    func testCancelBeforeCommitAuthorizationWinsAndNothingIsSaved() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)
        let diarizer = FakeSpeakerDiarizer()
        let loader = HoldingSourceLoader(root: root, heldCall: 2)
        let committer = HoldingSidecarCommitter(holds: false)
        let service = makeService(diarizer, sourceLoader: loader, sidecarCommitter: committer)
        let recorder = ReleaseRecorder(service)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { loader.heldCallLoaded }
        XCTAssertEqual(diarizer.callCount, 1, "inference already finished")
        XCTAssertEqual(service.phase, .validating)

        service.cancel(sessionID: manifest.sessionID)
        XCTAssertEqual(service.phase, .cancelling)
        loader.open()

        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(committer.commitCount, 0, "no save is attempted")
        XCTAssertEqual(S.sidecarData(paths), oldSidecar, "the previous sidecar is byte-identical")
        XCTAssertNil(service.activeSessionID)
        XCTAssertEqual(recorder.releases.map(\.operationEpoch), [1])
        XCTAssertEqual(recorder.activeSessionIDAtEmission, [nil])
    }

    func testCommitAuthorizationBeforeCancelLetsTheSaveFinishAsCompleted() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let oldSidecar = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)
        let committer = HoldingSidecarCommitter()
        let service = makeService(sidecarCommitter: committer)
        let recorder = ReleaseRecorder(service)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { committer.hasEntered }
        XCTAssertEqual(service.phase, .saving)
        XCTAssertEqual(S.sidecarData(paths), oldSidecar, "authorized, but the save has not run yet")

        service.cancel(sessionID: manifest.sessionID)
        XCTAssertEqual(service.phase, .saving, "cancel is a no-op once commit is authorized")
        XCTAssertEqual(service.activeSessionID, manifest.sessionID)
        committer.release()

        let expected = try await expectedResult(manifest.sessionID)
        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .completed(expected))
        XCTAssertEqual(service.phase, .finished(.completed(expected)))
        XCTAssertEqual(committer.completedSaveCount, 1)
        XCTAssertNotEqual(S.sidecarData(paths), oldSidecar)
        let stored = try await storedOutcome(manifest.sessionID)
        XCTAssertEqual(stored, .loaded(expected), "the old result was atomically replaced")
        let entries = try FileManager.default.contentsOfDirectory(atPath: DiarizationArtifactPaths.directory(sessionPaths: paths).path)
        XCTAssertEqual(entries, ["result.json"])
        XCTAssertEqual(recorder.releases.map(\.operationEpoch), [1])
    }

    func testRepeatedAndOtherSessionCancelsDuringAnAuthorizedSaveChangeNothing() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let committer = HoldingSidecarCommitter()
        let service = makeService(sidecarCommitter: committer)
        let recorder = ReleaseRecorder(service)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { committer.hasEntered }
        for _ in 0..<3 {
            service.cancel(sessionID: manifest.sessionID)
            service.cancel(sessionID: UUID())
        }
        XCTAssertEqual(service.phase, .saving)
        XCTAssertEqual(service.activeSessionID, manifest.sessionID)
        XCTAssertEqual(service.operationEpoch, 1)
        XCTAssertNil(service.lastReleasedOperation)
        XCTAssertEqual(service.diarize(sessionID: UUID()), .busy)
        committer.release()

        let expected = try await expectedResult(manifest.sessionID)
        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .completed(expected))
        XCTAssertEqual(recorder.releases.map(\.operationEpoch), [1], "exactly one release")
        XCTAssertEqual(recorder.activeSessionIDAtEmission, [nil])
        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted, "the slot is free after release")
        _ = await releasedOutcome(service, epoch: 2)
    }

    /// Shutdown closes admission but does not cancel an authorized save;
    /// its bounded wait observes the save finishing.
    func testShutdownDuringAnAuthorizedSaveLetsItCommit() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let committer = HoldingSidecarCommitter()
        let service = makeService(sidecarCommitter: committer)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { committer.hasEntered }
        service.beginShutdown()
        XCTAssertTrue(service.isShuttingDown)
        XCTAssertEqual(service.phase, .saving)
        XCTAssertEqual(service.diarize(sessionID: UUID()), .shuttingDown)

        committer.release()
        let shutdown = await service.shutdown(timeout: 5)
        XCTAssertEqual(shutdown, .completed)
        let expected = try await expectedResult(manifest.sessionID)
        XCTAssertEqual(service.lastReleasedOperation?.outcome, .completed(expected))
        XCTAssertNotNil(S.sidecarData(paths))
    }

    // MARK: - G. Epoch / release

    func testEachAdmissionHasItsOwnEpochAndReleasePublishesAfterOwnershipClears() async throws {
        let (first, _) = try S.writeSession(root: root)
        let (second, _) = try S.writeSession(root: root, status: .interrupted)
        let service = makeService()
        let recorder = ReleaseRecorder(service)

        XCTAssertEqual(service.diarize(sessionID: first.sessionID), .admitted)
        let epochA = service.operationEpoch
        _ = await releasedOutcome(service, epoch: epochA)
        let releaseA = service.lastReleasedOperation

        XCTAssertEqual(service.diarize(sessionID: second.sessionID), .admitted)
        let epochB = service.operationEpoch
        XCTAssertEqual(epochB, epochA + 1)
        XCTAssertEqual(service.lastReleasedOperation, releaseA, "A's release never matches B while B runs")
        _ = await releasedOutcome(service, epoch: epochB)
        let releaseB = service.lastReleasedOperation

        XCTAssertEqual(releaseA?.sessionID, first.sessionID)
        XCTAssertEqual(releaseB?.sessionID, second.sessionID)
        XCTAssertEqual(recorder.releases.map(\.operationEpoch), [epochA, epochB], "exactly one release per admission, in order")
        XCTAssertEqual(recorder.activeSessionIDAtEmission, [nil, nil], "ownership is cleared before the release is published")
        XCTAssertEqual(recorder.phaseAtEmission.map(\.isFinished), [true, true])
        let expectedA = try await expectedResult(first.sessionID)
        let expectedB = try await expectedResult(second.sessionID)
        XCTAssertEqual(recorder.releases.map(\.outcome), [.completed(expectedA), .completed(expectedB)])
        XCTAssertNil(service.activeSessionID)
        XCTAssertEqual(service.diarize(sessionID: first.sessionID), .admitted, "the slot is genuinely free after release")
        _ = await releasedOutcome(service, epoch: epochB + 1)
    }

    func testRejectedAdmissionsNeverConsumeAnEpochOrPublishARelease() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        let recorder = ReleaseRecorder(service)

        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }
        XCTAssertEqual(service.diarize(sessionID: UUID()), .busy)
        await service.shutdown(timeout: 5)
        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .shuttingDown)

        XCTAssertEqual(service.operationEpoch, 1)
        XCTAssertEqual(recorder.releases.map(\.operationEpoch), [1])
        XCTAssertEqual(recorder.releases.first?.outcome, .cancelled)
        XCTAssertEqual(recorder.nilEmissionCount, 0)
    }

    // MARK: - H. Shutdown

    func testBeginShutdownSynchronouslyClosesAdmissionAndCancelsIdempotently() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }

        service.beginShutdown()
        XCTAssertTrue(service.isShuttingDown)
        XCTAssertEqual(service.phase, .cancelling)
        XCTAssertEqual(service.diarize(sessionID: UUID()), .shuttingDown)

        service.beginShutdown()
        XCTAssertTrue(service.isShuttingDown)
        XCTAssertEqual(service.operationEpoch, 1)

        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .cancelled)
        service.beginShutdown()
        XCTAssertEqual(service.phase, .finished(.cancelled), "a repeat after release changes nothing")
        XCTAssertNil(S.sidecarData(paths))
    }

    func testShutdownWithNoOperationCompletesImmediately() async {
        let service = makeService()
        let start = ContinuousClock.now
        let outcome = await service.shutdown(timeout: 5)
        XCTAssertEqual(outcome, .completed)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertTrue(service.isShuttingDown)
    }

    func testShutdownWaitsForACooperativeRunToRelease() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }

        let shutdown = await service.shutdown(timeout: 5)
        XCTAssertEqual(shutdown, .completed)
        XCTAssertNil(service.activeSessionID)
        XCTAssertEqual(service.lastReleasedOperation?.outcome, .cancelled)
        XCTAssertNil(S.sidecarData(paths))
    }

    func testUncooperativeBackendTimesOutShutdownAndNeverFabricatesASidecar() async throws {
        let (manifest, paths) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .uncooperative)
        let service = makeService(diarizer)
        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }

        let start = ContinuousClock.now
        let shutdown = await service.shutdown(timeout: 0.2)
        XCTAssertEqual(shutdown, .timedOut)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "the wait is bounded")
        XCTAssertNil(S.sidecarData(paths))
        XCTAssertEqual(service.activeSessionID, manifest.sessionID)

        // The backend eventually returns: its output is still never saved.
        diarizer.open()
        let outcome = await releasedOutcome(service, epoch: 1)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(S.sidecarData(paths))
    }

    // MARK: - Independence

    /// The service's only collaborators are its backend, source loader,
    /// store, and clock (see `init`): no recording, transcription, Notes, or
    /// Summary owner exists for it to consult. A different session that is
    /// still recording in the same root does not affect admission.
    func testAdmissionIsIndependentOfAnotherSessionRecording() async throws {
        try S.writeSession(root: root, status: .recording)
        let (terminal, paths) = try S.writeSession(root: root, status: .completed)

        let outcome = await run(makeService(), terminal.sessionID)
        guard case .completed? = outcome else { return XCTFail("expected completed, got \(String(describing: outcome))") }
        XCTAssertNotNil(S.sidecarData(paths))
    }
}

/// Records every `lastReleasedOperation` emission and the ownership state
/// observable at that instant.
@MainActor
private final class ReleaseRecorder {
    private(set) var releases: [SessionDiarizationService.OperationRelease] = []
    private(set) var activeSessionIDAtEmission: [UUID?] = []
    private(set) var phaseAtEmission: [SessionDiarizationService.OperationPhase] = []
    private(set) var nilEmissionCount = 0
    private var cancellable: AnyCancellable?

    init(_ service: SessionDiarizationService) {
        cancellable = service.$lastReleasedOperation.dropFirst().sink { [weak self, weak service] release in
            guard let self else { return }
            guard let release else {
                self.nilEmissionCount += 1
                return
            }
            self.activeSessionIDAtEmission.append(service?.activeSessionID)
            if let phase = service?.phase { self.phaseAtEmission.append(phase) }
            self.releases.append(release)
        }
    }
}

private extension SessionDiarizationService.OperationPhase {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
