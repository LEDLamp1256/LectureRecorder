import XCTest
@testable import LectureRecorder

final class SessionTranscriptionStatusTests: XCTestCase {
    private let sessionID = UUID()

    private func makeAudioFormat() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
    }

    private func makeManifest(chunkCount: Int) -> SessionManifest {
        var manifest = SessionManifest.newSession(id: sessionID, audioFormat: makeAudioFormat(), targetChunkDurationSeconds: 30)
        manifest.status = .completed
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
        return manifest
    }

    private func makeSource(_ manifest: SessionManifest, _ seq: Int) -> TranscriptionSourceSnapshot {
        let chunk = manifest.chunks[seq]
        return TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID,
            chunkSequenceNumber: seq,
            chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount,
            startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds,
            audioFormat: manifest.audioFormat
        )
    }

    private func makeCompletedJob(_ manifest: SessionManifest, _ seq: Int) -> TranscriptionJob {
        TranscriptionJob(
            schemaVersion: TranscriptionJob.currentSchemaVersion,
            source: makeSource(manifest, seq),
            state: .completed,
            currentAttemptID: nil,
            attemptCount: 1,
            lastFailure: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
    }

    private func makeResult(_ manifest: SessionManifest, _ seq: Int, source: TranscriptionSourceSnapshot? = nil) -> TranscriptResult {
        TranscriptResult(
            schemaVersion: TranscriptResult.legacySchemaVersion,
            source: source ?? makeSource(manifest, seq),
            output: TranscriptionEngineOutput(text: "hi", engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil),
            attemptID: UUID(),
            completedDate: Date()
        )
    }

    // MARK: - Completion validator

    func testCompletionValidWhenEveryChunkHasMatchingCompletedJobAndResult() {
        let manifest = makeManifest(chunkCount: 2)
        let jobs = (0..<2).map { makeCompletedJob(manifest, $0) }
        let results = (0..<2).map { makeResult(manifest, $0) }
        XCTAssertTrue(SessionTranscriptionClassifier.isCompletionValid(manifest: manifest, jobs: jobs, results: results))
    }

    func testCompletionInvalidWhenResultSourceSnapshotDoesNotMatchManifest() {
        let manifest = makeManifest(chunkCount: 1)
        let jobs = [makeCompletedJob(manifest, 0)]
        var mismatchedSource = makeSource(manifest, 0)
        mismatchedSource.frameCount += 1
        let results = [makeResult(manifest, 0, source: mismatchedSource)]
        XCTAssertFalse(SessionTranscriptionClassifier.isCompletionValid(manifest: manifest, jobs: jobs, results: results))
    }

    func testCompletionInvalidWhenZeroChunks() {
        let manifest = makeManifest(chunkCount: 0)
        XCTAssertFalse(SessionTranscriptionClassifier.isCompletionValid(manifest: manifest, jobs: [], results: []))
    }

    func testCompletionInvalidWhenCompletedJobIsMissingItsResult() {
        let manifest = makeManifest(chunkCount: 1)
        let jobs = [makeCompletedJob(manifest, 0)]
        XCTAssertFalse(SessionTranscriptionClassifier.isCompletionValid(manifest: manifest, jobs: jobs, results: []))
    }

    func testCompletionInvalidWhenExtraRecognizedJobExistsOutsideExpectedCoverage() {
        let manifest = makeManifest(chunkCount: 2)
        var jobs = (0..<2).map { makeCompletedJob(manifest, $0) }
        var extraJob = makeCompletedJob(manifest, 0)
        extraJob.source.chunkSequenceNumber = 99
        extraJob.source.chunkFileName = TranscriptionArtifactPaths.canonicalChunkFileName(for: 99)
        jobs.append(extraJob)
        let results = (0..<2).map { makeResult(manifest, $0) }
        XCTAssertFalse(SessionTranscriptionClassifier.isCompletionValid(manifest: manifest, jobs: jobs, results: results))
    }

    func testCompletionInvalidWhenExtraRecognizedResultExistsOutsideExpectedCoverage() {
        let manifest = makeManifest(chunkCount: 2)
        let jobs = (0..<2).map { makeCompletedJob(manifest, $0) }
        var results = (0..<2).map { makeResult(manifest, $0) }
        var extraSource = makeSource(manifest, 0)
        extraSource.chunkSequenceNumber = 99
        extraSource.chunkFileName = TranscriptionArtifactPaths.canonicalChunkFileName(for: 99)
        results.append(makeResult(manifest, 0, source: extraSource))
        XCTAssertFalse(SessionTranscriptionClassifier.isCompletionValid(manifest: manifest, jobs: jobs, results: results))
    }

    func testCompletionValidWithExactExpectedCoverageAndNoExtras() {
        let manifest = makeManifest(chunkCount: 2)
        let jobs = (0..<2).map { makeCompletedJob(manifest, $0) }
        let results = (0..<2).map { makeResult(manifest, $0) }
        XCTAssertTrue(SessionTranscriptionClassifier.isCompletionValid(manifest: manifest, jobs: jobs, results: results))
    }

    func testHistoricalLastFailureDoesNotPreventCompletion() {
        let manifest = makeManifest(chunkCount: 1)
        var job = makeCompletedJob(manifest, 0)
        job.lastFailure = TranscriptionFailure(
            category: .engineThrew, message: "earlier attempt failed", retryDisposition: .retryable,
            failureDate: Date(), attemptNumber: 1
        )
        let results = [makeResult(manifest, 0)]
        XCTAssertTrue(SessionTranscriptionClassifier.isCompletionValid(manifest: manifest, jobs: [job], results: results))
    }

    // MARK: - classify()

    func testClassifyZeroChunkSession() {
        let manifest = makeManifest(chunkCount: 0)
        XCTAssertEqual(
            SessionTranscriptionClassifier.classify(manifest: manifest, jobs: [], results: [], inconsistencies: []),
            .zeroChunkSession
        )
    }

    func testClassifyNotTranscribedWhenNoJobsExist() {
        let manifest = makeManifest(chunkCount: 2)
        XCTAssertEqual(
            SessionTranscriptionClassifier.classify(manifest: manifest, jobs: [], results: [], inconsistencies: []),
            .notTranscribed
        )
    }

    func testClassifyIncompleteWhenPartiallyCompleted() {
        let manifest = makeManifest(chunkCount: 2)
        var queuedJob = makeCompletedJob(manifest, 1)
        queuedJob.state = .queued
        let jobs = [makeCompletedJob(manifest, 0), queuedJob]
        let results = [makeResult(manifest, 0)]
        XCTAssertEqual(
            SessionTranscriptionClassifier.classify(manifest: manifest, jobs: jobs, results: results, inconsistencies: []),
            .incomplete(completed: 1, total: 2)
        )
    }

    func testClassifyInterruptedForOwnerlessRunningJobAndSurfacesRetryableFailures() {
        let manifest = makeManifest(chunkCount: 2)
        var runningJob = makeCompletedJob(manifest, 0)
        runningJob.state = .running
        runningJob.currentAttemptID = UUID()

        var failedRetryable = makeCompletedJob(manifest, 1)
        failedRetryable.state = .failed
        failedRetryable.lastFailure = TranscriptionFailure(
            category: .sourceMissing, message: "x", retryDisposition: .retryable, failureDate: Date(), attemptNumber: 1
        )

        let status = SessionTranscriptionClassifier.classify(
            manifest: manifest, jobs: [runningJob, failedRetryable], results: [], inconsistencies: []
        )
        XCTAssertEqual(status, .interrupted(retryableSequenceNumbers: [1]))
    }

    func testClassifyRecoveryPendingWhenDurabilityUnconfirmed() {
        let manifest = makeManifest(chunkCount: 1)
        var runningJob = makeCompletedJob(manifest, 0)
        runningJob.state = .running
        runningJob.currentAttemptID = UUID()

        let status = SessionTranscriptionClassifier.classify(
            manifest: manifest,
            jobs: [runningJob],
            results: [makeResult(manifest, 0)],
            inconsistencies: [.resultDurabilityUnconfirmed(sequenceNumber: 0)]
        )
        XCTAssertEqual(status, .recoveryPending)
    }

    func testClassifyBlockedForGenuineIntegrityInconsistency() {
        let manifest = makeManifest(chunkCount: 1)
        let jobs = [makeCompletedJob(manifest, 0)]
        let status = SessionTranscriptionClassifier.classify(
            manifest: manifest,
            jobs: jobs,
            results: [],
            inconsistencies: [.completedJobMissingResult(sequenceNumber: 0)]
        )
        if case .blocked(let reasons) = status {
            XCTAssertEqual(reasons.count, 1)
        } else {
            XCTFail("expected .blocked, got \(status)")
        }
    }

    func testClassifyCompletedWhenCoverageIsComplete() {
        let manifest = makeManifest(chunkCount: 2)
        let jobs = (0..<2).map { makeCompletedJob(manifest, $0) }
        let results = (0..<2).map { makeResult(manifest, $0) }
        XCTAssertEqual(
            SessionTranscriptionClassifier.classify(manifest: manifest, jobs: jobs, results: results, inconsistencies: []),
            .completed
        )
    }
}
