import XCTest
@testable import LectureRecorder

final class SessionActionAvailabilityTests: XCTestCase {
    private let sessionID = UUID()
    private let otherSessionID = UUID()

    // MARK: - Ownership display

    func testOwnershipDisplayNoneWhenNoOperationActive() {
        XCTAssertEqual(SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: nil, sessionID: sessionID), .none)
    }

    func testOwnershipDisplayActiveHereWhenThisSessionOwnsOperation() {
        XCTAssertEqual(SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: sessionID, sessionID: sessionID), .activeHere)
    }

    func testOwnershipDisplayBusyElsewhereWhenAnotherSessionOwnsOperation() {
        XCTAssertEqual(SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: otherSessionID, sessionID: sessionID), .busyElsewhere)
    }

    // MARK: - Correction 2: another window observing global Busy

    func testBusyElsewhereDisablesAllActionsRegardlessOfPeekedStatus() {
        for status: SessionTranscriptionStatus? in [nil, .notTranscribed, .incomplete(completed: 1, total: 2), .interrupted(retryableSequenceNumbers: [0]), .recoveryPending, .completed, .blocked(reasons: ["x"])] {
            let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: status, ownership: .busyElsewhere)
            XCTAssertFalse(availability.canTranscribe, "status \(String(describing: status))")
            XCTAssertFalse(availability.canContinueOrRetry, "status \(String(describing: status))")
            XCTAssertFalse(availability.canCancel, "status \(String(describing: status))")
        }
    }

    func testActiveHereAllowsOnlyCancel() {
        let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: nil, ownership: .activeHere)
        XCTAssertFalse(availability.canTranscribe)
        XCTAssertFalse(availability.canContinueOrRetry)
        XCTAssertTrue(availability.canCancel)
    }

    // MARK: - Correction 1: eligibility returns after ownership is released

    func testNotTranscribedAllowsTranscribeOnlyWhenNoOperationOwnsIt() {
        let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: .notTranscribed, ownership: .none)
        XCTAssertTrue(availability.canTranscribe)
        XCTAssertFalse(availability.canContinueOrRetry)
        XCTAssertFalse(availability.canCancel)
    }

    func testIncompleteInterruptedRecoveryPendingAllowContinueOrRetryOnlyWhenNoOperationOwnsIt() {
        for status: SessionTranscriptionStatus in [.incomplete(completed: 1, total: 2), .interrupted(retryableSequenceNumbers: [0]), .recoveryPending] {
            let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: status, ownership: .none)
            XCTAssertTrue(availability.canContinueOrRetry, "status \(status)")
            XCTAssertFalse(availability.canTranscribe, "status \(status)")
            XCTAssertFalse(availability.canCancel, "status \(status)")
        }
    }

    func testCompletedAndBlockedAllowNoActions() {
        for status: SessionTranscriptionStatus in [.completed, .blocked(reasons: ["x"]), .zeroChunkSession] {
            let availability = SessionActionAvailabilityCalculator.availability(peekedStatus: status, ownership: .none)
            XCTAssertFalse(availability.canTranscribe, "status \(status)")
            XCTAssertFalse(availability.canContinueOrRetry, "status \(status)")
            XCTAssertFalse(availability.canCancel, "status \(status)")
        }
    }

    // MARK: - Correction 4: human-facing processing ordinal

    func testProcessingLabelConvertsZeroBasedSequenceToOneBasedOrdinal() {
        let label = SessionProgressFormatting.processingLabel(completed: 18, total: 42, currentlyProcessingSequence: 18)
        XCTAssertEqual(label, "18 / 42 saved — processing 19")
    }

    func testProcessingLabelForFirstChunk() {
        let label = SessionProgressFormatting.processingLabel(completed: 0, total: 1, currentlyProcessingSequence: 0)
        XCTAssertEqual(label, "0 / 1 saved — processing 1")
    }

    // MARK: - Ownership-transition refresh predicate

    func testRefreshesWhenThisSessionLosesOwnershipToNoOwner() {
        XCTAssertTrue(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: sessionID, newActiveSessionID: nil, sessionID: sessionID))
    }

    func testRefreshesWhenThisSessionLosesOwnershipToAnotherSession() {
        XCTAssertTrue(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: sessionID, newActiveSessionID: otherSessionID, sessionID: sessionID))
    }

    func testDoesNotRefreshWhenAnotherSessionLosesOwnership() {
        XCTAssertFalse(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: otherSessionID, newActiveSessionID: nil, sessionID: sessionID))
    }

    func testDoesNotRefreshWhenThisSessionNewlyGainsOwnership() {
        XCTAssertFalse(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: nil, newActiveSessionID: sessionID, sessionID: sessionID))
    }

    func testDoesNotRefreshWhenOwnershipIsUnchanged() {
        XCTAssertFalse(SessionOwnershipTransition.shouldRefreshDurableState(oldActiveSessionID: sessionID, newActiveSessionID: sessionID, sessionID: sessionID))
    }
}

// MARK: - T7-C1: admission refusals, failed parts, Continue no-op, blocked wording

extension SessionActionAvailabilityTests {
    private static let rawDiagnostic = "decoder said: /Users/someone/Library/Containers/x/chunk_000001.caf EOF"

    private func makeManifest(chunkCount: Int) -> SessionManifest {
        var manifest = SessionManifest.newSession(
            id: sessionID,
            audioFormat: AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32"),
            targetChunkDurationSeconds: 30
        )
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

    private func job(_ manifest: SessionManifest, _ seq: Int, _ state: TranscriptionJobState, _ disposition: RetryDisposition? = nil, category: TranscriptionFailureCategory = .engineThrew) -> TranscriptionJob {
        let chunk = manifest.chunks[seq]
        var job = TranscriptionJob.newQueued(
            source: TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID, chunkSequenceNumber: seq, chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
            ),
            now: Date()
        )
        job.state = state
        if let disposition {
            job.lastFailure = TranscriptionFailure(category: category, message: Self.rawDiagnostic, retryDisposition: disposition, failureDate: Date(), attemptNumber: 1)
        }
        return job
    }

    // Admission

    func testEveryAdmissionRefusalMapsToItsSafeMessage() {
        XCTAssertEqual(TranscriptionAdmissionMessage.message(for: .recordingActive), "Transcription can't start while a recording is in progress.")
        XCTAssertEqual(TranscriptionAdmissionMessage.message(for: .busy), "Another transcription is already running. Try again once it finishes.")
        XCTAssertEqual(TranscriptionAdmissionMessage.message(for: .shuttingDown), "Transcription can't start while the app is quitting.")
    }

    func testAdmittedClearsAnyPreviousRefusalMessage() {
        XCTAssertNil(TranscriptionAdmissionMessage.message(for: .admitted))
    }

    // Failure overview (pure)

    func testOverviewMasksDispositionOfFailedJobWithResultSoNeitherRetryPathSeesIt() {
        let manifest = makeManifest(chunkCount: 2)
        let failed = job(manifest, 0, .failed, .permanent)
        let result = TranscriptResult(
            schemaVersion: TranscriptResult.legacySchemaVersion, source: failed.source,
            output: FakeTranscriber.defaultFakeOutput, attemptID: UUID(), completedDate: Date()
        )
        let overview = TranscriptionFailureOverview.make(manifest: manifest, jobs: [failed, job(manifest, 1, .completed)], results: [result])
        XCTAssertEqual(overview.failedParts, [TranscriptionFailedPart(sequenceNumber: 0, category: .engineThrew, retryDisposition: nil)])
        XCTAssertFalse(overview.hasManualRetryEligibleParts)
        XCTAssertFalse(overview.hasAutomaticWork)
    }

    func testOverviewCountsQueuedRunningRetryableAndMissingJobsAsAutomaticWork() {
        let manifest = makeManifest(chunkCount: 2)
        for other in [job(manifest, 1, .queued), job(manifest, 1, .running), job(manifest, 1, .failed, .retryable)] {
            let overview = TranscriptionFailureOverview.make(manifest: manifest, jobs: [job(manifest, 0, .failed, .permanent), other], results: [])
            XCTAssertTrue(overview.hasAutomaticWork, "\(other.state) must count as automatic work")
        }
        let missing = TranscriptionFailureOverview.make(manifest: manifest, jobs: [job(manifest, 0, .failed, .permanent)], results: [])
        XCTAssertTrue(missing.hasAutomaticWork, "a chunk with no job yet is automatic (enqueue) work")
    }

    // Continue no-op

    func testContinueDisabledWhenAllRemainingFailuresArePermanent() {
        let overview = TranscriptionFailureOverview(
            failedParts: [TranscriptionFailedPart(sequenceNumber: 1, category: .unknown, retryDisposition: .permanent)],
            hasAutomaticWork: false
        )
        let availability = SessionActionAvailabilityCalculator.availability(
            peekedStatus: .incomplete(completed: 1, total: 2), failureOverview: overview, ownership: .none
        )
        XCTAssertEqual(availability, SessionActionAvailability(canTranscribe: false, canContinueOrRetry: false, canCancel: false, canRetryFailedParts: true))
        XCTAssertEqual(
            SessionActionAvailabilityCalculator.continueUnavailableExplanation(
                peekedStatus: .incomplete(completed: 1, total: 2), failureOverview: overview, ownership: .none
            ),
            TranscriptionStatusMessage.nothingToContinue + " " + TranscriptionStatusMessage.manualRetryHint
        )
    }

    func testContinueExplanationOmitsManualHintWhenNoPartIsManuallyRetryable() {
        // A failed job whose disposition was masked (result present) is
        // eligible for neither path.
        let overview = TranscriptionFailureOverview(
            failedParts: [TranscriptionFailedPart(sequenceNumber: 0, category: .engineThrew, retryDisposition: nil)],
            hasAutomaticWork: false
        )
        let status = SessionTranscriptionStatus.incomplete(completed: 0, total: 1)
        XCTAssertEqual(
            SessionActionAvailabilityCalculator.continueUnavailableExplanation(peekedStatus: status, failureOverview: overview, ownership: .none),
            TranscriptionStatusMessage.nothingToContinue
        )
        XCTAssertFalse(SessionActionAvailabilityCalculator.availability(peekedStatus: status, failureOverview: overview, ownership: .none).canRetryFailedParts)
    }

    // T7-C2: explicit permanent-failure retry availability

    func testManualRetryAvailabilityIsSeparateFromContinue() {
        let mixed = TranscriptionFailureOverview(
            failedParts: [
                TranscriptionFailedPart(sequenceNumber: 0, category: .unknown, retryDisposition: .permanent),
                TranscriptionFailedPart(sequenceNumber: 1, category: .engineThrew, retryDisposition: .retryable),
            ],
            hasAutomaticWork: true
        )
        XCTAssertEqual(
            SessionActionAvailabilityCalculator.availability(peekedStatus: .incomplete(completed: 0, total: 2), failureOverview: mixed, ownership: .none),
            SessionActionAvailability(canTranscribe: false, canContinueOrRetry: true, canCancel: false, canRetryFailedParts: true)
        )

        let retryableOnly = TranscriptionFailureOverview(
            failedParts: [TranscriptionFailedPart(sequenceNumber: 1, category: .engineThrew, retryDisposition: .retryable)],
            hasAutomaticWork: true
        )
        XCTAssertEqual(
            SessionActionAvailabilityCalculator.availability(peekedStatus: .incomplete(completed: 1, total: 2), failureOverview: retryableOnly, ownership: .none),
            SessionActionAvailability(canTranscribe: false, canContinueOrRetry: true, canCancel: false, canRetryFailedParts: false)
        )
    }

    func testManualRetryNeverOfferedWhileAnyOperationOwnsTheServiceOrForOtherStatuses() {
        let overview = TranscriptionFailureOverview(
            failedParts: [TranscriptionFailedPart(sequenceNumber: 0, category: .unknown, retryDisposition: .permanent)],
            hasAutomaticWork: false
        )
        for ownership: SessionOwnershipDisplay in [.activeHere, .busyElsewhere] {
            XCTAssertFalse(SessionActionAvailabilityCalculator.availability(
                peekedStatus: .incomplete(completed: 0, total: 1), failureOverview: overview, ownership: ownership
            ).canRetryFailedParts)
        }
        for status: SessionTranscriptionStatus in [.notTranscribed, .zeroChunkSession, .completed, .blocked(reasons: ["x"])] {
            XCTAssertFalse(SessionActionAvailabilityCalculator.availability(
                peekedStatus: status, failureOverview: overview, ownership: .none
            ).canRetryFailedParts)
        }
        XCTAssertFalse(SessionActionAvailabilityCalculator.availability(
            peekedStatus: .incomplete(completed: 0, total: 1), failureOverview: nil, ownership: .none
        ).canRetryFailedParts)
    }

    func testContinueEnabledWhenAnyAutomaticWorkRemains() {
        let overview = TranscriptionFailureOverview(
            failedParts: [
                TranscriptionFailedPart(sequenceNumber: 0, category: .unknown, retryDisposition: .permanent),
                TranscriptionFailedPart(sequenceNumber: 1, category: .engineThrew, retryDisposition: .retryable),
            ],
            hasAutomaticWork: true
        )
        for status: SessionTranscriptionStatus in [.incomplete(completed: 0, total: 2), .interrupted(retryableSequenceNumbers: [1]), .recoveryPending] {
            XCTAssertTrue(
                SessionActionAvailabilityCalculator.availability(peekedStatus: status, failureOverview: overview, ownership: .none).canContinueOrRetry
            )
            XCTAssertNil(SessionActionAvailabilityCalculator.continueUnavailableExplanation(peekedStatus: status, failureOverview: overview, ownership: .none))
        }
    }

    func testMissingOverviewLeavesStatusOnlyContinueDecisionUnchanged() {
        XCTAssertTrue(
            SessionActionAvailabilityCalculator.availability(peekedStatus: .incomplete(completed: 0, total: 2), failureOverview: nil, ownership: .none).canContinueOrRetry
        )
    }

    func testNoContinueExplanationWhileAnyOperationOwnsTheService() {
        let overview = TranscriptionFailureOverview(failedParts: [], hasAutomaticWork: false)
        for ownership: SessionOwnershipDisplay in [.activeHere, .busyElsewhere] {
            XCTAssertNil(SessionActionAvailabilityCalculator.continueUnavailableExplanation(
                peekedStatus: .incomplete(completed: 0, total: 1), failureOverview: overview, ownership: ownership
            ))
        }
    }

    // Failed-part wording

    func testFailedPartMessagesAreOneBasedAndCategorySpecific() {
        XCTAssertEqual(TranscriptionFailedPartMessage.message(sequenceNumber: 0, category: .sourceMissing, retryDisposition: .retryable), "Part 1: audio file is missing.")
        XCTAssertEqual(TranscriptionFailedPartMessage.message(sequenceNumber: 4, category: .engineThrew, retryDisposition: .retryable), "Part 5: transcription engine failed — Continue may succeed.")
        XCTAssertEqual(TranscriptionFailedPartMessage.message(sequenceNumber: 2, category: .unknown, retryDisposition: .permanent), "Part 3: couldn't be transcribed.")
        XCTAssertEqual(TranscriptionFailedPartMessage.message(sequenceNumber: 2, category: .engineThrew, retryDisposition: .permanent), "Part 3: couldn't be transcribed.")
        XCTAssertEqual(TranscriptionFailedPartMessage.message(sequenceNumber: 1, category: .cancellation, retryDisposition: .retryable), "Part 2: interrupted.")
        XCTAssertEqual(TranscriptionFailedPartMessage.message(sequenceNumber: 1, category: .abandonedRunningAttempt, retryDisposition: .retryable), "Part 2: interrupted.")
        XCTAssertEqual(TranscriptionFailedPartMessage.message(sequenceNumber: 1, category: nil, retryDisposition: nil), "Part 2: couldn't be transcribed.")
    }

    func testNoRawFailureMessageEverReachesFailedPartWording() {
        let manifest = makeManifest(chunkCount: 8)
        let categories: [TranscriptionFailureCategory] = [.engineThrew, .cancellation, .abandonedRunningAttempt, .sourceMissing, .resultCommitConflict, .resultCommitIntegrityError, .unknown]
        var jobs: [TranscriptionJob] = []
        for (index, category) in categories.enumerated() {
            jobs.append(job(manifest, index, .failed, index.isMultiple(of: 2) ? .permanent : .retryable, category: category))
        }
        let overview = TranscriptionFailureOverview.make(manifest: manifest, jobs: jobs, results: [])
        let lines = TranscriptionFailedPartMessage.lines(for: overview)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertFalse(line.contains("decoder"), line)
            XCTAssertFalse(line.contains("/Users/"), line)
            XCTAssertFalse(line.contains(".caf"), line)
        }
        for job in jobs {
            let failure = job.lastFailure!
            let line = TranscriptionFailedPartMessage.message(sequenceNumber: job.source.chunkSequenceNumber, category: failure.category, retryDisposition: failure.retryDisposition)
            XCTAssertFalse(line.contains(failure.message))
        }
    }

    func testFailedPartLinesAreCappedWithASummaryLine() {
        let parts = (0..<8).map { TranscriptionFailedPart(sequenceNumber: $0, category: .unknown, retryDisposition: .permanent) }
        let lines = TranscriptionFailedPartMessage.lines(for: TranscriptionFailureOverview(failedParts: parts, hasAutomaticWork: false))
        XCTAssertEqual(lines.count, TranscriptionFailedPartMessage.displayLimit + 1)
        XCTAssertEqual(lines.last, "…and 3 more failed parts.")
    }

    // Blocked

    func testBlockedStatusUsesFixedPreservedDataMessageNotRawReasons() {
        XCTAssertEqual(TranscriptionStatusMessage.blocked, "Saved transcription data needs attention. Existing files have been preserved.")
        let raw = SessionTranscriptionStatus.blocked(reasons: ["Chunk #3: corrupt job artifact (The data couldn’t be read)"])
        guard case .blocked(let reasons) = raw else { return XCTFail() }
        for reason in reasons {
            XCTAssertFalse(TranscriptionStatusMessage.blocked.contains(reason))
        }
        XCTAssertFalse(TranscriptionStatusMessage.blocked.contains("Chunk"))
        XCTAssertEqual(
            SessionActionAvailabilityCalculator.availability(peekedStatus: raw, failureOverview: nil, ownership: .none),
            SessionActionAvailability(canTranscribe: false, canContinueOrRetry: false, canCancel: false)
        )
    }
}
