import XCTest
@testable import LectureRecorder

/// A `NotesTranscriptSourceLoading` double whose calls either return a
/// scripted result immediately or, for a held session, suspend until the
/// test resumes that specific call — so request completion order is chosen
/// by the test, never by timing.
private actor ControllableSourceLoader: NotesTranscriptSourceLoading {
    private var immediateResults: [UUID: Result<NotesTranscriptSourceSnapshot, Error>] = [:]
    private var heldSessionIDs: Set<UUID> = []
    private var heldCalls: [CheckedContinuation<Result<NotesTranscriptSourceSnapshot, Error>, Never>?] = []

    func setResult(_ result: Result<NotesTranscriptSourceSnapshot, Error>, for sessionID: UUID) {
        immediateResults[sessionID] = result
    }

    func hold(_ sessionID: UUID) {
        heldSessionIDs.insert(sessionID)
    }

    var heldCallCount: Int { heldCalls.count }

    /// Resumes the `index`th held call (in arrival order) with `result`.
    func resumeHeldCall(_ index: Int, with result: Result<NotesTranscriptSourceSnapshot, Error>) {
        heldCalls[index]?.resume(returning: result)
        heldCalls[index] = nil
    }

    func loadCurrentSnapshot(sessionID: UUID) async throws -> NotesTranscriptSourceSnapshot {
        if heldSessionIDs.contains(sessionID) {
            let result = await withCheckedContinuation { continuation in
                heldCalls.append(continuation)
            }
            return try result.get()
        }
        guard let result = immediateResults[sessionID] else {
            throw NotesTranscriptSourceLoadError.sourceBuildFailed("no scripted result for session \(sessionID)")
        }
        return try result.get()
    }
}

@MainActor
final class SessionTranscriptRevealPresenterTests: XCTestCase {
    // MARK: - Fixtures

    private func makeEntry(sessionID: UUID = UUID()) -> CompletedSessionEntry {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionTranscriptRevealPresenterTests-\(UUID().uuidString)")
        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)
        var manifest = SessionManifest.newSession(
            id: sessionID,
            audioFormat: AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32"),
            targetChunkDurationSeconds: 30
        )
        manifest.status = .completed
        return CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)
    }

    private func makeSnapshot(sessionID: UUID, unitCount: Int = 3, textPrefix: String = "unit") -> NotesTranscriptSourceSnapshot {
        let units = (0..<unitCount).map { sequenceNumber in
            NotesTranscriptSourceUnit(
                sequenceNumber: sequenceNumber,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber),
                text: "\(textPrefix) \(sequenceNumber)",
                startOffsetSeconds: Double(sequenceNumber) * 30,
                durationSeconds: 30
            )
        }
        return NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        )
    }

    private func target(_ snapshot: NotesTranscriptSourceSnapshot, _ range: ClosedRange<Int>) -> TranscriptRevealTarget {
        TranscriptRevealTarget(
            sessionID: snapshot.sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            firstSequenceNumber: range.lowerBound,
            lastSequenceNumber: range.upperBound
        )
    }

    private func reference(_ sessionID: UUID, _ range: ClosedRange<Int>) -> NotesSourceReference {
        NotesSourceReference(sessionID: sessionID, firstSequenceNumber: range.lowerBound, lastSequenceNumber: range.upperBound)
    }

    private func waitForHeldCalls(_ count: Int, in loader: ControllableSourceLoader, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, await loader.heldCallCount < count {
            await Task.yield()
        }
        let heldCallCount = await loader.heldCallCount
        XCTAssertEqual(heldCallCount, count, "held loader calls", file: file, line: line)
    }

    // MARK: - Resolution

    func testInitialStateIsIdle() {
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: ControllableSourceLoader())
        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.sessionID)
        XCTAssertNil(presenter.pendingTarget)
    }

    func testMatchingFreshSnapshotPublishesExactWholeChunkTarget() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.setResult(.success(snapshot), for: snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...2), generatedFrom: snapshot.fingerprint, for: entry)

        XCTAssertEqual(presenter.sessionID, entry.manifest.sessionID)
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 1...2)))
        XCTAssertEqual(presenter.pendingTarget, target(snapshot, 1...2))
    }

    func testStaleDocumentFingerprintPublishesTranscriptMismatchAndNoTarget() async {
        let entry = makeEntry()
        let sessionID = entry.manifest.sessionID
        let generatedFrom = makeSnapshot(sessionID: sessionID, textPrefix: "original")
        let current = makeSnapshot(sessionID: sessionID, textPrefix: "retranscribed")
        XCTAssertNotEqual(generatedFrom.fingerprint, current.fingerprint)
        let loader = ControllableSourceLoader()
        await loader.setResult(.success(current), for: sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        await presenter.requestReveal(reference: reference(sessionID, 0...0), generatedFrom: generatedFrom.fingerprint, for: entry)

        XCTAssertEqual(presenter.state, .failed(.unresolvable(.transcriptMismatch)))
        XCTAssertNil(presenter.pendingTarget)
    }

    func testOutOfRangeReferencePublishesResolverRejectionAndNoTarget() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.setResult(.success(snapshot), for: snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        await presenter.requestReveal(reference: reference(snapshot.sessionID, 2...5), generatedFrom: snapshot.fingerprint, for: entry)

        XCTAssertEqual(presenter.state, .failed(.unresolvable(.outOfRange(availableRange: 0...2))))
        XCTAssertNil(presenter.pendingTarget)
    }

    func testReferenceFromAnotherSessionPublishesSessionMismatch() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.setResult(.success(snapshot), for: snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        await presenter.requestReveal(reference: reference(UUID(), 0...0), generatedFrom: snapshot.fingerprint, for: entry)

        XCTAssertEqual(presenter.state, .failed(.unresolvable(.sessionMismatch)))
        XCTAssertNil(presenter.pendingTarget)
    }

    func testSnapshotLoadFailurePublishesSourceUnavailableAndNoTarget() async {
        let entry = makeEntry()
        let loadError = NotesTranscriptSourceLoadError.ineligible("transcription incomplete")
        let loader = ControllableSourceLoader()
        await loader.setResult(.failure(loadError), for: entry.manifest.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)
        let documentFingerprint = makeSnapshot(sessionID: entry.manifest.sessionID).fingerprint

        await presenter.requestReveal(reference: reference(entry.manifest.sessionID, 0...0), generatedFrom: documentFingerprint, for: entry)

        XCTAssertEqual(presenter.sessionID, entry.manifest.sessionID)
        XCTAssertEqual(presenter.state, .failed(.sourceUnavailable(reason: loadError.localizedDescription)))
        XCTAssertNil(presenter.pendingTarget)
    }

    func testSnapshotForADifferentSessionIsRejectedWithoutResolving() async {
        let entry = makeEntry()
        let foreign = makeSnapshot(sessionID: UUID())
        let loader = ControllableSourceLoader()
        await loader.setResult(.success(foreign), for: entry.manifest.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        // Even a reference and fingerprint that match the foreign snapshot
        // must not resolve into this entry's workspace.
        await presenter.requestReveal(reference: reference(foreign.sessionID, 0...0), generatedFrom: foreign.fingerprint, for: entry)

        guard case .failed(.sourceUnavailable) = presenter.state else {
            return XCTFail("expected sourceUnavailable, got \(presenter.state)")
        }
        XCTAssertNil(presenter.pendingTarget)
    }

    // MARK: - Superseding

    func testNewRequestDropsOldTargetImmediatelyAndPublishesItsOwn() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.setResult(.success(snapshot), for: snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)
        await presenter.requestReveal(reference: reference(snapshot.sessionID, 0...0), generatedFrom: snapshot.fingerprint, for: entry)
        XCTAssertEqual(presenter.pendingTarget, target(snapshot, 0...0))

        await loader.hold(snapshot.sessionID)
        let second = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 2...2), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(1, in: loader)
        XCTAssertEqual(presenter.state, .resolving)
        XCTAssertNil(presenter.pendingTarget)

        await loader.resumeHeldCall(0, with: .success(snapshot))
        await second.value
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 2...2)))
    }

    func testFailedNewestRequestClearsPreviousSuccessfulTarget() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.setResult(.success(snapshot), for: snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)
        await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...1), generatedFrom: snapshot.fingerprint, for: entry)
        XCTAssertEqual(presenter.pendingTarget, target(snapshot, 1...1))

        await presenter.requestReveal(reference: reference(snapshot.sessionID, 9...9), generatedFrom: snapshot.fingerprint, for: entry)

        XCTAssertEqual(presenter.state, .failed(.unresolvable(.outOfRange(availableRange: 0...2))))
        XCTAssertNil(presenter.pendingTarget)
    }

    func testOutOfOrderCompletionPublishesOnlyTheNewestRequest() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.hold(snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        let requestA = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 0...0), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(1, in: loader)
        let requestB = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...2), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(2, in: loader)

        await loader.resumeHeldCall(1, with: .success(snapshot))
        await requestB.value
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 1...2)))

        await loader.resumeHeldCall(0, with: .success(snapshot))
        await requestA.value
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 1...2)))
    }

    func testLateFailureFromSupersededRequestCannotReplaceNewerTarget() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.hold(snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        let requestA = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 0...0), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(1, in: loader)
        let requestB = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 2...2), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(2, in: loader)

        await loader.resumeHeldCall(1, with: .success(snapshot))
        await requestB.value
        await loader.resumeHeldCall(0, with: .failure(NotesTranscriptSourceLoadError.unsafeManifest))
        await requestA.value

        XCTAssertEqual(presenter.state, .ready(target(snapshot, 2...2)))
    }

    func testLateResultForPreviousSessionCannotPublishIntoNewSession() async {
        let entryA = makeEntry()
        let entryB = makeEntry()
        let snapshotA = makeSnapshot(sessionID: entryA.manifest.sessionID)
        let snapshotB = makeSnapshot(sessionID: entryB.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.hold(snapshotA.sessionID)
        await loader.setResult(.success(snapshotB), for: snapshotB.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        let requestA = Task { await presenter.requestReveal(reference: reference(snapshotA.sessionID, 0...0), generatedFrom: snapshotA.fingerprint, for: entryA) }
        await waitForHeldCalls(1, in: loader)
        await presenter.requestReveal(reference: reference(snapshotB.sessionID, 1...1), generatedFrom: snapshotB.fingerprint, for: entryB)
        XCTAssertEqual(presenter.sessionID, entryB.manifest.sessionID)
        XCTAssertEqual(presenter.state, .ready(target(snapshotB, 1...1)))

        await loader.resumeHeldCall(0, with: .success(snapshotA))
        await requestA.value

        XCTAssertEqual(presenter.sessionID, entryB.manifest.sessionID)
        XCTAssertEqual(presenter.state, .ready(target(snapshotB, 1...1)))
    }

    func testInvalidateMakesInFlightRequestStaleAndReturnsToIdle() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.hold(snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        let request = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 0...0), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(1, in: loader)
        presenter.invalidate()
        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.sessionID)

        await loader.resumeHeldCall(0, with: .success(snapshot))
        await request.value

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.sessionID)
        XCTAssertNil(presenter.pendingTarget)
    }

    func testInvalidateClearsPublishedTarget() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.setResult(.success(snapshot), for: snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)
        await presenter.requestReveal(reference: reference(snapshot.sessionID, 0...1), generatedFrom: snapshot.fingerprint, for: entry)
        XCTAssertNotNil(presenter.pendingTarget)

        presenter.invalidate()

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.pendingTarget)
    }
}

// MARK: - Application-time revalidation, consume, and lifecycle

extension SessionTranscriptRevealPresenterTests {
    /// A presenter whose loader answers `snapshot` immediately, already
    /// holding a ready target for `range`.
    private func makeReadyPresenter(
        entry: CompletedSessionEntry,
        snapshot: NotesTranscriptSourceSnapshot,
        range: ClosedRange<Int> = 1...1
    ) async -> (SessionTranscriptRevealPresenter, ControllableSourceLoader) {
        let loader = ControllableSourceLoader()
        await loader.setResult(.success(snapshot), for: entry.manifest.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)
        await presenter.requestReveal(reference: reference(snapshot.sessionID, range), generatedFrom: snapshot.fingerprint, for: entry)
        XCTAssertEqual(presenter.pendingTarget, target(snapshot, range))
        return (presenter, loader)
    }

    func testRevalidationAuthorizesTheReadyTargetForSameSessionAndFingerprint() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot)

        let application = await presenter.revalidateReadyTarget(for: entry)

        XCTAssertEqual(application?.target, target(snapshot, 1...1))
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 1...1)), "revalidation alone never consumes")
    }

    func testRevalidationRejectsTargetWhenTranscriptFingerprintChanged() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        await loader.setResult(.success(makeSnapshot(sessionID: snapshot.sessionID, textPrefix: "retranscribed")), for: snapshot.sessionID)

        let application = await presenter.revalidateReadyTarget(for: entry)

        XCTAssertNil(application)
        XCTAssertEqual(presenter.state, .failed(.unresolvable(.transcriptMismatch)))
        XCTAssertNil(presenter.pendingTarget)
    }

    func testRevalidationRejectsSnapshotFromADifferentSession() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        await loader.setResult(.success(makeSnapshot(sessionID: UUID())), for: snapshot.sessionID)

        let application = await presenter.revalidateReadyTarget(for: entry)

        XCTAssertNil(application)
        guard case .failed(.sourceUnavailable) = presenter.state else {
            return XCTFail("expected sourceUnavailable, got \(presenter.state)")
        }
    }

    func testRevalidationRejectsTargetWhenSourceReloadFails() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        let loadError = NotesTranscriptSourceLoadError.preflightBlocked(reasons: ["chunk 1 missing"])
        await loader.setResult(.failure(loadError), for: snapshot.sessionID)

        let application = await presenter.revalidateReadyTarget(for: entry)

        XCTAssertNil(application)
        XCTAssertEqual(presenter.state, .failed(.sourceUnavailable(reason: loadError.localizedDescription)))
    }

    func testRevalidationForAnotherSessionsEntryIsRejected() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot)

        let application = await presenter.revalidateReadyTarget(for: makeEntry())

        XCTAssertNil(application)
        XCTAssertEqual(presenter.state, .failed(.unresolvable(.sessionMismatch)))
    }

    func testRevalidationWithoutReadyTargetDoesNothing() async {
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: ControllableSourceLoader())
        let application = await presenter.revalidateReadyTarget(for: makeEntry())
        XCTAssertNil(application)
        XCTAssertEqual(presenter.state, .idle)
    }

    func testStaleRevalidationCannotAlterANewerRequest() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await makeReadyPresenter(entry: entry, snapshot: snapshot, range: 0...0)
        await loader.hold(snapshot.sessionID)

        let revalidation = Task { await presenter.revalidateReadyTarget(for: entry) }
        await waitForHeldCalls(1, in: loader)
        let newer = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 2...2), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(2, in: loader)
        await loader.resumeHeldCall(1, with: .success(snapshot))
        await newer.value
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 2...2)))

        // The stale revalidation completes with a changed transcript: it
        // must neither authorize anything nor publish its failure.
        await loader.resumeHeldCall(0, with: .success(makeSnapshot(sessionID: snapshot.sessionID, textPrefix: "changed")))
        let staleApplication = await revalidation.value

        XCTAssertNil(staleApplication)
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 2...2)))
    }

    func testRevalidationInvalidatedMidFlightAuthorizesNothing() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        await loader.hold(snapshot.sessionID)

        let revalidation = Task { await presenter.revalidateReadyTarget(for: entry) }
        await waitForHeldCalls(1, in: loader)
        presenter.invalidate()
        await loader.resumeHeldCall(0, with: .success(snapshot))

        let application = await revalidation.value
        XCTAssertNil(application)
        XCTAssertEqual(presenter.state, .idle)
    }

    func testConsumeClearsOnlyTheMatchingReadyTargetAndKeepsSession() async throws {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        let application = await presenter.revalidateReadyTarget(for: entry)

        presenter.consume(try XCTUnwrap(application))

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.pendingTarget)
        XCTAssertEqual(presenter.sessionID, entry.manifest.sessionID, "consume is not a session change")
    }

    func testConsumingAnOlderApplicationCannotClearANewerEqualTarget() async throws {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        let olderApplication = await presenter.revalidateReadyTarget(for: entry)

        // The same Source clicked again resolves to an equal target.
        await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...1), generatedFrom: snapshot.fingerprint, for: entry)
        presenter.consume(try XCTUnwrap(olderApplication))
        presenter.reject(try XCTUnwrap(olderApplication), with: .locationUnavailable)
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 1...1)))

        let newerApplication = await presenter.revalidateReadyTarget(for: entry)
        presenter.consume(try XCTUnwrap(newerApplication))
        XCTAssertEqual(presenter.state, .idle)
    }

    func testConsumeDoesNotInvalidateLikeASessionChange() async throws {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        let firstApplication = await presenter.revalidateReadyTarget(for: entry)
        let application = try XCTUnwrap(firstApplication)

        // A second revalidation of the same request already in flight when
        // the first application is consumed: consume leaves the request
        // generation alone, but the target is no longer ready, so the late
        // revalidation authorizes nothing and publishes nothing.
        await loader.hold(snapshot.sessionID)
        let lateRevalidation = Task { await presenter.revalidateReadyTarget(for: entry) }
        await waitForHeldCalls(1, in: loader)
        presenter.consume(application)
        await loader.resumeHeldCall(0, with: .success(snapshot))
        let lateApplication = await lateRevalidation.value

        XCTAssertNil(lateApplication)
        XCTAssertEqual(presenter.state, .idle)
        XCTAssertEqual(presenter.sessionID, entry.manifest.sessionID)
    }

    func testRejectReplacesMatchingReadyTargetWithFailure() async throws {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        let application = await presenter.revalidateReadyTarget(for: entry)

        presenter.reject(try XCTUnwrap(application), with: .locationUnavailable)

        XCTAssertEqual(presenter.state, .failed(.locationUnavailable))
        XCTAssertNil(presenter.pendingTarget, "a rejected target is never retried")
    }

    // MARK: Plain-transcript fallback application

    private func completedSegments(_ sequenceNumbers: ClosedRange<Int>) -> [OrderedSegment] {
        sequenceNumbers.map { OrderedSegment(sequenceNumber: $0, state: .completed(text: "unit \($0)")) }
    }

    func testFallbackApplicationConsumesItsExactApplication() async throws {
        let entry = makeEntry()
        let sessionID = entry.manifest.sessionID
        let snapshot = makeSnapshot(sessionID: sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot, range: 1...2)

        let applicationRevalidation = await presenter.revalidateReadyTarget(for: entry)

        let application = try XCTUnwrap(applicationRevalidation)
        let outcome = TranscriptRevealApplicationPlanner.outcome(
            for: application.target, sessionID: sessionID, transcript: .plain(sessionID: sessionID, segments: completedSegments(0...2))
        )
        XCTAssertEqual(outcome, .applyFallback(TranscriptFallbackRevealSelection(scrollTargetSequenceNumber: 1, selectedSequenceNumbers: [1, 2])))
        presenter.consume(application)

        XCTAssertEqual(presenter.state, .idle, "applied once; never re-applied on remount")
        XCTAssertEqual(presenter.sessionID, sessionID)
    }

    func testUnrepresentableFallbackIsRejectedAndNotRetried() async throws {
        let entry = makeEntry()
        let sessionID = entry.manifest.sessionID
        let snapshot = makeSnapshot(sessionID: sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot, range: 1...2)

        let applicationRevalidation = await presenter.revalidateReadyTarget(for: entry)

        let application = try XCTUnwrap(applicationRevalidation)
        let segments = [OrderedSegment(sequenceNumber: 0, state: .completed(text: "unit 0")), OrderedSegment(sequenceNumber: 1, state: .missing)]
        let outcome = TranscriptRevealApplicationPlanner.outcome(for: application.target, sessionID: sessionID, transcript: .plain(sessionID: sessionID, segments: segments))
        XCTAssertEqual(outcome, .locationUnavailable)
        presenter.reject(application, with: .locationUnavailable)

        XCTAssertEqual(presenter.state, .failed(.locationUnavailable))
        XCTAssertNil(presenter.pendingTarget)
    }

    func testTargetWaitsWhileTranscriptIsStillLoading() async throws {
        let entry = makeEntry()
        let sessionID = entry.manifest.sessionID
        let snapshot = makeSnapshot(sessionID: sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        let pendingTarget = try XCTUnwrap(presenter.pendingTarget)

        XCTAssertEqual(TranscriptRevealApplicationPlanner.outcome(for: pendingTarget, sessionID: sessionID, transcript: .loading), .notApplicable)
        // Nothing was revalidated, consumed, or rejected: still ready.
        XCTAssertEqual(presenter.state, .ready(pendingTarget))
    }

    func testStaleFallbackApplicationCannotApplyOverANewerRequest() async throws {
        let entry = makeEntry()
        let sessionID = entry.manifest.sessionID
        let snapshot = makeSnapshot(sessionID: sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot, range: 1...1)
        let olderApplicationRevalidation = await presenter.revalidateReadyTarget(for: entry)
        let olderApplication = try XCTUnwrap(olderApplicationRevalidation)

        // A newer Source click supersedes the older application.
        await presenter.requestReveal(reference: reference(sessionID, 2...2), generatedFrom: snapshot.fingerprint, for: entry)
        presenter.consume(olderApplication)
        presenter.reject(olderApplication, with: .locationUnavailable)
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 2...2)), "the stale token neither consumed nor rejected the newer target")

        let newerApplicationRevalidation = await presenter.revalidateReadyTarget(for: entry)

        let newerApplication = try XCTUnwrap(newerApplicationRevalidation)
        XCTAssertEqual(
            TranscriptRevealApplicationPlanner.outcome(for: newerApplication.target, sessionID: sessionID, transcript: .plain(sessionID: sessionID, segments: completedSegments(0...2))),
            .applyFallback(TranscriptFallbackRevealSelection(scrollTargetSequenceNumber: 2, selectedSequenceNumbers: [2]))
        )
        presenter.consume(newerApplication)
        XCTAssertEqual(presenter.state, .idle)
    }

    func testFallbackCannotApplyAcrossSessions() async {
        let entry = makeEntry()
        let otherEntry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        let readyTarget = target(snapshot, 1...1)

        // Another session's pane never applies this target to its plain rows…
        let otherSessionID = otherEntry.manifest.sessionID
        XCTAssertEqual(
            TranscriptRevealApplicationPlanner.outcome(for: readyTarget, sessionID: otherSessionID, transcript: .plain(sessionID: otherSessionID, segments: completedSegments(0...2))),
            .notApplicable
        )
        XCTAssertEqual(presenter.state, .ready(readyTarget))
        // …and revalidation from another session's entry authorizes nothing.
        let application = await presenter.revalidateReadyTarget(for: otherEntry)
        XCTAssertNil(application)
        XCTAssertEqual(presenter.state, .failed(.unresolvable(.sessionMismatch)))
    }

    func testReadyTargetWaitsForALaterMountedTranscriptPane() async {
        // Narrow layout: the request completes while Notes is shown; the
        // Transcript pane only mounts (and revalidates) afterwards.
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot, range: 0...1)
        await Task.yield()
        XCTAssertEqual(presenter.pendingTarget, target(snapshot, 0...1))

        let application = await presenter.revalidateReadyTarget(for: entry)
        XCTAssertEqual(application?.target, target(snapshot, 0...1))
    }

    func testConsumedRevealIsNotReappliedOnRemountButSameSourceCanRevealAgain() async throws {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        let firstApplication = await presenter.revalidateReadyTarget(for: entry)
        presenter.consume(try XCTUnwrap(firstApplication))

        // A remounted pane finds nothing pending.
        XCTAssertNil(presenter.pendingTarget)
        let remountApplication = await presenter.revalidateReadyTarget(for: entry)
        XCTAssertNil(remountApplication)

        // Clicking the same Source again produces a fresh reveal.
        await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...1), generatedFrom: snapshot.fingerprint, for: entry)
        XCTAssertEqual(presenter.pendingTarget, target(snapshot, 1...1))
        let againApplication = await presenter.revalidateReadyTarget(for: entry)
        XCTAssertEqual(againApplication?.target, target(snapshot, 1...1))
    }
}

// MARK: - Transcript application planning and failure wording

final class TranscriptRevealApplicationPlannerTests: XCTestCase {
    private let sessionID = UUID()
    private let fingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "b", count: 64))

    private func target(_ range: ClosedRange<Int>, sessionID: UUID? = nil) -> TranscriptRevealTarget {
        TranscriptRevealTarget(
            sessionID: sessionID ?? self.sessionID,
            transcriptFingerprint: fingerprint,
            firstSequenceNumber: range.lowerBound,
            lastSequenceNumber: range.upperBound
        )
    }

    private func rows(_ sequenceNumber: Int, timedSegments count: Int) -> [TranscriptPlaybackItem] {
        (0..<count).map { index in
            TranscriptPlaybackItem(
                chunkSequenceNumber: sequenceNumber,
                target: .timedSegment(index: index),
                text: "chunk \(sequenceNumber) segment \(index)",
                startSessionFrame: Int64(index) * 100,
                endSessionFrame: Int64(index) * 100 + 100
            )
        }
    }

    private func chunkStart(_ sequenceNumber: Int) -> TranscriptPlaybackItem {
        TranscriptPlaybackItem(chunkSequenceNumber: sequenceNumber, target: .chunkStart, text: "chunk \(sequenceNumber)", startSessionFrame: 0, endSessionFrame: 1_000)
    }

    /// Chunk 0: two timed rows; chunk 1: three timed rows; chunk 2: one
    /// untimed chunk-start row; chunk 3: two timed rows.
    private var navigation: TranscriptPlaybackNavigation {
        TranscriptPlaybackNavigation(
            sessionID: sessionID,
            sampleRate: 16_000,
            items: rows(0, timedSegments: 2) + rows(1, timedSegments: 3) + [chunkStart(2)] + rows(3, timedSegments: 2)
        )
    }

    private func id(_ sequenceNumber: Int, _ index: Int) -> TranscriptPlaybackItem.ID {
        TranscriptPlaybackItem.ID(chunkSequenceNumber: sequenceNumber, target: .timedSegment(index: index))
    }

    func testSingleChunkRevealScrollsToItsFirstRowAndHighlightsEveryRowOfThatChunk() {
        let outcome = TranscriptRevealApplicationPlanner.outcome(for: target(1...1), sessionID: sessionID, transcript: .navigation(navigation))
        XCTAssertEqual(outcome, .apply(TranscriptRevealSelection(
            scrollTargetID: id(1, 0),
            selectedItemIDs: [id(1, 0), id(1, 1), id(1, 2)]
        )), "every timed row of the chunk, not just the scroll row")
    }

    func testMultiChunkRevealHighlightsAllRowsOfAllChunksAndNothingOutside() {
        let outcome = TranscriptRevealApplicationPlanner.outcome(for: target(1...2), sessionID: sessionID, transcript: .navigation(navigation))
        guard case .apply(let selection) = outcome else {
            return XCTFail("expected .apply, got \(outcome)")
        }
        XCTAssertEqual(selection.scrollTargetID, id(1, 0))
        let highlighted = Set(selection.selectedItemIDs)
        XCTAssertEqual(highlighted, [id(1, 0), id(1, 1), id(1, 2), TranscriptPlaybackItem.ID(chunkSequenceNumber: 2, target: .chunkStart)])
        for item in navigation.items where item.chunkSequenceNumber == 0 || item.chunkSequenceNumber == 3 {
            XCTAssertFalse(highlighted.contains(item.id), "row outside the source range: \(item.id)")
        }
    }

    func testUnmappableRangeIsLocationUnavailableNeverPartial() {
        // Chunk 4 has no rows: the whole mapping fails even though 3 exists.
        XCTAssertEqual(
            TranscriptRevealApplicationPlanner.outcome(for: target(3...4), sessionID: sessionID, transcript: .navigation(navigation)),
            .locationUnavailable
        )
    }

    func testTargetForAnotherSessionIsNotApplicableInThisPane() {
        XCTAssertEqual(
            TranscriptRevealApplicationPlanner.outcome(for: target(1...1, sessionID: UUID()), sessionID: sessionID, transcript: .navigation(navigation)),
            .notApplicable
        )
    }

    func testLoadingOrForeignTranscriptLeavesTargetPending() {
        XCTAssertEqual(TranscriptRevealApplicationPlanner.outcome(for: target(1...1), sessionID: sessionID, transcript: .loading), .notApplicable)
        let foreign = TranscriptPlaybackNavigation(sessionID: UUID(), sampleRate: 16_000, items: navigation.items)
        XCTAssertEqual(TranscriptRevealApplicationPlanner.outcome(for: target(1...1), sessionID: sessionID, transcript: .navigation(foreign)), .notApplicable)
        XCTAssertEqual(
            TranscriptRevealApplicationPlanner.outcome(for: target(1...1), sessionID: sessionID, transcript: .plain(sessionID: UUID(), segments: plainSegments)),
            .notApplicable
        )
    }

    // MARK: Plain-transcript fallback

    /// One completed row per chunk 0...3, matching `navigation`'s chunks.
    private var plainSegments: [OrderedSegment] {
        (0...3).map { OrderedSegment(sequenceNumber: $0, state: .completed(text: "chunk \($0)")) }
    }

    func testNavigationWinsOverPlainRowsWhenAvailable() {
        // The view reports `.navigation` whenever navigation is loaded, even
        // though plain segments exist too; the preferred selection is used.
        let outcome = TranscriptRevealApplicationPlanner.outcome(for: target(1...1), sessionID: sessionID, transcript: .navigation(navigation))
        guard case .apply(let selection) = outcome else {
            return XCTFail("expected navigation .apply, got \(outcome)")
        }
        XCTAssertEqual(selection.scrollTargetID, id(1, 0))
    }

    func testWithoutNavigationCompletedPlainRowsAreRevealedByWholeChunk() {
        XCTAssertEqual(
            TranscriptRevealApplicationPlanner.outcome(for: target(1...2), sessionID: sessionID, transcript: .plain(sessionID: sessionID, segments: plainSegments)),
            .applyFallback(TranscriptFallbackRevealSelection(scrollTargetSequenceNumber: 1, selectedSequenceNumbers: [1, 2]))
        )
    }

    func testWithoutNavigationUnusablePlainRowsAreLocationUnavailable() {
        var segments = plainSegments
        segments[2] = OrderedSegment(sequenceNumber: 2, state: .inProgress)
        XCTAssertEqual(
            TranscriptRevealApplicationPlanner.outcome(for: target(1...2), sessionID: sessionID, transcript: .plain(sessionID: sessionID, segments: segments)),
            .locationUnavailable
        )
        XCTAssertEqual(
            TranscriptRevealApplicationPlanner.outcome(for: target(1...2), sessionID: sessionID, transcript: .plain(sessionID: sessionID, segments: [])),
            .locationUnavailable,
            "a loaded transcript with no rows is final, not pending"
        )
    }

    func testTargetForAnotherSessionIsNotApplicableToPlainRows() {
        XCTAssertEqual(
            TranscriptRevealApplicationPlanner.outcome(for: target(1...1, sessionID: UUID()), sessionID: sessionID, transcript: .plain(sessionID: sessionID, segments: plainSegments)),
            .notApplicable
        )
    }

    func testFailureMessagesDistinguishChangedUnavailableLocationAndSource() {
        XCTAssertEqual(TranscriptRevealFailureMessage.message(for: .unresolvable(.transcriptMismatch)), TranscriptRevealFailureMessage.transcriptChanged)
        XCTAssertEqual(TranscriptRevealFailureMessage.message(for: .unresolvable(.outOfRange(availableRange: 0...2))), TranscriptRevealFailureMessage.locationUnavailable)
        XCTAssertEqual(TranscriptRevealFailureMessage.message(for: .unresolvable(.sessionMismatch)), TranscriptRevealFailureMessage.locationUnavailable)
        XCTAssertEqual(TranscriptRevealFailureMessage.message(for: .locationUnavailable), TranscriptRevealFailureMessage.locationUnavailable)
        let sourceMessage = TranscriptRevealFailureMessage.message(for: .sourceUnavailable(reason: "/private/path/manifest.json unreadable"))
        XCTAssertEqual(sourceMessage, TranscriptRevealFailureMessage.sourceUnavailable)
        XCTAssertFalse(sourceMessage.contains("/private"), "never exposes storage detail")
    }
}

// MARK: - Cancellation and failure dismissal

extension SessionTranscriptRevealPresenterTests {
    func testCancelledInitialLoadEndsCleanlyWithoutFailure() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.setResult(.failure(CancellationError()), for: entry.manifest.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...1), generatedFrom: snapshot.fingerprint, for: entry)

        XCTAssertEqual(presenter.state, .idle, "cancellation is not a source failure")
        XCTAssertNil(presenter.pendingTarget)
    }

    func testOperationalInitialLoadErrorStillFails() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.setResult(.failure(NotesTranscriptSourceLoadError.sourceBuildFailed("unreadable")), for: entry.manifest.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...1), generatedFrom: snapshot.fingerprint, for: entry)

        guard case .failed(.sourceUnavailable) = presenter.state else {
            return XCTFail("expected sourceUnavailable, got \(presenter.state)")
        }
    }

    /// A late cancellation from a superseded request must not end the newer
    /// request's ready target.
    func testCancelledSupersededRequestCannotAlterNewerRequest() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.hold(snapshot.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)

        let requestA = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 0...0), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(1, in: loader)
        let requestB = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...2), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(2, in: loader)
        await loader.resumeHeldCall(1, with: .success(snapshot))
        await requestB.value
        await loader.resumeHeldCall(0, with: .failure(CancellationError()))
        await requestA.value

        XCTAssertEqual(presenter.state, .ready(target(snapshot, 1...2)))
    }

    func testCancelledRevalidationKeepsReadyTargetForRetry() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await makeReadyPresenter(entry: entry, snapshot: snapshot)
        await loader.setResult(.failure(CancellationError()), for: entry.manifest.sessionID)

        let cancelled = await presenter.revalidateReadyTarget(for: entry)

        XCTAssertNil(cancelled)
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 1...1)))

        await loader.setResult(.success(snapshot), for: entry.manifest.sessionID)
        let retried = await presenter.revalidateReadyTarget(for: entry)
        XCTAssertEqual(retried?.target, target(snapshot, 1...1), "a later attempt can still apply it")
    }

    func testDismissFailureClearsOnlyAFailure() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let loader = ControllableSourceLoader()
        await loader.setResult(.failure(NotesTranscriptSourceLoadError.sourceBuildFailed("unreadable")), for: entry.manifest.sessionID)
        let presenter = SessionTranscriptRevealPresenter(sourceLoader: loader)
        await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...1), generatedFrom: snapshot.fingerprint, for: entry)
        guard case .failed = presenter.state else { return XCTFail("expected a failure") }

        presenter.dismissFailure()

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertEqual(presenter.sessionID, entry.manifest.sessionID)
    }

    func testDismissFailureLeavesReadyAndResolvingRequestsAlone() async {
        let entry = makeEntry()
        let snapshot = makeSnapshot(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await makeReadyPresenter(entry: entry, snapshot: snapshot)

        presenter.dismissFailure()
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 1...1)))

        await loader.hold(snapshot.sessionID)
        let request = Task { await presenter.requestReveal(reference: reference(snapshot.sessionID, 1...2), generatedFrom: snapshot.fingerprint, for: entry) }
        await waitForHeldCalls(1, in: loader)
        presenter.dismissFailure()
        XCTAssertEqual(presenter.state, .resolving)

        await loader.resumeHeldCall(0, with: .success(snapshot))
        await request.value
        XCTAssertEqual(presenter.state, .ready(target(snapshot, 1...2)), "the pending request still completes")
    }
}
