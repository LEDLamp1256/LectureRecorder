import XCTest
@testable import LectureRecorder

/// A 3 s, three-chunk 16 kHz session with a known speaker layout and a
/// matching transcript navigation, shared by the speaker-presentation tests.
///
/// Speakers: `speaker_0` [0, 1), `speaker_1` [1, 2.5), `speaker_0` [2.5, 3).
/// Items (expected attribution → header):
/// - chunk 0, segment 0, [0, 0.5) → speaker_0 → "Speaker 1"
/// - chunk 0, segment 1, [0.5, 1) → speaker_0 → (none)
/// - chunk 1, `.chunkStart`, [1, 2) → ineligible → "Speaker not identified"
/// - chunk 2, segment 0, [2, 2.5) → speaker_1 → "Speaker 2"
/// - chunk 2, segment 1, [2.5, 3) → speaker_0 → "Speaker 1"
enum SpeakerPresentationFixture {
    static let frameCounts = [16_000, 16_000, 16_000]

    static func result(sessionID: UUID, audioSource: DiarizationAudioSourceFingerprint, createdDate: Date = Date(timeIntervalSince1970: 1_000)) throws -> SpeakerDiarizationResult {
        try SpeakerDiarizationResult(
            sessionID: sessionID,
            createdDate: createdDate,
            provenance: SpeakerDiarizationProvenance(backendIdentifier: "fixture", backendVersion: "1", configurationIdentifier: "fixture"),
            audioSource: audioSource,
            ranges: [
                SpeakerTimeRange(speakerID: try SpeakerID(index: 0), startSeconds: 0, endSeconds: 1),
                SpeakerTimeRange(speakerID: try SpeakerID(index: 1), startSeconds: 1, endSeconds: 2.5),
                SpeakerTimeRange(speakerID: try SpeakerID(index: 0), startSeconds: 2.5, endSeconds: 3),
            ]
        )
    }

    static func item(_ chunk: Int, _ target: TranscriptPlaybackItem.Target, _ start: Int64, _ end: Int64) -> TranscriptPlaybackItem {
        TranscriptPlaybackItem(chunkSequenceNumber: chunk, target: target, text: "passage \(chunk) \(target)", startSessionFrame: start, endSessionFrame: end)
    }

    static func items() -> [TranscriptPlaybackItem] {
        [
            item(0, .timedSegment(index: 0), 0, 8_000),
            item(0, .timedSegment(index: 1), 8_000, 16_000),
            item(1, .chunkStart, 16_000, 32_000),
            item(2, .timedSegment(index: 0), 32_000, 40_000),
            item(2, .timedSegment(index: 1), 40_000, 48_000),
        ]
    }

    static func navigation(sessionID: UUID, items: [TranscriptPlaybackItem] = items(), sampleRate: Double = 16_000) -> TranscriptPlaybackNavigation {
        TranscriptPlaybackNavigation(sessionID: sessionID, sampleRate: sampleRate, items: items)
    }

    static func expectedHeaders() throws -> [TranscriptPlaybackItem.ID: SpeakerRowHeader] {
        let items = items()
        return [
            items[0].id: .speaker(try SpeakerID(index: 0)),
            items[2].id: .notIdentified,
            items[3].id: .speaker(try SpeakerID(index: 1)),
            items[4].id: .speaker(try SpeakerID(index: 0)),
        ]
    }

    static func entry(_ manifest: SessionManifest, _ paths: SessionPaths) -> CompletedSessionEntry {
        CompletedSessionEntry(manifest: manifest, sessionPaths: paths)
    }
}

/// A controllable `SessionDiarizationPresentationPeeking`: returns a set
/// state per session, and can hold a session's read until resumed.
@MainActor
final class FakePresentationPeeker: SessionDiarizationPresentationPeeking {
    var states: [UUID: SessionDiarizationService.PresentationState] = [:]
    private(set) var callCount = 0
    private var gated: Set<UUID> = []
    private var pending: [UUID: CheckedContinuation<Void, Never>] = [:]

    func gate(_ sessionID: UUID) { gated.insert(sessionID) }
    func hasPending(_ sessionID: UUID) -> Bool { pending[sessionID] != nil }
    func resume(_ sessionID: UUID) { pending.removeValue(forKey: sessionID)?.resume() }

    func peekPresentationState(sessionID: UUID) async -> SessionDiarizationService.PresentationState {
        callCount += 1
        if gated.remove(sessionID) != nil {
            await withCheckedContinuation { pending[sessionID] = $0 }
        }
        return states[sessionID] ?? .absent
    }
}

/// `SessionSpeakerPresenter` against a fake durable read over real session
/// audio: durable display mapping, decoration, generation guarding, and
/// release-cue semantics.
@MainActor
final class SessionSpeakerPresenterTests: XCTestCase {
    private typealias S = SessionDiarizationTestSupport
    private typealias F = SpeakerPresentationFixture

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try S.makeRoot()
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private struct Fixture {
        let entry: CompletedSessionEntry
        let snapshot: SessionDiarizationSourceSnapshot
        let result: SpeakerDiarizationResult
        var sessionID: UUID { entry.manifest.sessionID }
        var available: SessionDiarizationService.PresentationState { .available(result: result, source: snapshot.source) }
    }

    private func makeFixture(frameCounts: [Int] = F.frameCounts) async throws -> Fixture {
        let (manifest, paths) = try S.writeSession(root: root, frameCounts: frameCounts)
        let snapshot = try await S.loader(root: root).loadSourceSnapshot(sessionID: manifest.sessionID)
        let result = try F.result(sessionID: manifest.sessionID, audioSource: snapshot.audioSource)
        return Fixture(entry: F.entry(manifest, paths), snapshot: snapshot, result: result)
    }

    private func makePresenter(_ peeker: FakePresentationPeeker, initialRelease: SessionDiarizationService.OperationRelease? = nil) -> SessionSpeakerPresenter {
        SessionSpeakerPresenter(peeker: peeker, initialRelease: initialRelease)
    }

    // MARK: - Durable state

    func testStartsLoadingAndAbsentSidecarHasNothingToDecorate() async throws {
        let fixture = try await makeFixture()
        let peeker = FakePresentationPeeker()
        let presenter = makePresenter(peeker)
        XCTAssertEqual(presenter.display, .loading)

        presenter.update(navigation: F.navigation(sessionID: fixture.sessionID))
        await presenter.refresh(for: fixture.entry)

        XCTAssertEqual(presenter.displayedSessionID, fixture.sessionID)
        XCTAssertEqual(presenter.display, .absent)
        XCTAssertNil(presenter.decoration)
        XCTAssertNil(presenter.presentedResult)
    }

    func testValidResultWithoutNavigationIsAvailableAndDecoratesOnceNavigationArrives() async throws {
        let fixture = try await makeFixture()
        let peeker = FakePresentationPeeker()
        peeker.states[fixture.sessionID] = fixture.available
        let presenter = makePresenter(peeker)

        await presenter.refresh(for: fixture.entry)
        XCTAssertEqual(presenter.display, .available(speakerCount: 2))
        XCTAssertNil(presenter.decoration, "nothing to decorate without a transcript")
        XCTAssertEqual(presenter.presentedResult, fixture.result)

        let navigation = F.navigation(sessionID: fixture.sessionID)
        presenter.update(navigation: navigation)

        XCTAssertEqual(peeker.callCount, 1, "navigation arriving re-aligns without another durable read")
        XCTAssertEqual(presenter.display, .available(speakerCount: 2))
        XCTAssertEqual(presenter.decoration?.headerByItemID, try F.expectedHeaders())
        let attributions = try XCTUnwrap(presenter.decoration?.attributionByItemID)
        let items = F.items()
        XCTAssertEqual(attributions[items[0].id], .speaker(try SpeakerID(index: 0)))
        XCTAssertEqual(attributions[items[1].id], .speaker(try SpeakerID(index: 0)))
        XCTAssertEqual(attributions[items[2].id], .ineligible)
        XCTAssertEqual(attributions[items[3].id], .speaker(try SpeakerID(index: 1)))
        XCTAssertEqual(attributions[items[4].id], .speaker(try SpeakerID(index: 0)))
    }

    func testDecorationIsKeyedOnlyByExistingItemIDsAndNeverChangesTheNavigation() async throws {
        let fixture = try await makeFixture()
        let peeker = FakePresentationPeeker()
        peeker.states[fixture.sessionID] = fixture.available
        let presenter = makePresenter(peeker)
        let navigation = F.navigation(sessionID: fixture.sessionID)
        let copy = navigation

        presenter.update(navigation: navigation)
        await presenter.refresh(for: fixture.entry)

        let decoration = try XCTUnwrap(presenter.decoration)
        let itemIDs = Set(navigation.items.map(\.id))
        XCTAssertEqual(Set(decoration.attributionByItemID.keys), itemIDs)
        XCTAssertTrue(Set(decoration.headerByItemID.keys).isSubset(of: itemIDs))
        XCTAssertEqual(navigation, copy, "the input navigation is never modified")
        XCTAssertEqual(navigation.items.map(\.id), F.items().map(\.id))
    }

    func testNavigationChangeDropsTheOldDecorationAndRealigns() async throws {
        let fixture = try await makeFixture()
        let peeker = FakePresentationPeeker()
        peeker.states[fixture.sessionID] = fixture.available
        let presenter = makePresenter(peeker)
        presenter.update(navigation: F.navigation(sessionID: fixture.sessionID))
        await presenter.refresh(for: fixture.entry)
        XCTAssertNotNil(presenter.decoration)

        // A re-transcribed chunk 1 now has a timed segment: the old map,
        // which recorded chunk 1 as ineligible, must not be reused.
        var items = F.items()
        items[2] = F.item(1, .timedSegment(index: 0), 16_000, 32_000)
        let changed = F.navigation(sessionID: fixture.sessionID, items: items)
        presenter.update(navigation: changed)

        let decoration = try XCTUnwrap(presenter.decoration)
        XCTAssertEqual(Set(decoration.attributionByItemID.keys), Set(items.map(\.id)))
        XCTAssertEqual(decoration.attributionByItemID[items[2].id], .speaker(try SpeakerID(index: 1)))
        XCTAssertEqual(decoration.headerByItemID[items[2].id], .speaker(try SpeakerID(index: 1)))
        XCTAssertNil(decoration.headerByItemID[items[3].id], "chunk 2's first row continues Speaker 2's group")

        presenter.update(navigation: nil)
        XCTAssertNil(presenter.decoration)
        XCTAssertEqual(presenter.display, .available(speakerCount: 2))
        XCTAssertEqual(peeker.callCount, 1)
    }

    func testNavigationForAnotherSessionIsNeverDecorated() async throws {
        let fixture = try await makeFixture()
        let peeker = FakePresentationPeeker()
        peeker.states[fixture.sessionID] = fixture.available
        let presenter = makePresenter(peeker)
        presenter.update(navigation: F.navigation(sessionID: UUID()))
        await presenter.refresh(for: fixture.entry)

        XCTAssertNil(presenter.decoration)
        XCTAssertEqual(presenter.display, .available(speakerCount: 2))
    }

    func testUnavailableSidecarsMapToPresentationStatesWithoutDecoration() async throws {
        let fixture = try await makeFixture()
        let cases: [(SessionDiarizationService.PresentationState, SpeakerDurableDisplay)] = [
            (.unavailable(.audioSourceMismatch), .outOfDate),
            (.unavailable(.corrupt), .unreadable(.sidecar(.corrupt))),
            (.unavailable(.unsupportedSchemaVersion(7)), .unreadable(.sidecar(.unsupportedSchemaVersion(7)))),
            (.unavailable(.invalidResult(.nonDenseSpeakerIDs)), .unreadable(.sidecar(.invalidResult(.nonDenseSpeakerIDs)))),
            (.unavailable(.sessionMismatch), .unreadable(.sidecar(.sessionMismatch))),
            (.unavailable(.unsafePath), .storageUnavailable),
            (.sourceUnavailable(.notTerminal(.recording)), .sourceUnavailable(.notTerminal(.recording))),
            (.sourceUnavailable(.sessionUnavailable), .sourceUnavailable(.sessionUnavailable)),
        ]
        for (state, expected) in cases {
            let peeker = FakePresentationPeeker()
            peeker.states[fixture.sessionID] = state
            let presenter = makePresenter(peeker)
            presenter.update(navigation: F.navigation(sessionID: fixture.sessionID))
            await presenter.refresh(for: fixture.entry)
            XCTAssertEqual(presenter.display, expected, "\(state)")
            XCTAssertNil(presenter.decoration, "\(state) never decorates rows")
            XCTAssertNil(presenter.presentedResult)
        }
    }

    func testAlignmentFailureNeverPublishesPartialDecoration() async throws {
        let fixture = try await makeFixture()
        let peeker = FakePresentationPeeker()
        peeker.states[fixture.sessionID] = fixture.available
        let presenter = makePresenter(peeker)
        await presenter.refresh(for: fixture.entry)

        presenter.update(navigation: F.navigation(sessionID: fixture.sessionID, sampleRate: 44_100))
        XCTAssertNil(presenter.decoration)
        XCTAssertEqual(presenter.display, .unreadable(.alignment(.sampleRateMismatch)))

        // A matching navigation recovers without another read.
        presenter.update(navigation: F.navigation(sessionID: fixture.sessionID))
        XCTAssertNotNil(presenter.decoration)
        XCTAssertEqual(presenter.display, .available(speakerCount: 2))
    }

    func testResultForOtherAudioIsOutOfDateAtAlignment() async throws {
        let fixture = try await makeFixture()
        // The same session's audio, re-read after it grew: the result no
        // longer describes this source.
        try S.writeSession(root: root, sessionID: fixture.sessionID, frameCounts: [16_000, 16_000, 24_000])
        let longer = try await S.loader(root: root).loadSourceSnapshot(sessionID: fixture.sessionID)
        let peeker = FakePresentationPeeker()
        peeker.states[fixture.sessionID] = .available(result: fixture.result, source: longer.source)
        let presenter = makePresenter(peeker)
        presenter.update(navigation: F.navigation(sessionID: fixture.sessionID))
        await presenter.refresh(for: fixture.entry)

        XCTAssertEqual(presenter.display, .outOfDate)
        XCTAssertNil(presenter.decoration)
    }

    func testStaleReadCannotOverwriteANewerSession() async throws {
        let a = try await makeFixture()
        let b = try await makeFixture()
        let peeker = FakePresentationPeeker()
        peeker.states[a.sessionID] = a.available
        peeker.states[b.sessionID] = .absent
        peeker.gate(a.sessionID)
        let presenter = makePresenter(peeker)

        let first = Task { await presenter.refresh(for: a.entry) }
        while !peeker.hasPending(a.sessionID) { await Task.yield() }
        await presenter.refresh(for: b.entry)
        peeker.resume(a.sessionID)
        await first.value

        XCTAssertEqual(presenter.displayedSessionID, b.sessionID)
        XCTAssertEqual(presenter.display, .absent)
        XCTAssertNil(presenter.presentedResult)
    }

    func testRefreshOfTheSameSessionKeepsThePreviousPresentationUntilTheReadLands() async throws {
        let fixture = try await makeFixture()
        let peeker = FakePresentationPeeker()
        peeker.states[fixture.sessionID] = fixture.available
        let presenter = makePresenter(peeker)
        presenter.update(navigation: F.navigation(sessionID: fixture.sessionID))
        await presenter.refresh(for: fixture.entry)
        let decoration = presenter.decoration
        XCTAssertNotNil(decoration)

        peeker.gate(fixture.sessionID)
        let refresh = Task { await presenter.refresh(for: fixture.entry) }
        while !peeker.hasPending(fixture.sessionID) { await Task.yield() }
        XCTAssertEqual(presenter.display, .available(speakerCount: 2))
        XCTAssertEqual(presenter.decoration, decoration)
        peeker.resume(fixture.sessionID)
        await refresh.value
        XCTAssertEqual(presenter.decoration, decoration)
    }

    // MARK: - Release cue

    private func release(_ sessionID: UUID, epoch: Int, _ outcome: SessionDiarizationService.DiarizationOperationOutcome?) -> SessionDiarizationService.OperationRelease {
        SessionDiarizationService.OperationRelease(sessionID: sessionID, operationEpoch: epoch, outcome: outcome)
    }

    func testTheReleaseCurrentAtCreationIsAcknowledgedWithoutAMessage() {
        let sessionID = UUID()
        let old = release(sessionID, epoch: 3, .failed(.backendFailed(description: "detail")))
        let presenter = makePresenter(FakePresentationPeeker(), initialRelease: old)

        XCTAssertFalse(presenter.observeRelease(old, sessionID: sessionID))
        XCTAssertNil(presenter.releaseMessage)
        XCTAssertFalse(presenter.observeRelease(nil, sessionID: sessionID))
    }

    func testAppearanceWithTheReleaseCurrentAtCreationStaysSilentButStillReadsDisk() async throws {
        let fixture = try await makeFixture()
        let peeker = FakePresentationPeeker()
        let seeded = release(fixture.sessionID, epoch: 4, .failed(.backendFailed(description: "detail")))
        let presenter = makePresenter(peeker, initialRelease: seeded)

        await presenter.reconcileOnAppear(for: fixture.entry, currentRelease: seeded)

        XCTAssertNil(presenter.releaseMessage, "a release that predates the pane is never resurrected")
        XCTAssertEqual(peeker.callCount, 1)
        XCTAssertEqual(presenter.display, .absent)
    }

    func testAReleasePublishedAfterCreationButBeforeObservationIsProcessedOnceOnAppear() async throws {
        let fixture = try await makeFixture()
        for seeded in [nil, release(fixture.sessionID, epoch: 4, .cancelled)] {
            let peeker = FakePresentationPeeker()
            let presenter = makePresenter(peeker, initialRelease: seeded)
            // Published after construction, before the view's `onChange`
            // observer could see it.
            let missed = release(fixture.sessionID, epoch: 5, .failed(.saveFailed(description: "detail")))

            await presenter.reconcileOnAppear(for: fixture.entry, currentRelease: missed)
            XCTAssertEqual(presenter.releaseMessage, "Speaker labels couldn't be saved.", "seeded: \(String(describing: seeded))")
            XCTAssertEqual(peeker.callCount, 1, "the appearance read is the durable refresh")
            XCTAssertEqual(presenter.displayedSessionID, fixture.sessionID)

            // The same release later reaching the observer, or a repeated
            // appearance, is not processed again.
            XCTAssertFalse(presenter.observeRelease(missed, sessionID: fixture.sessionID))
            presenter.recordAdmission(.admitted)
            await presenter.reconcileOnAppear(for: fixture.entry, currentRelease: missed)
            XCTAssertNil(presenter.releaseMessage, "the epoch is processed only once")

            // Later releases still flow through ordinary observation.
            XCTAssertTrue(presenter.observeRelease(release(fixture.sessionID, epoch: 6, .cancelled), sessionID: fixture.sessionID))
            XCTAssertEqual(presenter.releaseMessage, "Speaker identification cancelled.")
        }
    }

    func testAnotherSessionsReleaseOnAppearStaysSilent() async throws {
        let fixture = try await makeFixture()
        let presenter = makePresenter(FakePresentationPeeker())
        let other = release(UUID(), epoch: 1, .failed(.invalidBackendOutput))

        await presenter.reconcileOnAppear(for: fixture.entry, currentRelease: other)

        XCTAssertNil(presenter.releaseMessage)
        XCTAssertFalse(presenter.observeRelease(other, sessionID: fixture.sessionID))
    }

    func testANewReleaseForThisSessionCuesARefreshAndAMessage() {
        let sessionID = UUID()
        let presenter = makePresenter(FakePresentationPeeker(), initialRelease: release(sessionID, epoch: 1, .cancelled))

        XCTAssertTrue(presenter.observeRelease(release(sessionID, epoch: 2, .failed(.backendFailed(description: "model detail /path"))), sessionID: sessionID))
        XCTAssertEqual(presenter.releaseMessage, "Speaker identification couldn't finish.")
        XCTAssertFalse(presenter.observeRelease(release(sessionID, epoch: 2, .cancelled), sessionID: sessionID), "the same epoch is seen once")

        XCTAssertTrue(presenter.observeRelease(release(sessionID, epoch: 3, .cancelled), sessionID: sessionID))
        XCTAssertEqual(presenter.releaseMessage, "Speaker identification cancelled.")
    }

    func testAnotherSessionsReleaseChangesNothingHere() {
        let sessionID = UUID()
        let presenter = makePresenter(FakePresentationPeeker())
        XCTAssertTrue(presenter.observeRelease(release(sessionID, epoch: 1, .staleSource), sessionID: sessionID))
        let message = presenter.releaseMessage

        XCTAssertFalse(presenter.observeRelease(release(UUID(), epoch: 2, .failed(.invalidBackendOutput)), sessionID: sessionID))
        XCTAssertEqual(presenter.releaseMessage, message)
        XCTAssertFalse(presenter.observeRelease(release(sessionID, epoch: 1, .cancelled), sessionID: sessionID), "an older epoch is never new")
    }

    func testAdmissionMessagesAndAdmittedOperationsClearEarlierMessages() {
        let sessionID = UUID()
        let presenter = makePresenter(FakePresentationPeeker())
        _ = presenter.observeRelease(release(sessionID, epoch: 1, .failed(.saveFailed(description: "x"))), sessionID: sessionID)
        XCTAssertEqual(presenter.releaseMessage, "Speaker labels couldn't be saved.")

        presenter.recordAdmission(.busy)
        XCTAssertEqual(presenter.admissionMessage, "Speakers are already being identified for another session.")
        XCTAssertEqual(presenter.releaseMessage, "Speaker labels couldn't be saved.")

        presenter.recordAdmission(.shuttingDown)
        XCTAssertEqual(presenter.admissionMessage, "Speaker identification can't start while the app is quitting.")

        presenter.recordAdmission(.admitted)
        XCTAssertNil(presenter.admissionMessage)
        XCTAssertNil(presenter.releaseMessage)
    }
}
