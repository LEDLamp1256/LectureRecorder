import XCTest
@testable import LectureRecorder

/// Deterministic, per-session-gated fake loader — lets a test suspend
/// exactly one session's `peekStatus` call until explicitly resumed, while
/// other sessions resolve immediately.
@MainActor
private final class FakeStatusLoader: CompletedSessionStatusLoading {
    private var scriptedStatuses: [UUID: SessionTranscriptionStatus] = [:]
    private var scriptedSegments: [UUID: [OrderedSegment]] = [:]
    private var gatedSessionIDs: Set<UUID> = []
    private var pendingContinuations: [UUID: [CheckedContinuation<SessionTranscriptionStatus, Never>]] = [:]
    private(set) var statusCallCount: [UUID: Int] = [:]

    func setStatus(_ status: SessionTranscriptionStatus, for sessionID: UUID) {
        scriptedStatuses[sessionID] = status
    }

    func setSegments(_ segments: [OrderedSegment], for sessionID: UUID) {
        scriptedSegments[sessionID] = segments
    }

    func gate(_ sessionID: UUID) {
        gatedSessionIDs.insert(sessionID)
    }

    func hasPendingLoad(for sessionID: UUID) -> Bool {
        !(pendingContinuations[sessionID] ?? []).isEmpty
    }

    func resume(_ sessionID: UUID) {
        let continuations = pendingContinuations[sessionID] ?? []
        pendingContinuations[sessionID] = []
        let status = scriptedStatuses[sessionID] ?? .notTranscribed
        for continuation in continuations {
            continuation.resume(returning: status)
        }
    }

    func peekStatus(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> SessionTranscriptionStatus {
        statusCallCount[sessionID, default: 0] += 1
        if gatedSessionIDs.contains(sessionID) {
            gatedSessionIDs.remove(sessionID)
            return await withCheckedContinuation { continuation in
                pendingContinuations[sessionID, default: []].append(continuation)
            }
        }
        return scriptedStatuses[sessionID] ?? .notTranscribed
    }

    func peekOrderedSegments(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> [OrderedSegment]? {
        scriptedSegments[sessionID]
    }
}

@MainActor
final class SessionTranscriptPresenterTests: XCTestCase {
    private func makeEntry(sessionID: UUID = UUID(), chunkCount: Int = 1) -> CompletedSessionEntry {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionTranscriptPresenterTests-\(UUID().uuidString)")
        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)
        var manifest = SessionManifest.newSession(
            id: sessionID,
            audioFormat: AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32"),
            targetChunkDurationSeconds: 30
        )
        manifest.status = .completed
        manifest.chunks = (0..<chunkCount).map {
            ChunkMetadata(
                sequenceNumber: $0, fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: $0),
                startOffsetSeconds: Double($0) * 30, durationSeconds: 30, frameCount: 1_000, state: .completed
            )
        }
        return CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)
    }

    // MARK: - Stale-load protection (review item 4's exact scenario)

    func testStaleLoadForPreviouslySelectedSessionCannotOverwriteNewerSelection() async throws {
        let loader = FakeStatusLoader()
        let entryA = makeEntry()
        let entryB = makeEntry()
        loader.setStatus(.incomplete(completed: 1, total: 2), for: entryA.manifest.sessionID)
        loader.setStatus(.completed, for: entryB.manifest.sessionID)
        loader.setSegments([OrderedSegment(sequenceNumber: 0, state: .completed(text: "b-text"))], for: entryB.manifest.sessionID)
        loader.gate(entryA.manifest.sessionID)

        let presenter = SessionTranscriptPresenter(loader: loader)

        // 1. Select A — its load starts and remains suspended.
        let taskA = Task { await presenter.refresh(for: entryA) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !loader.hasPendingLoad(for: entryA.manifest.sessionID) {
            await Task.yield()
        }
        XCTAssertTrue(loader.hasPendingLoad(for: entryA.manifest.sessionID))

        // 2. Switch to B — completes and publishes immediately (ungated).
        await presenter.refresh(for: entryB)
        XCTAssertEqual(presenter.displayedSessionID, entryB.manifest.sessionID)
        XCTAssertEqual(presenter.status, .completed)
        XCTAssertEqual(presenter.segments.map { if case .completed(let t) = $0.state { return t } else { return "" } }, ["b-text"])

        // 3. A later resumes/completes.
        loader.resume(entryA.manifest.sessionID)
        _ = await taskA.value

        // 4. A must not have replaced B's displayed state.
        XCTAssertEqual(presenter.displayedSessionID, entryB.manifest.sessionID)
        XCTAssertEqual(presenter.status, .completed)
    }

    // MARK: - Window-local independence (items 15/16)

    func testTwoIndependentPresentersDoNotShareSelection() async {
        let loader = FakeStatusLoader()
        let entryA = makeEntry()
        let entryB = makeEntry()
        loader.setStatus(.notTranscribed, for: entryA.manifest.sessionID)
        loader.setStatus(.completed, for: entryB.manifest.sessionID)

        let presenterWindow1 = SessionTranscriptPresenter(loader: loader)
        let presenterWindow2 = SessionTranscriptPresenter(loader: loader)

        await presenterWindow1.refresh(for: entryA)
        await presenterWindow2.refresh(for: entryB)

        XCTAssertEqual(presenterWindow1.displayedSessionID, entryA.manifest.sessionID)
        XCTAssertEqual(presenterWindow2.displayedSessionID, entryB.manifest.sessionID)
        XCTAssertNotEqual(presenterWindow1.status, presenterWindow2.status)
    }

    // MARK: - Ordering / empty-text / integrity display (items 18, 19, 20, 21)

    func testCompletedTranscriptSegmentsPreserveNumericOrderIncludingEmptyText() async {
        let loader = FakeStatusLoader()
        let entry = makeEntry(chunkCount: 3)
        let sessionID = entry.manifest.sessionID
        loader.setStatus(.completed, for: sessionID)
        loader.setSegments(
            [
                OrderedSegment(sequenceNumber: 0, state: .completed(text: "")),
                OrderedSegment(sequenceNumber: 1, state: .completed(text: "hello")),
                OrderedSegment(sequenceNumber: 2, state: .completed(text: "world")),
            ],
            for: sessionID
        )

        let presenter = SessionTranscriptPresenter(loader: loader)
        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.segments.map(\.sequenceNumber), [0, 1, 2])
        if case .completed(let text) = presenter.segments[0].state {
            XCTAssertEqual(text, "", "an empty per-chunk transcript is a valid completed segment, not missing")
        } else {
            XCTFail("expected completed segment")
        }
    }

    func testBlockedStatusIsDisplayedNotRepaired() async {
        let loader = FakeStatusLoader()
        let entry = makeEntry()
        loader.setStatus(.blocked(reasons: ["Chunk #0: corrupt job artifact"]), for: entry.manifest.sessionID)

        let presenter = SessionTranscriptPresenter(loader: loader)
        await presenter.refresh(for: entry)

        if case .blocked(let reasons) = presenter.status {
            XCTAssertEqual(reasons, ["Chunk #0: corrupt job artifact"])
        } else {
            XCTFail("expected .blocked, got \(String(describing: presenter.status))")
        }
        XCTAssertTrue(presenter.segments.isEmpty, "a blocked session must never display a fabricated transcript")
    }

    func testRecoveryPendingStatusIsDisplayedNotRepaired() async {
        let loader = FakeStatusLoader()
        let entry = makeEntry()
        loader.setStatus(.recoveryPending, for: entry.manifest.sessionID)

        let presenter = SessionTranscriptPresenter(loader: loader)
        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.status, .recoveryPending)
        XCTAssertTrue(presenter.segments.isEmpty)
    }

    // MARK: - Saved transcript independent of current inference readiness (items 23-26)

    func testCompletedTranscriptDisplaysWithoutConsultingAnyInferenceReadinessSignal() async {
        // The fake loader has no concept of a model/worker/config at all —
        // its `peekOrderedSegments` is a pure lookup keyed only by session
        // ID, proving the presenter's own display path never needs one.
        let loader = FakeStatusLoader()
        let entry = makeEntry()
        loader.setStatus(.completed, for: entry.manifest.sessionID)
        loader.setSegments([OrderedSegment(sequenceNumber: 0, state: .completed(text: "hi"))], for: entry.manifest.sessionID)

        let presenter = SessionTranscriptPresenter(loader: loader)
        await presenter.refresh(for: entry)

        XCTAssertEqual(presenter.status, .completed)
        XCTAssertEqual(presenter.segments.count, 1)
    }
}
