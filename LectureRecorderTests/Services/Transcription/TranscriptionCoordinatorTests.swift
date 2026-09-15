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
            schemaVersion: TranscriptResult.legacySchemaVersion,
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

    func testProcessJobCarriesStructuredProvenanceThroughPersistenceAndReload() async throws {
        let store = TranscriptionStore()
        var output = TranscriptionEngineOutput(
            text: "technical lecture",
            engineIdentifier: "whisper.cpp",
            modelIdentifier: "large-v3-turbo",
            language: "en",
            segments: [TranscriptionTimingSegment(startSeconds: 0, endSeconds: 1, text: "technical lecture")],
            engineVersion: "1.9.2"
        )
        output.provenance = makeT3BProvenance()
        let transcriber = FakeTranscriber()
        transcriber.setOutput(output, forSequenceNumber: 0)
        let coordinator = makeCoordinator(store: store, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)

        let result = try await store.loadResult(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(result?.schemaVersion, 2)
        XCTAssertEqual(result?.output.provenance, makeT3BProvenance())
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

    // MARK: - Genuine concurrent claim race (regression for the check-then-act
    // reentrancy bug: `activeAttempts.insert` used to happen only after the
    // `await store.loadJob` suspension, so two truly concurrent calls could
    // both pass the "already claimed" guard before either reserved the key)

    func testConcurrentProcessJobCallsOnSameCoordinatorRefuseTheSecondAndTranscribeOnlyOnce() async throws {
        let realStore = TranscriptionStore()
        let gatedStore = GatedTranscriptionStore(wrapped: realStore)
        let transcriber = FakeTranscriber()
        let coordinator = makeCoordinator(store: gatedStore, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        await gatedStore.armGate(forSequenceNumber: 0)

        let firstTask = Task {
            try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
        }

        // Prove real overlap: wait until the first call is genuinely
        // suspended inside `store.loadJob` before starting the second.
        while await !gatedStore.hasEnteredGate {
            await Task.yield()
        }

        let secondTask = Task {
            try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
        }

        // The second call must resolve to a refusal on its own, without
        // the gate ever being released — proving the refusal happened
        // synchronously against the first call's already-reserved key,
        // not merely after the first call eventually finished.
        do {
            _ = try await secondTask.value
            XCTFail("Expected the second concurrent call to be refused")
        } catch let error as TranscriptionCoordinatorError {
            guard case .alreadyClaimedByThisCoordinator = error else {
                return XCTFail("Expected alreadyClaimedByThisCoordinator, got \(error)")
            }
        }

        await gatedStore.release()
        let completed = try await firstTask.value

        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(transcriber.recordedCalls.count, 1)

        let finalJob = try await realStore.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(finalJob?.attemptCount, 1)

        let result = try await realStore.loadResult(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertNotNil(result)
    }

    // MARK: - Failure-window persistence tests (using `FailingTranscriptionStore`)

    func testClaimJobFailurePersistingRunningLeavesJobQueuedTranscriberNotInvokedAndReleasesOwnership() async throws {
        let realStore = TranscriptionStore()
        let failingStore = FailingTranscriptionStore(wrapped: realStore)
        let transcriber = FakeTranscriber()
        let coordinator = makeCoordinator(store: failingStore, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        await failingStore.setReplaceJobFailureQueue([true])

        do {
            _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
            XCTFail("Expected the injected replaceJob failure to propagate")
        } catch is FailingTranscriptionStore.TestInjectedError {
            // expected
        }

        XCTAssertEqual(transcriber.recordedCalls.count, 0)

        let job = try await realStore.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job?.state, .queued)
        XCTAssertEqual(job?.attemptCount, 0)

        // A later call, once the store is healthy again, must be able to
        // claim and process the job normally — proving the failed attempt
        // above did not leak `activeAttempts` ownership.
        let completedJob = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(completedJob.state, .completed)
        XCTAssertEqual(transcriber.recordedCalls.count, 1)
    }

    func testCompleteJobPersistenceFailureAfterCommitLeavesJobRunningAndReconciliationCompletesIt() async throws {
        let realStore = TranscriptionStore()
        let failingStore = FailingTranscriptionStore(wrapped: realStore)
        let attemptID = UUID()
        let transcriber = FakeTranscriber()
        let coordinator = makeCoordinator(store: failingStore, transcriber: transcriber, makeAttemptID: { attemptID })
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        // First replaceJob (claimJob's queued -> running) succeeds; the
        // second (completeJob's running -> completed, reached only after
        // commitResult has already durably succeeded) fails.
        await failingStore.setReplaceJobFailureQueue([false, true])

        do {
            _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
            XCTFail("Expected commitDurabilityUncertain")
        } catch let error as TranscriptionCoordinatorError {
            guard case .commitDurabilityUncertain = error else {
                return XCTFail("Expected commitDurabilityUncertain, got \(error)")
            }
        }

        // The immutable result really was committed and must remain
        // present, untouched, and correctly attributed.
        let result = try await realStore.loadResult(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.attemptID, attemptID)

        // The job's own durable state was never advanced past .running
        // (the failed write never landed).
        let job = try await realStore.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job?.state, .running)
        XCTAssertEqual(job?.currentAttemptID, attemptID)

        // This coordinator's in-memory claim was released, not leaked --
        // proven by getting `jobNotClaimable` (the durable state check)
        // rather than `alreadyClaimedByThisCoordinator` (the in-memory
        // ownership check) on a same-instance retry.
        do {
            _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
            XCTFail("Expected jobNotClaimable")
        } catch let error as TranscriptionCoordinatorError {
            guard case .jobNotClaimable = error else {
                return XCTFail("Expected jobNotClaimable, got \(error)")
            }
        }

        // A fresh coordinator instance, with no in-memory activeAttempts
        // of its own, must reconcile this into .completed using the
        // matching-attempt result already durably on disk.
        let freshCoordinator = makeCoordinator(store: realStore)
        let report = try await freshCoordinator.reconcileState(paths: artifactPaths)
        let reconciled = report.jobs.first { $0.source.chunkSequenceNumber == 0 }
        XCTAssertEqual(reconciled?.state, .completed)
    }

    func testCancellationPersistenceFailureStillRethrowsAndLeavesAbandonedRunningAttemptForReconciliation() async throws {
        let realStore = TranscriptionStore()
        let failingStore = FailingTranscriptionStore(wrapped: realStore)
        let transcriber = CancellationAwareFakeTranscriber()
        transcriber.armGate()
        let coordinator = makeCoordinator(store: failingStore, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        // First replaceJob (queued -> running) succeeds; the second
        // (failJob's running -> failed, on the cancellation path) fails.
        await failingStore.setReplaceJobFailureQueue([false, true])

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
            // Cancellation must still rethrow even though the durable
            // failure-persistence write below it failed.
        }

        let result = try await realStore.loadResult(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertNil(result)

        let job = try await realStore.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job?.state, .running)

        // Ownership was released on the original coordinator, not leaked
        // — proven the same way as above (jobNotClaimable, not
        // alreadyClaimedByThisCoordinator).
        do {
            _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
            XCTFail("Expected jobNotClaimable")
        } catch let error as TranscriptionCoordinatorError {
            guard case .jobNotClaimable = error else {
                return XCTFail("Expected jobNotClaimable, got \(error)")
            }
        }

        let freshCoordinator = makeCoordinator(store: realStore)
        let report = try await freshCoordinator.reconcileState(paths: artifactPaths)
        let reconciled = report.jobs.first { $0.source.chunkSequenceNumber == 0 }
        XCTAssertEqual(reconciled?.state, .failed)
        XCTAssertEqual(reconciled?.lastFailure?.category, .abandonedRunningAttempt)
        XCTAssertEqual(reconciled?.lastFailure?.retryDisposition, .retryable)
    }

    /// Shared setup for both durability-reconfirmation reconciliation
    /// tests below: drives `processJob` through the real crash window (the
    /// exclusive rename genuinely succeeded — a valid, attempt-matching
    /// result really is on disk — but the containing-directory fsync could
    /// not be confirmed at commit time), and proves the already-covered,
    /// unchanged `processJob`-level behavior (requirements 1-3: the commit
    /// is reported durability-uncertain, the job is left `.running`, and
    /// the result is present and untouched) before returning control to
    /// the caller to exercise reconciliation's *new* behavior.
    private func setUpDurabilityUncertainCommit(
        spy: SpyExclusiveArtifactFileSystem,
        store: TranscriptionStore,
        attemptID: UUID,
        coordinator: TranscriptionCoordinator
    ) async throws -> (resultURL: URL, precommittedData: Data) {
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        let resultURL = artifactPaths.resultURL(sequenceNumber: 0)
        let precommitted = makeResult(sequenceNumber: 0, attemptID: attemptID)
        try FileManager.default.createDirectory(at: artifactPaths.resultsDirectory, withIntermediateDirectories: true)
        let precommittedData = try AtomicFileWriter.defaultEncoder.encode(precommitted)
        try precommittedData.write(to: resultURL)
        spy.forceResult(.success(.createdDurabilityUncertain), forURL: resultURL)

        do {
            _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
            XCTFail("Expected commitDurabilityUncertain")
        } catch let error as TranscriptionCoordinatorError {
            guard case .commitDurabilityUncertain = error else {
                XCTFail("Expected commitDurabilityUncertain, got \(error)")
                return (resultURL, precommittedData)
            }
        }

        // Requirements 1-3: processJob does not complete the job, and the
        // result is present and unchanged.
        let job = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job?.state, .running)
        XCTAssertEqual(job?.currentAttemptID, attemptID)
        XCTAssertEqual(try Data(contentsOf: resultURL), precommittedData)

        do {
            _ = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
            XCTFail("Expected jobNotClaimable (proving activeAttempts ownership was released, not leaked)")
        } catch let error as TranscriptionCoordinatorError {
            guard case .jobNotClaimable = error else {
                XCTFail("Expected jobNotClaimable, got \(error)")
                return (resultURL, precommittedData)
            }
        }

        return (resultURL, precommittedData)
    }

    // MARK: - `alreadyCommittedIdentical` durability re-confirmation

    /// Shared setup for the two `completeJob`-level `.alreadyCommittedIdentical`
    /// tests below: leaves job #0 `.running` with `attemptID`, and durably
    /// commits (via the real store, `.committed`) a canonical result that
    /// is byte-for-byte what `completeJob(sequenceNumber:attemptID:output:paths:)`
    /// will itself construct for the same `output`/`attemptID`/`fixedNow` —
    /// so a subsequent `completeJob` call genuinely observes
    /// `.alreadyCommittedIdentical`, not `.conflict`, without needing to
    /// force the exclusive-create outcome itself.
    private func setUpRunningJobWithIdenticalCommittedResult(
        store: TranscriptionStore,
        attemptID: UUID,
        fixedNow: Date,
        coordinator: TranscriptionCoordinator
    ) async throws -> (output: TranscriptionEngineOutput, resultURL: URL, precommittedData: Data) {
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)

        var job = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)!
        job.state = .running
        job.currentAttemptID = attemptID
        job.attemptCount = 1
        try await store.replaceJob(job, paths: artifactPaths)

        let output = TranscriptionEngineOutput(
            text: "hi",
            engineIdentifier: "fake-v1",
            modelIdentifier: nil,
            language: nil,
            segments: nil,
            engineVersion: nil
        )
        let result = TranscriptResult(
            schemaVersion: TranscriptResult.schemaVersion(for: output),
            source: job.source,
            output: output,
            attemptID: attemptID,
            completedDate: fixedNow
        )
        let commitOutcome = try await store.commitResult(result, paths: artifactPaths)
        if commitOutcome != .committed {
            XCTFail("Expected initial commit to succeed durably, got \(commitOutcome)")
        }

        let resultURL = artifactPaths.resultURL(sequenceNumber: 0)
        let precommittedData = try Data(contentsOf: resultURL)
        return (output, resultURL, precommittedData)
    }

    func testCompleteJobLeavesJobRunningWhenAlreadyCommittedIdenticalDurabilityReconfirmationFails() async throws {
        let spy = SpyExclusiveArtifactFileSystem()
        let store = TranscriptionStore(exclusiveFileSystem: spy)
        let attemptID = UUID()
        let fixedNow = Date()
        let transcriber = FakeTranscriber()
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, now: { fixedNow }, makeAttemptID: { attemptID })
        let (output, resultURL, precommittedData) = try await setUpRunningJobWithIdenticalCommittedResult(
            store: store, attemptID: attemptID, fixedNow: fixedNow, coordinator: coordinator
        )

        // Fresh durability re-confirmation for the results directory fails
        // -- the identical result's mere readability is not itself
        // evidence that an earlier durability uncertainty was resolved.
        spy.forceDirectorySync(false, forURL: artifactPaths.resultsDirectory)

        do {
            _ = try await coordinator.completeJob(sequenceNumber: 0, attemptID: attemptID, output: output, paths: artifactPaths)
            XCTFail("Expected commitDurabilityUncertain")
        } catch let error as TranscriptionCoordinatorError {
            guard case .commitDurabilityUncertain = error else {
                return XCTFail("Expected commitDurabilityUncertain, got \(error)")
            }
        }

        // The job is left exactly `.running` with the same attempt --
        // never marked failed, never rerun.
        let job = try await store.loadJob(sequenceNumber: 0, paths: artifactPaths)
        XCTAssertEqual(job?.state, .running)
        XCTAssertEqual(job?.currentAttemptID, attemptID)
        // The canonical result was never rewritten, replaced, or deleted.
        XCTAssertEqual(try Data(contentsOf: resultURL), precommittedData)
        // completeJob itself never invokes the transcriber.
        XCTAssertEqual(transcriber.recordedCalls.count, 0)
    }

    func testCompleteJobCompletesAlreadyCommittedIdenticalResultOnceDurabilityReconfirmationSucceeds() async throws {
        let spy = SpyExclusiveArtifactFileSystem()
        let store = TranscriptionStore(exclusiveFileSystem: spy)
        let attemptID = UUID()
        let fixedNow = Date()
        let transcriber = FakeTranscriber()
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, now: { fixedNow }, makeAttemptID: { attemptID })
        let (output, resultURL, precommittedData) = try await setUpRunningJobWithIdenticalCommittedResult(
            store: store, attemptID: attemptID, fixedNow: fixedNow, coordinator: coordinator
        )

        // An un-forced `synchronizeDirectory` call delegates to the real
        // filesystem, which genuinely can fsync this writable temp
        // directory -- fresh durability confirmation succeeds.
        let completed = try await coordinator.completeJob(
            sequenceNumber: 0, attemptID: attemptID, output: output, paths: artifactPaths
        )

        XCTAssertEqual(completed.state, .completed)
        XCTAssertNil(completed.currentAttemptID)
        XCTAssertTrue(spy.recordedCalls.contains(.synchronizeDirectory(artifactPaths.resultsDirectory)))
        // The already-identical canonical result remains exactly as it was.
        XCTAssertEqual(try Data(contentsOf: resultURL), precommittedData)
        // completeJob itself never invokes the transcriber.
        XCTAssertEqual(transcriber.recordedCalls.count, 0)
    }

    func testReconciliationLeavesJobRunningWhenResultDurabilityReconfirmationStillFails() async throws {
        let spy = SpyExclusiveArtifactFileSystem()
        let store = TranscriptionStore(exclusiveFileSystem: spy)
        let attemptID = UUID()
        let transcriber = FakeTranscriber()
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, makeAttemptID: { attemptID })
        let (resultURL, precommittedData) = try await setUpDurabilityUncertainCommit(
            spy: spy, store: store, attemptID: attemptID, coordinator: coordinator
        )
        let sourceAudioURL = artifactPaths.chunkAudioURL(fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: 0))
        let sourceAudioBefore = try Data(contentsOf: sourceAudioURL)

        // Requirement 4: recovery's fresh directory re-confirmation still
        // fails (the same underlying durability problem persists).
        spy.forceDirectorySync(false, forURL: artifactPaths.resultsDirectory)

        // A distinct transcriber instance, never passed to `coordinator`
        // above, so its own call count is proof reconciliation itself
        // invoked no inference -- not merely that the *original*
        // transcriber wasn't called again.
        let recoveryTranscriber = FakeTranscriber()
        let freshCoordinator = makeCoordinator(store: store, transcriber: recoveryTranscriber)
        let report = try await freshCoordinator.reconcileState(paths: artifactPaths)
        let reconciled = report.jobs.first { $0.source.chunkSequenceNumber == 0 }

        // Never presented as completed while durability remains
        // unresolved, and never silently failed either -- the result
        // really is there and transcription must not be rerun.
        XCTAssertEqual(reconciled?.state, .running)
        XCTAssertEqual(reconciled?.currentAttemptID, attemptID)
        XCTAssertTrue(report.inconsistencies.contains(.resultDurabilityUnconfirmed(sequenceNumber: 0)))

        // The immutable result was never rewritten or replaced.
        XCTAssertEqual(try Data(contentsOf: resultURL), precommittedData)
        // No second transcription/inference call was made during recovery.
        XCTAssertEqual(recoveryTranscriber.recordedCalls.count, 0)
        // The original attempt's own single transcribe call still stands.
        XCTAssertEqual(transcriber.recordedCalls.count, 1)
        // Source audio is untouched by the failed recovery attempt.
        XCTAssertEqual(try Data(contentsOf: sourceAudioURL), sourceAudioBefore)

        // A second reconciliation pass, still without durability restored,
        // must behave identically -- not flip to failed or completed.
        spy.forceDirectorySync(false, forURL: artifactPaths.resultsDirectory)
        let secondReport = try await freshCoordinator.reconcileState(paths: artifactPaths)
        let secondReconciled = secondReport.jobs.first { $0.source.chunkSequenceNumber == 0 }
        XCTAssertEqual(secondReconciled?.state, .running)
        XCTAssertEqual(recoveryTranscriber.recordedCalls.count, 0)
    }

    func testReconciliationCompletesJobOnceResultDurabilityReconfirmationSucceeds() async throws {
        let spy = SpyExclusiveArtifactFileSystem()
        let store = TranscriptionStore(exclusiveFileSystem: spy)
        let attemptID = UUID()
        let transcriber = FakeTranscriber()
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, makeAttemptID: { attemptID })
        let (resultURL, precommittedData) = try await setUpDurabilityUncertainCommit(
            spy: spy, store: store, attemptID: attemptID, coordinator: coordinator
        )
        let sourceAudioURL = artifactPaths.chunkAudioURL(fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: 0))
        let sourceAudioBefore = try Data(contentsOf: sourceAudioURL)

        // Requirement 5: an un-forced `synchronizeDirectory` call delegates
        // to the real filesystem, which genuinely can fsync this writable
        // temp directory -- fresh durability confirmation succeeds.
        //
        // A distinct transcriber instance, never passed to `coordinator`
        // above, so its own call count is proof reconciliation itself
        // invoked no inference -- not merely that the *original*
        // transcriber wasn't called again.
        let recoveryTranscriber = FakeTranscriber()
        let freshCoordinator = makeCoordinator(store: store, transcriber: recoveryTranscriber)
        let report = try await freshCoordinator.reconcileState(paths: artifactPaths)
        let reconciled = report.jobs.first { $0.source.chunkSequenceNumber == 0 }

        XCTAssertEqual(reconciled?.state, .completed)
        XCTAssertNil(reconciled?.currentAttemptID)
        XCTAssertFalse(report.inconsistencies.contains { inconsistency in
            if case .resultDurabilityUnconfirmed = inconsistency { return true }
            return false
        })
        XCTAssertTrue(spy.recordedCalls.contains(.synchronizeDirectory(artifactPaths.resultsDirectory)))

        // Requirement 6: no second transcription/inference call was made
        // during recovery.
        XCTAssertEqual(recoveryTranscriber.recordedCalls.count, 0)
        // The original attempt's own single transcribe call still stands.
        XCTAssertEqual(transcriber.recordedCalls.count, 1)
        // Requirement 7: the canonical result was never rewritten.
        XCTAssertEqual(try Data(contentsOf: resultURL), precommittedData)
        // Requirement 10: source audio is untouched by recovery.
        XCTAssertEqual(try Data(contentsOf: sourceAudioURL), sourceAudioBefore)
    }
}
