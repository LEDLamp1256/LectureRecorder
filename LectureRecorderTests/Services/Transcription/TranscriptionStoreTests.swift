import XCTest
@testable import LectureRecorder

final class TranscriptionStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var paths: TranscriptionArtifactPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let sessionID = UUID()
        let sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        let transcriptionDirectory = sessionPaths.sessionDirectory.appendingPathComponent("transcription", isDirectory: true)
        paths = TranscriptionArtifactPaths(
            sessionID: sessionID,
            chunksDirectory: sessionPaths.chunksDirectory,
            transcriptionDirectory: transcriptionDirectory,
            jobsDirectory: transcriptionDirectory.appendingPathComponent("jobs", isDirectory: true),
            resultsDirectory: transcriptionDirectory.appendingPathComponent("results", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeSource(sequenceNumber: Int) -> TranscriptionSourceSnapshot {
        TranscriptionSourceSnapshot(
            sessionID: paths.sessionID,
            chunkSequenceNumber: sequenceNumber,
            chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber),
            frameCount: 1_000,
            startOffsetSeconds: Double(sequenceNumber) * 30,
            durationSeconds: 30,
            audioFormat: AudioFormatDescriptor(
                sampleRate: 44_100,
                channelCount: 1,
                bitsPerChannel: 32,
                formatIdentifier: "lpcm-float32"
            )
        )
    }

    private func makeJob(sequenceNumber: Int) -> TranscriptionJob {
        TranscriptionJob.newQueued(source: makeSource(sequenceNumber: sequenceNumber), now: Date())
    }

    /// The JSON date strategy shared with `AtomicFileWriter` only
    /// preserves millisecond precision, so a value round-tripped through
    /// disk necessarily differs from its pre-encoding in-memory original
    /// at the sub-millisecond level. Normalizing an expected value through
    /// the same encode/decode round trip before comparing it to something
    /// loaded off disk avoids spurious failures from that precision loss.
    private func normalized(_ job: TranscriptionJob) throws -> TranscriptionJob {
        try AtomicFileWriter.defaultDecoder.decode(
            TranscriptionJob.self,
            from: try AtomicFileWriter.defaultEncoder.encode(job)
        )
    }

    private func normalized(_ result: TranscriptResult) throws -> TranscriptResult {
        try AtomicFileWriter.defaultDecoder.decode(
            TranscriptResult.self,
            from: try AtomicFileWriter.defaultEncoder.encode(result)
        )
    }

    private func makeResult(sequenceNumber: Int, attemptID: UUID = UUID(), text: String = "hi") -> TranscriptResult {
        TranscriptResult(
            schemaVersion: TranscriptResult.currentSchemaVersion,
            source: makeSource(sequenceNumber: sequenceNumber),
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

    // MARK: - Job creation exclusivity

    func testCreateJobIfAbsentCreatesNewJob() async throws {
        let store = TranscriptionStore()
        let job = makeJob(sequenceNumber: 0)
        let outcome = try await store.createJobIfAbsent(job, paths: paths)
        guard case .created(let created) = outcome else {
            return XCTFail("Expected .created, got \(outcome)")
        }
        XCTAssertEqual(created, job)
    }

    func testDuplicateCreateJobIfAbsentIsIdempotentNoOp() async throws {
        let store = TranscriptionStore()
        let job = makeJob(sequenceNumber: 0)
        _ = try await store.createJobIfAbsent(job, paths: paths)

        var secondCandidate = job
        secondCandidate.createdDate = Date().addingTimeInterval(1_000)
        let outcome = try await store.createJobIfAbsent(secondCandidate, paths: paths)
        guard case .alreadyExistsValid(let existing) = outcome else {
            return XCTFail("Expected .alreadyExistsValid, got \(outcome)")
        }
        XCTAssertEqual(existing, try normalized(job))
    }

    func testCreateJobIfAbsentReportsInconsistentExistingMalformedJobWithoutTouchingIt() async throws {
        try FileManager.default.createDirectory(at: paths.jobsDirectory, withIntermediateDirectories: true)
        let url = paths.jobURL(sequenceNumber: 0)
        try Data("not json".utf8).write(to: url)

        let store = TranscriptionStore()
        let outcome = try await store.createJobIfAbsent(makeJob(sequenceNumber: 0), paths: paths)
        guard case .alreadyExistsInconsistent(let inconsistency) = outcome else {
            return XCTFail("Expected .alreadyExistsInconsistent, got \(outcome)")
        }
        guard case .corruptJob = inconsistency else {
            return XCTFail("Expected .corruptJob, got \(inconsistency)")
        }

        let stillThere = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(stillThere, "not json")
    }

    // MARK: - Job replacement

    func testReplaceJobUpdatesExistingRecord() async throws {
        let store = TranscriptionStore()
        var job = makeJob(sequenceNumber: 0)
        _ = try await store.createJobIfAbsent(job, paths: paths)

        job.state = .running
        job.currentAttemptID = UUID()
        job.attemptCount = 1
        try await store.replaceJob(job, paths: paths)

        let reloaded = try await store.loadJob(sequenceNumber: 0, paths: paths)
        XCTAssertEqual(reloaded, try normalized(job))
    }

    // MARK: - Result exclusivity

    func testCommitResultCommitsNewResult() async throws {
        let store = TranscriptionStore()
        let outcome = try await store.commitResult(makeResult(sequenceNumber: 0), paths: paths)
        XCTAssertEqual(outcome, .committed)
    }

    func testDuplicateIdenticalCommitIsIdempotent() async throws {
        let store = TranscriptionStore()
        let attemptID = UUID()
        let result = makeResult(sequenceNumber: 0, attemptID: attemptID)
        _ = try await store.commitResult(result, paths: paths)
        let second = try await store.commitResult(result, paths: paths)
        XCTAssertEqual(second, .alreadyCommittedIdentical)
    }

    func testDifferentResultForSameIdentityIsConflictAndOriginalIsPreserved() async throws {
        let store = TranscriptionStore()
        let first = makeResult(sequenceNumber: 0, text: "first")
        _ = try await store.commitResult(first, paths: paths)

        let second = makeResult(sequenceNumber: 0, text: "second")
        let outcome = try await store.commitResult(second, paths: paths)
        guard case .conflict(let existing) = outcome else {
            return XCTFail("Expected .conflict, got \(outcome)")
        }
        XCTAssertEqual(existing, try normalized(first))

        let reloaded = try await store.loadResult(sequenceNumber: 0, paths: paths)
        XCTAssertEqual(reloaded, try normalized(first))
    }

    func testCommitResultMapsDurabilityUncertainOutcome() async throws {
        let spy = SpyExclusiveArtifactFileSystem()
        let store = TranscriptionStore(exclusiveFileSystem: spy)
        let result = makeResult(sequenceNumber: 0)
        let url = paths.resultURL(sequenceNumber: 0)
        spy.forceResult(.success(.createdDurabilityUncertain), forURL: url)

        let outcome = try await store.commitResult(result, paths: paths)
        XCTAssertEqual(outcome, .committedDurabilityUncertain)
    }

    // MARK: - Schema version rejection

    func testLoadJobRejectsUnsupportedSchemaVersion() async throws {
        try FileManager.default.createDirectory(at: paths.jobsDirectory, withIntermediateDirectories: true)
        var job = makeJob(sequenceNumber: 0)
        job.schemaVersion = 999
        let data = try AtomicFileWriter.defaultEncoder.encode(job)
        try data.write(to: paths.jobURL(sequenceNumber: 0))

        let store = TranscriptionStore()
        do {
            _ = try await store.loadJob(sequenceNumber: 0, paths: paths)
            XCTFail("Expected an error")
        } catch let error as TranscriptionStoreError {
            guard case .unsupportedSchemaVersion(let seq, let version) = error else {
                return XCTFail("Expected .unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(seq, 0)
            XCTAssertEqual(version, 999)
        }
    }

    func testLoadResultRejectsUnsupportedSchemaVersion() async throws {
        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        var result = makeResult(sequenceNumber: 0)
        result.schemaVersion = 999
        let data = try AtomicFileWriter.defaultEncoder.encode(result)
        try data.write(to: paths.resultURL(sequenceNumber: 0))

        let store = TranscriptionStore()
        do {
            _ = try await store.loadResult(sequenceNumber: 0, paths: paths)
            XCTFail("Expected an error")
        } catch let error as TranscriptionStoreError {
            guard case .unsupportedSchemaVersion = error else {
                return XCTFail("Expected .unsupportedSchemaVersion, got \(error)")
            }
        }
    }

    // MARK: - Identity mismatch

    func testLoadJobRejectsIdentityMismatch() async throws {
        try FileManager.default.createDirectory(at: paths.jobsDirectory, withIntermediateDirectories: true)
        let job = makeJob(sequenceNumber: 7)
        let data = try AtomicFileWriter.defaultEncoder.encode(job)
        try data.write(to: paths.jobURL(sequenceNumber: 0))

        let store = TranscriptionStore()
        do {
            _ = try await store.loadJob(sequenceNumber: 0, paths: paths)
            XCTFail("Expected an error")
        } catch let error as TranscriptionStoreError {
            guard case .identityMismatch = error else {
                return XCTFail("Expected .identityMismatch, got \(error)")
            }
        }
    }

    // MARK: - Partial-tolerant enumeration

    func testLoadAllJobArtifactsIsPartialTolerant() async throws {
        let store = TranscriptionStore()
        _ = try await store.createJobIfAbsent(makeJob(sequenceNumber: 0), paths: paths)
        _ = try await store.createJobIfAbsent(makeJob(sequenceNumber: 2), paths: paths)

        try FileManager.default.createDirectory(at: paths.jobsDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: paths.jobURL(sequenceNumber: 1))

        let results = try await store.loadAllJobArtifacts(paths: paths)
        XCTAssertEqual(results.count, 3)

        var successCount = 0
        var failureCount = 0
        for result in results {
            switch result {
            case .success:
                successCount += 1
            case .failure(let seq, let inconsistency):
                failureCount += 1
                XCTAssertEqual(seq, 1)
                guard case .corruptJob = inconsistency else {
                    return XCTFail("Expected .corruptJob, got \(inconsistency)")
                }
            }
        }
        XCTAssertEqual(successCount, 2)
        XCTAssertEqual(failureCount, 1)
    }

    func testLoadAllJobArtifactsReturnsEmptyForNonexistentDirectory() async throws {
        let store = TranscriptionStore()
        let results = try await store.loadAllJobArtifacts(paths: paths)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - commitResult integrity-error cases for an existing result file

    func testCommitResultReportsIntegrityErrorForCorruptExistingResultWithoutTouchingIt() async throws {
        let store = TranscriptionStore()
        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        let url = paths.resultURL(sequenceNumber: 0)
        try Data("not json".utf8).write(to: url)

        let outcome = try await store.commitResult(makeResult(sequenceNumber: 0), paths: paths)
        guard case .integrityError = outcome else {
            return XCTFail("Expected .integrityError, got \(outcome)")
        }

        let stillThere = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(stillThere, "not json")
    }

    func testCommitResultReportsIntegrityErrorForIdentityMismatchedExistingResultWithoutTouchingIt() async throws {
        let store = TranscriptionStore()
        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        let url = paths.resultURL(sequenceNumber: 0)
        // A validly-encoded result, but for a different sequence number --
        // its decoded identity does not match the path it's found at.
        let mismatched = makeResult(sequenceNumber: 7)
        try AtomicFileWriter.defaultEncoder.encode(mismatched).write(to: url)

        let outcome = try await store.commitResult(makeResult(sequenceNumber: 0), paths: paths)
        guard case .integrityError = outcome else {
            return XCTFail("Expected .integrityError, got \(outcome)")
        }

        let reloadedRaw = try Data(contentsOf: url)
        let reloadedMismatched = try AtomicFileWriter.defaultDecoder.decode(TranscriptResult.self, from: reloadedRaw)
        XCTAssertEqual(reloadedMismatched.source.chunkSequenceNumber, 7)
    }

    // MARK: - Partial-tolerant bulk enumeration: remaining inconsistency categories

    func testLoadAllJobArtifactsReportsUnsupportedSchemaWhileContinuingWithValidJobs() async throws {
        let store = TranscriptionStore()
        _ = try await store.createJobIfAbsent(makeJob(sequenceNumber: 0), paths: paths)

        try FileManager.default.createDirectory(at: paths.jobsDirectory, withIntermediateDirectories: true)
        var futureJob = makeJob(sequenceNumber: 1)
        futureJob.schemaVersion = 999
        try AtomicFileWriter.defaultEncoder.encode(futureJob).write(to: paths.jobURL(sequenceNumber: 1))

        _ = try await store.createJobIfAbsent(makeJob(sequenceNumber: 2), paths: paths)

        let results = try await store.loadAllJobArtifacts(paths: paths)
        XCTAssertEqual(results.count, 3)

        var successCount = 0
        for result in results {
            switch result {
            case .success:
                successCount += 1
            case .failure(let seq, let inconsistency):
                XCTAssertEqual(seq, 1)
                guard case .unsupportedJobSchema(_, let version) = inconsistency else {
                    return XCTFail("Expected .unsupportedJobSchema, got \(inconsistency)")
                }
                XCTAssertEqual(version, 999)
            }
        }
        XCTAssertEqual(successCount, 2)
    }

    func testLoadAllResultArtifactsReportsUnsupportedSchemaWhileContinuing() async throws {
        let store = TranscriptionStore()
        _ = try await store.commitResult(makeResult(sequenceNumber: 0), paths: paths)

        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        var futureResult = makeResult(sequenceNumber: 1)
        futureResult.schemaVersion = 999
        try AtomicFileWriter.defaultEncoder.encode(futureResult).write(to: paths.resultURL(sequenceNumber: 1))

        _ = try await store.commitResult(makeResult(sequenceNumber: 2), paths: paths)

        let results = try await store.loadAllResultArtifacts(paths: paths)
        XCTAssertEqual(results.count, 3)

        var successCount = 0
        for result in results {
            switch result {
            case .success:
                successCount += 1
            case .failure(let seq, let inconsistency):
                XCTAssertEqual(seq, 1)
                guard case .unsupportedResultSchema(_, let version) = inconsistency else {
                    return XCTFail("Expected .unsupportedResultSchema, got \(inconsistency)")
                }
                XCTAssertEqual(version, 999)
            }
        }
        XCTAssertEqual(successCount, 2)
    }

    func testLoadAllResultArtifactsIsPartialTolerantAcrossCorruptAndValidResults() async throws {
        let store = TranscriptionStore()
        _ = try await store.commitResult(makeResult(sequenceNumber: 0), paths: paths)

        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: paths.resultURL(sequenceNumber: 1))

        _ = try await store.commitResult(makeResult(sequenceNumber: 2), paths: paths)

        let results = try await store.loadAllResultArtifacts(paths: paths)
        XCTAssertEqual(results.count, 3)

        var successCount = 0
        var failureCount = 0
        for result in results {
            switch result {
            case .success:
                successCount += 1
            case .failure(let seq, let inconsistency):
                failureCount += 1
                XCTAssertEqual(seq, 1)
                guard case .corruptResult = inconsistency else {
                    return XCTFail("Expected .corruptResult, got \(inconsistency)")
                }
            }
        }
        XCTAssertEqual(successCount, 2)
        XCTAssertEqual(failureCount, 1)
    }

    func testLoadAllResultArtifactsReportsIdentityMismatchWhileContinuing() async throws {
        let store = TranscriptionStore()
        _ = try await store.commitResult(makeResult(sequenceNumber: 0), paths: paths)

        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        // A validly-encoded result for sequence 9, placed at sequence 1's path.
        let mismatched = makeResult(sequenceNumber: 9)
        try AtomicFileWriter.defaultEncoder.encode(mismatched).write(to: paths.resultURL(sequenceNumber: 1))

        _ = try await store.commitResult(makeResult(sequenceNumber: 2), paths: paths)

        let results = try await store.loadAllResultArtifacts(paths: paths)
        XCTAssertEqual(results.count, 3)

        var successCount = 0
        for result in results {
            switch result {
            case .success:
                successCount += 1
            case .failure(let seq, let inconsistency):
                XCTAssertEqual(seq, 1)
                guard case .jobResultIdentityMismatch = inconsistency else {
                    return XCTFail("Expected .jobResultIdentityMismatch, got \(inconsistency)")
                }
            }
        }
        XCTAssertEqual(successCount, 2)
    }
}
