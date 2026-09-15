import XCTest
@testable import LectureRecorder

final class LectureNotesStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!
    private var store: LectureNotesStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectureNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        sessionID = UUID()
        // Deliberately the non-creating variant: notes persistence must
        // never require a `chunks/`/`logs/` directory to already exist, and
        // `testNotesPersistenceDoesNotTouchTranscriptionOrChunkDirectories`
        // asserts exactly that absence.
        sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: tempDirectory, sessionID: sessionID)
        store = LectureNotesStore()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makePaths(generationID: UUID) throws -> NotesArtifactPaths {
        try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
    }

    private func makeFingerprint(_ seed: String) -> TranscriptSourceFingerprint {
        TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: seed, count: 64).prefix(64).description)
    }

    private func makeGeneration(
        generationID: UUID = UUID(),
        forSessionID overrideSessionID: UUID? = nil,
        fingerprint: TranscriptSourceFingerprint,
        windows: [NotesInputWindow] = []
    ) -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord.newGeneration(
            generationID: generationID,
            sessionID: overrideSessionID ?? sessionID,
            transcriptFingerprint: fingerprint,
            windowPlan: NotesWindowPlan(windows: windows),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "fake-recipe-v1"),
            // A whole-number epoch date has no sub-millisecond component, so
            // it round-trips exactly through AtomicFileWriter's
            // millisecond-precision JSON date encoding — letting these
            // tests assert exact equality against freshly-loaded artifacts
            // instead of only through a double-decode comparison.
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testGenerationMetadataRoundTrips() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("a"))
        let paths = try makePaths(generationID: generation.generationID)

        let createOutcome = try store.createGenerationIfAbsent(generation, paths: paths)
        XCTAssertEqual(createOutcome, .created)

        let loaded = try store.loadGeneration(paths: paths)
        XCTAssertEqual(loaded, generation)
    }

    func testDocumentRoundTrips() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("b"))
        let paths = try makePaths(generationID: generation.generationID)
        _ = try store.createGenerationIfAbsent(generation, paths: paths)

        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            createdDate: Date(timeIntervalSince1970: 1_700_000_000),
            overview: "Overview of the lecture.",
            sections: [
                LectureNoteSection(heading: "Intro", items: [
                    LectureNoteItem(
                        kind: .keyConcept,
                        body: "A key concept.",
                        fidelity: .transcriptSupported,
                        sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)]
                    )
                ])
            ]
        )

        let commitOutcome = try store.commitDocument(document, paths: paths)
        XCTAssertEqual(commitOutcome, .committed)

        let loaded = try store.loadDocument(paths: paths)
        XCTAssertEqual(loaded, document)
    }

    func testTwoGenerationsCoexistWithoutOverwrite() throws {
        let firstGeneration = makeGeneration(fingerprint: makeFingerprint("c"))
        let secondGeneration = makeGeneration(fingerprint: makeFingerprint("c"))
        let firstPaths = try makePaths(generationID: firstGeneration.generationID)
        let secondPaths = try makePaths(generationID: secondGeneration.generationID)

        XCTAssertEqual(try store.createGenerationIfAbsent(firstGeneration, paths: firstPaths), .created)
        XCTAssertEqual(try store.createGenerationIfAbsent(secondGeneration, paths: secondPaths), .created)

        XCTAssertEqual(try store.loadGeneration(paths: firstPaths), firstGeneration)
        XCTAssertEqual(try store.loadGeneration(paths: secondPaths), secondGeneration)

        let generationIDs = try store.listGenerationIDs(sessionPaths: sessionPaths)
        XCTAssertEqual(Set(generationIDs), Set([firstGeneration.generationID, secondGeneration.generationID]))
    }

    func testRecommittingIdenticalGenerationIsNotAConflict() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("d"))
        let paths = try makePaths(generationID: generation.generationID)
        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .created)
        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .alreadyExistsIdentical)
    }

    func testConflictingGenerationAtSameIDIsRejected() throws {
        let generationID = UUID()
        let generation = makeGeneration(generationID: generationID, fingerprint: makeFingerprint("e"))
        var different = generation
        different.provenance.recipeVersion = "different-recipe"
        let paths = try makePaths(generationID: generationID)

        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .created)
        XCTAssertEqual(try store.createGenerationIfAbsent(different, paths: paths), .conflict)
    }

    func testWindowAnalysisCommitAndLoadRoundTrips() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("f"))
        let paths = try makePaths(generationID: generation.generationID)
        _ = try store.createGenerationIfAbsent(generation, paths: paths)

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )

        XCTAssertEqual(try store.commitWindowAnalysis(analysis, paths: paths), .committed)
        XCTAssertEqual(try store.loadWindowAnalysis(windowIndex: 0, paths: paths), analysis)

        let all = try store.loadAllWindowAnalyses(paths: paths)
        XCTAssertEqual(all.count, 1)
        guard case .success(let windowIndex, let value) = all[0] else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(windowIndex, 0)
        XCTAssertEqual(value, analysis)
    }

    func testMalformedGenerationArtifactFailsSafely() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("g"))
        let paths = try makePaths(generationID: generation.generationID)
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: paths.generationRecordURL)

        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) { error in
            guard case LectureNotesStoreError.corruptArtifact = error else {
                return XCTFail("expected corruptArtifact, got \(error)")
            }
        }
    }

    func testUnsupportedSchemaVersionArtifactFailsSafely() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("h"))
        let paths = try makePaths(generationID: generation.generationID)
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)

        var payload = try JSONSerialization.jsonObject(with: AtomicFileWriter.defaultEncoder.encode(generation)) as! [String: Any]
        payload["schemaVersion"] = 999
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: paths.generationRecordURL)

        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) { error in
            guard case LectureNotesStoreError.unsupportedSchemaVersion(_, let version) = error else {
                return XCTFail("expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(version, 999)
        }
    }

    func testNotesPersistenceDoesNotTouchTranscriptionOrChunkDirectories() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("i"))
        let paths = try makePaths(generationID: generation.generationID)
        _ = try store.createGenerationIfAbsent(generation, paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPaths.chunksDirectory.path))
        let transcriptionDirectory = sessionPaths.sessionDirectory.appendingPathComponent("transcription", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptionDirectory.path))
        XCTAssertTrue(paths.notesDirectory.path.hasSuffix("/notes"))
    }

    func testLoadingHistoricalDocumentRequiresNoGeneratorBackend() throws {
        // Deliberately never constructs any `LectureNotesGenerating`
        // conformer — only the store and plain models are used, proving a
        // previously saved document reopens without one.
        let generation = makeGeneration(fingerprint: makeFingerprint("j"))
        let paths = try makePaths(generationID: generation.generationID)
        _ = try store.createGenerationIfAbsent(generation, paths: paths)
        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            createdDate: Date(timeIntervalSince1970: 1_700_000_000),
            overview: "Historical overview.",
            sections: []
        )
        _ = try store.commitDocument(document, paths: paths)

        let reopenedStore = LectureNotesStore()
        let reopened = try reopenedStore.loadDocument(paths: paths)
        XCTAssertEqual(reopened, document)
    }

    // MARK: - Identity verification

    func testCreateGenerationWithMismatchedSessionIDRejected() throws {
        let wrongSessionID = UUID()
        let generation = makeGeneration(forSessionID: wrongSessionID, fingerprint: makeFingerprint("k"))
        let paths = try makePaths(generationID: generation.generationID)

        XCTAssertThrowsError(try store.createGenerationIfAbsent(generation, paths: paths)) { error in
            guard case LectureNotesStoreError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.generationRecordURL.path))
    }

    func testCreateGenerationWithMismatchedGenerationIDRejected() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("l"))
        // Paths built for a *different* generation ID than the record claims.
        let paths = try makePaths(generationID: UUID())

        XCTAssertThrowsError(try store.createGenerationIfAbsent(generation, paths: paths)) { error in
            guard case LectureNotesStoreError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
    }

    func testLoadGenerationWithTamperedSessionIDFailsSafely() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("m"))
        let paths = try makePaths(generationID: generation.generationID)
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)

        var tampered = generation
        tampered.sessionID = UUID()
        try AtomicFileWriter.defaultEncoder.encode(tampered).write(to: paths.generationRecordURL)

        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) { error in
            guard case LectureNotesStoreError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
    }

    func testCommitWindowAnalysisWithMismatchedGenerationIDRejected() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("n"))
        let paths = try makePaths(generationID: generation.generationID)
        _ = try store.createGenerationIfAbsent(generation, paths: paths)

        let analysis = LectureNotesWindowAnalysis(
            generationID: UUID(),
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )

        XCTAssertThrowsError(try store.commitWindowAnalysis(analysis, paths: paths)) { error in
            guard case LectureNotesStoreError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.windowAnalysisURL(windowIndex: 0).path))
    }

    func testCommitDocumentWithMismatchedSessionIDRejected() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("o"))
        let paths = try makePaths(generationID: generation.generationID)
        _ = try store.createGenerationIfAbsent(generation, paths: paths)

        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: UUID(),
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: "overview",
            sections: []
        )

        XCTAssertThrowsError(try store.commitDocument(document, paths: paths)) { error in
            guard case LectureNotesStoreError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.documentURL.path))
    }

    // MARK: - Window plan validation

    func testCreateGenerationWithInvalidWindowPlanRejected() throws {
        let duplicateWindow = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 0, unitCount: 1, isOversizedSingleUnit: false)
        let generation = makeGeneration(fingerprint: makeFingerprint("u"), windows: [duplicateWindow, duplicateWindow])
        let paths = try makePaths(generationID: generation.generationID)

        XCTAssertThrowsError(try store.createGenerationIfAbsent(generation, paths: paths)) { error in
            guard case LectureNotesStoreError.invalidWindowPlan = error else {
                return XCTFail("expected invalidWindowPlan, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.generationRecordURL.path))
    }

    func testLoadGenerationWithTamperedWindowPlanFailsSafely() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("v"))
        let paths = try makePaths(generationID: generation.generationID)
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)

        var payload = try JSONSerialization.jsonObject(with: AtomicFileWriter.defaultEncoder.encode(generation)) as! [String: Any]
        // Inject a gap: two windows whose indices are not exactly 0..<count.
        payload["windowPlan"] = [
            "schemaVersion": 1,
            "windows": [
                ["windowIndex": 0, "firstSequenceNumber": 0, "lastSequenceNumber": 0, "unitCount": 1, "isOversizedSingleUnit": false],
                ["windowIndex": 2, "firstSequenceNumber": 1, "lastSequenceNumber": 1, "unitCount": 1, "isOversizedSingleUnit": false]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: paths.generationRecordURL)

        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) { error in
            guard case LectureNotesStoreError.invalidWindowPlan = error else {
                return XCTFail("expected invalidWindowPlan, got \(error)")
            }
        }
    }

    // MARK: - Symlink safety (mirrors T4's CompletedSessionPathSafety standard)

    func testSymlinkedGenerationRecordFileIsRejectedAndExternalTargetUntouched() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("p"))
        let paths = try makePaths(generationID: generation.generationID)
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)

        let externalTarget = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("NotesGenerationCanary-\(UUID().uuidString).json")
        let canaryContent = "canary-generation-record-untouched"
        try Data(canaryContent.utf8).write(to: externalTarget)
        defer { try? FileManager.default.removeItem(at: externalTarget) }

        try FileManager.default.createSymbolicLink(at: paths.generationRecordURL, withDestinationURL: externalTarget)

        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) { error in
            guard case LectureNotesStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.createGenerationIfAbsent(generation, paths: paths)) { error in
            guard case LectureNotesStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }

        let finalContent = try Data(contentsOf: externalTarget)
        XCTAssertEqual(String(data: finalContent, encoding: .utf8), canaryContent)
    }

    func testSymlinkedGenerationDirectoryIsRejectedAndExternalTargetUntouched() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("q"))
        let paths = try makePaths(generationID: generation.generationID)

        let externalTargetDirectory = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("NotesGenerationDirCanary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTargetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalTargetDirectory) }

        try FileManager.default.createDirectory(at: paths.generationsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.generationDirectory, withDestinationURL: externalTargetDirectory)

        XCTAssertThrowsError(try store.createGenerationIfAbsent(generation, paths: paths)) { error in
            guard case LectureNotesStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }

        let externalContents = try FileManager.default.contentsOfDirectory(atPath: externalTargetDirectory.path)
        XCTAssertTrue(externalContents.isEmpty)
    }

    func testSymlinkedNotesDirectoryIsRejectedAndExternalTargetUntouched() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("w"))
        let paths = try makePaths(generationID: generation.generationID)

        let externalTargetDirectory = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("NotesRootDirCanary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTargetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalTargetDirectory) }

        // `notesDirectory`'s own parent (the session directory) must exist
        // before a symlink can be created at `notesDirectory` itself.
        try FileManager.default.createDirectory(at: sessionPaths.sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.notesDirectory, withDestinationURL: externalTargetDirectory)

        XCTAssertThrowsError(try store.createGenerationIfAbsent(generation, paths: paths)) { error in
            guard case LectureNotesStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) { error in
            guard case LectureNotesStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }

        let externalContents = try FileManager.default.contentsOfDirectory(atPath: externalTargetDirectory.path)
        XCTAssertTrue(externalContents.isEmpty)
    }

    func testSymlinkedGenerationsDirectoryIsRejectedAndExternalTargetUntouched() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("x"))
        let paths = try makePaths(generationID: generation.generationID)

        let externalTargetDirectory = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("NotesGenerationsDirCanary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTargetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalTargetDirectory) }

        try FileManager.default.createDirectory(at: paths.notesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.generationsDirectory, withDestinationURL: externalTargetDirectory)

        XCTAssertThrowsError(try store.createGenerationIfAbsent(generation, paths: paths)) { error in
            guard case LectureNotesStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) { error in
            guard case LectureNotesStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.listGenerationIDs(sessionPaths: sessionPaths)) { error in
            guard case LectureNotesStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }

        let externalContents = try FileManager.default.contentsOfDirectory(atPath: externalTargetDirectory.path)
        XCTAssertTrue(externalContents.isEmpty)
    }

    func testSymlinkedGenerationDirectoryDuringLoadIsRejectedAndExternalTargetUntouched() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("y"))
        let paths = try makePaths(generationID: generation.generationID)

        let externalTargetDirectory = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("NotesGenerationLoadCanary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTargetDirectory, withIntermediateDirectories: true)
        let canaryFile = externalTargetDirectory.appendingPathComponent("generation.json")
        let canaryContent = "canary-generation-directory-untouched"
        try Data(canaryContent.utf8).write(to: canaryFile)
        defer { try? FileManager.default.removeItem(at: externalTargetDirectory) }

        try FileManager.default.createDirectory(at: paths.generationsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.generationDirectory, withDestinationURL: externalTargetDirectory)

        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) { error in
            guard case LectureNotesStoreError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }

        let finalContent = try Data(contentsOf: canaryFile)
        XCTAssertEqual(String(data: finalContent, encoding: .utf8), canaryContent)
    }

    func testGenerationEnumerationExcludesUnsafeUUIDNamedEntries() throws {
        let realGeneration = makeGeneration(fingerprint: makeFingerprint("z"))
        let realPaths = try makePaths(generationID: realGeneration.generationID)
        _ = try store.createGenerationIfAbsent(realGeneration, paths: realPaths)

        let externalTarget = tempDirectory.deletingLastPathComponent()
            .appendingPathComponent("NotesEnumerationCanary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTarget, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalTarget) }

        let generationsDirectory = NotesArtifactPaths.generationsDirectory(sessionPaths: sessionPaths)
        let symlinkedID = UUID()
        try FileManager.default.createSymbolicLink(
            at: generationsDirectory.appendingPathComponent(symlinkedID.uuidString, isDirectory: true),
            withDestinationURL: externalTarget
        )
        let wrongTypeID = UUID()
        try Data("not a directory".utf8).write(to: generationsDirectory.appendingPathComponent(wrongTypeID.uuidString))

        let ids = try store.listGenerationIDs(sessionPaths: sessionPaths)

        XCTAssertEqual(ids, [realGeneration.generationID])
        XCTAssertFalse(ids.contains(symlinkedID))
        XCTAssertFalse(ids.contains(wrongTypeID))
    }

    // MARK: - Durability-uncertain outcome preservation

    func testCreateGenerationDurabilityUncertainIsPreservedNotCollapsed() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("r"))
        let paths = try makePaths(generationID: generation.generationID)
        let spyFileSystem = SpyNotesExclusiveArtifactFileSystem()
        let spyStore = LectureNotesStore(fileSystem: spyFileSystem)
        spyFileSystem.forceOutcome(.createdDurabilityUncertain, forURL: paths.generationRecordURL)

        XCTAssertEqual(try spyStore.createGenerationIfAbsent(generation, paths: paths), .createdDurabilityUncertain)
    }

    func testCommitWindowAnalysisDurabilityUncertainIsPreservedNotCollapsed() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("s"))
        let paths = try makePaths(generationID: generation.generationID)
        let spyFileSystem = SpyNotesExclusiveArtifactFileSystem()
        let spyStore = LectureNotesStore(fileSystem: spyFileSystem)
        _ = try spyStore.createGenerationIfAbsent(generation, paths: paths)

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )
        spyFileSystem.forceOutcome(.createdDurabilityUncertain, forURL: paths.windowAnalysisURL(windowIndex: 0))

        XCTAssertEqual(try spyStore.commitWindowAnalysis(analysis, paths: paths), .committedDurabilityUncertain)
    }

    func testCommitDocumentDurabilityUncertainIsPreservedNotCollapsed() throws {
        let generation = makeGeneration(fingerprint: makeFingerprint("t"))
        let paths = try makePaths(generationID: generation.generationID)
        let spyFileSystem = SpyNotesExclusiveArtifactFileSystem()
        let spyStore = LectureNotesStore(fileSystem: spyFileSystem)
        _ = try spyStore.createGenerationIfAbsent(generation, paths: paths)

        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: "overview",
            sections: []
        )
        spyFileSystem.forceOutcome(.createdDurabilityUncertain, forURL: paths.documentURL)

        XCTAssertEqual(try spyStore.commitDocument(document, paths: paths), .committedDurabilityUncertain)
    }
}
