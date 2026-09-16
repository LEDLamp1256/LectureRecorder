import XCTest
@testable import LectureRecorder

final class LectureNotesOperationStateStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!
    private var store: LectureNotesOperationStateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LNOperationStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        sessionID = UUID()
        sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: tempDirectory, sessionID: sessionID)
        store = LectureNotesOperationStateStore()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makePaths(generationID: UUID = UUID()) throws -> NotesArtifactPaths {
        try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
    }

    private func makeState(paths: NotesArtifactPaths, lifecycle: NotesGenerationOperationLifecycle = .running) -> NotesGenerationOperationState {
        NotesGenerationOperationState(
            sessionID: paths.sessionID,
            generationID: paths.generationID,
            transcriptFingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "a", count: 64)),
            activeRunID: UUID(),
            runAttemptCount: 1,
            lifecycle: lifecycle,
            currentStage: .analyzingWindow(windowIndex: 2),
            failureDescription: nil,
            updatedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testLoadReturnsNilWhenNoStateSaved() throws {
        let paths = try makePaths()
        XCTAssertNil(try store.loadOperationState(paths: paths))
    }

    func testStateRoundTrips() throws {
        let paths = try makePaths()
        let state = makeState(paths: paths)
        try store.saveOperationState(state, paths: paths)
        XCTAssertEqual(try store.loadOperationState(paths: paths), state)
    }

    func testStateCanBeOverwrittenRepeatedly() throws {
        let paths = try makePaths()
        try store.saveOperationState(makeState(paths: paths, lifecycle: .running), paths: paths)
        let updated = makeState(paths: paths, lifecycle: .completed)
        try store.saveOperationState(updated, paths: paths)
        XCTAssertEqual(try store.loadOperationState(paths: paths), updated)
    }

    func testStageRoundTripsForSynthesizing() throws {
        let paths = try makePaths()
        var state = makeState(paths: paths)
        state.currentStage = .synthesizing
        try store.saveOperationState(state, paths: paths)
        XCTAssertEqual(try store.loadOperationState(paths: paths)?.currentStage, .synthesizing)
    }

    func testUnsupportedSchemaVersionRejected() throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)
        var raw = try JSONSerialization.jsonObject(with: AtomicFileWriter.defaultEncoder.encode(makeState(paths: paths))) as! [String: Any]
        raw["schemaVersion"] = 999
        let data = try JSONSerialization.data(withJSONObject: raw)
        try data.write(to: paths.operationStateURL)

        XCTAssertThrowsError(try store.loadOperationState(paths: paths)) { error in
            guard case NotesOperationStateStoreError.unsupportedSchemaVersion = error else {
                return XCTFail("expected unsupportedSchemaVersion, got \(error)")
            }
        }
    }

    func testCorruptJSONRejected() throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: paths.operationStateURL)

        XCTAssertThrowsError(try store.loadOperationState(paths: paths)) { error in
            guard case NotesOperationStateStoreError.corruptArtifact = error else {
                return XCTFail("expected corruptArtifact, got \(error)")
            }
        }
    }

    func testIdentityMismatchRejectedOnSave() throws {
        let paths = try makePaths()
        var mismatched = makeState(paths: paths)
        mismatched.generationID = UUID()

        XCTAssertThrowsError(try store.saveOperationState(mismatched, paths: paths)) { error in
            guard case NotesOperationStateStoreError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
    }

    func testIdentityMismatchRejectedOnLoad() throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)
        // Written directly (bypassing `saveOperationState`'s own identity
        // check) to simulate an artifact that became mismatched with its
        // path some other way — decoding successfully proves nothing about
        // whether it actually belongs here.
        let foreignState = makeState(paths: try makePaths(generationID: UUID()))
        try AtomicFileWriter.writeJSON(foreignState, to: paths.operationStateURL)

        XCTAssertThrowsError(try store.loadOperationState(paths: paths)) { error in
            guard case NotesOperationStateStoreError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
    }

    func testSymlinkedOperationStateFileRejectedAndExternalTargetUntouched() throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)

        let externalTarget = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("OperationStateCanary-\(UUID().uuidString).json")
        let canaryContent = "canary-operation-state-untouched"
        try Data(canaryContent.utf8).write(to: externalTarget)
        defer { try? FileManager.default.removeItem(at: externalTarget) }

        try FileManager.default.createSymbolicLink(at: paths.operationStateURL, withDestinationURL: externalTarget)

        XCTAssertThrowsError(try store.loadOperationState(paths: paths)) { error in
            guard case NotesOperationStateStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.saveOperationState(makeState(paths: paths), paths: paths)) { error in
            guard case NotesOperationStateStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }

        let finalContent = try Data(contentsOf: externalTarget)
        XCTAssertEqual(String(data: finalContent, encoding: .utf8), canaryContent)
    }

    func testSymlinkedGenerationDirectoryAncestorRejected() throws {
        let paths = try makePaths()

        let externalTargetDirectory = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("OperationStateDirCanary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTargetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalTargetDirectory) }

        try FileManager.default.createDirectory(at: paths.generationsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.generationDirectory, withDestinationURL: externalTargetDirectory)

        XCTAssertThrowsError(try store.saveOperationState(makeState(paths: paths), paths: paths)) { error in
            guard case NotesOperationStateStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
        let externalContents = try FileManager.default.contentsOfDirectory(atPath: externalTargetDirectory.path)
        XCTAssertTrue(externalContents.isEmpty)
    }
}
