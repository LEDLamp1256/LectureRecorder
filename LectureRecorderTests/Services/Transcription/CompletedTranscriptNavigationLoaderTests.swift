import AVFoundation
import XCTest
@testable import LectureRecorder

/// Exercises the production `CompletedTranscriptNavigationLoader` against
/// real on-disk transcription artifacts, produced by the real
/// `CompletedSessionTranscriptionService` driving a `FakeTranscriber` (no
/// microphone, Whisper, or model).
@MainActor
final class CompletedTranscriptNavigationLoaderTests: XCTestCase {
    private static let framesPerChunk = 44_100

    private var tempDirectory: URL!
    private var sessionID: UUID!
    private var sessionPaths: SessionPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletedTranscriptNavigationLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        sessionID = UUID()
        sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func writeManifest(chunkCount: Int) throws -> SessionManifest {
        var manifest = SessionManifest.newSession(
            id: sessionID,
            audioFormat: AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32"),
            targetChunkDurationSeconds: 30
        )
        manifest.status = .completed
        manifest.endedCleanly = true
        manifest.chunks = (0..<chunkCount).map { seq in
            ChunkMetadata(
                sequenceNumber: seq, fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq), durationSeconds: 1, frameCount: Self.framesPerChunk, state: .completed
            )
        }
        try AtomicFileWriter.writeJSON(manifest, to: sessionPaths.manifestURL)
        for seq in 0..<chunkCount {
            let url = sessionPaths.chunksDirectory.appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: seq))
            try Data("placeholder".utf8).write(to: url)
        }
        return manifest
    }

    private func makeService(transcriber: any Transcribing) -> CompletedSessionTranscriptionService {
        let manager = SessionManager(
            store: SessionStore(locator: TestLocator(root: tempDirectory)),
            permissionService: MockMicrophonePermissionService(status: .granted),
            captureService: MockAudioCaptureService(
                formatToPrepare: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
            ),
            chunkWriterFactory: DefaultAudioChunkWriterFactory()
        )
        let root = tempDirectory!
        return CompletedSessionTranscriptionService(
            sessionManager: manager,
            transcriptionStore: TranscriptionStore(),
            transcriber: transcriber,
            sessionsRootResolver: { root }
        )
    }

    private struct TestLocator: FileSystemLocating {
        let root: URL
        func sessionsRootDirectory() throws -> URL { root }
        func paths(for sessionID: UUID) throws -> SessionPaths {
            try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: sessionID)
        }
    }

    private func transcribeToCompletion(_ service: CompletedSessionTranscriptionService) async {
        XCTAssertEqual(service.transcribe(sessionID: sessionID), .admitted)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .finished = service.phase { return }
            await Task.yield()
        }
        XCTFail("transcription did not finish")
    }

    private func output(_ segments: [TranscriptionTimingSegment]?, text: String? = nil) -> TranscriptionEngineOutput {
        TranscriptionEngineOutput(
            text: text ?? segments?.map(\.text).joined() ?? "",
            engineIdentifier: "fake-v1",
            modelIdentifier: "fake-model",
            language: "en",
            segments: segments,
            engineVersion: "1.0"
        )
    }

    private func loader() -> CompletedTranscriptNavigationLoader {
        CompletedTranscriptNavigationLoader(transcriptionStore: TranscriptionStore())
    }

    private func load(_ manifest: SessionManifest) async -> TranscriptPlaybackNavigation? {
        await loader().loadNavigation(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
    }

    /// Relative path → (contents, modification date) for every regular file
    /// under the test root.
    private func snapshotFiles() throws -> [String: (Data, Date)] {
        var snapshot: [String: (Data, Date)] = [:]
        let rootPath = tempDirectory.resolvingSymlinksInPath().path
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: tempDirectory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ))
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(rootPath.count))
            snapshot[relative] = (try Data(contentsOf: url), try XCTUnwrap(values.contentModificationDate))
        }
        return snapshot
    }

    // MARK: - Tests

    func testCompletedTranscriptProducesTimedAndHistoricalNavigation() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let transcriber = FakeTranscriber()
        transcriber.setOutput(output([
            TranscriptionTimingSegment(startSeconds: 0, endSeconds: 0.5, text: " First"),
            TranscriptionTimingSegment(startSeconds: 0.5, endSeconds: 0.9, text: " second")
        ]), forSequenceNumber: 0)
        transcriber.setOutput(output(nil, text: " Historical chunk"), forSequenceNumber: 1)
        await transcribeToCompletion(makeService(transcriber: transcriber))

        let loaded = await load(manifest)
        let navigation = try XCTUnwrap(loaded)

        XCTAssertEqual(navigation.sessionID, sessionID)
        XCTAssertEqual(navigation.sampleRate, 44_100)
        XCTAssertEqual(navigation.items.map(\.target), [.timedSegment(index: 0), .timedSegment(index: 1), .chunkStart])
        XCTAssertEqual(navigation.items.map(\.startSessionFrame), [0, 22_050, Int64(Self.framesPerChunk)])
        XCTAssertEqual(navigation.items.map(\.text), [" First", " second", " Historical chunk"])
    }

    func testHistoricalOnlyTranscriptRemainsNavigable() async throws {
        let manifest = try writeManifest(chunkCount: 3)
        await transcribeToCompletion(makeService(transcriber: FakeTranscriber()))

        let loaded = await load(manifest)
        let navigation = try XCTUnwrap(loaded)
        XCTAssertEqual(navigation.items.map(\.target), [.chunkStart, .chunkStart, .chunkStart])
        XCTAssertEqual(navigation.items.map(\.startSessionFrame), [0, 44_100, 88_200])
        XCTAssertEqual(navigation.items.map(\.text), Array(repeating: "fake transcript", count: 3))
    }

    func testNotTranscribedSessionIsNotNavigable() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let navigation = await load(manifest)
        XCTAssertNil(navigation)
    }

    func testIncompleteTranscriptIsNotNavigable() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let transcriber = FakeTranscriber()
        transcriber.setFailure(
            FakeTranscriberFailure(category: .engineThrew, diagnosticMessage: "boom", retryDisposition: .permanent),
            forSequenceNumber: 1
        )
        let service = makeService(transcriber: transcriber)
        await transcribeToCompletion(service)
        XCTAssertNotEqual(service.phase, .finished(.completed), "sanity: session is not complete")

        let navigation = await load(manifest)
        XCTAssertNil(navigation)
    }

    func testBlockedTranscriptIsNotNavigable() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let service = makeService(transcriber: FakeTranscriber())
        await transcribeToCompletion(service)
        let loadedBefore = await load(manifest)
        XCTAssertNotNil(loadedBefore, "sanity: navigable before corruption")

        let artifactPaths = try SessionTranscriptionEligibility.validate(
            expectedSessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths
        ).artifactPaths
        try Data("{ not json".utf8).write(to: artifactPaths.resultURL(sequenceNumber: 1))

        let status = await service.peekStatus(sessionID: sessionID, manifest: manifest, sessionPaths: sessionPaths)
        guard case .blocked = status else { return XCTFail("sanity: expected blocked, got \(status)") }
        let navigation = await load(manifest)
        XCTAssertNil(navigation)
    }

    func testLoadingInvokesNoTranscriptionAndModifiesNoFiles() async throws {
        let manifest = try writeManifest(chunkCount: 2)
        let transcriber = FakeTranscriber()
        await transcribeToCompletion(makeService(transcriber: transcriber))
        let callsBefore = transcriber.recordedCalls.count
        let filesBefore = try snapshotFiles()

        let first = await load(manifest)
        let second = await load(manifest)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(transcriber.recordedCalls.count, callsBefore, "no transcriber call")
        let filesAfter = try snapshotFiles()
        XCTAssertEqual(Set(filesAfter.keys), Set(filesBefore.keys), "no file created or removed")
        for (path, before) in filesBefore {
            XCTAssertEqual(filesAfter[path]?.0, before.0, "\(path) contents unchanged")
            XCTAssertEqual(filesAfter[path]?.1, before.1, "\(path) not rewritten")
        }
    }

    func testMismatchedSessionIdentityIsNotNavigable() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        await transcribeToCompletion(makeService(transcriber: FakeTranscriber()))

        let navigation = await loader().loadNavigation(sessionID: UUID(), manifest: manifest, sessionPaths: sessionPaths)
        XCTAssertNil(navigation)
    }

    // MARK: - Presenter integration

    func testTranscriptPresenterPublishesNavigationOnlyForCompletedTranscript() async throws {
        let manifest = try writeManifest(chunkCount: 1)
        let entry = CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)
        let service = makeService(transcriber: FakeTranscriber())
        let presenter = SessionTranscriptPresenter(loader: service, navigationLoader: loader())

        await presenter.refresh(for: entry)
        XCTAssertEqual(presenter.status, .notTranscribed)
        XCTAssertNil(presenter.navigation)

        await transcribeToCompletion(service)
        await presenter.refresh(for: entry)
        XCTAssertEqual(presenter.status, .completed)
        XCTAssertEqual(presenter.segments.count, 1)
        XCTAssertEqual(presenter.navigation?.items.map(\.startSessionFrame), [0])
    }
}
