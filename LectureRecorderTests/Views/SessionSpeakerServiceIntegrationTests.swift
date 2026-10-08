import XCTest
@testable import LectureRecorder

/// `SessionSpeakerPresenter` driven by the real, single
/// `SessionDiarizationService` (fake backend, real on-disk sessions): rerun
/// and failure behavior, the release cue, multiple windows, and presenter
/// lifetime. Each presenter is fed exactly what `SessionTranscriptView`
/// feeds it: the navigation, `refresh(for:)` on mount, and
/// `observeRelease` → `refresh(for:)` on each published release.
@MainActor
final class SessionSpeakerServiceIntegrationTests: XCTestCase {
    private typealias S = SessionDiarizationTestSupport
    private typealias F = SpeakerPresentationFixture
    private typealias Service = SessionDiarizationService

    private var root: URL!
    private var lockedDirectories: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        root = try S.makeRoot()
    }

    override func tearDown() async throws {
        for directory in lockedDirectories {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeService(
        _ diarizer: FakeSpeakerDiarizer = FakeSpeakerDiarizer(),
        sidecarCommitter: (any SessionDiarizationSidecarCommitting)? = nil
    ) -> Service {
        Service(
            diarizer: diarizer,
            sourceLoader: S.loader(root: root),
            sidecarCommitter: sidecarCommitter,
            now: { S.createdDate },
            shutdownPollInterval: 0.005
        )
    }

    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    private struct Session {
        let entry: CompletedSessionEntry
        let paths: SessionPaths
        var sessionID: UUID { entry.manifest.sessionID }
    }

    private func makeSession() throws -> Session {
        let (manifest, paths) = try S.writeSession(root: root, frameCounts: F.frameCounts)
        return Session(entry: F.entry(manifest, paths), paths: paths)
    }

    /// Commits the fixture result as the session's existing sidecar.
    @discardableResult
    private func seedFixtureSidecar(_ session: Session) async throws -> SpeakerDiarizationResult {
        let snapshot = try await S.loader(root: root).loadSourceSnapshot(sessionID: session.sessionID)
        let result = try F.result(sessionID: session.sessionID, audioSource: snapshot.audioSource)
        try SpeakerDiarizationStore().save(result, source: snapshot.source, sessionPaths: snapshot.sessionPaths)
        return result
    }

    /// What `SessionTranscriptView` does when it appears.
    private func mount(_ service: Service, _ session: Session) async -> SessionSpeakerPresenter {
        let presenter = SessionSpeakerPresenter(peeker: service, initialRelease: service.lastReleasedOperation)
        presenter.update(navigation: F.navigation(sessionID: session.sessionID))
        await presenter.reconcileOnAppear(for: session.entry, currentRelease: service.lastReleasedOperation)
        return presenter
    }

    /// What `SessionTranscriptView` does for each published release.
    @discardableResult
    private func deliver(_ release: Service.OperationRelease?, to presenter: SessionSpeakerPresenter, _ session: Session) async -> Bool {
        guard presenter.observeRelease(release, sessionID: session.sessionID) else { return false }
        await presenter.refresh(for: session.entry)
        return true
    }

    private func waitForRelease(_ service: Service, epoch: Int) async {
        await waitUntil { service.lastReleasedOperation?.operationEpoch == epoch }
    }

    private func newResult(_ session: Session) async throws -> SpeakerDiarizationResult {
        let snapshot = try await S.loader(root: root).loadSourceSnapshot(sessionID: session.sessionID)
        return try SpeakerDiarizationResult(output: S.output(), source: snapshot.source, createdDate: S.createdDate)
    }

    // MARK: - Rerun

    func testRerunKeepsOldLabelsUntilReleaseThenShowsTheNewlyCommittedResult() async throws {
        let session = try makeSession()
        let old = try await seedFixtureSidecar(session)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        let presenter = await mount(service, session)
        let oldDecoration = try XCTUnwrap(presenter.decoration)
        XCTAssertEqual(presenter.presentedResult, old)

        let availability = SpeakerIdentificationAvailabilityCalculator.availability(display: presenter.display, ownership: .none, phase: service.phase)
        XCTAssertEqual(availability.actionTitle, "Identify Speakers Again")
        presenter.recordAdmission(service.diarize(sessionID: session.sessionID))
        await waitUntil { diarizer.hasEntered }

        await presenter.refresh(for: session.entry)
        XCTAssertEqual(presenter.presentedResult, old, "durable state during a run is still the old sidecar")
        XCTAssertEqual(presenter.decoration, oldDecoration)
        XCTAssertEqual(presenter.display, .available(speakerCount: 2))

        diarizer.open()
        await waitForRelease(service, epoch: 1)
        guard case .completed(let inMemory)? = service.lastReleasedOperation?.outcome else { return XCTFail("expected completed") }
        XCTAssertEqual(presenter.presentedResult, old, "nothing changes until the release is observed")

        let refreshed = await deliver(service.lastReleasedOperation, to: presenter, session)
        XCTAssertTrue(refreshed)
        let expected = try await newResult(session)
        XCTAssertEqual(presenter.presentedResult, expected, "the newly committed sidecar, re-read from disk")
        XCTAssertEqual(inMemory, expected)
        XCTAssertNotEqual(presenter.decoration, oldDecoration)
        XCTAssertNil(presenter.releaseMessage, "success needs no message")
    }

    func testAnAuthorizedSaveKeepsOldLabelsAndCannotBeCancelled() async throws {
        let session = try makeSession()
        let old = try await seedFixtureSidecar(session)
        let committer = HoldingSidecarCommitter()
        let service = makeService(sidecarCommitter: committer)
        let presenter = await mount(service, session)
        let oldDecoration = presenter.decoration

        XCTAssertEqual(service.diarize(sessionID: session.sessionID), .admitted)
        await waitUntil { committer.hasEntered }
        XCTAssertEqual(service.phase, .saving)
        let availability = SpeakerIdentificationAvailabilityCalculator.availability(display: presenter.display, ownership: .activeHere, phase: service.phase)
        XCTAssertTrue(availability.showsCancel)
        XCTAssertFalse(availability.canCancel, "Cancel is disabled once commit is authorized")
        XCTAssertEqual(SpeakerIdentificationAvailabilityCalculator.status(display: presenter.display, ownership: .activeHere, phase: service.phase).text, "Saving speaker labels…")

        await presenter.refresh(for: session.entry)
        XCTAssertEqual(presenter.presentedResult, old)
        XCTAssertEqual(presenter.decoration, oldDecoration)

        service.cancel(sessionID: session.sessionID)
        XCTAssertEqual(service.phase, .saving)
        committer.release()
        await waitForRelease(service, epoch: 1)
        await deliver(service.lastReleasedOperation, to: presenter, session)

        let expected = try await newResult(session)
        XCTAssertEqual(presenter.presentedResult, expected)
    }

    /// Runs one operation for an existing valid sidecar and asserts the old
    /// labels are still what is presented after the release is observed.
    private func assertFailedRerunKeepsOldLabels(
        _ service: Service,
        _ session: Session,
        old: SpeakerDiarizationResult,
        expectedMessage: String,
        during: (() async throws -> Void)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let presenter = await mount(service, session)
        let oldDecoration = try XCTUnwrap(presenter.decoration, file: file, line: line)
        let epoch = service.operationEpoch + 1
        XCTAssertEqual(service.diarize(sessionID: session.sessionID), .admitted, file: file, line: line)
        try await during?()
        await waitForRelease(service, epoch: epoch)

        let refreshed = await deliver(service.lastReleasedOperation, to: presenter, session)
        XCTAssertTrue(refreshed, file: file, line: line)
        XCTAssertEqual(presenter.releaseMessage, expectedMessage, file: file, line: line)
        XCTAssertEqual(presenter.presentedResult, old, "the old committed result is still authoritative", file: file, line: line)
        XCTAssertEqual(presenter.decoration, oldDecoration, file: file, line: line)
        XCTAssertEqual(presenter.display, .available(speakerCount: 2), file: file, line: line)
    }

    func testBackendFailureKeepsOldLabels() async throws {
        let session = try makeSession()
        let old = try await seedFixtureSidecar(session)
        let service = makeService(FakeSpeakerDiarizer(response: .failure(FakeDiarizerError())))
        try await assertFailedRerunKeepsOldLabels(service, session, old: old, expectedMessage: "Speaker identification couldn't finish.")
    }

    func testInvalidBackendOutputKeepsOldLabels() async throws {
        let session = try makeSession()
        let old = try await seedFixtureSidecar(session)
        let malformed = SpeakerDiarizationOutput(
            provenance: S.provenance,
            segments: [DiarizationBackendSegment(label: "A", startSeconds: 1, endSeconds: 0.5)]
        )
        let service = makeService(FakeSpeakerDiarizer(response: .success(malformed)))
        try await assertFailedRerunKeepsOldLabels(service, session, old: old, expectedMessage: "Speaker identification produced an unusable result.")
    }

    func testSaveFailureKeepsOldLabels() async throws {
        let session = try makeSession()
        let old = try await seedFixtureSidecar(session)
        let directory = DiarizationArtifactPaths.directory(sessionPaths: session.paths)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        lockedDirectories.append(directory)
        try await assertFailedRerunKeepsOldLabels(makeService(), session, old: old, expectedMessage: "Speaker labels couldn't be saved.")
    }

    func testCancellationKeepsOldLabels() async throws {
        let session = try makeSession()
        let old = try await seedFixtureSidecar(session)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        try await assertFailedRerunKeepsOldLabels(service, session, old: old, expectedMessage: "Speaker identification cancelled.") {
            await self.waitUntil { diarizer.hasEntered }
            service.cancel(sessionID: session.sessionID)
            XCTAssertEqual(service.phase, .cancelling)
        }
    }

    func testStaleSourceKeepsOldLabelsOnceTheSourceIsCurrentAgain() async throws {
        let session = try makeSession()
        let old = try await seedFixtureSidecar(session)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        let manifest = session.entry.manifest
        try await assertFailedRerunKeepsOldLabels(service, session, old: old, expectedMessage: "The recording changed while speakers were being identified. Try again.") {
            await self.waitUntil { diarizer.hasEntered }
            // Briefly nonterminal while the backend runs, so its output is
            // stale; then terminal with the very same audio again before
            // anything re-reads durable state.
            var recording = manifest
            recording.status = .recording
            try S.writeManifest(recording, paths: session.paths)
            diarizer.open()
            await self.waitUntil { service.lastReleasedOperation?.operationEpoch == service.operationEpoch }
            XCTAssertEqual(service.lastReleasedOperation?.outcome, .staleSource)
            try S.writeManifest(manifest, paths: session.paths)
        }
    }

    // MARK: - Release cue

    func testAPaneMountedAfterAFailureShowsDurableStateWithoutTheOldMessage() async throws {
        let session = try makeSession()
        let old = try await seedFixtureSidecar(session)
        let service = makeService(FakeSpeakerDiarizer(response: .failure(FakeDiarizerError())))
        XCTAssertEqual(service.diarize(sessionID: session.sessionID), .admitted)
        await waitForRelease(service, epoch: 1)

        let presenter = await mount(service, session)
        let refreshed = await deliver(service.lastReleasedOperation, to: presenter, session)
        XCTAssertFalse(refreshed)
        XCTAssertNil(presenter.releaseMessage, "an earlier operation's failure is not resurrected")
        XCTAssertEqual(presenter.presentedResult, old)
    }

    func testAReleaseBetweenCreationAndObservationIsShownOnceOnAppear() async throws {
        let session = try makeSession()
        let old = try await seedFixtureSidecar(session)
        let service = makeService(FakeSpeakerDiarizer(response: .failure(FakeDiarizerError())))
        // Created as the view's `@StateObject` is, before anything has run.
        let presenter = SessionSpeakerPresenter(peeker: service, initialRelease: service.lastReleasedOperation)
        presenter.update(navigation: F.navigation(sessionID: session.sessionID))

        // The operation releases before the view observes changes.
        XCTAssertEqual(service.diarize(sessionID: session.sessionID), .admitted)
        await waitForRelease(service, epoch: 1)

        await presenter.reconcileOnAppear(for: session.entry, currentRelease: service.lastReleasedOperation)
        XCTAssertEqual(presenter.releaseMessage, "Speaker identification couldn't finish.")
        XCTAssertEqual(presenter.presentedResult, old)
        XCTAssertNotNil(presenter.decoration)

        let again = await deliver(service.lastReleasedOperation, to: presenter, session)
        XCTAssertFalse(again, "the observer seeing the same release does not process it twice")
    }

    // MARK: - Multiple windows and lifetime

    func testTwoPanesForOneSessionFollowTheOneOperationAndRefreshFromOneRelease() async throws {
        let a = try makeSession()
        let b = try makeSession()
        try await seedFixtureSidecar(b)
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        let paneA1 = await mount(service, a)
        let paneA2 = await mount(service, a)
        let paneB = await mount(service, b)
        let bDecoration = try XCTUnwrap(paneB.decoration)

        XCTAssertEqual(service.diarize(sessionID: a.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }

        for pane in [paneA1, paneA2] {
            let ownership = SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: service.activeSessionID, sessionID: a.sessionID)
            XCTAssertEqual(ownership, .activeHere)
            let availability = SpeakerIdentificationAvailabilityCalculator.availability(display: pane.display, ownership: ownership, phase: service.phase)
            XCTAssertTrue(availability.canCancel)
            XCTAssertEqual(SpeakerIdentificationAvailabilityCalculator.status(display: pane.display, ownership: ownership, phase: service.phase).text, "Identifying speakers…")
        }

        let ownershipB = SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: service.activeSessionID, sessionID: b.sessionID)
        XCTAssertEqual(ownershipB, .busyElsewhere)
        let availabilityB = SpeakerIdentificationAvailabilityCalculator.availability(display: paneB.display, ownership: ownershipB, phase: service.phase)
        XCTAssertFalse(availabilityB.canIdentify)
        XCTAssertFalse(availabilityB.showsCancel)
        XCTAssertEqual(paneB.decoration, bDecoration, "B's existing labels stay visible while busy elsewhere")
        XCTAssertEqual(service.diarize(sessionID: b.sessionID), .busy, "no second operation, nothing queued")
        paneB.recordAdmission(.busy)
        XCTAssertNotNil(paneB.admissionMessage)

        diarizer.open()
        await waitForRelease(service, epoch: 1)
        let release = service.lastReleasedOperation
        let refreshedA1 = await deliver(release, to: paneA1, a)
        let refreshedA2 = await deliver(release, to: paneA2, a)
        let refreshedB = await deliver(release, to: paneB, b)
        XCTAssertTrue(refreshedA1)
        XCTAssertTrue(refreshedA2)
        XCTAssertFalse(refreshedB, "another session's release changes nothing for B")

        let expected = try await newResult(a)
        XCTAssertEqual(paneA1.presentedResult, expected)
        XCTAssertEqual(paneA2.presentedResult, expected)
        XCTAssertEqual(paneA1.decoration, paneA2.decoration)
        XCTAssertEqual(paneB.decoration, bDecoration)
    }

    func testAPaneGoingAwayNeverCancelsAndALaterPaneRebuildsFromDisk() async throws {
        let session = try makeSession()
        let diarizer = FakeSpeakerDiarizer(gate: .cooperative)
        let service = makeService(diarizer)
        var origin: SessionSpeakerPresenter? = await mount(service, session)
        weak let weakOrigin = origin

        XCTAssertEqual(service.diarize(sessionID: session.sessionID), .admitted)
        await waitUntil { diarizer.hasEntered }
        origin = nil
        XCTAssertNil(weakOrigin, "the presenter holds no operation and is released normally")
        XCTAssertEqual(service.activeSessionID, session.sessionID)
        XCTAssertEqual(service.phase, .diarizing, "the operation is unaffected")
        XCTAssertFalse(diarizer.sawCancellationWhileGated)

        diarizer.open()
        await waitForRelease(service, epoch: 1)
        XCTAssertNotNil(S.sidecarData(session.paths), "finished with no pane present")

        let later = await mount(service, session)
        let expected = try await newResult(session)
        XCTAssertEqual(later.presentedResult, expected)
        XCTAssertNotNil(later.decoration)
        XCTAssertNil(later.releaseMessage)
    }
}
