import AVFoundation
import XCTest
@testable import LectureRecorder

/// A `ChunkFinalizationFileSystem` that delegates to the real Darwin
/// implementation but always reports a rename collision.
private struct CollidingRenameFileSystem: ChunkFinalizationFileSystem {
    let real = DarwinChunkFinalizationFileSystem()

    func synchronizeFile(at url: URL) throws { try real.synchronizeFile(at: url) }
    func synchronizeDirectory(at url: URL) throws { try real.synchronizeDirectory(at: url) }
    func rename(from source: URL, to destination: URL) throws {
        throw ChunkRenameCollision(destination: destination)
    }
}

/// A `ChunkFinalizationFileSystem` that delegates to the real Darwin
/// implementation but fails file and/or directory synchronization.
private struct FailingSyncFileSystem: ChunkFinalizationFileSystem {
    let real = DarwinChunkFinalizationFileSystem()
    var failFileSync = false
    var failDirectorySync = false

    private struct InjectedSyncFailure: Error {}

    func synchronizeFile(at url: URL) throws {
        if failFileSync { throw InjectedSyncFailure() }
        try real.synchronizeFile(at: url)
    }
    func synchronizeDirectory(at url: URL) throws {
        if failDirectorySync { throw InjectedSyncFailure() }
        try real.synchronizeDirectory(at: url)
    }
    func rename(from source: URL, to destination: URL) throws {
        try real.rename(from: source, to: destination)
    }
}

/// T7-B: launch-time recovery of abandoned `.recording` sessions. Every
/// fixture is synthetic, tiny (8 kHz, 80 frames per chunk) and lives in its
/// own temporary sessions root.
final class AbandonedRecordingRecoveryTests: XCTestCase {
    private static let sampleRate: Double = 8_000
    private static let chunkSeconds: Double = 0.01
    private static let framesPerChunk = 80

    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AbandonedRecordingRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Sessions", isDirectory: true)
        outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixture helpers

    private var format: AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: Self.sampleRate, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
    }

    private func recovery(
        bootTime: Date? = .distantPast,
        fileSystem: any ChunkFinalizationFileSystem = DarwinChunkFinalizationFileSystem()
    ) -> AbandonedRecordingRecovery {
        let root = self.root!
        return AbandonedRecordingRecovery(
            sessionsRootResolver: { root },
            bootTimeProvider: { bootTime },
            fileSystem: fileSystem
        )
    }

    private func chunkURL(_ paths: SessionPaths, _ sequence: Int, partial: Bool = false) -> URL {
        paths.chunksDirectory.appendingPathComponent(
            partial
                ? AbandonedRecordingRecovery.partialChunkFileName(for: sequence)
                : TranscriptionArtifactPaths.canonicalChunkFileName(for: sequence)
        )
    }

    /// Writes a float32 non-interleaved CAF of `frameCount` frames.
    private func writeAudio(
        to url: URL,
        frameCount: Int,
        sampleRate: Double = AbandonedRecordingRecoveryTests.sampleRate,
        sample: (Int) -> Float = { Float($0 % 50) / 100 }
    ) throws {
        let avFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ))
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: avFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            if frameCount > 0 {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)))
                buffer.frameLength = AVAudioFrameCount(frameCount)
                let channel = try XCTUnwrap(buffer.floatChannelData)[0]
                for index in 0..<frameCount { channel[index] = sample(index) }
                try file.write(from: buffer)
            }
            file.close()
        }
    }

    private func metadata(_ sequence: Int, frames: Int = AbandonedRecordingRecoveryTests.framesPerChunk, startFrame: Int) -> ChunkMetadata {
        ChunkMetadata(
            sequenceNumber: sequence,
            fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequence),
            startOffsetSeconds: Double(startFrame) / Self.sampleRate,
            durationSeconds: Double(frames) / Self.sampleRate,
            frameCount: frames,
            state: .completed
        )
    }

    /// Creates a session directory whose manifest references `referenced`
    /// full chunks (all written to disk), with `status`.
    @discardableResult
    private func makeSession(
        status: SessionStatus = .recording,
        referenced: Int,
        sessionID: UUID = UUID(),
        manifestSessionID: UUID? = nil,
        schemaVersion: Int = SessionManifest.currentSchemaVersion
    ) throws -> (manifest: SessionManifest, paths: SessionPaths) {
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: sessionID)
        var manifest = SessionManifest.newSession(
            id: manifestSessionID ?? sessionID,
            audioFormat: format,
            targetChunkDurationSeconds: Self.chunkSeconds
        )
        manifest.schemaVersion = schemaVersion
        manifest.status = status
        if status != .recording {
            manifest.endDate = Date()
            manifest.endReason = status == .completed ? .userStopped : .error
            manifest.endedCleanly = status == .completed
        }
        for sequence in 0..<referenced {
            try writeAudio(to: chunkURL(paths, sequence), frameCount: Self.framesPerChunk)
            manifest.chunks.append(metadata(sequence, startFrame: sequence * Self.framesPerChunk))
        }
        try AtomicFileWriter.writeJSON(manifest, to: paths.manifestURL)
        return (manifest, paths)
    }

    private func readManifest(_ paths: SessionPaths) throws -> SessionManifest {
        try AtomicFileWriter.readJSON(SessionManifest.self, from: paths.manifestURL)
    }

    private func chunkDirectoryListing(_ paths: SessionPaths) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.chunksDirectory.path).sorted()
    }

    private func assertInterruptedFields(_ manifest: SessionManifest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(manifest.status, .interrupted, file: file, line: line)
        XCTAssertEqual(manifest.endReason, .unknown, file: file, line: line)
        XCTAssertFalse(manifest.endedCleanly, file: file, line: line)
        XCTAssertNil(manifest.endDate, file: file, line: line)
        XCTAssertNil(manifest.failureDescription, file: file, line: line)
    }

    // MARK: - Canonical recovery

    func testRecordingManifestWithValidReferencedChunksBecomesInterrupted() throws {
        let (_, paths) = try makeSession(referenced: 2)
        // The persisted form (dates round-trip at millisecond precision).
        let original = try readManifest(paths)

        let report = recovery().recoverAbandonedRecordings()

        let recovered = try readManifest(paths)
        assertInterruptedFields(recovered)
        XCTAssertEqual(recovered.chunks, original.chunks)
        XCTAssertEqual(recovered.creationDate, original.creationDate)
        XCTAssertEqual(report.recovered.count, 1)
        XCTAssertEqual(report.recovered.first?.referencedChunksIntact, true)
        XCTAssertEqual(report.recovered.first?.adoptedCanonicalChunkCount, 0)
        XCTAssertEqual(report.recovered.first?.tail, AbandonedRecordingRecoveryReport.TailOutcome.none)
    }

    func testValidUnreferencedNextCanonicalChunkIsAdoptedWithWriterMetadata() throws {
        let (_, paths) = try makeSession(referenced: 2)
        try writeAudio(to: chunkURL(paths, 2), frameCount: Self.framesPerChunk)

        let report = recovery().recoverAbandonedRecordings()

        let recovered = try readManifest(paths)
        XCTAssertEqual(recovered.chunks.count, 3)
        XCTAssertEqual(recovered.chunks[2], metadata(2, startFrame: 2 * Self.framesPerChunk))
        XCTAssertEqual(report.recovered.first?.adoptedCanonicalChunkCount, 1)
    }

    func testMultipleContiguousUnreferencedCanonicalChunksAreAllAdopted() throws {
        let (_, paths) = try makeSession(referenced: 5)
        try writeAudio(to: chunkURL(paths, 5), frameCount: Self.framesPerChunk)
        try writeAudio(to: chunkURL(paths, 6), frameCount: Self.framesPerChunk)
        try writeAudio(to: chunkURL(paths, 7), frameCount: 30)

        let report = recovery().recoverAbandonedRecordings()

        let recovered = try readManifest(paths)
        XCTAssertEqual(recovered.chunks.map(\.sequenceNumber), Array(0...7))
        XCTAssertEqual(recovered.chunks[5], metadata(5, startFrame: 5 * Self.framesPerChunk))
        XCTAssertEqual(recovered.chunks[6], metadata(6, startFrame: 6 * Self.framesPerChunk))
        XCTAssertEqual(recovered.chunks[7], metadata(7, frames: 30, startFrame: 7 * Self.framesPerChunk))
        XCTAssertEqual(report.recovered.first?.adoptedCanonicalChunkCount, 3)
    }

    func testSequenceGapStopsAdoptionAndLeavesLaterFilesUntouched() throws {
        let (_, paths) = try makeSession(referenced: 2)
        let later = chunkURL(paths, 3)
        try writeAudio(to: later, frameCount: Self.framesPerChunk)
        let laterBytes = try Data(contentsOf: later)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 2)
        XCTAssertEqual(try Data(contentsOf: later), laterBytes)
    }

    func testMalformedCanonicalChunkIsNotAdoptedAndStopsTheRun() throws {
        let (_, paths) = try makeSession(referenced: 2)
        let malformed = chunkURL(paths, 2)
        try Data("not audio".utf8).write(to: malformed)
        try writeAudio(to: chunkURL(paths, 3), frameCount: Self.framesPerChunk)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 2)
        XCTAssertEqual(try Data(contentsOf: malformed), Data("not audio".utf8))
    }

    func testFormatMismatchedCanonicalChunkIsNotAdopted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1), frameCount: Self.framesPerChunk, sampleRate: 16_000)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
    }

    func testOversizedCanonicalChunkIsNotAdopted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1), frameCount: Self.framesPerChunk + 1)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
    }

    func testShortNonFinalCanonicalChunkStopsAdoption() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1), frameCount: 30)
        try writeAudio(to: chunkURL(paths, 2), frameCount: Self.framesPerChunk)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1, "a short chunk followed by more audio is ambiguous")
    }

    func testSymlinkedCanonicalChunkIsNotAdopted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        let target = outside.appendingPathComponent("elsewhere.caf")
        try writeAudio(to: target, frameCount: Self.framesPerChunk)
        try FileManager.default.createSymbolicLink(at: chunkURL(paths, 1), withDestinationURL: target)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
    }

    func testUnrelatedFilesAreIgnoredAndUntouched() throws {
        let (_, paths) = try makeSession(referenced: 1)
        let unrelated = ["notes.txt", "chunk_1.caf", "chunk_0000001.caf", "chunk_00000a.caf", ".hidden.caf"]
        for name in unrelated {
            try Data(name.utf8).write(to: paths.chunksDirectory.appendingPathComponent(name))
        }
        let before = try chunkDirectoryListing(paths)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertEqual(try chunkDirectoryListing(paths), before)
        for name in unrelated {
            XCTAssertEqual(try Data(contentsOf: paths.chunksDirectory.appendingPathComponent(name)), Data(name.utf8))
        }
    }

    func testMissingReferencedChunkAdoptsNothingPromotesNothingButMarksInterrupted() throws {
        let (original, paths) = try makeSession(referenced: 3)
        try FileManager.default.removeItem(at: chunkURL(paths, 1))
        try writeAudio(to: chunkURL(paths, 3), frameCount: Self.framesPerChunk)
        try writeAudio(to: chunkURL(paths, 4, partial: true), frameCount: 20)

        let report = recovery().recoverAbandonedRecordings()

        let recovered = try readManifest(paths)
        assertInterruptedFields(recovered)
        XCTAssertEqual(recovered.chunks, original.chunks, "the existing chunk list is never altered")
        XCTAssertEqual(report.recovered.first?.referencedChunksIntact, false)
        XCTAssertEqual(report.recovered.first?.adoptedCanonicalChunkCount, 0)
        XCTAssertEqual(report.recovered.first?.tail, AbandonedRecordingRecoveryReport.TailOutcome.none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 4).path))
    }

    func testMismatchedReferencedChunkLeavesChunkListUnchanged() throws {
        let (original, paths) = try makeSession(referenced: 2)
        try FileManager.default.removeItem(at: chunkURL(paths, 1))
        try writeAudio(to: chunkURL(paths, 1), frameCount: 40)
        try writeAudio(to: chunkURL(paths, 2), frameCount: Self.framesPerChunk)

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks, original.chunks)
        XCTAssertEqual(report.recovered.first?.referencedChunksIntact, false)
    }

    func testRecoveredManifestIsPublishedAtomically() throws {
        let (_, paths) = try makeSession(referenced: 1)

        recovery().recoverAbandonedRecordings()

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.sessionDirectory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertNoThrow(try readManifest(paths))
    }

    func testRecoveryIsIdempotent() throws {
        let (_, paths) = try makeSession(referenced: 2)
        try writeAudio(to: chunkURL(paths, 2), frameCount: Self.framesPerChunk)
        recovery().recoverAbandonedRecordings()
        let manifestBytes = try Data(contentsOf: paths.manifestURL)
        let listing = try chunkDirectoryListing(paths)

        let second = recovery().recoverAbandonedRecordings()

        XCTAssertTrue(second.recovered.isEmpty)
        XCTAssertTrue(second.skipped.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), manifestBytes)
        XCTAssertEqual(try chunkDirectoryListing(paths), listing)
    }

    func testCompletedFailedInterruptedAndImportedSessionsAreNeverMutated() throws {
        var untouched: [(SessionPaths, Data, [String])] = []
        for status in [SessionStatus.completed, .failed, .interrupted] {
            let (_, paths) = try makeSession(status: status, referenced: 1)
            // Extra canonical and partial files must not be adopted for a
            // terminal session either.
            try writeAudio(to: chunkURL(paths, 1), frameCount: Self.framesPerChunk)
            try writeAudio(to: chunkURL(paths, 2, partial: true), frameCount: 10)
            untouched.append((paths, try Data(contentsOf: paths.manifestURL), try chunkDirectoryListing(paths)))
        }
        // An imported session: completed, no logs, never a `.recording`.
        let (_, imported) = try makeSession(status: .completed, referenced: 2)
        try? FileManager.default.removeItem(at: imported.logsDirectory)
        untouched.append((imported, try Data(contentsOf: imported.manifestURL), try chunkDirectoryListing(imported)))

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertTrue(report.recovered.isEmpty)
        for (paths, manifestBytes, listing) in untouched {
            XCTAssertEqual(try Data(contentsOf: paths.manifestURL), manifestBytes)
            XCTAssertEqual(try chunkDirectoryListing(paths), listing)
        }
    }

    func testLiveLockedRecordingIsSkippedUntouched() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1), frameCount: Self.framesPerChunk)
        guard case .acquired(let liveOwner) = SessionDirectoryLock.tryAcquire(directory: paths.sessionDirectory) else {
            return XCTFail("fixture lock")
        }
        defer { liveOwner.release() }
        let manifestBytes = try Data(contentsOf: paths.manifestURL)

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertTrue(report.recovered.isEmpty)
        XCTAssertEqual(report.skipped, [.init(directoryName: paths.sessionDirectory.lastPathComponent, reason: .liveOwner)])
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), manifestBytes)
    }

    func testIdentityMismatchedManifestIsSkippedUntouched() throws {
        let (_, paths) = try makeSession(referenced: 1, manifestSessionID: UUID())
        let manifestBytes = try Data(contentsOf: paths.manifestURL)

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertEqual(report.skipped.map(\.reason), [.identityMismatch])
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), manifestBytes)
    }

    func testUnsupportedSchemaManifestIsSkippedUntouched() throws {
        let (_, paths) = try makeSession(referenced: 1, schemaVersion: 99)
        let manifestBytes = try Data(contentsOf: paths.manifestURL)

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertEqual(report.skipped.map(\.reason), [.unsupportedSchema(99)])
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), manifestBytes)
    }

    func testSymlinkedSessionDirectoryIsSkippedAndTargetUntouched() throws {
        let sessionID = UUID()
        let realPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: outside, sessionID: sessionID)
        let manifest = SessionManifest.newSession(id: sessionID, audioFormat: format, targetChunkDurationSeconds: Self.chunkSeconds)
        try AtomicFileWriter.writeJSON(manifest, to: realPaths.manifestURL)
        let manifestBytes = try Data(contentsOf: realPaths.manifestURL)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(sessionID.uuidString),
            withDestinationURL: realPaths.sessionDirectory
        )

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertTrue(report.recovered.isEmpty)
        XCTAssertEqual(report.skipped.map(\.reason), [.unsafeSessionDirectory])
        XCTAssertEqual(try Data(contentsOf: realPaths.manifestURL), manifestBytes)
    }

    func testCorruptManifestIsLeftUntouched() throws {
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: UUID())
        try Data("{ not json".utf8).write(to: paths.manifestURL)

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertTrue(report.recovered.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), Data("{ not json".utf8))
    }

    func testZeroChunkAbandonedRecordingBecomesInterrupted() throws {
        let (_, paths) = try makeSession(referenced: 0)

        recovery().recoverAbandonedRecordings()

        let recovered = try readManifest(paths)
        assertInterruptedFields(recovered)
        XCTAssertTrue(recovered.chunks.isEmpty)
    }

    func testRecoveryAppendsAContentFreeLogLine() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try Data("2026-01-01T00:00:00Z [INFO] Session created.\n".utf8).write(to: paths.logFileURL)

        recovery().recoverAbandonedRecordings()

        let log = try String(contentsOf: paths.logFileURL, encoding: .utf8)
        XCTAssertTrue(log.hasPrefix("2026-01-01T00:00:00Z [INFO] Session created.\n"))
        XCTAssertTrue(log.contains("Abandoned recording recovered at launch as interrupted"))
    }

    // MARK: - Partial tail

    func testValidSameBootPartialTailIsPromotedAndOriginalStaysByteIdentical() throws {
        let (_, paths) = try makeSession(referenced: 2)
        let partial = chunkURL(paths, 2, partial: true)
        try writeAudio(to: partial, frameCount: 37)
        let partialBytes = try Data(contentsOf: partial)

        let report = recovery().recoverAbandonedRecordings()

        let recovered = try readManifest(paths)
        assertInterruptedFields(recovered)
        XCTAssertEqual(recovered.chunks.count, 3)
        XCTAssertEqual(recovered.chunks[2], metadata(2, frames: 37, startFrame: 2 * Self.framesPerChunk))
        XCTAssertEqual(report.recovered.first?.tail, .promoted(sequenceNumber: 2, frameCount: 37))
        XCTAssertEqual(AbandonedRecordingRecovery.validatedFrameCount(at: chunkURL(paths, 2), format: format), 37)
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes, "the original partial is never modified")
        XCTAssertFalse(try chunkDirectoryListing(paths).contains { $0.hasPrefix(".") }, "no temporary copy is left behind")
        // The promoted audio is the partial's audio.
        let copy = try AVAudioFile(forReading: chunkURL(paths, 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: copy.processingFormat, frameCapacity: 37))
        try copy.read(into: buffer, frameCount: 37)
        XCTAssertEqual(buffer.floatChannelData?[0][10], Float(10) / 100)
    }

    func testPromotedTailFollowsAdoptedCanonicalChunks() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1), frameCount: Self.framesPerChunk)
        try writeAudio(to: chunkURL(paths, 2, partial: true), frameCount: 12)

        recovery().recoverAbandonedRecordings()

        let recovered = try readManifest(paths)
        XCTAssertEqual(recovered.chunks.map(\.sequenceNumber), [0, 1, 2])
        XCTAssertEqual(recovered.chunks[2], metadata(2, frames: 12, startFrame: 2 * Self.framesPerChunk))
    }

    func testZeroFramePartialIsNotPromoted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1, partial: true), frameCount: 0)

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 1).path))
        guard case .preserved = report.recovered.first?.tail else {
            return XCTFail("expected the partial to be preserved, got \(String(describing: report.recovered.first?.tail))")
        }
    }

    func testHeaderTruncatedPartialIsNotPromoted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        let source = outside.appendingPathComponent("source.caf")
        try writeAudio(to: source, frameCount: 50)
        let partial = chunkURL(paths, 1, partial: true)
        try Data(contentsOf: source).prefix(2_000).write(to: partial)
        let partialBytes = try Data(contentsOf: partial)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 1).path))
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
    }

    func testFormatMismatchedPartialIsNotPromoted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1, partial: true), frameCount: 20, sampleRate: 16_000)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 1).path))
    }

    func testOversizedPartialIsNotPromoted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1, partial: true), frameCount: Self.framesPerChunk + 1)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 1).path))
    }

    func testPartialForUnexpectedSequenceIsNotPromoted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 3, partial: true), frameCount: 20)

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 3).path))
        guard case .preserved(3, _) = report.recovered.first?.tail else {
            return XCTFail("expected partial #3 to be preserved")
        }
    }

    func testNonFiniteSamplePartialIsNotPromoted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        let partial = chunkURL(paths, 1, partial: true)
        try writeAudio(to: partial, frameCount: 30) { $0 == 17 ? .nan : 0.1 }
        let partialBytes = try Data(contentsOf: partial)

        recovery().recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 1).path))
        XCTAssertFalse(try chunkDirectoryListing(paths).contains { $0.hasPrefix(".") }, "the abandoned copy is cleaned up")
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
    }

    func testPartialFromBeforeCurrentBootIsPreservedNotPromoted() throws {
        let (_, paths) = try makeSession(referenced: 1)
        let partial = chunkURL(paths, 1, partial: true)
        try writeAudio(to: partial, frameCount: 20)
        let partialBytes = try Data(contentsOf: partial)

        let report = recovery(bootTime: .distantFuture).recoverAbandonedRecordings()

        assertInterruptedFields(try readManifest(paths))
        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 1).path))
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
        guard case .preserved(1, _) = report.recovered.first?.tail else {
            return XCTFail("a previous-boot partial must be preserved, never promoted")
        }
    }

    func testUnavailableBootTimeNeverPromotes() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1, partial: true), frameCount: 20)

        recovery(bootTime: nil).recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 1).path))
    }

    func testCanonicalWinsOverConflictingPartialForTheSameSequence() throws {
        // Also the state left by a crash after a recovery rename but before
        // the recovered manifest was published.
        let (_, paths) = try makeSession(referenced: 2)
        try writeAudio(to: chunkURL(paths, 2), frameCount: 25)
        let partial = chunkURL(paths, 2, partial: true)
        try writeAudio(to: partial, frameCount: 25)
        let partialBytes = try Data(contentsOf: partial)

        let report = recovery().recoverAbandonedRecordings()

        let recovered = try readManifest(paths)
        XCTAssertEqual(recovered.chunks.count, 3)
        XCTAssertEqual(recovered.chunks[2], metadata(2, frames: 25, startFrame: 2 * Self.framesPerChunk))
        XCTAssertEqual(report.recovered.first?.adoptedCanonicalChunkCount, 1)
        guard case .preserved = report.recovered.first?.tail else {
            return XCTFail("the partial must not be promoted when its canonical chunk exists")
        }
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
    }

    func testPromotionNeverOverwritesOnRenameCollision() throws {
        let (_, paths) = try makeSession(referenced: 1)
        let partial = chunkURL(paths, 1, partial: true)
        try writeAudio(to: partial, frameCount: 20)
        let partialBytes = try Data(contentsOf: partial)

        let report = recovery(fileSystem: CollidingRenameFileSystem()).recoverAbandonedRecordings()

        XCTAssertEqual(try readManifest(paths).chunks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURL(paths, 1).path))
        XCTAssertFalse(try chunkDirectoryListing(paths).contains { $0.hasPrefix(".") })
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
        guard case .preserved = report.recovered.first?.tail else {
            return XCTFail("a rename collision must preserve the partial")
        }
    }

    func testCrashBeforeCopyCompletionLeavesARecoverableState() throws {
        // A previous pass died mid-copy: only its hidden temporary file
        // remains next to the untouched partial.
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1, partial: true), frameCount: 20)
        let staleTemporary = paths.chunksDirectory.appendingPathComponent(".\(UUID().uuidString).recovering.caf")
        try Data("half-written".utf8).write(to: staleTemporary)

        let report = recovery().recoverAbandonedRecordings()

        XCTAssertEqual(report.recovered.first?.tail, .promoted(sequenceNumber: 1, frameCount: 20))
        XCTAssertEqual(try readManifest(paths).chunks.count, 2)
        XCTAssertEqual(try Data(contentsOf: staleTemporary), Data("half-written".utf8))
    }

    func testRepeatedRecoveryAfterPromotionIsANoOp() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1, partial: true), frameCount: 20)
        recovery().recoverAbandonedRecordings()
        let manifestBytes = try Data(contentsOf: paths.manifestURL)
        let listing = try chunkDirectoryListing(paths)

        let second = recovery().recoverAbandonedRecordings()

        XCTAssertTrue(second.recovered.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), manifestBytes)
        XCTAssertEqual(try chunkDirectoryListing(paths), listing)
    }

    // MARK: - Durability failures defer recovery

    func testFileSyncFailureForValidCanonicalChunkDefersRecoveryUntouched() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1), frameCount: Self.framesPerChunk)
        let manifestBytes = try Data(contentsOf: paths.manifestURL)

        let deferred = recovery(fileSystem: FailingSyncFileSystem(failFileSync: true)).recoverAbandonedRecordings()

        XCTAssertTrue(deferred.recovered.isEmpty)
        guard case .durabilityUnconfirmed = deferred.skipped.first?.reason else {
            return XCTFail("expected a deferred recovery, got \(deferred.skipped)")
        }
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), manifestBytes, "the session stays .recording for a later retry")

        // The next launch, with durability restored, adopts the chunk.
        recovery().recoverAbandonedRecordings()
        let recovered = try readManifest(paths)
        assertInterruptedFields(recovered)
        XCTAssertEqual(recovered.chunks.count, 2)
    }

    func testDirectorySyncFailureForAdoptedChunksDefersRecoveryUntouched() throws {
        let (_, paths) = try makeSession(referenced: 1)
        try writeAudio(to: chunkURL(paths, 1), frameCount: Self.framesPerChunk)
        let manifestBytes = try Data(contentsOf: paths.manifestURL)

        let deferred = recovery(fileSystem: FailingSyncFileSystem(failDirectorySync: true)).recoverAbandonedRecordings()

        XCTAssertTrue(deferred.recovered.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), manifestBytes)
        recovery().recoverAbandonedRecordings()
        XCTAssertEqual(try readManifest(paths).chunks.count, 2)
    }

    func testDirectorySyncFailureAfterTailRenameDefersAndNextLaunchAdoptsTheCanonicalCopy() throws {
        let (_, paths) = try makeSession(referenced: 1)
        let partial = chunkURL(paths, 1, partial: true)
        try writeAudio(to: partial, frameCount: 20)
        let partialBytes = try Data(contentsOf: partial)
        let manifestBytes = try Data(contentsOf: paths.manifestURL)

        let deferred = recovery(fileSystem: FailingSyncFileSystem(failDirectorySync: true)).recoverAbandonedRecordings()

        XCTAssertTrue(deferred.recovered.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), manifestBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunkURL(paths, 1).path), "the published copy is kept")
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)

        let next = recovery().recoverAbandonedRecordings()

        let recovered = try readManifest(paths)
        assertInterruptedFields(recovered)
        XCTAssertEqual(recovered.chunks.count, 2)
        XCTAssertEqual(recovered.chunks[1], metadata(1, frames: 20, startFrame: Self.framesPerChunk))
        XCTAssertEqual(next.recovered.first?.adoptedCanonicalChunkCount, 1)
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
    }

    // MARK: - Composition

    @MainActor
    func testEnvironmentComposedWithoutRecoveryNeverRecovers() {
        XCTAssertNil(AppEnvironment().launchRecoveryReport)
    }

    func testTestHostIsDetectedSoRealLaunchRecoveryIsSuppressed() {
        XCTAssertTrue(
            AppTerminationDelegate.isHostingXCTest,
            "hosted test runs share the real application container and must never run launch recovery"
        )
    }
}
