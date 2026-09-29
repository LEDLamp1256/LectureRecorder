import XCTest
@testable import LectureRecorder

@MainActor
final class LecturePlaybackControllerTests: XCTestCase {
    /// 1 kHz so seconds and frames read plainly: 2.5 s, boundaries at 1000/2000.
    private let total: Int64 = 2_500
    private var source: LecturePlaybackSource!
    private var backend: FakeLectureAudioPlaybackBackend!

    override func setUpWithError() throws {
        let manifest = PlaybackTestManifest.make(sampleRate: 1_000, frameCounts: [1_000, 1_000, 500])
        let timeline = try LecturePlaybackTimeline(manifest: manifest)
        source = LecturePlaybackSource(
            timeline: timeline,
            chunkURLs: timeline.chunks.map { URL(fileURLWithPath: "/nonexistent/\($0.fileName)") },
            channelCount: 1
        )
        backend = FakeLectureAudioPlaybackBackend()
    }

    private func makeController() -> LecturePlaybackController {
        LecturePlaybackController(source: source, backend: backend)
    }

    private func makePlayingController(renderedFrame: Int64? = nil) -> LecturePlaybackController {
        let controller = makeController()
        controller.play()
        backend.renderedFrame = renderedFrame
        return controller
    }

    // MARK: - Basic lifecycle

    func testInitPreparesBackendAndStartsReadyAtZero() {
        let controller = makeController()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.currentSessionFrame, 0)
        XCTAssertEqual(controller.currentSessionTime, 0)
        XCTAssertEqual(controller.durationSeconds, 2.5)
        XCTAssertEqual(backend.calls, [.prepare(source)])
    }

    func testPlayFromReadyStartsAtZero() {
        let controller = makeController()
        controller.play()
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertEqual(backend.playCalls, [0])
    }

    func testPlayFromReadyAfterSeekStartsAtRetainedPosition() {
        let controller = makeController()
        XCTAssertTrue(controller.seek(toSessionTime: 1.25))
        XCTAssertEqual(controller.phase, .ready)
        controller.play()
        XCTAssertEqual(backend.playCalls, [1_250])
    }

    func testPlayWhilePlayingIsNoOp() {
        let controller = makePlayingController()
        controller.play()
        XCTAssertEqual(backend.playCalls, [0])
    }

    func testPositionWhilePlayingIsRenderedSessionFrameOrAnchorBeforeFirstRender() {
        let controller = makeController()
        controller.seek(toSessionTime: 0.5)
        controller.play()
        XCTAssertEqual(controller.currentSessionFrame, 500, "no render yet → anchor")
        backend.renderedFrame = 1_700
        XCTAssertEqual(controller.currentSessionFrame, 1_700)
        XCTAssertEqual(controller.currentSessionTime, 1.7)
    }

    // MARK: - Pause / resume

    func testPauseRetainsExactReportedPosition() {
        let controller = makePlayingController(renderedFrame: 1_234)
        controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(controller.currentSessionFrame, 1_234)
        XCTAssertEqual(backend.calls.last, .stop)

        backend.renderedFrame = 2_000 // backend clock is ignored once paused
        XCTAssertEqual(controller.currentSessionFrame, 1_234)
    }

    func testResumeContinuesFromRetainedPositionNotChunkStart() {
        let controller = makePlayingController(renderedFrame: 1_234)
        controller.pause()
        controller.play()
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertEqual(backend.playCalls, [0, 1_234])
    }

    func testPauseWhenNotPlayingIsNoOp() {
        let controller = makeController()
        controller.pause()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(backend.calls, [.prepare(source)])
    }

    // MARK: - Seek

    func testSeekWhilePausedStaysPausedWithoutRescheduling() {
        let controller = makePlayingController(renderedFrame: 300)
        controller.pause()
        let callsBefore = backend.calls

        XCTAssertTrue(controller.seek(toSessionTime: 2.0))
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(controller.currentSessionFrame, 2_000)
        XCTAssertEqual(backend.calls, callsBefore)

        controller.play()
        XCTAssertEqual(backend.playCalls.last, 2_000)
    }

    func testSeekWhilePlayingReschedulesAtRequestedPositionAndKeepsPlaying() {
        let controller = makePlayingController(renderedFrame: 400)
        XCTAssertTrue(controller.seek(toSessionTime: 1.5))
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertEqual(backend.playCalls, [0, 1_500])
        XCTAssertEqual(controller.currentSessionFrame, 1_500)
    }

    func testSeekToEndProducesEndedFromEveryNonFailedPhase() {
        let playing = makePlayingController(renderedFrame: 10)
        XCTAssertTrue(playing.seek(toSessionTime: 2.5))
        XCTAssertEqual(playing.phase, .ended)
        XCTAssertEqual(playing.currentSessionFrame, total)
        XCTAssertEqual(backend.calls.last, .stop)

        let ready = makeController()
        XCTAssertTrue(ready.seek(toSessionTime: 99))
        XCTAssertEqual(ready.phase, .ended)
        XCTAssertEqual(ready.currentSessionFrame, total)

        let paused = makePlayingController(renderedFrame: 10)
        paused.pause()
        paused.seek(toSessionTime: 2.5)
        XCTAssertEqual(paused.phase, .ended)
    }

    func testSeekClampsNegativeToZeroAndRejectsNonFinite() {
        let controller = makePlayingController(renderedFrame: 900)
        controller.pause()

        XCTAssertFalse(controller.seek(toSessionTime: .nan))
        XCTAssertFalse(controller.seek(toSessionTime: .infinity))
        XCTAssertEqual(controller.currentSessionFrame, 900)
        XCTAssertEqual(controller.phase, .paused)

        XCTAssertTrue(controller.seek(toSessionTime: -3))
        XCTAssertEqual(controller.currentSessionFrame, 0)
        XCTAssertEqual(controller.phase, .paused)
    }

    func testSeekFromEndedToInteriorBecomesPaused() {
        let controller = makeController()
        controller.seek(toSessionTime: 2.5)
        XCTAssertTrue(controller.seek(toSessionTime: 1.0))
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(controller.currentSessionFrame, 1_000)
    }

    // MARK: - End

    func testNaturalCompletionProducesEndedAtEnd() {
        let controller = makePlayingController(renderedFrame: 2_499)
        backend.deliver(.reachedEnd, toSchedule: 0)
        XCTAssertEqual(controller.phase, .ended)
        XCTAssertEqual(controller.currentSessionFrame, total)
        XCTAssertEqual(backend.calls.last, .stop)
    }

    func testPlayFromEndedRestartsFromZero() {
        let controller = makePlayingController()
        backend.deliver(.reachedEnd, toSchedule: 0)
        controller.play()
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertEqual(backend.playCalls, [0, 0])

        let seekEnded = makeController()
        seekEnded.seek(toSessionTime: 2.5)
        seekEnded.play()
        XCTAssertEqual(backend.playCalls.last, 0)
    }

    // MARK: - Stale events

    func testStaleEventsFromSupersededSeekCannotEndOrFailCurrentPlayback() {
        let controller = makePlayingController()
        controller.seek(toSessionTime: 0.5)
        XCTAssertEqual(backend.eventHandlers.count, 2)

        backend.deliver(.reachedEnd, toSchedule: 0)
        backend.deliver(.failed(.schedulingFailed(sequenceNumber: 1)), toSchedule: 0)
        backend.deliver(.interrupted(atSessionFrame: 10), toSchedule: 0)
        XCTAssertEqual(controller.phase, .playing)
        XCTAssertEqual(controller.currentSessionFrame, 500)

        backend.deliver(.reachedEnd, toSchedule: 1)
        XCTAssertEqual(controller.phase, .ended)
    }

    func testEventsAfterPauseOrStopAreIgnored() {
        let controller = makePlayingController(renderedFrame: 700)
        controller.pause()
        backend.deliver(.reachedEnd, toSchedule: 0)
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(controller.currentSessionFrame, 700)

        controller.play()
        controller.stop()
        backend.deliver(.failed(.notPrepared), toSchedule: 1)
        XCTAssertEqual(controller.phase, .ready)
    }

    // MARK: - Stop

    func testStopResetsToReadyAtZeroFromAnyNonFailedPhase() {
        let controller = makePlayingController(renderedFrame: 1_800)
        controller.stop()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.currentSessionFrame, 0)
        XCTAssertEqual(backend.calls.last, .stop)

        controller.seek(toSessionTime: 1.0)
        controller.play()
        controller.pause()
        controller.stop()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.currentSessionFrame, 0)

        controller.play()
        XCTAssertEqual(backend.playCalls.last, 0)
    }

    // MARK: - Interruption and failure

    func testInterruptionPausesAtReportedFrame() {
        let controller = makePlayingController()
        backend.deliver(.interrupted(atSessionFrame: 1_111), toSchedule: 0)
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(controller.currentSessionFrame, 1_111)
        controller.play()
        XCTAssertEqual(backend.playCalls.last, 1_111)
    }

    func testPrepareFailureSurfacesAsFailed() {
        backend.prepareError = LecturePlaybackFailure.source(.chunkFileMissing(sequenceNumber: 2))
        let controller = makeController()
        XCTAssertEqual(controller.phase, .failed(.source(.chunkFileMissing(sequenceNumber: 2))))
    }

    func testPlayFailureSurfacesAsFailedAtRequestedPosition() {
        backend.playError = LecturePlaybackFailure.engineStartFailed("no device")
        let controller = makeController()
        controller.seek(toSessionTime: 0.75)
        controller.play()
        XCTAssertEqual(controller.phase, .failed(.engineStartFailed("no device")))
        XCTAssertEqual(controller.currentSessionFrame, 750)
    }

    func testBackendFailureEventSurfacesAsFailedAndIsTerminal() {
        let controller = makePlayingController(renderedFrame: 1_400)
        backend.deliver(.failed(.source(.chunkFrameCountMismatch(sequenceNumber: 2))), toSchedule: 0)
        XCTAssertEqual(controller.phase, .failed(.source(.chunkFrameCountMismatch(sequenceNumber: 2))))
        XCTAssertEqual(controller.currentSessionFrame, 1_400)
        XCTAssertEqual(backend.calls.last, .stop)

        let callsAfterFailure = backend.calls
        controller.play()
        controller.pause()
        XCTAssertFalse(controller.seek(toSessionTime: 1))
        controller.stop()
        XCTAssertEqual(backend.calls, callsAfterFailure)
        XCTAssertEqual(controller.phase, .failed(.source(.chunkFrameCountMismatch(sequenceNumber: 2))))
    }

    // MARK: - Input immutability

    func testControllerNeverAltersItsTimelineOrSource() {
        let original = source!
        let controller = makePlayingController(renderedFrame: 100)
        controller.seek(toSessionTime: 2.0)
        controller.pause()
        controller.seek(toSessionTime: 2.5)
        controller.play()
        backend.deliver(.reachedEnd, toSchedule: 2)
        controller.stop()

        XCTAssertEqual(controller.timeline, original.timeline)
        XCTAssertEqual(source, original)
        XCTAssertEqual(backend.calls.first, .prepare(original))
    }
}
