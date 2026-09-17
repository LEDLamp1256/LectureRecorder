import XCTest
@testable import LectureRecorder

final class LectureSummaryStoreTests: XCTestCase {
    private var root: URL!
    private var sessionPaths: SessionPaths!
    private var store: LectureSummaryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectureSummaryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(
            rootDirectory: root, sessionID: SummaryTestSupport.sessionID
        )
        store = LectureSummaryStore()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func paths(_ generationID: UUID = SummaryTestSupport.summaryGenerationID) throws -> SummaryArtifactPaths {
        try SummaryArtifactPaths.validated(
            sessionPaths: sessionPaths,
            sessionID: SummaryTestSupport.sessionID,
            generationID: generationID
        )
    }

    private func analysis(
        _ generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot,
        batchIndex: Int = 0
    ) throws -> LectureSummaryAnalysis {
        let batch = generation.batchPlan.batches[batchIndex]
        return LectureSummaryAnalysis(
            generationID: generation.generationID, sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: batch.batchID, batchIndex: batch.batchIndex,
            passages: batchIndex == 0 ? [try SummaryTestSupport.passage(source: source)] : [],
            provenance: generation.provenance
        )
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFileWriter.defaultEncoder.encode(value).write(to: url)
    }

    private func document(
        _ generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) throws -> LectureSummaryDocument {
        LectureSummaryDocument(
            generationID: generation.generationID, sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: generation.provenance,
            createdDate: Date(timeIntervalSince1970: 1_700_000_020),
            sections: [LectureSummarySection(heading: "Core", passages: [try SummaryTestSupport.passage(source: source)])]
        )
    }

    func testCanonicalLayoutAndCommitOnceRoundTrips() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try paths()
        XCTAssertTrue(paths.generationRecordURL.path.hasSuffix("/summaries/generations/\(generation.generationID.uuidString)/generation.json"))
        XCTAssertTrue(paths.batchAnalysisURL(batchIndex: 0).path.hasSuffix("/batch_analyses/batch_0000.analysis.json"))
        XCTAssertTrue(paths.documentURL.path.hasSuffix("/document.json"))
        XCTAssertTrue(paths.operationStateURL.path.hasSuffix("/operation-state.json"))

        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .created)
        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .alreadyExistsIdentical)
        XCTAssertEqual(try store.loadGeneration(paths: paths), generation)

        let analysis = try analysis(generation, source: source)
        XCTAssertEqual(try store.commitAnalysis(analysis, paths: paths), .committed)
        XCTAssertEqual(try store.commitAnalysis(analysis, paths: paths), .alreadyCommittedIdentical)
        XCTAssertEqual(try store.loadAnalysis(batchIndex: 0, paths: paths), analysis)

        let document = try document(generation, source: source)
        XCTAssertEqual(try store.commitDocument(document, paths: paths), .committed)
        XCTAssertEqual(try store.commitDocument(document, paths: paths), .alreadyCommittedIdentical)
        XCTAssertEqual(try store.loadDocument(paths: paths), document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.operationStateURL.path))
    }

    func testConflictingArtifactsAreRejectedWithoutReplacement() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try paths()
        XCTAssertEqual(try store.createGenerationIfAbsent(generation, paths: paths), .created)
        var changed = generation
        changed.provenance.generatorVersion = "different"
        XCTAssertEqual(try store.createGenerationIfAbsent(changed, paths: paths), .conflict)
        XCTAssertEqual(try store.loadGeneration(paths: paths), generation)

        let original = try document(generation, source: source)
        XCTAssertEqual(try store.commitDocument(original, paths: paths), .committed)
        var conflicting = original
        conflicting.sections[0].heading = "Different"
        XCTAssertEqual(try store.commitDocument(conflicting, paths: paths), .conflict)
        XCTAssertEqual(try store.loadDocument(paths: paths), original)
    }

    func testMultipleSummaryGenerationsCoexist() throws {
        let source = try SummaryTestSupport.source()
        let first = try SummaryTestSupport.generation(source: source)
        var second = first
        second.generationID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let firstPaths = try paths(first.generationID)
        let secondPaths = try paths(second.generationID)
        XCTAssertEqual(try store.createGenerationIfAbsent(first, paths: firstPaths), .created)
        XCTAssertEqual(try store.createGenerationIfAbsent(second, paths: secondPaths), .created)
        XCTAssertEqual(Set(try store.listGenerationIDs(sessionPaths: sessionPaths)), Set([first.generationID, second.generationID]))
    }

    func testCorruptUnsupportedAndMismatchedArtifactsFailClosed() throws {
        let generation = try SummaryTestSupport.generation()
        let paths = try paths()
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: paths.generationRecordURL)
        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) {
            guard case LectureSummaryStoreError.corruptArtifact = $0 else { return XCTFail("unexpected \($0)") }
        }

        try FileManager.default.removeItem(at: paths.generationRecordURL)
        var unsupported = generation
        unsupported.schemaVersion = 999
        try AtomicFileWriter.defaultEncoder.encode(unsupported).write(to: paths.generationRecordURL)
        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) {
            guard case LectureSummaryStoreError.unsupportedSchemaVersion = $0 else { return XCTFail("unexpected \($0)") }
        }

        try FileManager.default.removeItem(at: paths.generationRecordURL)
        var mismatched = generation
        mismatched.generationID = UUID()
        try AtomicFileWriter.defaultEncoder.encode(mismatched).write(to: paths.generationRecordURL)
        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) {
            guard case LectureSummaryStoreError.identityMismatch = $0 else { return XCTFail("unexpected \($0)") }
        }
    }

    func testPathMismatchAndSymlinkedSummaryAncestorAreRejected() throws {
        let wrongSessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: UUID())
        XCTAssertThrowsError(try SummaryArtifactPaths.validated(
            sessionPaths: wrongSessionPaths,
            sessionID: SummaryTestSupport.sessionID,
            generationID: SummaryTestSupport.summaryGenerationID
        ))

        try FileManager.default.createDirectory(at: sessionPaths.sessionDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let paths = try paths()
        try FileManager.default.createSymbolicLink(at: paths.summariesDirectory, withDestinationURL: target)
        XCTAssertThrowsError(try store.createGenerationIfAbsent(try SummaryTestSupport.generation(), paths: paths)) {
            guard case LectureSummaryStoreError.unsafePath = $0 else { return XCTFail("unexpected \($0)") }
        }
    }

    func testSymlinkedArtifactLeafIsRejected() throws {
        let paths = try paths()
        try FileManager.default.createDirectory(at: paths.generationDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.generationRecordURL, withDestinationURL: target)
        XCTAssertThrowsError(try store.createGenerationIfAbsent(try SummaryTestSupport.generation(), paths: paths)) {
            guard case LectureSummaryStoreError.unsafePath = $0 else { return XCTFail("unexpected \($0)") }
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "outside")
    }

    func testMalformedPlanIsRejectedOnCommitAndLoadWithTypedError() throws {
        var malformed = try SummaryTestSupport.generation()
        malformed.batchPlan.batches[0].serializedByteCount = 0
        let paths = try paths()

        XCTAssertThrowsError(try store.createGenerationIfAbsent(malformed, paths: paths)) {
            guard case LectureSummaryStoreError.invalidPlan(
                _, .nonPositiveSerializedByteCount(batchIndex: 0, count: 0)
            ) = $0 else { return XCTFail("unexpected \($0)") }
        }

        try write(malformed, to: paths.generationRecordURL)
        XCTAssertThrowsError(try store.loadGeneration(paths: paths)) {
            guard case LectureSummaryStoreError.invalidPlan(
                _, .nonPositiveSerializedByteCount(batchIndex: 0, count: 0)
            ) = $0 else { return XCTFail("unexpected \($0)") }
        }
    }

    func testLoadAllAnalysesReturnsEmptyWhenDirectoryIsMissing() throws {
        XCTAssertEqual(try store.loadAllAnalyses(paths: paths()).count, 0)
    }

    func testLoadAllAnalysesReturnsValidFilesInDeterministicBatchOrder() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try paths()
        let first = try analysis(generation, source: source, batchIndex: 0)
        let second = try analysis(generation, source: source, batchIndex: 1)
        _ = try store.commitAnalysis(second, paths: paths)
        _ = try store.commitAnalysis(first, paths: paths)

        let results = try store.loadAllAnalyses(paths: paths)
        XCTAssertEqual(results.map(\.batchIndex), [0, 1])
        guard case .success(_, let loadedFirst) = results[0],
              case .success(_, let loadedSecond) = results[1] else {
            return XCTFail("expected two successes")
        }
        XCTAssertEqual(loadedFirst, first)
        XCTAssertEqual(loadedSecond, second)
    }

    func testLoadAllAnalysesKeepsValidSiblingWhenRecognizedFileIsCorrupt() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try paths()
        _ = try store.commitAnalysis(try analysis(generation, source: source), paths: paths)
        try Data("not-json".utf8).write(to: paths.batchAnalysisURL(batchIndex: 1))

        let results = try store.loadAllAnalyses(paths: paths)
        XCTAssertEqual(results.map(\.batchIndex), [0, 1])
        guard case .success = results[0], case .failure = results[1] else {
            return XCTFail("expected success followed by per-file failure")
        }
    }

    func testLoadAllAnalysesReportsUnsupportedSchemaPerFile() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try paths()
        var unsupported = try analysis(generation, source: source)
        unsupported.schemaVersion = 999
        try write(unsupported, to: paths.batchAnalysisURL(batchIndex: 0))

        let results = try store.loadAllAnalyses(paths: paths)
        XCTAssertEqual(results.count, 1)
        guard case .failure(batchIndex: 0, let error) = results[0] else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.contains("unsupported schema version 999"))
    }

    func testLoadAllAnalysesReportsEmbeddedPathIdentityMismatchPerFile() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try paths()
        let value = try analysis(generation, source: source, batchIndex: 0)
        try write(value, to: paths.batchAnalysisURL(batchIndex: 1))

        let results = try store.loadAllAnalyses(paths: paths)
        XCTAssertEqual(results.count, 1)
        guard case .failure(batchIndex: 1, let error) = results[0] else {
            return XCTFail("expected identity failure")
        }
        XCTAssertTrue(error.contains("batch identity does not match path"))
    }

    func testLoadAllAnalysesSurfacesUnexpectedRecognizedIndex() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try paths()
        var unexpected = try analysis(generation, source: source)
        unexpected.batchIndex = 99
        unexpected.batchID = LectureSummaryPlanner.batchID(99)
        try write(unexpected, to: paths.batchAnalysisURL(batchIndex: 99))

        let results = try store.loadAllAnalyses(paths: paths)
        XCTAssertEqual(results.map(\.batchIndex), [99])
        guard case .success(_, let loaded) = results[0] else {
            return XCTFail("expected unexpected index to remain available")
        }
        XCTAssertEqual(loaded, unexpected)
    }

    func testLoadAllAnalysesReportsSymlinkWithoutDereferencingTarget() throws {
        let paths = try paths()
        try FileManager.default.createDirectory(at: paths.batchAnalysesDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside-analysis.json")
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: paths.batchAnalysisURL(batchIndex: 0),
            withDestinationURL: target
        )

        let results = try store.loadAllAnalyses(paths: paths)
        XCTAssertEqual(results.count, 1)
        guard case .failure(batchIndex: 0, let error) = results[0] else {
            return XCTFail("expected unsafe-path failure")
        }
        XCTAssertTrue(error.contains("symlink"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "outside")
    }

    func testLoadAllAnalysesIgnoresUnrelatedFilesAndPreservesDuplicateLogicalIndices() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let paths = try paths()
        let value = try analysis(generation, source: source)
        try write(value, to: paths.batchAnalysisURL(batchIndex: 0))
        try write(value, to: paths.batchAnalysesDirectory.appendingPathComponent("batch_0.analysis.json"))
        try Data("ignored".utf8).write(to: paths.batchAnalysesDirectory.appendingPathComponent("README.txt"))

        let results = try store.loadAllAnalyses(paths: paths)
        XCTAssertEqual(results.map(\.batchIndex), [0, 0])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy {
            if case .success = $0 { return true }
            return false
        })
    }
}

private struct FixedSummaryTranscriptLoader: NotesTranscriptSourceLoading {
    let snapshot: NotesTranscriptSourceSnapshot
    func loadCurrentSnapshot(sessionID: UUID) async throws -> NotesTranscriptSourceSnapshot { snapshot }
}

final class LectureSummarySourceLoaderTests: XCTestCase {
    func testLoaderBuildsSnapshotOnlyFromCompleteCommittedNotesArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectureSummarySourceLoaderCompleteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(
            rootDirectory: root, sessionID: SummaryTestSupport.sessionID
        )
        try FileManager.default.createDirectory(at: sessionPaths.sessionDirectory, withIntermediateDirectories: true)
        let evidence = SummaryTestSupport.notesEvidence()
        let notesPaths = try NotesArtifactPaths.validated(
            sessionPaths: sessionPaths,
            sessionID: SummaryTestSupport.sessionID,
            generationID: SummaryTestSupport.notesGenerationID
        )
        let notesStore = LectureNotesStore()
        _ = try notesStore.createGenerationIfAbsent(evidence.0, paths: notesPaths)
        _ = try notesStore.commitWindowAnalysis(evidence.3[0], paths: notesPaths)
        _ = try notesStore.commitDocument(evidence.1, paths: notesPaths)
        let loader = LectureSummarySourceLoader(
            notesStore: notesStore,
            transcriptLoader: FixedSummaryTranscriptLoader(snapshot: evidence.2),
            sessionsRootResolver: { root }
        )
        let loaded = try await loader.loadSourceSnapshot(
            sessionID: SummaryTestSupport.sessionID,
            notesGenerationID: SummaryTestSupport.notesGenerationID
        )
        XCTAssertEqual(loaded, try SummaryTestSupport.source())
    }

    func testLoaderRejectsMissingAndIncompleteNotesGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectureSummarySourceLoaderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(
            rootDirectory: root, sessionID: SummaryTestSupport.sessionID
        )
        try FileManager.default.createDirectory(at: sessionPaths.sessionDirectory, withIntermediateDirectories: true)
        let loader = LectureSummarySourceLoader(
            notesStore: LectureNotesStore(),
            transcriptLoader: FixedSummaryTranscriptLoader(snapshot: SummaryTestSupport.transcript()),
            sessionsRootResolver: { root }
        )
        do {
            _ = try await loader.loadSourceSnapshot(
                sessionID: SummaryTestSupport.sessionID,
                notesGenerationID: SummaryTestSupport.notesGenerationID
            )
            XCTFail("expected missing generation")
        } catch {
            XCTAssertEqual(error as? LectureSummarySourceError, .missingGeneration)
        }

        let evidence = SummaryTestSupport.notesEvidence()
        let notesPaths = try NotesArtifactPaths.validated(
            sessionPaths: sessionPaths,
            sessionID: SummaryTestSupport.sessionID,
            generationID: SummaryTestSupport.notesGenerationID
        )
        _ = try LectureNotesStore().createGenerationIfAbsent(evidence.0, paths: notesPaths)
        do {
            _ = try await loader.loadSourceSnapshot(
                sessionID: SummaryTestSupport.sessionID,
                notesGenerationID: SummaryTestSupport.notesGenerationID
            )
            XCTFail("expected incomplete generation")
        } catch {
            XCTAssertEqual(error as? LectureSummarySourceError, .incompleteGeneration)
        }
    }
}
