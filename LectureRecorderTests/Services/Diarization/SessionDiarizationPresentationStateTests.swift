import XCTest
@testable import LectureRecorder

/// `SessionDiarizationService.peekPresentationState`: the read-only durable
/// query that pairs a usable result with the source it was validated
/// against, and that `peekState` is defined by.
@MainActor
final class SessionDiarizationPresentationStateTests: XCTestCase {
    private typealias S = SessionDiarizationTestSupport
    private typealias Service = SessionDiarizationService

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try S.makeRoot()
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func makeService(_ diarizer: FakeSpeakerDiarizer) -> Service {
        Service(diarizer: diarizer, sourceLoader: S.loader(root: root), now: { S.createdDate })
    }

    /// Asserts the presentation state, that `peekState` reports exactly its
    /// `durableState`, and that neither read changes anything on disk.
    private func assertPresentation(
        _ service: Service,
        _ sessionID: UUID,
        _ expected: Service.PresentationState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let before = try S.tree(root)
        let state = await service.peekPresentationState(sessionID: sessionID)
        XCTAssertEqual(state, expected, file: file, line: line)
        let durable = await service.peekState(sessionID: sessionID)
        XCTAssertEqual(durable, expected.durableState, "peekState is the same read", file: file, line: line)
        XCTAssertEqual(try S.tree(root), before, "the query never creates, repairs, or deletes anything", file: file, line: line)
    }

    func testEveryDurableStateIsReportedReadOnlyAndWithoutTheBackend() async throws {
        let diarizer = FakeSpeakerDiarizer()
        let service = makeService(diarizer)
        let (manifest, paths) = try S.writeSession(root: root)
        let sessionID = manifest.sessionID
        let directory = DiarizationArtifactPaths.directory(sessionPaths: paths)

        try await assertPresentation(service, sessionID, .absent)

        let seeded = try await S.seedSidecar(root: root, sessionID: sessionID)
        let seededResult = try AtomicFileWriter.defaultDecoder.decode(SpeakerDiarizationResult.self, from: seeded)
        let source = try await S.loader(root: root).loadSourceSnapshot(sessionID: sessionID).source
        try await assertPresentation(service, sessionID, .available(result: seededResult, source: source))

        try Data("{ not json".utf8).write(to: S.sidecarURL(paths))
        try await assertPresentation(service, sessionID, .unavailable(.corrupt))

        try Data(#"{"schemaVersion": 99}"#.utf8).write(to: S.sidecarURL(paths))
        try await assertPresentation(service, sessionID, .unavailable(.unsupportedSchemaVersion(99)))

        try FileManager.default.removeItem(at: directory)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
        try await assertPresentation(service, sessionID, .unavailable(.unsafePath))
        try FileManager.default.removeItem(at: directory)

        _ = try await S.seedSidecar(root: root, sessionID: sessionID)
        try S.writeSession(root: root, sessionID: sessionID, frameCounts: [16_000, 4_000])
        try await assertPresentation(service, sessionID, .unavailable(.audioSourceMismatch))

        var recording = try AtomicFileWriter.readJSON(SessionManifest.self, from: paths.manifestURL)
        recording.status = .recording
        try S.writeManifest(recording, paths: paths)
        try await assertPresentation(service, sessionID, .sourceUnavailable(.notTerminal(.recording)))
        try await assertPresentation(service, UUID(), .sourceUnavailable(.sessionUnavailable))

        XCTAssertEqual(diarizer.callCount, 0, "the query never invokes the backend")
        XCTAssertEqual(service.operationEpoch, 0, "the query never admits an operation")
        XCTAssertEqual(service.phase, .idle)
        XCTAssertNil(service.activeSessionID)
        XCTAssertNil(service.lastReleasedOperation)
    }

    func testAnotherSessionsSidecarIsReportedAsSessionMismatch() async throws {
        let service = makeService(FakeSpeakerDiarizer())
        let (manifestA, pathsA) = try S.writeSession(root: root)
        let (manifestB, _) = try S.writeSession(root: root)
        let sidecarB = try await S.seedSidecar(root: root, sessionID: manifestB.sessionID)
        try FileManager.default.createDirectory(at: DiarizationArtifactPaths.directory(sessionPaths: pathsA), withIntermediateDirectories: true)
        try sidecarB.write(to: S.sidecarURL(pathsA))

        try await assertPresentation(service, manifestA.sessionID, .unavailable(.sessionMismatch))
    }

    func testAvailableResultIsPairedWithTheSourceItWasValidatedAgainst() async throws {
        let service = makeService(FakeSpeakerDiarizer())
        let (manifest, _) = try S.writeSession(root: root, frameCounts: [16_000, 16_000, 8_000])
        _ = try await S.seedSidecar(root: root, sessionID: manifest.sessionID)

        let state = await service.peekPresentationState(sessionID: manifest.sessionID)

        guard case .available(let result, let source) = state else { return XCTFail("expected available, got \(state)") }
        XCTAssertEqual(source.timeline.sessionID, manifest.sessionID)
        XCTAssertEqual(source.timeline.chunks.map(\.frameCount), [16_000, 16_000, 8_000])
        XCTAssertEqual(result.audioSource, DiarizationAudioSourceFingerprint.compute(source: source))
        XCTAssertNoThrow(try SpeakerTranscriptAligner().align(
            TranscriptPlaybackNavigation(sessionID: manifest.sessionID, sampleRate: S.sampleRate, items: []),
            with: result,
            source: source
        ), "the pair aligns without another read")
    }

    func testTheQueryIsAvailableWhileAnOperationIsActiveAndChangesNothingAboutIt() async throws {
        let (manifest, _) = try S.writeSession(root: root)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        XCTAssertEqual(service.diarize(sessionID: manifest.sessionID), .admitted)
        let deadline = ContinuousClock.now + .seconds(5)
        while !diarizer.hasEntered, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(diarizer.hasEntered)

        let state = await service.peekPresentationState(sessionID: manifest.sessionID)
        XCTAssertEqual(state, .absent)
        XCTAssertEqual(service.phase, .diarizing)
        XCTAssertEqual(service.activeSessionID, manifest.sessionID)
        XCTAssertEqual(service.operationEpoch, 1)

        service.cancel(sessionID: manifest.sessionID)
        while service.lastReleasedOperation == nil, ContinuousClock.now < deadline + .seconds(5) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(service.lastReleasedOperation?.outcome, .cancelled)
    }
}
