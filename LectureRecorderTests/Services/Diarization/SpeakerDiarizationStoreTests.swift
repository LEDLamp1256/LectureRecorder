import XCTest
@testable import LectureRecorder

final class SpeakerDiarizationStoreTests: XCTestCase {
    private typealias F = DiarizationTestFixtures

    private var root: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!
    private var source: LecturePlaybackSource!
    private let store = SpeakerDiarizationStore()

    private var diarizationDirectory: URL { DiarizationArtifactPaths.directory(sessionPaths: sessionPaths) }
    private var resultURL: URL { DiarizationArtifactPaths.resultURL(sessionPaths: sessionPaths) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerDiarizationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sessionID = UUID()
        sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: sessionID)
        source = try F.source(sessionID: sessionID)
    }

    override func tearDownWithError() throws {
        if let root {
            // Restore permissions changed by a test before removal.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: diarizationDirectory.path)
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func validResult(_ ranges: [SpeakerTimeRange]? = nil) throws -> SpeakerDiarizationResult {
        try F.result(source: source, ranges: ranges ?? [try F.range(0, 0, 4.5), try F.range(1, 4, 9)])
    }

    /// Writes `value` to the sidecar path, bypassing the store's checks.
    private func writeRaw<T: Encodable>(_ value: T) throws {
        try AtomicFileWriter.writeJSON(value, to: resultURL)
    }

    private func writeRaw(_ data: Data) throws {
        try FileManager.default.createDirectory(at: diarizationDirectory, withIntermediateDirectories: true)
        try data.write(to: resultURL)
    }

    private func assertSaveFails(
        _ result: SpeakerDiarizationResult,
        source: LecturePlaybackSource? = nil,
        sessionPaths: SessionPaths? = nil,
        _ expected: SpeakerDiarizationStoreError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try store.save(result, source: source ?? self.source, sessionPaths: sessionPaths ?? self.sessionPaths),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? SpeakerDiarizationStoreError, expected, file: file, line: line)
        }
    }

    // MARK: - Absent / round trip

    func testMissingSidecarIsAbsentAndLoadingCreatesNothing() throws {
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diarizationDirectory.path))

        try FileManager.default.createDirectory(at: diarizationDirectory, withIntermediateDirectories: false)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .absent)
    }

    func testSaveThenLoadRoundTripsAtTheSidecarPath() throws {
        let result = try validResult()
        try store.save(result, source: source, sessionPaths: sessionPaths)

        XCTAssertEqual(resultURL.path, sessionPaths.sessionDirectory.path + "/diarization/result.json")
        XCTAssertEqual(CompletedSessionPathSafety.checkExistingRegularFile(resultURL), .safe)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .loaded(result))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: diarizationDirectory.path), ["result.json"],
                       "no temporary files or generations directory")
    }

    func testSaveReplacesAnExistingResultAtomically() throws {
        try store.save(try validResult(), source: source, sessionPaths: sessionPaths)
        let replacement = try F.result(source: source, ranges: [try F.range(0, 10, 20)], createdDate: F.createdDate.addingTimeInterval(60))
        try store.save(replacement, source: source, sessionPaths: sessionPaths)

        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .loaded(replacement))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: diarizationDirectory.path), ["result.json"])
    }

    // MARK: - Unavailable outcomes

    func testCorruptSidecarIsUnavailableAndLeftInPlace() throws {
        for bytes in [Data(), Data("{not json".utf8), Data(#"{"schemaVersion":1}"#.utf8), Data("[]".utf8)] {
            try writeRaw(bytes)
            XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.corrupt))
            XCTAssertEqual(try Data(contentsOf: resultURL), bytes, "never deleted or repaired")
        }
    }

    func testUnsupportedSchemaIsUnavailable() throws {
        try writeRaw(Data(#"{"schemaVersion":2,"somethingNew":true}"#.utf8))
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.unsupportedSchemaVersion(2)))
    }

    func testInvalidRangesAreUnavailable() throws {
        var reversed = try validResult()
        reversed.ranges = [try F.range(0, 5, 4)]
        try writeRaw(reversed)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.invalidResult(.emptyOrReversedRange(index: 0))))

        var overlapping = try validResult()
        overlapping.ranges = [try F.range(0, 0, 5), try F.range(0, 4, 6)]
        try writeRaw(overlapping)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.invalidResult(.overlappingSameSpeaker(index: 1))))

        var beyond = try validResult()
        beyond.ranges = [try F.range(0, 60, 71)]
        try writeRaw(beyond)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.invalidResult(.rangeBeyondAudio(index: 0))))
    }

    func testMalformedSpeakerIDIsAnInvalidResult() throws {
        let json = String(decoding: try AtomicFileWriter.defaultEncoder.encode(try validResult()), as: UTF8.self)
            .replacingOccurrences(of: "speaker_1", with: "Speaker 2")
        try writeRaw(Data(json.utf8))
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.invalidResult(.invalidSpeakerID)))
    }

    func testAnotherSessionsResultIsUnavailable() throws {
        let other = try F.result(source: try F.source(), ranges: [try F.range(0, 0, 1)])
        try writeRaw(other)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.sessionMismatch))
    }

    func testResultFromDifferentAudioIsUnavailable() throws {
        // Same session and an in-bounds range, but one chunk's frame count differs.
        let stale = try F.result(source: try F.source(sessionID: sessionID, frameCounts: [480_000, 480_001, 160_000]), ranges: [try F.range(0, 0, 1)])
        try writeRaw(stale)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.audioSourceMismatch))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "stale results are never auto-deleted")

        let otherFormat = try F.source(sessionID: sessionID, channelCount: 2)
        try store.save(try F.result(source: otherFormat, ranges: []), source: otherFormat, sessionPaths: sessionPaths)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.audioSourceMismatch))
    }

    // MARK: - Path safety

    func testSymlinkedOrWrongTypeSidecarPathsAreUnavailableAndRefused() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent("result.json")
        try AtomicFileWriter.writeJSON(try validResult(), to: target)
        let targetBytes = try Data(contentsOf: target)

        // diarization/ is a symlink to a directory holding a valid result.
        try FileManager.default.createSymbolicLink(at: diarizationDirectory, withDestinationURL: elsewhere)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.unsafePath))
        assertSaveFails(try validResult([]), .unsafeSidecarPath)
        try FileManager.default.removeItem(at: diarizationDirectory)

        // diarization/ is a regular file.
        try Data().write(to: diarizationDirectory)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.unsafePath))
        assertSaveFails(try validResult([]), .unsafeSidecarPath)
        try FileManager.default.removeItem(at: diarizationDirectory)

        // result.json is a symlink to a valid result.
        try FileManager.default.createDirectory(at: diarizationDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: resultURL, withDestinationURL: target)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.unsafePath))
        assertSaveFails(try validResult([]), .unsafeSidecarPath)
        try FileManager.default.removeItem(at: resultURL)

        // result.json is a directory.
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: false)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .unavailable(.unsafePath))
        assertSaveFails(try validResult([]), .unsafeSidecarPath)

        XCTAssertEqual(try Data(contentsOf: target), targetBytes, "a symlink target is never written through")
    }

    func testMissingSymlinkedOrMismatchedSessionDirectoryIsNeverCreatedOrUsed() throws {
        // Paths for a different session ID.
        let otherPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: UUID())
        XCTAssertEqual(store.load(source: source, sessionPaths: otherPaths), .unavailable(.unsafePath))
        assertSaveFails(try validResult(), sessionPaths: otherPaths, .sessionMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherPaths.sessionDirectory.path))

        // The session directory is missing.
        let missingRoot = root.appendingPathComponent("missing", isDirectory: true)
        let missingPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: missingRoot, sessionID: sessionID)
        XCTAssertEqual(store.load(source: source, sessionPaths: missingPaths), .unavailable(.unsafePath))
        assertSaveFails(try validResult(), sessionPaths: missingPaths, .sessionDirectoryUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path), "never creates a session root")

        // The session directory is a symlink to a real session directory.
        let linkRoot = root.appendingPathComponent("links", isDirectory: true)
        try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        let linkPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: linkRoot, sessionID: sessionID)
        try FileManager.default.createSymbolicLink(at: linkPaths.sessionDirectory, withDestinationURL: sessionPaths.sessionDirectory)
        try store.save(try validResult(), source: source, sessionPaths: sessionPaths)
        XCTAssertEqual(store.load(source: source, sessionPaths: linkPaths), .unavailable(.unsafePath))
        assertSaveFails(try validResult([]), sessionPaths: linkPaths, .sessionDirectoryUnavailable)
    }

    // MARK: - Failed saves preserve the prior result

    func testRejectedSavesLeaveThePriorResultByteIdentical() throws {
        let prior = try validResult()
        try store.save(prior, source: source, sessionPaths: sessionPaths)
        let priorBytes = try Data(contentsOf: resultURL)

        var invalid = prior
        invalid.ranges = [try F.range(0, 3, 1)]
        assertSaveFails(invalid, .invalidResult(.emptyOrReversedRange(index: 0)))

        var beyond = prior
        beyond.ranges = [try F.range(0, 69, 70.5)]
        assertSaveFails(beyond, .invalidResult(.rangeBeyondAudio(index: 0)))

        let otherSession = try F.result(source: try F.source(), ranges: [])
        assertSaveFails(otherSession, .sessionMismatch)

        let staleAudio = try F.result(source: try F.source(sessionID: sessionID, sampleRate: 48_000), ranges: [])
        assertSaveFails(staleAudio, .audioSourceMismatch)

        XCTAssertEqual(try Data(contentsOf: resultURL), priorBytes)
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .loaded(prior))
    }

    func testWriteFailureLeavesThePriorResultIntact() throws {
        let prior = try validResult()
        try store.save(prior, source: source, sessionPaths: sessionPaths)
        let priorBytes = try Data(contentsOf: resultURL)

        // A read-only diarization/ makes the atomic writer fail to create its
        // temporary file, before any replacement.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: diarizationDirectory.path)
        XCTAssertThrowsError(try store.save(try validResult([try F.range(0, 1, 2)]), source: source, sessionPaths: sessionPaths))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: diarizationDirectory.path)

        XCTAssertEqual(try Data(contentsOf: resultURL), priorBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: diarizationDirectory.path), ["result.json"])
        XCTAssertEqual(store.load(source: source, sessionPaths: sessionPaths), .loaded(prior))
    }

    // MARK: - Isolation from other session artifacts

    func testSavingTouchesNothingOutsideTheDiarizationDirectory() throws {
        let manifest = PlaybackTestManifest.make(sessionID: sessionID, sampleRate: 16_000, frameCounts: [480_000, 480_000, 160_000])
        try AtomicFileWriter.writeJSON(manifest, to: sessionPaths.manifestURL)
        let others: [URL] = [
            sessionPaths.sessionDirectory.appendingPathComponent("transcription/results/chunk_000000.json"),
            sessionPaths.sessionDirectory.appendingPathComponent("notes/generations/x/document.json"),
            sessionPaths.chunksDirectory.appendingPathComponent("chunk_000000.caf"),
        ]
        for url in others {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original \(url.lastPathComponent)".utf8).write(to: url)
        }
        let before = try snapshot(excluding: diarizationDirectory)

        try store.save(try validResult(), source: source, sessionPaths: sessionPaths)
        _ = store.load(source: source, sessionPaths: sessionPaths)

        XCTAssertEqual(try snapshot(excluding: diarizationDirectory), before)
        XCTAssertEqual(try AtomicFileWriter.readJSON(SessionManifest.self, from: sessionPaths.manifestURL), manifest)
    }

    /// Relative path → bytes for every regular file in the session.
    private func snapshot(excluding excluded: URL) throws -> [String: Data] {
        let base = sessionPaths.sessionDirectory.resolvingSymlinksInPath().path
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sessionPaths.sessionDirectory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator {
            let path = url.resolvingSymlinksInPath().path
            guard !path.hasPrefix(excluded.resolvingSymlinksInPath().path),
                  (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            files[String(path.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return files
    }
}
