import AVFoundation
import XCTest
@testable import LectureRecorder

/// Proves the live, no-polling Completed Sessions refresh path described on
/// `CompletedSessionsView`: a window's `CompletedSessionsListPresenter`
/// reloads the catalog only when `SessionManager.lastCompletedSession`
/// publishes a genuinely new, durably-finalized session id — using a real
/// `SessionManager` (hardware-free) and a real `CompletedSessionCatalog`
/// pointed at the same on-disk sessions root, so this exercises the actual
/// production refresh path, not just the pure predicate in isolation.
@MainActor
final class CompletedSessionsListPresenterTests: XCTestCase {
    private var tempDirectory: URL!

    private struct TestLocator: FileSystemLocating {
        let root: URL
        func sessionsRootDirectory() throws -> URL { root }
        func paths(for sessionID: UUID) throws -> SessionPaths {
            try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: sessionID)
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletedSessionsListPresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeCatalog() -> CompletedSessionCatalog {
        let root = tempDirectory!
        return CompletedSessionCatalog(sessionsRootResolver: { root })
    }

    private func makePresenter() -> CompletedSessionsListPresenter {
        CompletedSessionsListPresenter(catalog: makeCatalog())
    }

    private func makeSessionManager() -> SessionManager {
        SessionManager(
            store: SessionStore(locator: TestLocator(root: tempDirectory)),
            permissionService: MockMicrophonePermissionService(status: .granted),
            captureService: MockAudioCaptureService(
                formatToPrepare: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)!
            ),
            chunkWriterFactory: FakeAudioChunkWriterFactory()
        )
    }

    private func makeAudioFormat() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
    }

    /// Writes an already-`.completed` session manifest directly to disk,
    /// bypassing `SessionManager` — used to simulate "a session the
    /// catalog would find on reload" independently of the live
    /// finalization path under test.
    @discardableResult
    private func writeCompletedSessionDirectly(sessionID: UUID = UUID(), endDate: Date = Date()) throws -> SessionPaths {
        let sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        var manifest = SessionManifest.newSession(id: sessionID, audioFormat: makeAudioFormat(), targetChunkDurationSeconds: 30)
        manifest.status = .completed
        manifest.endedCleanly = true
        manifest.endDate = endDate
        try AtomicFileWriter.writeJSON(manifest, to: sessionPaths.manifestURL)
        return sessionPaths
    }

    // MARK: - Refresh after finalization

    func testRefreshAfterFinalizationLoadsTheNewlyCompletedSession() async throws {
        let presenter = makePresenter()
        presenter.reload()
        XCTAssertEqual(presenter.result?.sessions.count, 0)

        let manager = makeSessionManager()
        XCTAssertNil(manager.lastCompletedSession)

        await manager.startSession()
        await manager.stopSession()
        let finalized = try XCTUnwrap(manager.lastCompletedSession)

        presenter.refreshAfterFinalization(oldLastCompletedSessionID: nil, newLastCompletedSessionID: finalized.sessionID)

        XCTAssertEqual(presenter.result?.sessions.map(\.manifest.sessionID), [finalized.sessionID])
    }

    // MARK: - No premature refresh

    func testNoRefreshOccursWhileStillFinalizing() async throws {
        let presenter = makePresenter()
        presenter.reload()
        XCTAssertEqual(presenter.result?.sessions.count, 0)

        // A completed session now exists on disk that a reload WOULD pick
        // up — proving the assertion below is actually about the guard,
        // not merely about there being nothing to find.
        try writeCompletedSessionDirectly()

        // `lastCompletedSession` staying nil (session still recording, not
        // yet finalized) is exactly the `nil -> nil` case the trigger must
        // never treat as a refresh.
        presenter.refreshAfterFinalization(oldLastCompletedSessionID: nil, newLastCompletedSessionID: nil)

        XCTAssertEqual(presenter.result?.sessions.count, 0, "must not have reloaded while no finalization occurred")
    }

    // MARK: - Selection preservation

    func testSelectionIsPreservedAcrossALiveRefresh() async throws {
        let existingID = UUID()
        try writeCompletedSessionDirectly(sessionID: existingID, endDate: Date(timeIntervalSince1970: 1_700_000_000))

        let presenter = makePresenter()
        presenter.reload()
        presenter.selectedSessionID = existingID
        XCTAssertEqual(presenter.result?.sessions.map(\.manifest.sessionID), [existingID])

        let manager = makeSessionManager()
        await manager.startSession()
        await manager.stopSession()
        let newlyFinalized = try XCTUnwrap(manager.lastCompletedSession)

        presenter.refreshAfterFinalization(oldLastCompletedSessionID: nil, newLastCompletedSessionID: newlyFinalized.sessionID)

        XCTAssertEqual(Set(presenter.result?.sessions.map(\.manifest.sessionID) ?? []), [existingID, newlyFinalized.sessionID])
        XCTAssertEqual(presenter.selectedSessionID, existingID, "the window's own selection must survive the live refresh")
    }

    // MARK: - New session does not steal selection

    func testNewlyAppearingSessionDoesNotStealSelectionEvenWhenItSortsFirst() async throws {
        let existingID = UUID()
        try writeCompletedSessionDirectly(sessionID: existingID, endDate: Date(timeIntervalSince1970: 1_700_000_000))

        let presenter = makePresenter()
        presenter.reload()
        presenter.selectedSessionID = existingID

        let manager = makeSessionManager()
        await manager.startSession()
        await manager.stopSession()
        let newlyFinalized = try XCTUnwrap(manager.lastCompletedSession)

        presenter.refreshAfterFinalization(oldLastCompletedSessionID: nil, newLastCompletedSessionID: newlyFinalized.sessionID)

        // The new session is more recent, so it sorts to the top of the
        // list — but selection must remain on the pre-existing session,
        // not silently jump to whatever is now first.
        XCTAssertEqual(presenter.result?.sessions.first?.manifest.sessionID, newlyFinalized.sessionID)
        XCTAssertEqual(presenter.selectedSessionID, existingID)
        XCTAssertNotEqual(presenter.selectedSessionID, newlyFinalized.sessionID)
    }

    // MARK: - Multiple windows

    /// Two windows are two independent `CompletedSessionsListPresenter`
    /// instances (exactly as production `CompletedSessionsView` creates
    /// one per `@StateObject` per window). Both observe the same
    /// underlying catalog root and the same finalization, but each must
    /// keep its own local selection — this is a pure presentation/state
    /// assertion, no SwiftUI view hosting and no hardware involved.
    func testMultipleWindowsRetainIndependentSelectionsAcrossTheSameRefresh() async throws {
        let existingXID = UUID()
        let existingZID = UUID()
        try writeCompletedSessionDirectly(sessionID: existingXID, endDate: Date(timeIntervalSince1970: 1_700_000_000))
        try writeCompletedSessionDirectly(sessionID: existingZID, endDate: Date(timeIntervalSince1970: 1_700_000_060))

        let presenterA = makePresenter()
        presenterA.reload()
        presenterA.selectedSessionID = existingXID

        let presenterB = makePresenter()
        presenterB.reload()
        presenterB.selectedSessionID = existingZID

        let manager = makeSessionManager()
        await manager.startSession()
        await manager.stopSession()
        let newlyFinalizedY = try XCTUnwrap(manager.lastCompletedSession)

        presenterA.refreshAfterFinalization(oldLastCompletedSessionID: nil, newLastCompletedSessionID: newlyFinalizedY.sessionID)
        presenterB.refreshAfterFinalization(oldLastCompletedSessionID: nil, newLastCompletedSessionID: newlyFinalizedY.sessionID)

        // Both windows' independently-loaded results include the newly
        // finalized session...
        XCTAssertTrue(presenterA.result?.sessions.map(\.manifest.sessionID).contains(newlyFinalizedY.sessionID) ?? false)
        XCTAssertTrue(presenterB.result?.sessions.map(\.manifest.sessionID).contains(newlyFinalizedY.sessionID) ?? false)

        // ...but neither window's own selection moved to it, and each
        // window kept its own, different, pre-existing selection.
        XCTAssertEqual(presenterA.selectedSessionID, existingXID)
        XCTAssertEqual(presenterB.selectedSessionID, existingZID)
        XCTAssertNotEqual(presenterA.selectedSessionID, newlyFinalizedY.sessionID)
        XCTAssertNotEqual(presenterB.selectedSessionID, newlyFinalizedY.sessionID)
    }

    // MARK: - Stale selection clearing

    /// A selected session that genuinely disappears from the catalog
    /// (its directory is removed entirely, not merely superseded by a
    /// newer one) must clear selection on the next successful reload —
    /// never left dangling, and never silently reassigned to some other
    /// session.
    func testSelectionIsClearedWhenTheSelectedSessionIsGenuinelyRemoved() throws {
        let existingID = UUID()
        let sessionPaths = try writeCompletedSessionDirectly(sessionID: existingID, endDate: Date(timeIntervalSince1970: 1_700_000_000))

        let presenter = makePresenter()
        presenter.reload()
        presenter.selectedSessionID = existingID
        XCTAssertEqual(presenter.result?.sessions.map(\.manifest.sessionID), [existingID])

        try FileManager.default.removeItem(at: sessionPaths.sessionDirectory)

        presenter.reload()

        XCTAssertEqual(presenter.result?.sessions.count, 0)
        XCTAssertNil(presenter.selectedSessionID, "selection must clear once the selected session no longer exists")
    }
}
