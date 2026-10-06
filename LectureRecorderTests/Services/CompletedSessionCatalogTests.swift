import XCTest
@testable import LectureRecorder

final class CompletedSessionCatalogTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletedSessionCatalogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    private func makeCatalog(rootExists: Bool = true) throws -> CompletedSessionCatalog {
        if rootExists {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        }
        return CompletedSessionCatalog(sessionsRootResolver: { self.tempRoot })
    }

    private func makeAudioFormat() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
    }

    @discardableResult
    private func writeCompletedSession(
        sessionID: UUID = UUID(),
        status: SessionStatus = .completed,
        chunkCount: Int = 2,
        chunkState: ChunkState = .completed,
        corruptFileNames: Bool = false,
        writeChunkFiles: Bool = true,
        endDate: Date? = nil
    ) throws -> SessionPaths {
        let sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempRoot, sessionID: sessionID)
        var manifest = SessionManifest.newSession(id: sessionID, audioFormat: makeAudioFormat(), targetChunkDurationSeconds: 30)
        manifest.status = status
        manifest.endedCleanly = true
        manifest.endDate = endDate
        manifest.chunks = (0..<chunkCount).map { seq in
            ChunkMetadata(
                sequenceNumber: seq,
                fileName: corruptFileNames ? "wrong-name-\(seq).caf" : TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30,
                frameCount: 1_000,
                state: chunkState
            )
        }
        try AtomicFileWriter.writeJSON(manifest, to: sessionPaths.manifestURL)
        if writeChunkFiles {
            for seq in 0..<chunkCount {
                let url = sessionPaths.chunksDirectory.appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: seq))
                try Data("placeholder".utf8).write(to: url)
            }
        }
        return sessionPaths
    }

    func testMissingRootReturnsEmptyCatalogWithoutCreatingIt() throws {
        let catalog = try makeCatalog(rootExists: false)
        let result = try catalog.listCompletedSessions()
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.path))
    }

    func testValidCompletedSessionIsListed() throws {
        let sessionID = UUID()
        try writeCompletedSession(sessionID: sessionID)
        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.manifest.sessionID, sessionID)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testNonCompletedSessionIsExcludedWithoutError() throws {
        try writeCompletedSession(status: .recording)
        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }

    /// T7-B: a terminal interrupted recording with durable audio is listed,
    /// keeping its real status.
    func testInterruptedSessionWithChunksIsListed() throws {
        let sessionID = UUID()
        try writeCompletedSession(sessionID: sessionID, status: .interrupted, chunkCount: 2)
        let result = try makeCatalog().listCompletedSessions()
        XCTAssertEqual(result.sessions.map(\.manifest.sessionID), [sessionID])
        XCTAssertEqual(result.sessions.first?.manifest.status, .interrupted)
        XCTAssertTrue(result.errors.isEmpty)
    }

    /// T7-B: a failed recording with durable audio is listed, keeping its
    /// real status.
    func testFailedSessionWithChunksIsListed() throws {
        let sessionID = UUID()
        try writeCompletedSession(sessionID: sessionID, status: .failed, chunkCount: 1)
        let result = try makeCatalog().listCompletedSessions()
        XCTAssertEqual(result.sessions.map(\.manifest.sessionID), [sessionID])
        XCTAssertEqual(result.sessions.first?.manifest.status, .failed)
    }

    /// T7-B: failed/interrupted attempts that captured no audio stay out of
    /// the library (unlike zero-chunk completed sessions, unchanged).
    func testZeroChunkFailedOrInterruptedSessionIsNotListed() throws {
        try writeCompletedSession(status: .failed, chunkCount: 0)
        try writeCompletedSession(status: .interrupted, chunkCount: 0)
        let result = try makeCatalog().listCompletedSessions()
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }

    /// T7-B: the catalog stays read-only — listing a terminal session never
    /// rewrites its manifest.
    func testListingTerminalSessionsNeverMutatesTheirManifests() throws {
        let paths = try writeCompletedSession(status: .interrupted, chunkCount: 2)
        let before = try Data(contentsOf: paths.manifestURL)
        _ = try makeCatalog().listCompletedSessions()
        XCTAssertEqual(try Data(contentsOf: paths.manifestURL), before)
    }

    func testRecordingStatusDisplayNeverPresentsTerminalFailuresAsCompleted() {
        var manifest = SessionManifest.newSession(id: UUID(), audioFormat: makeAudioFormat(), targetChunkDurationSeconds: 30)

        manifest.status = .completed
        manifest.endReason = .userStopped
        XCTAssertNil(SessionRecordingStatusDisplay.listCaption(for: manifest))
        XCTAssertNil(SessionRecordingStatusDisplay.detailStatus(for: manifest))

        manifest.endReason = .appTerminated
        XCTAssertEqual(SessionRecordingStatusDisplay.listCaption(for: manifest), "Ended when the app quit")

        manifest.status = .interrupted
        manifest.endReason = .unknown
        XCTAssertEqual(SessionRecordingStatusDisplay.listCaption(for: manifest), "Interrupted recording")
        XCTAssertNotNil(SessionRecordingStatusDisplay.detailStatus(for: manifest))

        manifest.status = .failed
        manifest.endReason = .error
        manifest.failureDescription = "Capture failure: device changed"
        XCTAssertEqual(SessionRecordingStatusDisplay.listCaption(for: manifest), "Recording failed")
        XCTAssertEqual(SessionRecordingStatusDisplay.detailStatus(for: manifest), "Recording failed: Capture failure: device changed")
    }

    func testZeroChunkCompletedSessionIsListedAsValid() throws {
        try writeCompletedSession(chunkCount: 0)
        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertTrue(result.sessions.first?.manifest.chunks.isEmpty ?? false)
    }

    func testNonCompletedChunkIsReportedAsIneligibleError() throws {
        let sessionID = UUID()
        try writeCompletedSession(sessionID: sessionID, chunkState: .recording)
        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        if case .ineligible(let id, let error) = result.errors.first {
            XCTAssertEqual(id, sessionID)
            if case .nonCompletedChunk = error {} else { XCTFail("expected nonCompletedChunk, got \(error)") }
        } else {
            XCTFail("expected .ineligible, got \(String(describing: result.errors.first))")
        }
    }

    func testBadCanonicalFileNameIsReportedAsIneligibleError() throws {
        try writeCompletedSession(corruptFileNames: true)
        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        if case .ineligible(_, let error) = result.errors.first,
           case .artifactPathValidation(.nonCanonicalChunkFileName) = error {
            // expected
        } else {
            XCTFail("expected nonCanonicalChunkFileName, got \(String(describing: result.errors.first))")
        }
    }

    func testMalformedManifestIsReportedAsError() throws {
        let sessionID = UUID()
        let sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempRoot, sessionID: sessionID)
        try Data("not json".utf8).write(to: sessionPaths.manifestURL)
        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        if case .corruptManifest(let id, _) = result.errors.first {
            XCTAssertEqual(id, sessionID)
        } else {
            XCTFail("expected corruptManifest, got \(String(describing: result.errors.first))")
        }
    }

    func testOneBadSessionDoesNotHideAnotherValidSession() throws {
        let goodID = UUID()
        try writeCompletedSession(sessionID: goodID)

        let badID = UUID()
        let badPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempRoot, sessionID: badID)
        try Data("corrupt".utf8).write(to: badPaths.manifestURL)

        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()
        XCTAssertEqual(result.sessions.map(\.manifest.sessionID), [goodID])
        XCTAssertEqual(result.errors.count, 1)
    }

    func testSymlinkedSessionDirectoryIsRejectedAndExternalTargetIsUntouched() throws {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // The external canary: a real directory containing a manifest,
        // living OUTSIDE the sessions root, that a malicious symlink will
        // point at.
        let externalTarget = tempRoot.deletingLastPathComponent()
            .appendingPathComponent("CompletedSessionCatalogCanary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTarget, withIntermediateDirectories: true)
        let canaryManifestURL = externalTarget.appendingPathComponent("session.json")
        let canaryContent = "canary-untouched-marker"
        try Data(canaryContent.utf8).write(to: canaryManifestURL)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: canaryManifestURL.path)
        let originalModificationDate = originalAttributes[.modificationDate] as? Date

        let symlinkID = UUID()
        let symlinkPath = tempRoot.appendingPathComponent(symlinkID.uuidString)
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: externalTarget)

        defer { try? FileManager.default.removeItem(at: externalTarget) }

        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.errors, [.unsafeSessionDirectory(symlinkID)])

        // Canary: the external target's content and mtime are unchanged —
        // the catalog never opened or followed the symlink.
        let finalContent = try Data(contentsOf: canaryManifestURL)
        XCTAssertEqual(String(data: finalContent, encoding: .utf8), canaryContent)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: canaryManifestURL.path)
        XCTAssertEqual(finalAttributes[.modificationDate] as? Date, originalModificationDate)
    }

    func testInvalidSessionDirectoryNameIsReportedWithoutAbortingScan() throws {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("not-a-uuid", isDirectory: true),
            withIntermediateDirectories: true
        )
        let goodID = UUID()
        try writeCompletedSession(sessionID: goodID)

        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()
        XCTAssertEqual(result.sessions.map(\.manifest.sessionID), [goodID])
        XCTAssertEqual(result.errors, [.invalidSessionDirectoryName("not-a-uuid")])
    }

    // MARK: - Ordering

    func testCompletedSessionsAreOrderedNewestFirstByManifestEndDate() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let oldestID = UUID()
        let middleID = UUID()
        let newestID = UUID()
        // Written in a deliberately non-chronological order so the result
        // can only be correct if sorting uses manifest metadata, not
        // filesystem enumeration/creation order.
        try writeCompletedSession(sessionID: middleID, endDate: base.addingTimeInterval(60))
        try writeCompletedSession(sessionID: newestID, endDate: base.addingTimeInterval(120))
        try writeCompletedSession(sessionID: oldestID, endDate: base)

        let catalog = try makeCatalog()
        let result = try catalog.listCompletedSessions()

        XCTAssertEqual(result.sessions.map(\.manifest.sessionID), [newestID, middleID, oldestID])
    }

    func testEqualEndDatesBreakTieDeterministicallyOnSessionID() throws {
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // Written with the numerically-higher id first, so a correct,
        // metadata-driven tie-break (not scan order) is required to land
        // on [lowerID, higherID].
        try writeCompletedSession(sessionID: higherID, endDate: sameDate)
        try writeCompletedSession(sessionID: lowerID, endDate: sameDate)

        let catalog = try makeCatalog()
        let firstResult = try catalog.listCompletedSessions()
        let secondResult = try catalog.listCompletedSessions()

        XCTAssertEqual(firstResult.sessions.map(\.manifest.sessionID), [lowerID, higherID])
        XCTAssertEqual(
            secondResult.sessions.map(\.manifest.sessionID),
            firstResult.sessions.map(\.manifest.sessionID),
            "ordering must be stable across repeated calls, not merely correct once"
        )
    }
}
