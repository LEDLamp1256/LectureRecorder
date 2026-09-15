import XCTest
@testable import LectureRecorder

final class SessionArtifactPreflightTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!
    private var artifactPaths: TranscriptionArtifactPaths!
    private var manifest: SessionManifest!
    private var store: TranscriptionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionArtifactPreflightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        sessionID = UUID()
        sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        manifest = makeManifest(chunkCount: 2)
        try AtomicFileWriter.writeJSON(manifest, to: sessionPaths.manifestURL)
        for chunk in manifest.chunks {
            try Data("placeholder".utf8).write(to: sessionPaths.chunksDirectory.appendingPathComponent(chunk.fileName))
        }
        artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        store = TranscriptionStore()
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

    private func makeManifest(chunkCount: Int) -> SessionManifest {
        var m = SessionManifest.newSession(id: sessionID, audioFormat: makeAudioFormat(), targetChunkDurationSeconds: 30)
        m.status = .completed
        m.chunks = (0..<chunkCount).map { seq in
            ChunkMetadata(
                sequenceNumber: seq,
                fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30,
                frameCount: 1_000,
                state: .completed
            )
        }
        return m
    }

    private func expectedSource(sequenceNumber: Int) -> TranscriptionSourceSnapshot {
        let chunk = manifest.chunks[sequenceNumber]
        return TranscriptionSourceSnapshot(
            sessionID: sessionID, chunkSequenceNumber: sequenceNumber, chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
        )
    }

    private func writeQueuedJob(sequenceNumber: Int, source: TranscriptionSourceSnapshot) async throws {
        _ = try await store.createJobIfAbsent(
            TranscriptionJob.newQueued(source: source, now: Date()),
            paths: artifactPaths
        )
    }

    private func writeResult(sequenceNumber: Int, source: TranscriptionSourceSnapshot) async throws {
        _ = try await store.commitResult(
            TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion,
                source: source,
                output: TranscriptionEngineOutput(text: "x", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                attemptID: UUID(),
                completedDate: Date()
            ),
            paths: artifactPaths
        )
    }

    private func runPreflight() async -> SessionArtifactPreflightReport {
        await SessionArtifactPreflight.run(manifest: manifest, sessionPaths: sessionPaths, artifactPaths: artifactPaths, store: store)
    }

    // MARK: - Sanity

    func testValidSessionWithNoArtifactsIsNotBlocked() async {
        let report = await runPreflight()
        XCTAssertTrue(report.blockingReasons.isEmpty)
    }

    func testValidQueuedJobsAreNotBlocked() async throws {
        try await writeQueuedJob(sequenceNumber: 0, source: expectedSource(sequenceNumber: 0))
        try await writeQueuedJob(sequenceNumber: 1, source: expectedSource(sequenceNumber: 1))
        let report = await runPreflight()
        XCTAssertTrue(report.blockingReasons.isEmpty)
        XCTAssertEqual(report.jobsBySequence.count, 2)
    }

    // MARK: - Source-snapshot mismatch (correction item 2)

    func testQueuedJobWithMismatchedChunkFileNameIsBlocked() async throws {
        var mismatched = expectedSource(sequenceNumber: 0)
        mismatched.chunkFileName = "chunk_000099.caf"
        try await writeQueuedJob(sequenceNumber: 0, source: mismatched)
        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)
    }

    func testQueuedJobWithMismatchedFrameCountIsBlocked() async throws {
        var mismatched = expectedSource(sequenceNumber: 0)
        mismatched.frameCount += 1
        try await writeQueuedJob(sequenceNumber: 0, source: mismatched)
        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)
    }

    func testResultSourceMismatchIsBlocked() async throws {
        try await writeQueuedJob(sequenceNumber: 0, source: expectedSource(sequenceNumber: 0))
        var mismatched = expectedSource(sequenceNumber: 0)
        mismatched.durationSeconds += 1
        try await writeResult(sequenceNumber: 0, source: mismatched)
        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)
    }

    // MARK: - Coverage (correction item 3, at the preflight layer)

    func testJobSequenceOutsideExpectedCoverageIsBlocked() async throws {
        // Sequence 99 is outside this manifest's expected {0,1} coverage.
        var outOfRange = expectedSource(sequenceNumber: 0)
        outOfRange.chunkSequenceNumber = 99
        outOfRange.chunkFileName = TranscriptionArtifactPaths.canonicalChunkFileName(for: 99)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        _ = try await store.createJobIfAbsent(TranscriptionJob.newQueued(source: outOfRange, now: Date()), paths: artifactPaths)
        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)
    }

    func testOrphanResultIsBlocked() async throws {
        try await writeResult(sequenceNumber: 0, source: expectedSource(sequenceNumber: 0))
        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)
    }

    func testCompletedJobMissingResultIsBlocked() async throws {
        var completed = TranscriptionJob.newQueued(source: expectedSource(sequenceNumber: 0), now: Date())
        completed.state = .completed
        _ = try await store.createJobIfAbsent(completed, paths: artifactPaths)
        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)
    }

    // MARK: - Recoverable states are NOT blockers (item 1's explicit requirement)

    func testOwnerlessRunningJobWithNoResultIsNotBlocked() async throws {
        var running = TranscriptionJob.newQueued(source: expectedSource(sequenceNumber: 0), now: Date())
        running.state = .running
        running.currentAttemptID = UUID()
        _ = try await store.createJobIfAbsent(running, paths: artifactPaths)
        let report = await runPreflight()
        XCTAssertTrue(report.blockingReasons.isEmpty, "ownerless running should be left for reconcileState, not blocked: \(report.blockingReasons)")
    }

    func testRunningJobWithMatchingResultIsNotBlocked() async throws {
        let attemptID = UUID()
        var running = TranscriptionJob.newQueued(source: expectedSource(sequenceNumber: 0), now: Date())
        running.state = .running
        running.currentAttemptID = attemptID
        _ = try await store.createJobIfAbsent(running, paths: artifactPaths)
        _ = try await store.commitResult(
            TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion,
                source: expectedSource(sequenceNumber: 0),
                output: TranscriptionEngineOutput(text: "x", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                attemptID: attemptID,
                completedDate: Date()
            ),
            paths: artifactPaths
        )
        let report = await runPreflight()
        XCTAssertTrue(report.blockingReasons.isEmpty, "recovery-pending should be left for reconcileState, not blocked: \(report.blockingReasons)")
    }

    // MARK: - Job/result relationship validation (correction item 2)

    func testRunningJobWithAttemptMismatchedResultIsBlocked() async throws {
        var running = TranscriptionJob.newQueued(source: expectedSource(sequenceNumber: 0), now: Date())
        running.state = .running
        running.currentAttemptID = UUID()
        _ = try await store.createJobIfAbsent(running, paths: artifactPaths)
        // A DIFFERENT attempt ID than the job's currentAttemptID.
        _ = try await store.commitResult(
            TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion,
                source: expectedSource(sequenceNumber: 0),
                output: TranscriptionEngineOutput(text: "x", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
                attemptID: UUID(),
                completedDate: Date()
            ),
            paths: artifactPaths
        )
        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)
    }

    func testQueuedJobWithAnyResultIsBlocked() async throws {
        try await writeQueuedJob(sequenceNumber: 0, source: expectedSource(sequenceNumber: 0))
        try await writeResult(sequenceNumber: 0, source: expectedSource(sequenceNumber: 0))
        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)
    }

    func testFailedJobWithAnyResultIsBlocked() async throws {
        var failed = TranscriptionJob.newQueued(source: expectedSource(sequenceNumber: 0), now: Date())
        failed.state = .failed
        failed.lastFailure = TranscriptionFailure(
            category: .engineThrew, message: "x", retryDisposition: .retryable, failureDate: Date(), attemptNumber: 1
        )
        _ = try await store.createJobIfAbsent(failed, paths: artifactPaths)
        try await writeResult(sequenceNumber: 0, source: expectedSource(sequenceNumber: 0))
        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)
    }

    // MARK: - Unexpected-sequence symlinked artifacts (correction item 3)

    func testUnexpectedSequenceSymlinkedJobArtifactIsBlockedAndExternalTargetUntouched() async throws {
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        let externalTarget = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("PreflightUnexpectedJobCanary-\(UUID().uuidString).json")
        let canaryContent = "unexpected-job-canary-untouched"
        try Data(canaryContent.utf8).write(to: externalTarget)
        defer { try? FileManager.default.removeItem(at: externalTarget) }

        // Sequence 99 is outside this manifest's expected {0,1} coverage.
        let rogueJobURL = artifactPaths.jobURL(sequenceNumber: 99)
        try FileManager.default.createSymbolicLink(at: rogueJobURL, withDestinationURL: externalTarget)

        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)

        let finalContent = try Data(contentsOf: externalTarget)
        XCTAssertEqual(String(data: finalContent, encoding: .utf8), canaryContent)
    }

    func testUnexpectedSequenceSymlinkedResultArtifactIsBlockedAndExternalTargetUntouched() async throws {
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        let externalTarget = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("PreflightUnexpectedResultCanary-\(UUID().uuidString).json")
        let canaryContent = "unexpected-result-canary-untouched"
        try Data(canaryContent.utf8).write(to: externalTarget)
        defer { try? FileManager.default.removeItem(at: externalTarget) }

        let rogueResultURL = artifactPaths.resultURL(sequenceNumber: 99)
        try FileManager.default.createSymbolicLink(at: rogueResultURL, withDestinationURL: externalTarget)

        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)

        let finalContent = try Data(contentsOf: externalTarget)
        XCTAssertEqual(String(data: finalContent, encoding: .utf8), canaryContent)
    }

    // MARK: - Symlink safety + external canary untouched

    func testSymlinkedChunkAudioFileIsBlockedAndExternalTargetUntouched() async throws {
        let externalTarget = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("SessionArtifactPreflightCanary-\(UUID().uuidString).caf")
        let canaryContent = "canary-audio-untouched"
        try Data(canaryContent.utf8).write(to: externalTarget)
        defer { try? FileManager.default.removeItem(at: externalTarget) }

        let chunkURL = sessionPaths.chunksDirectory.appendingPathComponent(manifest.chunks[0].fileName)
        try FileManager.default.removeItem(at: chunkURL)
        try FileManager.default.createSymbolicLink(at: chunkURL, withDestinationURL: externalTarget)

        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)

        let finalContent = try Data(contentsOf: externalTarget)
        XCTAssertEqual(String(data: finalContent, encoding: .utf8), canaryContent)
    }

    func testSymlinkedJobArtifactPathIsBlockedAndExternalTargetUntouched() async throws {
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        let externalTarget = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("SessionArtifactPreflightJobCanary-\(UUID().uuidString).json")
        let canaryContent = "canary-job-untouched"
        try Data(canaryContent.utf8).write(to: externalTarget)
        defer { try? FileManager.default.removeItem(at: externalTarget) }

        let jobURL = artifactPaths.jobURL(sequenceNumber: 0)
        try FileManager.default.createSymbolicLink(at: jobURL, withDestinationURL: externalTarget)

        let report = await runPreflight()
        XCTAssertFalse(report.blockingReasons.isEmpty)

        let finalContent = try Data(contentsOf: externalTarget)
        XCTAssertEqual(String(data: finalContent, encoding: .utf8), canaryContent)
    }
}
