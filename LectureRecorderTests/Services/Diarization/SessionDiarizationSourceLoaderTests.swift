import AVFoundation
import XCTest
@testable import LectureRecorder

/// The D3 terminal-session eligibility rule: terminal status is necessary,
/// and the durable chunks must still form a valid `LecturePlaybackSource`.
final class SessionDiarizationSourceLoaderTests: XCTestCase {
    private typealias S = SessionDiarizationTestSupport

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try S.makeRoot()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func load(_ sessionID: UUID) async throws -> SessionDiarizationSourceSnapshot {
        try await S.loader(root: root).loadSourceSnapshot(sessionID: sessionID)
    }

    private func assertLoadFails(
        _ sessionID: UUID,
        _ expected: SessionDiarizationSourceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await load(sessionID)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SessionDiarizationSourceError, expected, file: file, line: line)
        }
    }

    // MARK: - Status rule

    func testStatusRuleAcceptsExactlyTheTerminalStatuses() {
        XCTAssertTrue(SessionDiarizationSourceLoader.isEligibleStatus(.completed))
        XCTAssertTrue(SessionDiarizationSourceLoader.isEligibleStatus(.interrupted))
        XCTAssertTrue(SessionDiarizationSourceLoader.isEligibleStatus(.failed))
        XCTAssertFalse(SessionDiarizationSourceLoader.isEligibleStatus(.recording))
    }

    /// No transcription, Notes, or Summary artifacts exist for these
    /// sessions, and `endedCleanly` is false for the non-completed ones.
    func testValidCompletedInterruptedAndFailedSessionsLoad() async throws {
        for status in [SessionStatus.completed, .interrupted, .failed] {
            let (manifest, paths) = try S.writeSession(root: root, status: status)
            let snapshot = try await load(manifest.sessionID)

            XCTAssertEqual(snapshot.sessionPaths, paths, "\(status)")
            XCTAssertEqual(snapshot.source.timeline, try LecturePlaybackTimeline(manifest: manifest), "\(status)")
            XCTAssertEqual(snapshot.audioSource, DiarizationAudioSourceFingerprint.compute(source: snapshot.source), "\(status)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionDirectory.appendingPathComponent("transcription").path))
        }
    }

    func testRecordingSessionIsRejectedEvenWithValidAudio() async throws {
        let (manifest, _) = try S.writeSession(root: root, status: .recording)
        await assertLoadFails(manifest.sessionID, .notTerminal(.recording))
    }

    // MARK: - Terminal but structurally invalid

    func testTerminalSessionsWithInvalidChunksAreRejected() async throws {
        for status in [SessionStatus.interrupted, .failed, .completed] {
            // Non-completed chunk metadata.
            var (manifest, paths) = try S.writeSession(root: root, status: status)
            manifest.chunks[1].state = .recording
            try S.writeManifest(manifest, paths: paths)
            await assertLoadFails(manifest.sessionID, .audioUnavailable(.sessionIneligible(.nonCompletedChunk(sequenceNumber: 1))))

            // Missing chunk file.
            (manifest, paths) = try S.writeSession(root: root, status: status)
            try FileManager.default.removeItem(at: paths.chunksDirectory.appendingPathComponent(manifest.chunks[1].fileName))
            await assertLoadFails(manifest.sessionID, .audioUnavailable(.chunkFileMissing(sequenceNumber: 1)))

            // Symlinked chunk file (pointing at a valid CAF).
            (manifest, paths) = try S.writeSession(root: root, status: status)
            let chunkURL = paths.chunksDirectory.appendingPathComponent(manifest.chunks[1].fileName)
            let elsewhere = root.appendingPathComponent("elsewhere-\(UUID().uuidString).caf")
            try FileManager.default.moveItem(at: chunkURL, to: elsewhere)
            try FileManager.default.createSymbolicLink(at: chunkURL, withDestinationURL: elsewhere)
            await assertLoadFails(manifest.sessionID, .audioUnavailable(.chunkFileUnsafe(sequenceNumber: 1)))

            // Persisted frame count disagrees with the file.
            (manifest, paths) = try S.writeSession(root: root, status: status)
            manifest.chunks[0].frameCount += 1
            try S.writeManifest(manifest, paths: paths)
            await assertLoadFails(manifest.sessionID, .audioUnavailable(.chunkFrameCountMismatch(sequenceNumber: 0)))

            // File format differs from the session format.
            (manifest, paths) = try S.writeSession(root: root, status: status)
            let first = paths.chunksDirectory.appendingPathComponent(manifest.chunks[0].fileName)
            try FileManager.default.removeItem(at: first)
            try PlaybackTestAudio.writeChunk(to: first, frameCount: manifest.chunks[0].frameCount, firstSessionFrame: 0, sampleRate: 44_100)
            await assertLoadFails(manifest.sessionID, .audioUnavailable(.chunkFormatMismatch(sequenceNumber: 0)))

            // Invalid timeline (non-contiguous sequence).
            (manifest, paths) = try S.writeSession(root: root, status: status)
            manifest.chunks.removeFirst()
            try S.writeManifest(manifest, paths: paths)
            do {
                _ = try await load(manifest.sessionID)
                XCTFail("a gapped chunk sequence must not load (\(status))")
            } catch {
                guard case .audioUnavailable? = error as? SessionDiarizationSourceError else {
                    return XCTFail("expected audioUnavailable, got \(error)")
                }
            }
        }
    }

    func testSessionWithNoAudioIsRejected() async throws {
        for status in [SessionStatus.completed, .interrupted, .failed] {
            let (manifest, _) = try S.writeSession(root: root, status: status, frameCounts: [])
            await assertLoadFails(manifest.sessionID, .audioUnavailable(.timeline(.noChunks)))
        }
    }

    // MARK: - Session identity and paths

    func testMissingSessionIdentityMismatchAndUnreadableManifestAreRejected() async throws {
        await assertLoadFails(UUID(), .sessionUnavailable)

        let (manifest, paths) = try S.writeSession(root: root)
        var foreign = manifest
        foreign.sessionID = UUID()
        try S.writeManifest(foreign, paths: paths)
        await assertLoadFails(manifest.sessionID, .sessionIdentityMismatch)

        try Data("not json".utf8).write(to: paths.manifestURL)
        await assertLoadFails(manifest.sessionID, .manifestUnreadable)
    }

    func testSymlinkedSessionDirectoryAndUnresolvableRootAreRejected() async throws {
        let realRoot = try S.makeRoot()
        defer { try? FileManager.default.removeItem(at: realRoot) }
        let (manifest, paths) = try S.writeSession(root: realRoot)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(manifest.sessionID.uuidString),
            withDestinationURL: paths.sessionDirectory
        )
        await assertLoadFails(manifest.sessionID, .sessionUnavailable)

        struct Unresolvable: Error {}
        let unresolvable = SessionDiarizationSourceLoader(sessionsRootResolver: { throw Unresolvable() })
        do {
            _ = try await unresolvable.loadSourceSnapshot(sessionID: manifest.sessionID)
            XCTFail("an unresolvable root must not load")
        } catch {
            XCTAssertEqual(error as? SessionDiarizationSourceError, .sessionUnavailable)
        }
    }

    // MARK: - Read-only

    func testLoadingNeverCreatesOrModifiesAnything() async throws {
        let (manifest, _) = try S.writeSession(root: root, status: .interrupted)
        let before = try S.tree(root)

        _ = try await load(manifest.sessionID)
        await assertLoadFails(UUID(), .sessionUnavailable)

        XCTAssertEqual(try S.tree(root), before)
    }

    func testEachLoadRereadsTheManifestFromDisk() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let first = try await load(manifest.sessionID)

        let (_, rewrittenPaths) = try S.writeSession(root: root, sessionID: manifest.sessionID, frameCounts: [16_000, 4_000])
        let second = try await load(manifest.sessionID)
        XCTAssertNotEqual(second.audioSource, first.audioSource)
        XCTAssertEqual(second.sessionPaths, rewrittenPaths)

        var recording = try AtomicFileWriter.readJSON(SessionManifest.self, from: rewrittenPaths.manifestURL)
        recording.status = .recording
        try S.writeManifest(recording, paths: rewrittenPaths)
        await assertLoadFails(manifest.sessionID, .notTerminal(.recording))
    }
}
