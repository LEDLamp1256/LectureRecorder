import XCTest
@testable import LectureRecorder

final class TranscriptionArtifactPathsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionArtifactPathsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeAudioFormat() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
    }

    private func makeCompletedManifest(sessionID: UUID, chunkCount: Int) -> SessionManifest {
        var manifest = SessionManifest.newSession(
            id: sessionID,
            audioFormat: makeAudioFormat(),
            targetChunkDurationSeconds: 30
        )
        manifest.status = .completed
        manifest.endedCleanly = true
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

    func testValidatedAcceptsWellFormedCompletedManifest() throws {
        let sessionID = UUID()
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        let manifest = makeCompletedManifest(sessionID: sessionID, chunkCount: 3)
        let result = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: paths)
        XCTAssertEqual(result.sessionID, sessionID)
        XCTAssertEqual(result.jobsDirectory.lastPathComponent, "jobs")
        XCTAssertEqual(result.resultsDirectory.lastPathComponent, "results")
    }

    func testValidatedAcceptsEmptyChunkList() throws {
        let sessionID = UUID()
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        let manifest = makeCompletedManifest(sessionID: sessionID, chunkCount: 0)
        XCTAssertNoThrow(try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: paths))
    }

    func testValidatedRejectsNonCompletedManifest() throws {
        let sessionID = UUID()
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        var manifest = makeCompletedManifest(sessionID: sessionID, chunkCount: 1)
        manifest.status = .failed
        XCTAssertThrowsError(try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: paths)) { error in
            guard case TranscriptionArtifactPaths.ValidationError.sessionNotCompleted = error else {
                return XCTFail("Expected sessionNotCompleted, got \(error)")
            }
        }
    }

    func testValidatedRejectsMismatchedSessionPaths() throws {
        let sessionID = UUID()
        let otherSessionID = UUID()
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: otherSessionID)
        let manifest = makeCompletedManifest(sessionID: sessionID, chunkCount: 1)
        XCTAssertThrowsError(try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: paths)) { error in
            guard case TranscriptionArtifactPaths.ValidationError.pathSessionMismatch = error else {
                return XCTFail("Expected pathSessionMismatch, got \(error)")
            }
        }
    }

    func testValidatedRejectsUnexpectedPathTopology() throws {
        let sessionID = UUID()
        let sessionDirectory = tempDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let badPaths = SessionPaths(
            sessionDirectory: sessionDirectory,
            chunksDirectory: tempDirectory.appendingPathComponent("elsewhere", isDirectory: true),
            logsDirectory: sessionDirectory.appendingPathComponent("logs", isDirectory: true),
            manifestURL: sessionDirectory.appendingPathComponent("session.json"),
            logFileURL: sessionDirectory.appendingPathComponent("logs/recording.log")
        )
        let manifest = makeCompletedManifest(sessionID: sessionID, chunkCount: 0)
        XCTAssertThrowsError(try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: badPaths)) { error in
            guard case TranscriptionArtifactPaths.ValidationError.unexpectedPathTopology = error else {
                return XCTFail("Expected unexpectedPathTopology, got \(error)")
            }
        }
    }

    func testValidatedRejectsNonContiguousSequence() throws {
        let sessionID = UUID()
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        var manifest = makeCompletedManifest(sessionID: sessionID, chunkCount: 2)
        manifest.chunks[1].sequenceNumber = 5
        XCTAssertThrowsError(try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: paths)) { error in
            guard case TranscriptionArtifactPaths.ValidationError.nonContiguousChunkSequence = error else {
                return XCTFail("Expected nonContiguousChunkSequence, got \(error)")
            }
        }
    }

    func testValidatedRejectsDuplicateSequenceNumbers() throws {
        let sessionID = UUID()
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        var manifest = makeCompletedManifest(sessionID: sessionID, chunkCount: 2)
        manifest.chunks[1].sequenceNumber = 0
        XCTAssertThrowsError(try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: paths)) { error in
            guard case TranscriptionArtifactPaths.ValidationError.nonContiguousChunkSequence = error else {
                return XCTFail("Expected nonContiguousChunkSequence, got \(error)")
            }
        }
    }

    func testValidatedRejectsNonCanonicalFileNameForItsOwnSequence() throws {
        let sessionID = UUID()
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        var manifest = makeCompletedManifest(sessionID: sessionID, chunkCount: 3)
        // Sequence 2 claims sequence 5's canonical-looking filename — this
        // must be rejected even though it matches the general chunk_%06d
        // pattern, since it doesn't match *its own* sequence number.
        manifest.chunks[2].fileName = "chunk_000005.caf"
        XCTAssertThrowsError(try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: paths)) { error in
            guard case TranscriptionArtifactPaths.ValidationError.nonCanonicalChunkFileName(let seq, _) = error else {
                return XCTFail("Expected nonCanonicalChunkFileName, got \(error)")
            }
            XCTAssertEqual(seq, 2)
        }
    }

    func testCanonicalJobAndResultURLsUseZeroPaddedSequence() throws {
        let sessionID = UUID()
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
        let manifest = makeCompletedManifest(sessionID: sessionID, chunkCount: 1)
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: paths)
        XCTAssertEqual(artifactPaths.jobURL(sequenceNumber: 0).lastPathComponent, "chunk_000000.job.json")
        XCTAssertEqual(artifactPaths.resultURL(sequenceNumber: 0).lastPathComponent, "chunk_000000.transcript.json")
    }
}
