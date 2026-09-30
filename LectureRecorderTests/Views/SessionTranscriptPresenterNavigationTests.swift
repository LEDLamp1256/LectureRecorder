import XCTest
@testable import LectureRecorder

@MainActor
private final class CompletedStatusLoader: CompletedSessionStatusLoading {
    func peekStatus(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> SessionTranscriptionStatus {
        .completed
    }

    func peekOrderedSegments(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> [OrderedSegment]? {
        [OrderedSegment(sequenceNumber: 0, state: .completed(text: "text"))]
    }
}

/// Suspends a gated session's navigation load until resumed.
private actor GatedNavigationLoader: CompletedTranscriptNavigationLoading {
    private var gated: Set<UUID> = []
    private var pending: [UUID: CheckedContinuation<Void, Never>] = [:]

    func gate(_ sessionID: UUID) {
        gated.insert(sessionID)
    }

    func hasPending(_ sessionID: UUID) -> Bool {
        pending[sessionID] != nil
    }

    func resume(_ sessionID: UUID) {
        pending.removeValue(forKey: sessionID)?.resume()
    }

    func loadNavigation(sessionID: UUID, manifest: SessionManifest, sessionPaths: SessionPaths) async -> TranscriptPlaybackNavigation? {
        if gated.remove(sessionID) != nil {
            await withCheckedContinuation { pending[sessionID] = $0 }
        }
        let item = TranscriptPlaybackItem(
            chunkSequenceNumber: 0, target: .chunkStart, text: "text", startSessionFrame: 0, endSessionFrame: 1_000
        )
        return TranscriptPlaybackNavigation(sessionID: sessionID, sampleRate: 44_100, items: [item])
    }
}

@MainActor
final class SessionTranscriptPresenterNavigationTests: XCTestCase {
    private func makeEntry() -> CompletedSessionEntry {
        let manifest = PlaybackTestManifest.make(frameCounts: [1_000])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionTranscriptPresenterNavigationTests-\(UUID().uuidString)")
        return CompletedSessionEntry(
            manifest: manifest,
            sessionPaths: DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: manifest.sessionID)
        )
    }

    func testStaleNavigationLoadCannotOverwriteNewerSelection() async {
        let navigationLoader = GatedNavigationLoader()
        let presenter = SessionTranscriptPresenter(loader: CompletedStatusLoader(), navigationLoader: navigationLoader)
        let entryA = makeEntry()
        let entryB = makeEntry()
        await navigationLoader.gate(entryA.manifest.sessionID)

        let taskA = Task { await presenter.refresh(for: entryA) }
        while await !navigationLoader.hasPending(entryA.manifest.sessionID) { await Task.yield() }

        await presenter.refresh(for: entryB)
        XCTAssertEqual(presenter.navigation?.sessionID, entryB.manifest.sessionID)

        await navigationLoader.resume(entryA.manifest.sessionID)
        await taskA.value

        XCTAssertEqual(presenter.displayedSessionID, entryB.manifest.sessionID)
        XCTAssertEqual(presenter.navigation?.sessionID, entryB.manifest.sessionID)
    }

    func testPresenterWithoutNavigationLoaderPublishesNoNavigation() async {
        let presenter = SessionTranscriptPresenter(loader: CompletedStatusLoader())
        await presenter.refresh(for: makeEntry())

        XCTAssertEqual(presenter.status, .completed)
        XCTAssertEqual(presenter.segments.count, 1)
        XCTAssertNil(presenter.navigation)
    }
}
