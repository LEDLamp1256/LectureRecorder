import XCTest
@testable import LectureRecorder

final class TranscriptionCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!
    private var manifest: SessionManifest!
    private var artifactPaths: TranscriptionArtifactPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        sessionID = UUID()
        sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        manifest = makeCompletedManifest(chunkCount: 3)

        // Chunks 0 and 2 have a real (placeholder) source file; chunk 1's
        // source is deliberately left missing.
        try writePlaceholderChunkFile(sequenceNumber: 0)
        try writePlaceholderChunkFile(sequenceNumber: 2)

        artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
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

    private func makeCompletedManifest(chunkCount: Int) -> SessionManifest {
        var m = SessionManifest.newSession(id: sessionID, audioFormat: makeAudioFormat(), targetChunkDurationSeconds: 30)
        m.status = .completed
        m.endedCleanly = true
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

    private func writePlaceholderChunkFile(sequenceNumber: Int) throws {
        let url = sessionPaths.chunksDirectory.appendingPathComponent(
            TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber)
        )
        try Data("placeholder audio".utf8).write(to: url)
    }

    private func makeSource(_ sequenceNumber: Int) -> TranscriptionSourceSnapshot {
        TranscriptionSourceSnapshot(
            sessionID: sessionID,
            chunkSequenceNumber: sequenceNumber,
            chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber),
            frameCount: 1_000,
            startOffsetSeconds: Double(sequenceNumber) * 30,
            durationSeconds: 30,
            audioFormat: makeAudioFormat()
        )
    }

    private func makeResult(sequenceNumber: Int, attemptID: UUID = UUID(), text: String = "hi") -> TranscriptResult {
        TranscriptResult(
            schemaVersion: TranscriptResult.currentSchemaVersion,
            source: makeSource(sequenceNumber),
            output: TranscriptionEngineOutput(
                text: text,
                engineIdentifier: "fake-v1",
                modelIdentifier: nil,
                language: nil,
                segments: nil,
                engineVersion: nil
            ),
            attemptID: attemptID,
            completedDate: Date()
        )
    }

    private func makeCoordinator(
        store: any TranscriptionStoring,
        transcriber: any Transcribing = FakeTranscriber(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeAttemptID: @escaping @Sendable () -> UUID = UUID.init
    ) -> TranscriptionCoordinator {
        TranscriptionCoordinator(store: store, transcriber: transcriber, now: now, makeAttemptID: makeAttemptID)
    }

    // MARK: - Enqueue

    func testEnqueueCreatesQueuedJobForPresentSourceAndFailedForMissingSource() async throws {
        let store = TranscriptionStore()
        let coordinator = makeCoordinator(store: store)
        let report = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertEqual(Set(report.created), Set([0, 1, 2]))

        let job0 = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job0?.state, .queued)

        let job1 = try await store.loadJob(sequenceNumber: 1, paths: artifactPaths)
        XCTAssertEqual(job1?.state, .failed)
        XCTAssertEqual(job1?.lastFailure?.category, .sourceMissing)
        XCTAssertEqual(job1?.lastFailure?.retryDisposition, .retryable)
        XCTAssertEqual(job1?.attemptCount, 0)

        let job2 = try await store.loadJob(sequenceNumber: 2, paths: artifactPaths)
        XCTAssertEqual(job2?.state, .queued)
    }

    func testDuplicateEnqueueDoesNotRecreateOrRetryFailedJob() async throws {
        let store = TranscriptionStore()
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        var job0 = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)!
        job0.state = .failed
        job0.attemptCount = 1
        job0.lastFailure = TranscriptionFailure(
            category: .engineThrew,
            message: "prior failure",
            retryDisposition: .retryable,
            failureDate: Date(),
            attemptNumber: 1
        )
        try await store.replaceJob(job0, paths: artifactPaths)

        let secondReport = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertTrue(secondReport.created.isEmpty)
        XCTAssertEqual(Set(secondReport.alreadyExisted), Set([0, 1, 2]))

        let reloaded = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(reloaded?.state, .failed)
        XCTAssertEqual(reloaded?.lastFailure?.message, "prior failure")
    }

    func testEnqueueRefusesNonCompletedSession() async throws {
        let store = TranscriptionStore()
        let coordinator = makeCoordinator(store: store)
        var nonCompleted = manifest!
        nonCompleted.status = .recording
        do {
            _ = try await coordinator.enqueueEligibleChunks(manifest: nonCompleted, sessionPaths: sessionPaths)
            XCTFail("Expected sessionNotCompleted")
        } catch let error as TranscriptionArtifactPaths.ValidationError {
            guard case .sessionNotCompleted = error else {
                return XCTFail("Expected sessionNotCompleted, got \(error)")
            }
        }
    }

    // MARK: - processJob happy path

    func testProcessJobCompletesSuccessfullyAndCommitsResult() async throws {
        let store = TranscriptionStore()
        let transcriber = FakeTranscriber()
        transcriber.setOutput(
            TranscriptionEngineOutput(
                text: "hello world",
                engineIdentifier: "fake-v1",
                modelIdentifier: nil,
                language: nil,
                segments: nil,
                engineVersion: nil
            ),
            forSequenceNumber: 0
        )
        let coordinator = makeCoordinator(store: store, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        let completed = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertNil(completed.currentAttemptID)

        let result = try await store.loadResult(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(result?.output.text, "hello world")
        XCTAssertEqual(transcriber.recordedCalls.count, 1)
    }

    func testProcessJobNeverModifiesSourceAudio() async throws {
        let store = TranscriptionStore()
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        let url = sessionPaths.chunksDirectory
            .appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: 0))
        let before = try Data(contentsOf: url)

        _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)

        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after)
    }

    // MARK: - Concurrent claim / reentrancy

    func testConcurrentClaimOnSameCoordinatorIsRefused() async throws {
        let store = TranscriptionStore()
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        _ = try await coordinator.claimJob(sequenceNumber: 0, paths: artifactPaths)
        do {
            _ = try await coordinator.claimJob(sequenceNumber: 0, paths: artifactPaths)
            XCTFail("Expected alreadyClaimedByThisCoordinator")
        } catch let error as TranscriptionCoordinatorError {
            guard case .alreadyClaimedByThisCoordinator = error else {
                return XCTFail("Expected alreadyClaimedByThisCoordinator, got \(error)")
            }
        }
    }

    func testDuplicateCompletionForSupersededAttemptIsRefused() async throws {
        let store = TranscriptionStore()
        let transcriber = FakeTranscriber()
        let attemptID = UUID()
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, makeAttemptID: { attemptID })
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)
        _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)

        do {
            _ = try await coordinator.completeJob(
                sequenceNumber: 0,
                attemptID: attemptID,
                output: FakeTranscriber.defaultFakeOutput,
                paths: artifactPaths
            )
            XCTFail("Expected attemptSuperseded")
        } catch let error as TranscriptionCoordinatorError {
            guard case .attemptSuperseded = error else {
                return XCTFail("Expected attemptSuperseded, got \(error)")
            }
        }
    }

    // MARK: - Typed engine failure classification

    func testTypedEngineFailurePersistsWithCategoryAndDisposition() async throws {
        let store = TranscriptionStore()
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "bad audio", retryDisposition: .permanent),
            forSequenceNumber: 0
        )
        let coordinator = makeCoordinator(store: store, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        let failed = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.lastFailure?.category, .engineThrew)
        XCTAssertEqual(failed.lastFailure?.retryDisposition, .permanent)
        XCTAssertEqual(failed.lastFailure?.message, "bad audio")

        let result = try await store.loadResult(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertNil(result)
    }

    func testUnclassifiedErrorIsMappedConservativelyToUnknownPermanent() async throws {
        let store = TranscriptionStore()
        let transcriber = FakeTranscriber()
        transcriber.setFailure(UnclassifiedFakeError(), forSequenceNumber: 0)
        let coordinator = makeCoordinator(store: store, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        let failed = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.lastFailure?.category, .unknown)
        XCTAssertEqual(failed.lastFailure?.retryDisposition, .permanent)
    }

    // MARK: - Cancellation

    func testCancellationPersistsRetryableFailureAndRethrowsAndNeverCommitsAResult() async throws {
        let store = TranscriptionStore()
        let transcriber = CancellationAwareFakeTranscriber()
        transcriber.armGate()
        let coordinator = makeCoordinator(store: store, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        let task = Task {
            try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
        }

        while !transcriber.hasEnteredGate {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }

        let job = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job?.state, .failed)
        XCTAssertEqual(job?.lastFailure?.category, .cancellation)
        XCTAssertEqual(job?.lastFailure?.retryDisposition, .retryable)

        let result = try await store.loadResult(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertNil(result)
    }

    // MARK: - Retry

    func testExplicitRetryMovesRetryableFailedJobBackToQueued() async throws {
        let store = TranscriptionStore()
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "transient", retryDisposition: .retryable),
            forSequenceNumber: 0
        )
        let coordinator = makeCoordinator(store: store, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)
        _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)

        let retried = try await coordinator.retryJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(retried.state, .queued)
        XCTAssertNil(retried.currentAttemptID)
    }

    func testRetryRefusedForPermanentFailure() async throws {
        let store = TranscriptionStore()
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "fatal", retryDisposition: .permanent),
            forSequenceNumber: 0
        )
        let coordinator = makeCoordinator(store: store, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)
        _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)

        do {
            _ = try await coordinator.retryJob(sequenceNumber: 0, paths: artifactPaths)
            XCTFail("Expected retryNotEligible")
        } catch let error as TranscriptionCoordinatorError {
            guard case .retryNotEligible = error else {
                return XCTFail("Expected retryNotEligible, got \(error)")
            }
        }
    }

    // MARK: - Source revalidation before claiming

    func testClaimJobFailsSourceMissingIfCafDeletedAfterEnqueue() async throws {
        let store = TranscriptionStore()
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        let url = sessionPaths.chunksDirectory
            .appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: 0))
        try FileManager.default.removeItem(at: url)

        do {
            _ = try await coordinator.claimJob(sequenceNumber: 0, paths: artifactPaths)
            XCTFail("Expected sourceMissing")
        } catch let error as TranscriptionCoordinatorError {
            guard case .sourceMissing = error else {
                return XCTFail("Expected sourceMissing, got \(error)")
            }
        }

        let job = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job?.state, .failed)
        XCTAssertEqual(job?.lastFailure?.category, .sourceMissing)
    }

    // MARK: - Reconciliation

    func testReconcileReclassifiesAbandonedRunningJobWithoutResultAsRetryableFailure() async throws {
        let store = TranscriptionStore()
        _ = try await store.createJobIfAbsent(TranscriptionJob.newQueued(source: makeSource(0), now: Date()), paths: artifactPaths)
        var job = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)!
        job.state = .running
        job.currentAttemptID = UUID()
        job.attemptCount = 1
        try await store.replaceJob(job, paths: artifactPaths)

        let coordinator = makeCoordinator(store: store)
        let report = try await coordinator.reconcileState(paths: artifactPaths)

        let reconciledJob = report.jobs.first { $0.source.chunkSequenceNumber == 0 }
        XCTAssertEqual(reconciledJob?.state, .failed)
        XCTAssertEqual(reconciledJob?.lastFailure?.category, .abandonedRunningAttempt)
        XCTAssertEqual(reconciledJob?.lastFailure?.retryDisposition, .retryable)
        XCTAssertTrue(report.inconsistencies.contains(.abandonedRunningAttemptWithoutResult(sequenceNumber: 0)))
    }

    func testReconcileCompletesAbandonedRunningJobWhenMatchingResultExists() async throws {
        let store = TranscriptionStore()
        let attemptID = UUID()
        _ = try await store.createJobIfAbsent(TranscriptionJob.newQueued(source: makeSource(0), now: Date()), paths: artifactPaths)
        var job = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)!
        job.state = .running
        job.currentAttemptID = attemptID
        job.attemptCount = 1
        try await store.replaceJob(job, paths: artifactPaths)

        _ = try await store.commitResult(makeResult(sequenceNumber: 0, attemptID: attemptID), paths: artifactPaths)

        let coordinator = makeCoordinator(store: store)
        let report = try await coordinator.reconcileState(paths: artifactPaths)
        let reconciledJob = report.jobs.first { $0.source.chunkSequenceNumber == 0 }
        XCTAssertEqual(reconciledJob?.state, .completed)
        XCTAssertFalse(report.inconsistencies.contains(.completedJobMissingResult(sequenceNumber: 0)))
    }

    func testReconcileFlagsResultAttemptMismatchAndReclassifiesAsRetryableFailure() async throws {
        let store = TranscriptionStore()
        let oldAttemptID = UUID()
        let currentAttemptID = UUID()
        _ = try await store.createJobIfAbsent(TranscriptionJob.newQueued(source: makeSource(0), now: Date()), paths: artifactPaths)
        var job = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)!
        job.state = .running
        job.currentAttemptID = currentAttemptID
        job.attemptCount = 2
        try await store.replaceJob(job, paths: artifactPaths)

        _ = try await store.commitResult(makeResult(sequenceNumber: 0, attemptID: oldAttemptID), paths: artifactPaths)

        let coordinator = makeCoordinator(store: store)
        let report = try await coordinator.reconcileState(paths: artifactPaths)
        XCTAssertTrue(report.inconsistencies.contains(.resultAttemptMismatch(sequenceNumber: 0)))
        let reconciledJob = report.jobs.first { $0.source.chunkSequenceNumber == 0 }
        XCTAssertEqual(reconciledJob?.state, .failed)
        XCTAssertEqual(reconciledJob?.lastFailure?.retryDisposition, .retryable)
    }

    func testReconcileFlagsCompletedJobMissingResultWithoutRepair() async throws {
        let store = TranscriptionStore()
        _ = try await store.createJobIfAbsent(TranscriptionJob.newQueued(source: makeSource(0), now: Date()), paths: artifactPaths)
        var job = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)!
        job.state = .completed
        job.currentAttemptID = nil
        try await store.replaceJob(job, paths: artifactPaths)

        let coordinator = makeCoordinator(store: store)
        let report = try await coordinator.reconcileState(paths: artifactPaths)
        XCTAssertTrue(report.inconsistencies.contains(.completedJobMissingResult(sequenceNumber: 0)))
        let reconciledJob = report.jobs.first { $0.source.chunkSequenceNumber == 0 }
        XCTAssertEqual(reconciledJob?.state, .completed)
    }

    func testReconcileFlagsResultWithNonTerminalJobAndNeverAutoCompletesIt() async throws {
        let store = TranscriptionStore()
        _ = try await store.createJobIfAbsent(TranscriptionJob.newQueued(source: makeSource(0), now: Date()), paths: artifactPaths)
        _ = try await store.commitResult(makeResult(sequenceNumber: 0), paths: artifactPaths)

        let coordinator = makeCoordinator(store: store)
        let report = try await coordinator.reconcileState(paths: artifactPaths)
        XCTAssertTrue(report.inconsistencies.contains(.resultWithNonTerminalJob(sequenceNumber: 0, jobState: .queued)))
        let reconciledJob = report.jobs.first { $0.source.chunkSequenceNumber == 0 }
        XCTAssertEqual(reconciledJob?.state, .queued)
    }

    func testReconcileFlagsOrphanedResult() async throws {
        let store = TranscriptionStore()
        _ = try await store.commitResult(makeResult(sequenceNumber: 0), paths: artifactPaths)

        let coordinator = makeCoordinator(store: store)
        let report = try await coordinator.reconcileState(paths: artifactPaths)
        XCTAssertTrue(report.inconsistencies.contains(.orphanedResult(sequenceNumber: 0)))
    }

    func testReconcileIsPartialTolerantAcrossCorruptAndValidJobs() async throws {
        let store = TranscriptionStore()
        _ = try await store.createJobIfAbsent(TranscriptionJob.newQueued(source: makeSource(0), now: Date()), paths: artifactPaths)
        try FileManager.default.createDirectory(at: artifactPaths.jobsDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: artifactPaths.jobURL(sequenceNumber: 1))
        _ = try await store.createJobIfAbsent(TranscriptionJob.newQueued(source: makeSource(2), now: Date()), paths: artifactPaths)

        let coordinator = makeCoordinator(store: store)
        let report = try await coordinator.reconcileState(paths: artifactPaths)

        XCTAssertEqual(report.jobs.count, 2)
        XCTAssertTrue(report.inconsistencies.contains { inconsistency in
            if case .corruptJob(let seq, _) = inconsistency { return seq == 1 }
            return false
        })
    }

    func testReconcileDoesNotReclassifyAttemptOwnedByThisInstance() async throws {
        let store = TranscriptionStore()
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        _ = try await coordinator.claimJob(sequenceNumber: 0, paths: artifactPaths)

        let report = try await coordinator.reconcileState(paths: artifactPaths)
        let job0 = report.jobs.first { $0.source.chunkSequenceNumber == 0 }
        XCTAssertEqual(job0?.state, .running)
    }

    // MARK: - Derived ordered assembly

    func testAssembleOrderedTranscriptOrdersBySequenceRegardlessOfCompletionOrder() {
        let coordinator = makeCoordinator(store: TranscriptionStore())
        let chunks = (0..<3).map { seq in
            ChunkMetadata(
                sequenceNumber: seq,
                fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30,
                frameCount: 1_000,
                state: .completed
            )
        }
        var job0 = TranscriptionJob.newQueued(source: makeSource(0), now: Date()); job0.state = .completed
        var job1 = TranscriptionJob.newQueued(source: makeSource(1), now: Date()); job1.state = .completed
        var job2 = TranscriptionJob.newQueued(source: makeSource(2), now: Date()); job2.state = .completed

        let result0 = makeResult(sequenceNumber: 0, text: "zero")
        let result1 = makeResult(sequenceNumber: 1, text: "one")
        let result2 = makeResult(sequenceNumber: 2, text: "two")

        let segments = coordinator.assembleOrderedTranscript(
            chunks: chunks,
            jobs: [job2, job0, job1],
            results: [result2, result0, result1]
        )
        XCTAssertEqual(segments.map(\.sequenceNumber), [0, 1, 2])
        let texts = segments.map { segment -> String in
            if case .completed(let text) = segment.state { return text }
            return "?"
        }
        XCTAssertEqual(texts, ["zero", "one", "two"])
    }

    func testAssembleOrderedTranscriptMarksMissingSequenceExplicitly() {
        let coordinator = makeCoordinator(store: TranscriptionStore())
        let chunks = (0..<2).map { seq in
            ChunkMetadata(
                sequenceNumber: seq,
                fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30,
                frameCount: 1_000,
                state: .completed
            )
        }
        var job0 = TranscriptionJob.newQueued(source: makeSource(0), now: Date()); job0.state = .completed
        let result0 = makeResult(sequenceNumber: 0)

        let segments = coordinator.assembleOrderedTranscript(chunks: chunks, jobs: [job0], results: [result0])
        XCTAssertEqual(segments[1].state, .missing)
    }

    func testAssembleOrderedTranscriptShowsFailedMiddleChunkWithLaterSuccess() {
        let coordinator = makeCoordinator(store: TranscriptionStore())
        let chunks = (0..<3).map { seq in
            ChunkMetadata(
                sequenceNumber: seq,
                fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30,
                frameCount: 1_000,
                state: .completed
            )
        }
        var job0 = TranscriptionJob.newQueued(source: makeSource(0), now: Date()); job0.state = .completed
        var job1 = TranscriptionJob.newQueued(source: makeSource(1), now: Date())
        job1.state = .failed
        job1.lastFailure = TranscriptionFailure(
            category: .engineThrew,
            message: "x",
            retryDisposition: .permanent,
            failureDate: Date(),
            attemptNumber: 1
        )
        var job2 = TranscriptionJob.newQueued(source: makeSource(2), now: Date()); job2.state = .completed

        let result0 = makeResult(sequenceNumber: 0)
        let result2 = makeResult(sequenceNumber: 2)

        let segments = coordinator.assembleOrderedTranscript(
            chunks: chunks,
            jobs: [job0, job1, job2],
            results: [result0, result2]
        )
        guard case .completed = segments[0].state else { return XCTFail("expected completed at 0") }
        guard case .failed = segments[1].state else { return XCTFail("expected failed at 1") }
        guard case .completed = segments[2].state else { return XCTFail("expected completed at 2") }
    }
}
