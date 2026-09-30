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
