import AVFoundation
import XCTest
@testable import LectureRecorder

final class LecturePlaybackSourceLoaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try PlaybackTestAudio.makeTemporaryRoot()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func load(_ manifest: SessionManifest, _ paths: SessionPaths) throws -> LecturePlaybackSource {
        try LecturePlaybackSourceLoader.load(expectedSessionID: manifest.sessionID, manifest: manifest, sessionPaths: paths)
    }

    private func assertLoadFails(
        _ manifest: SessionManifest,
        _ paths: SessionPaths,
        _ expected: LecturePlaybackSourceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try load(manifest, paths), file: file, line: line) { error in
            XCTAssertEqual(error as? LecturePlaybackSourceError, expected, file: file, line: line)
        }
    }

    private func chunkURL(_ paths: SessionPaths, _ sequenceNumber: Int) -> URL {
        paths.chunksDirectory.appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber))
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })
    }

    func testValidCanonicalSessionLoadsReadOnly() throws {
        let (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [4_410, 4_411, 100])
        let before = try snapshot(paths.chunksDirectory)
        let sessionEntriesBefore = try FileManager.default.contentsOfDirectory(atPath: paths.sessionDirectory.path).sorted()

        let source = try load(manifest, paths)

        XCTAssertEqual(source.timeline, try LecturePlaybackTimeline(manifest: manifest))
        XCTAssertEqual(source.chunkURLs, (0..<3).map { chunkURL(paths, $0) })
        XCTAssertEqual(source.channelCount, 1)
        XCTAssertEqual(try snapshot(paths.chunksDirectory), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.sessionDirectory.path).sorted(), sessionEntriesBefore)
    }

    func testIneligibleSessionIsRejectedByReusedEligibilityCheck() throws {
        var (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [100])
        manifest.status = .interrupted
        assertLoadFails(manifest, paths, .sessionIneligible(.artifactPathValidation(.sessionNotCompleted(.interrupted))))

        manifest.status = .completed
        XCTAssertThrowsError(
            try LecturePlaybackSourceLoader.load(expectedSessionID: UUID(), manifest: manifest, sessionPaths: paths)
        ) { error in
            XCTAssertEqual(error as? LecturePlaybackSourceError, .sessionIneligible(.sessionIdentityMismatch))
        }
    }

    func testZeroChunkCompletedSessionIsExplicitlyRejectedAsNoChunks() throws {
        let (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [])
        // The lower-level contract still accepts it as a completed recording…
        XCTAssertNoThrow(try SessionTranscriptionEligibility.validate(
            expectedSessionID: manifest.sessionID, manifest: manifest, sessionPaths: paths
        ))
        // …but playback rejects it with a typed error rather than an empty timeline.
        assertLoadFails(manifest, paths, .timeline(.noChunks))
    }

    func testMissingChunkFileIsRejected() throws {
        let (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [100, 100])
        try FileManager.default.removeItem(at: chunkURL(paths, 1))
        assertLoadFails(manifest, paths, .chunkFileMissing(sequenceNumber: 1))
    }

    func testSymlinkedChunkIsRejectedWithoutFollowing() throws {
        let (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [100, 100])
        let elsewhere = root.appendingPathComponent("elsewhere.caf")
        try FileManager.default.moveItem(at: chunkURL(paths, 1), to: elsewhere)
        try FileManager.default.createSymbolicLink(at: chunkURL(paths, 1), withDestinationURL: elsewhere)
        assertLoadFails(manifest, paths, .chunkFileUnsafe(sequenceNumber: 1))
    }

    func testDirectoryAtChunkPathIsRejected() throws {
        let (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [100])
        try FileManager.default.removeItem(at: chunkURL(paths, 0))
        try FileManager.default.createDirectory(at: chunkURL(paths, 0), withIntermediateDirectories: false)
        assertLoadFails(manifest, paths, .chunkFileUnsafe(sequenceNumber: 0))
    }

    func testSymlinkedSessionDirectoryIsRejected() throws {
        let realRoot = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let (manifest, realPaths) = try PlaybackTestAudio.makeSession(root: realRoot, frameCounts: [100])
        let paths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: manifest.sessionID)
        try FileManager.default.createSymbolicLink(at: paths.sessionDirectory, withDestinationURL: realPaths.sessionDirectory)
        assertLoadFails(manifest, paths, .sessionDirectoryUnsafe)
    }

    func testSessionDirectoryIsCheckedBeforeEligibilityOrAnyDescendantAccess() throws {
        let realRoot = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        var (manifest, realPaths) = try PlaybackTestAudio.makeSession(root: realRoot, frameCounts: [100])
        let paths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: manifest.sessionID)
        try FileManager.default.createSymbolicLink(at: paths.sessionDirectory, withDestinationURL: realPaths.sessionDirectory)
        // Also ineligible: were eligibility (which inspects chunks/) run
        // first, it would report this instead.
        manifest.status = .interrupted
        assertLoadFails(manifest, paths, .sessionDirectoryUnsafe)
    }

    func testMissingSessionDirectoryIsRejectedAsUnsafe() throws {
        let manifest = PlaybackTestManifest.make(frameCounts: [100])
        let paths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: manifest.sessionID)
        assertLoadFails(manifest, paths, .sessionDirectoryUnsafe)
    }

    func testUnreadableAudioIsRejected() throws {
        let (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [100, 100])
        try Data("not audio".utf8).write(to: chunkURL(paths, 1))
        assertLoadFails(manifest, paths, .chunkAudioUnreadable(sequenceNumber: 1))
    }

    func testPersistedFrameCountMismatchIsRejected() throws {
        var (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [100, 100])
        manifest.chunks[1].frameCount = 101
        assertLoadFails(manifest, paths, .chunkFrameCountMismatch(sequenceNumber: 1))
    }

    func testSampleRateMismatchIsRejected() throws {
        let (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [100, 100])
        try FileManager.default.removeItem(at: chunkURL(paths, 1))
        try PlaybackTestAudio.writeChunk(to: chunkURL(paths, 1), frameCount: 100, firstSessionFrame: 100, sampleRate: 48_000)
        assertLoadFails(manifest, paths, .chunkFormatMismatch(sequenceNumber: 1))
    }

    func testChannelCountMismatchIsRejected() throws {
        let (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [100])
        try FileManager.default.removeItem(at: chunkURL(paths, 0))
        try PlaybackTestAudio.writeChunk(to: chunkURL(paths, 0), frameCount: 100, firstSessionFrame: 0, channelCount: 2)
        assertLoadFails(manifest, paths, .chunkFormatMismatch(sequenceNumber: 0))
    }

    func testZeroChannelCountIsRejected() throws {
        var (manifest, paths) = try PlaybackTestAudio.makeSession(root: root, frameCounts: [100])
        manifest.audioFormat.channelCount = 0
        assertLoadFails(manifest, paths, .invalidChannelCount)
    }
}
