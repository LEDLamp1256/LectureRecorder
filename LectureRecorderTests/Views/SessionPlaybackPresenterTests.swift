import XCTest
@testable import LectureRecorder

/// Honours the backend contract that `renderedSessionFrame()` is `nil` once
/// nothing is playing, and counts render-clock samples.
@MainActor
private final class PresenterFakeBackend: LectureAudioPlaybackBackend {
    private(set) var playCalls: [Int64] = []
    private(set) var stopCount = 0
    private(set) var renderedQueryCount = 0
    private var handlers: [@MainActor (LecturePlaybackBackendEvent) -> Void] = []
    private var isPlaying = false
    var prepareError: Error?
    var renderedFrame: Int64?

    func prepare(_ source: LecturePlaybackSource) throws {
        if let prepareError { throw prepareError }
    }

    func play(fromSessionFrame frame: Int64, onEvent: @escaping @MainActor (LecturePlaybackBackendEvent) -> Void) throws {
        playCalls.append(frame)
        handlers.append(onEvent)
        isPlaying = true
        renderedFrame = nil
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }

    func renderedSessionFrame() -> Int64? {
        renderedQueryCount += 1
        return isPlaying ? renderedFrame : nil
    }

    func deliverToLatest(_ event: LecturePlaybackBackendEvent) {
        handlers.last?(event)
    }
}

/// Fires ticks only when a test says so.
@MainActor
private final class ManualPollScheduler: PlaybackPositionPollScheduling {
    final class Poll: PlaybackPositionPolling {
        let tick: @MainActor () -> Void
        private(set) var isCancelled = false

        init(tick: @escaping @MainActor () -> Void) {
            self.tick = tick
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var intervals: [Duration] = []
    private(set) var polls: [Poll] = []

    var activePolls: [Poll] { polls.filter { !$0.isCancelled } }

    func schedule(every interval: Duration, _ tick: @escaping @MainActor () -> Void) -> any PlaybackPositionPolling {
        intervals.append(interval)
        let poll = Poll(tick: tick)
        polls.append(poll)
        return poll
    }

    func fire() {
        for poll in activePolls {
            poll.tick()
        }
    }
}

/// Resolves sources immediately unless a session is gated, in which case
/// its load suspends until `resume` is called.
@MainActor
private final class GatedSourceLoader {
    var sources: [UUID: LecturePlaybackSource] = [:]
    var errors: [UUID: Error] = [:]
    private var gated: Set<UUID> = []
    private var pending: [UUID: CheckedContinuation<Void, Never>] = [:]

    func gate(_ sessionID: UUID) {
        gated.insert(sessionID)
    }

    func hasPending(_ sessionID: UUID) -> Bool {
        pending[sessionID] != nil
    }

    func resume(_ sessionID: UUID) {
        pending.removeValue(forKey: sessionID)?.resume()
    }

    func load(_ sessionID: UUID) async throws -> LecturePlaybackSource {
        if gated.remove(sessionID) != nil {
            await withCheckedContinuation { pending[sessionID] = $0 }
        }
        if let error = errors[sessionID] { throw error }
        guard let source = sources[sessionID] else { throw LecturePlaybackSourceError.sessionDirectoryUnsafe }
        return source
    }
}

@MainActor
final class SessionPlaybackPresenterTests: XCTestCase {
    /// 1 s, 1 s + 1 frame, 0.5 s at 44.1 kHz.
    private let frameCounts = [44_100, 44_101, 22_050]

    private var loader: GatedSourceLoader!
    private var scheduler: ManualPollScheduler!
    private var backends: [PresenterFakeBackend] = []
    private var nextPrepareError: Error?

    override func setUp() async throws {
        try await super.setUp()
        loader = GatedSourceLoader()
        scheduler = ManualPollScheduler()
        backends = []
        nextPrepareError = nil
    }

    private func makePresenter() -> SessionPlaybackPresenter {
        let loader = self.loader!
        return SessionPlaybackPresenter(
            sourceLoader: { sessionID, _, _ in try await loader.load(sessionID) },
            backendFactory: { [unowned self] in
                let backend = PresenterFakeBackend()
                backend.prepareError = nextPrepareError
                backends.append(backend)
                return backend
            },
            pollScheduler: scheduler
        )
    }

    private func makeEntry() throws -> (entry: CompletedSessionEntry, source: LecturePlaybackSource) {
        let manifest = PlaybackTestManifest.make(frameCounts: frameCounts)
        let timeline = try LecturePlaybackTimeline(manifest: manifest)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionPlaybackPresenterTests-\(UUID().uuidString)")
        let paths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: manifest.sessionID)
        let source = LecturePlaybackSource(
            timeline: timeline,
            chunkURLs: timeline.chunks.map { paths.chunksDirectory.appendingPathComponent($0.fileName) },
            channelCount: 1
        )
        loader.sources[manifest.sessionID] = source
        return (CompletedSessionEntry(manifest: manifest, sessionPaths: paths), source)
    }

    private func makeNavigation(
        for source: LecturePlaybackSource,
        startFrame: Int64,
        chunk: Int = 1
    ) -> (navigation: TranscriptPlaybackNavigation, item: TranscriptPlaybackItem) {
        let item = TranscriptPlaybackItem(
            chunkSequenceNumber: chunk,
            target: .timedSegment(index: 0),
            text: " passage",
            startSessionFrame: startFrame,
            endSessionFrame: startFrame + 10
        )
        return (TranscriptPlaybackNavigation(sessionID: source.timeline.sessionID, sampleRate: source.timeline.sampleRate, items: [item]), item)
    }

    private func preparedPresenter() async throws -> (SessionPlaybackPresenter, LecturePlaybackSource, PresenterFakeBackend) {
        let presenter = makePresenter()
        let (entry, source) = try makeEntry()
        await presenter.prepare(for: entry)
        return (presenter, source, try XCTUnwrap(backends.last))
    }

    // MARK: - Prepare

    func testPrepareReachesReadyWithoutAutoPlaying() async throws {
        let (presenter, source, backend) = try await preparedPresenter()

        XCTAssertEqual(presenter.status, .available(.ready))
        XCTAssertEqual(presenter.displayedSessionID, source.timeline.sessionID)
        XCTAssertEqual(presenter.durationSeconds, source.timeline.durationSeconds)
        XCTAssertEqual(presenter.currentSessionFrame, 0)
        XCTAssertEqual(presenter.currentSessionTime, 0)
        XCTAssertTrue(backend.playCalls.isEmpty, "opening the transcript never auto-plays")
        XCTAssertFalse(presenter.isPolling)
        XCTAssertTrue(scheduler.intervals.isEmpty)
        XCTAssertTrue(presenter.canPlayOrPause)
        XCTAssertFalse(presenter.canStop)
    }

    // MARK: - Polling

    func testPlayStartsPollingAtOneHundredMillisecondsAndSamplesEachTick() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        presenter.play()

        XCTAssertEqual(presenter.status, .available(.playing))
        XCTAssertEqual(SessionPlaybackPresenter.positionPollInterval, .milliseconds(100))
        XCTAssertEqual(scheduler.intervals, [.milliseconds(100)])
        XCTAssertEqual(scheduler.activePolls.count, 1)

        let queriesBefore = backend.renderedQueryCount
        var expectedFrames: [Int64] = []
        var observedFrames: [Int64] = []
        for frame in stride(from: Int64(4_410), through: 44_100, by: 4_410) {
            backend.renderedFrame = frame
            scheduler.fire()
            expectedFrames.append(frame)
            observedFrames.append(presenter.currentSessionFrame)
        }
        XCTAssertEqual(observedFrames, expectedFrames, "every 100 ms tick republishes the render clock")
        XCTAssertEqual(backend.renderedQueryCount - queriesBefore, expectedFrames.count, "one render-clock sample per tick")
        XCTAssertEqual(presenter.currentSessionTime, 1.0, accuracy: 1e-12)
    }

    func testPauseStopsPollingAndRetainsSampledPosition() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        presenter.play()
        backend.renderedFrame = 30_000
        scheduler.fire()

        presenter.pause()

        XCTAssertEqual(presenter.status, .available(.paused))
        XCTAssertFalse(presenter.isPolling)
        XCTAssertTrue(scheduler.activePolls.isEmpty)
        XCTAssertEqual(presenter.currentSessionFrame, 30_000)

        let queries = backend.renderedQueryCount
        scheduler.fire()
        XCTAssertEqual(backend.renderedQueryCount, queries, "no sampling while paused")

        presenter.play()
        XCTAssertEqual(backend.playCalls.last, 30_000, "resumes from the retained position")
        XCTAssertEqual(scheduler.activePolls.count, 1)
    }

    func testRouteChangeInterruptionPausesAtReportedFrameAndStopsPolling() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        presenter.play()
        backend.renderedFrame = 50_000
        scheduler.fire()

        backend.stop()
        backend.deliverToLatest(.interrupted(atSessionFrame: 50_100))

        XCTAssertEqual(presenter.status, .available(.paused))
        XCTAssertEqual(presenter.currentSessionFrame, 50_100)
        XCTAssertFalse(presenter.isPolling)
    }

    // MARK: - Transcript navigation

    func testNavigateWhileReadyStartsAtTarget() async throws {
        let (presenter, source, backend) = try await preparedPresenter()
        let target = makeNavigation(for: source, startFrame: 60_000)

        XCTAssertTrue(presenter.navigate(to: target.item, in: target.navigation))

        XCTAssertEqual(backend.playCalls, [60_000])
        XCTAssertEqual(presenter.status, .available(.playing))
        XCTAssertEqual(presenter.currentSessionFrame, 60_000)
        XCTAssertTrue(presenter.isPolling)
    }

    func testNavigateWhilePausedSeeksThenPlays() async throws {
        let (presenter, source, backend) = try await preparedPresenter()
        presenter.play()
        backend.renderedFrame = 10_000
        presenter.pause()
        let target = makeNavigation(for: source, startFrame: 70_001)

        XCTAssertTrue(presenter.navigate(to: target.item, in: target.navigation))

        XCTAssertEqual(backend.playCalls, [0, 70_001])
        XCTAssertEqual(presenter.status, .available(.playing))
    }

    func testNavigateWhilePlayingSeeksAndKeepsPlayingWithOnePoll() async throws {
        let (presenter, source, backend) = try await preparedPresenter()
        presenter.play()
        let target = makeNavigation(for: source, startFrame: 88_201, chunk: 2)

        XCTAssertTrue(presenter.navigate(to: target.item, in: target.navigation))

        XCTAssertEqual(backend.playCalls, [0, 88_201])
        XCTAssertEqual(presenter.status, .available(.playing))
        XCTAssertEqual(presenter.currentSessionFrame, 88_201)
        XCTAssertEqual(scheduler.intervals.count, 1, "the running poll continues; no second poll")
        XCTAssertEqual(scheduler.activePolls.count, 1)
    }

    func testNavigateAfterEndPlaysFromTargetNotFromZero() async throws {
        let (presenter, source, backend) = try await preparedPresenter()
        presenter.play()
        backend.deliverToLatest(.reachedEnd)
        XCTAssertEqual(presenter.status, .available(.ended))
        let target = makeNavigation(for: source, startFrame: 45_000)

        XCTAssertTrue(presenter.navigate(to: target.item, in: target.navigation))

        XCTAssertEqual(backend.playCalls.last, 45_000)
        XCTAssertEqual(presenter.status, .available(.playing))
    }

    func testNavigationForAnotherSessionOrOutsideTimelineIsRejected() async throws {
        let (presenter, source, backend) = try await preparedPresenter()
        let own = makeNavigation(for: source, startFrame: 1_000)
        let foreign = TranscriptPlaybackNavigation(sessionID: UUID(), sampleRate: source.timeline.sampleRate, items: [own.item])
        let atEnd = TranscriptPlaybackItem(
            chunkSequenceNumber: 2, target: .chunkStart, text: "", startSessionFrame: source.timeline.totalFrameCount,
            endSessionFrame: source.timeline.totalFrameCount
        )

        XCTAssertFalse(presenter.navigate(to: own.item, in: foreign))
        XCTAssertFalse(presenter.navigate(to: atEnd, in: own.navigation))
        XCTAssertTrue(backend.playCalls.isEmpty)
        XCTAssertEqual(presenter.status, .available(.ready))
    }

    // MARK: - Slider seek (keeps the play state)

    func testSeekWhileReadyMovesPositionWithoutPlaying() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        XCTAssertTrue(presenter.canSeek)

        XCTAssertTrue(presenter.seek(toSessionTime: 1.5))

        XCTAssertEqual(presenter.status, .available(.ready))
        XCTAssertEqual(presenter.currentSessionFrame, 66_150)
        XCTAssertEqual(presenter.currentSessionTime, 1.5, accuracy: 1e-12)
        XCTAssertTrue(backend.playCalls.isEmpty, "the slider never starts playback")
        XCTAssertFalse(presenter.isPolling)

        presenter.play()
        XCTAssertEqual(backend.playCalls, [66_150], "Play starts from the sought position")
    }

    func testSeekWhilePausedMovesPositionAndStaysPaused() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        presenter.play()
        backend.renderedFrame = 10_000
        presenter.pause()

        XCTAssertTrue(presenter.seek(toSessionTime: 2.0))

        XCTAssertEqual(presenter.status, .available(.paused))
        XCTAssertEqual(presenter.currentSessionFrame, 88_200)
        XCTAssertEqual(backend.playCalls, [0])
        XCTAssertFalse(presenter.isPolling)

        presenter.play()
        XCTAssertEqual(backend.playCalls.last, 88_200, "resumes from the sought position")
    }

    func testSeekWhilePlayingReschedulesAndKeepsPlayingWithOnePoll() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        presenter.play()

        XCTAssertTrue(presenter.seek(toSessionTime: 0.5))

        XCTAssertEqual(backend.playCalls, [0, 22_050])
        XCTAssertEqual(presenter.status, .available(.playing))
        XCTAssertEqual(presenter.currentSessionFrame, 22_050)
        XCTAssertEqual(scheduler.intervals.count, 1, "the running poll continues; no second poll")
        XCTAssertEqual(scheduler.activePolls.count, 1)
    }

    func testSeekBackwardFromEndedMovesAwayWithoutPlaying() async throws {
        let (presenter, source, backend) = try await preparedPresenter()
        presenter.play()
        backend.deliverToLatest(.reachedEnd)
        XCTAssertEqual(presenter.currentSessionFrame, source.timeline.totalFrameCount)

        XCTAssertTrue(presenter.seek(toSessionTime: 1.0))

        XCTAssertEqual(presenter.status, .available(.paused), "T6-B: seeking from ended pauses at the target")
        XCTAssertEqual(presenter.currentSessionFrame, 44_100)
        XCTAssertEqual(backend.playCalls, [0], "no playback started")
        XCTAssertFalse(presenter.isPolling)
    }

    func testNonFiniteSeekIsRejectedAndChangesNothing() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        XCTAssertTrue(presenter.seek(toSessionTime: 0.5))

        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(presenter.seek(toSessionTime: bad), "\(bad)")
        }

        XCTAssertEqual(presenter.status, .available(.ready))
        XCTAssertEqual(presenter.currentSessionFrame, 22_050)
        XCTAssertTrue(backend.playCalls.isEmpty)
    }

    func testOutOfRangeSeekUsesControllerClamping() async throws {
        let (presenter, source, _) = try await preparedPresenter()

        XCTAssertTrue(presenter.seek(toSessionTime: -3))
        XCTAssertEqual(presenter.currentSessionFrame, 0)
        XCTAssertEqual(presenter.status, .available(.ready))

        XCTAssertTrue(presenter.seek(toSessionTime: 1_000))
        XCTAssertEqual(presenter.currentSessionFrame, source.timeline.totalFrameCount)
        XCTAssertEqual(presenter.status, .available(.ended), "T6-B: seeking to the end settles as ended")
        XCTAssertFalse(presenter.isPolling)
    }

    func testSeekWithoutControllerIsRejected() async throws {
        let presenter = makePresenter()

        XCTAssertFalse(presenter.canSeek)
        XCTAssertFalse(presenter.seek(toSessionTime: 1))
        XCTAssertEqual(presenter.status, .idle)
        XCTAssertEqual(presenter.currentSessionFrame, 0)
    }

    // MARK: - Stop / end / failure

    func testStopResetsDisplayToZero() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        presenter.play()
        backend.renderedFrame = 40_000
        scheduler.fire()
        XCTAssertEqual(presenter.currentSessionFrame, 40_000)

        presenter.stop()

        XCTAssertEqual(presenter.status, .available(.ready))
        XCTAssertEqual(presenter.currentSessionFrame, 0)
        XCTAssertEqual(presenter.currentSessionTime, 0)
        XCTAssertFalse(presenter.isPolling)
        XCTAssertFalse(presenter.canStop)
    }

    func testResetFromPausedAndEndedReturnsToReadyAtZero() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        presenter.play()
        backend.renderedFrame = 30_000
        presenter.pause()
        XCTAssertEqual(presenter.currentSessionFrame, 30_000)

        presenter.stop()
        XCTAssertEqual(presenter.status, .available(.ready), "reset from paused")
        XCTAssertEqual(presenter.currentSessionFrame, 0)

        presenter.play()
        backend.deliverToLatest(.reachedEnd)
        XCTAssertEqual(presenter.status, .available(.ended))

        presenter.stop()
        XCTAssertEqual(presenter.status, .available(.ready), "reset from ended")
        XCTAssertEqual(presenter.currentSessionFrame, 0)
        XCTAssertEqual(presenter.currentSessionTime, 0)
        XCTAssertFalse(presenter.isPolling)
    }

    func testNaturalEndShowsDurationAndStopsPolling() async throws {
        let (presenter, source, backend) = try await preparedPresenter()
        presenter.play()

        backend.deliverToLatest(.reachedEnd)

        XCTAssertEqual(presenter.status, .available(.ended))
        XCTAssertEqual(presenter.currentSessionFrame, source.timeline.totalFrameCount)
        XCTAssertEqual(presenter.currentSessionTime, source.timeline.durationSeconds)
        XCTAssertFalse(presenter.isPolling)
        XCTAssertTrue(presenter.canStop)
    }

    func testSourceValidationFailureIsUnavailableAndCreatesNoController() async throws {
        let presenter = makePresenter()
        let (entry, _) = try makeEntry()
        let error = LecturePlaybackSourceError.chunkFileMissing(sequenceNumber: 1)
        loader.errors[entry.manifest.sessionID] = error

        await presenter.prepare(for: entry)

        XCTAssertEqual(presenter.status, .unavailable(try XCTUnwrap(error.errorDescription)))
        XCTAssertTrue(backends.isEmpty, "T6-B validation is not bypassed")
        XCTAssertFalse(presenter.canPlayOrPause)
        XCTAssertNil(presenter.durationSeconds)
    }

    func testBackendFailureIsTerminalAndDisablesNavigation() async throws {
        nextPrepareError = LecturePlaybackFailure.notPrepared
        let (presenter, source, backend) = try await preparedPresenter()

        XCTAssertEqual(presenter.status, .available(.failed(.notPrepared)))
        XCTAssertFalse(presenter.canPlayOrPause)
        let target = makeNavigation(for: source, startFrame: 1_000)
        XCTAssertFalse(presenter.navigate(to: target.item, in: target.navigation))
        XCTAssertTrue(backend.playCalls.isEmpty)
    }

    func testPlaybackFailureWhilePlayingStopsPolling() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        presenter.play()

        backend.deliverToLatest(.failed(.schedulingFailed(sequenceNumber: 1)))

        XCTAssertEqual(presenter.status, .available(.failed(.schedulingFailed(sequenceNumber: 1))))
        XCTAssertFalse(presenter.isPolling)
    }

    // MARK: - Session lifecycle

    func testStalePreparationFromPreviousSelectionIsIgnored() async throws {
        let presenter = makePresenter()
        let (entryA, _) = try makeEntry()
        let (entryB, sourceB) = try makeEntry()
        loader.gate(entryA.manifest.sessionID)

        let taskA = Task { await presenter.prepare(for: entryA) }
        while !loader.hasPending(entryA.manifest.sessionID) { await Task.yield() }

        await presenter.prepare(for: entryB)
        XCTAssertEqual(presenter.displayedSessionID, sourceB.timeline.sessionID)
        XCTAssertEqual(presenter.status, .available(.ready))

        loader.resume(entryA.manifest.sessionID)
        await taskA.value

        XCTAssertEqual(presenter.displayedSessionID, sourceB.timeline.sessionID)
        XCTAssertEqual(presenter.durationSeconds, sourceB.timeline.durationSeconds)
        XCTAssertEqual(presenter.status, .available(.ready))
        XCTAssertEqual(backends.count, 1, "session A's late source never became a controller")
    }

    func testPreparingAnotherSessionStopsPreviousPlayback() async throws {
        let (presenter, _, backendA) = try await preparedPresenter()
        presenter.play()
        let stopsBefore = backendA.stopCount
        let (entryB, _) = try makeEntry()

        await presenter.prepare(for: entryB)

        XCTAssertGreaterThan(backendA.stopCount, stopsBefore)
        XCTAssertEqual(scheduler.activePolls.count, 0, "session A's poll is cancelled")
        backendA.deliverToLatest(.reachedEnd)
        XCTAssertEqual(presenter.status, .available(.ready), "old session events cannot affect the new one")
    }

    func testTearDownStopsPlaybackAndForgetsSession() async throws {
        let (presenter, _, backend) = try await preparedPresenter()
        presenter.play()
        let stopsBefore = backend.stopCount

        presenter.tearDown()

        XCTAssertGreaterThan(backend.stopCount, stopsBefore)
        XCTAssertEqual(presenter.status, .idle)
        XCTAssertNil(presenter.displayedSessionID)
        XCTAssertFalse(presenter.isPolling)
        backend.deliverToLatest(.reachedEnd)
        XCTAssertEqual(presenter.status, .idle)
    }

    func testTearDownDuringPreparationDiscardsLateSource() async throws {
        let presenter = makePresenter()
        let (entry, _) = try makeEntry()
        loader.gate(entry.manifest.sessionID)

        let task = Task { await presenter.prepare(for: entry) }
        while !loader.hasPending(entry.manifest.sessionID) { await Task.yield() }
        presenter.tearDown()
        loader.resume(entry.manifest.sessionID)
        await task.value

        XCTAssertEqual(presenter.status, .idle)
        XCTAssertTrue(backends.isEmpty)
    }
}

/// The production scheduler, with a tiny interval and generous deadlines so
/// the test does not depend on precise timing.
@MainActor
final class TaskPlaybackPositionPollSchedulerTests: XCTestCase {
    func testTicksRepeatedlyUntilCancelled() async throws {
        var ticks = 0
        let poll = TaskPlaybackPositionPollScheduler().schedule(every: .milliseconds(1)) { ticks += 1 }

        let deadline = ContinuousClock.now + .seconds(5)
        while ticks < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(ticks, 3)

        poll.cancel()
        try await Task.sleep(for: .milliseconds(20))
        let afterCancel = ticks
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ticks, afterCancel, "no ticks after cancel")
    }
}
