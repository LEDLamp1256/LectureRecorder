import AVFoundation
import XCTest
@testable import LectureRecorder

/// Drives the production backend through an offline manual-rendering
/// engine: real `AVAudioEngine`/`AVAudioPlayerNode` scheduling of real CAF
/// chunks, with no audio device and no audible output.
@MainActor
final class AVFoundationLecturePlaybackBackendTests: XCTestCase {
    private static let sampleRate: Double = 8_000
    private static let renderBlock: AVAudioFrameCount = 256
    /// Five chunks so refills beyond the initial look-ahead are exercised.
    private let frameCounts = [1_000, 1_000, 1_000, 1_000, 500]
    private var total: Int64 { Int64(frameCounts.reduce(0, +)) }

    private var root: URL!
    private var engine: AVAudioEngine!
    private var backend: AVFoundationLecturePlaybackBackend!
    private var source: LecturePlaybackSource!
    private var paths: SessionPaths!

    override func setUp() async throws {
        root = try PlaybackTestAudio.makeTemporaryRoot()
        let session = try PlaybackTestAudio.makeSession(root: root, frameCounts: frameCounts, sampleRate: Self.sampleRate)
        paths = session.paths
        source = try LecturePlaybackSourceLoader.load(
            expectedSessionID: session.manifest.sessionID,
            manifest: session.manifest,
            sessionPaths: session.paths
        )

        engine = AVAudioEngine()
        let renderFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: Self.renderBlock)
        backend = AVFoundationLecturePlaybackBackend(engine: engine)
    }

    override func tearDown() async throws {
        backend?.stop()
        backend = nil
        engine = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Renders `frames` frames block by block, yielding between blocks so
    /// main-actor completion hops (look-ahead refills) can run, as they do
    /// during real-time playback.
    private func render(frames: Int) async throws -> [Float] {
        var samples: [Float] = []
        while samples.count < frames {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.renderBlock
            ))
            let status = try engine.renderOffline(Self.renderBlock, to: buffer)
            XCTAssertEqual(status, .success)
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            try await drainMainActorHops()
        }
        return Array(samples.prefix(frames))
    }

    private func drainMainActorHops() async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(2))
            await Task.yield()
        }
    }

    private func waitFor(_ condition: () -> Bool, timeoutSeconds: Double = 2) async throws {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func assertSessionAudio(
        _ samples: [Float],
        startingAt firstFrame: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (index, sample) in samples.enumerated() {
            let expected = PlaybackTestAudio.sampleValue(forSessionFrame: firstFrame + Int64(index))
            if abs(sample - expected) > 1e-7 {
                XCTFail("sample \(index) = \(sample), expected session frame \(firstFrame + Int64(index)) (\(expected))",
                        file: file, line: line)
                return
            }
        }
    }

    func testSeekIntoChunkPlaysContinuousSessionAudioAcrossEveryBoundaryThenReachesEnd() async throws {
        try backend.prepare(source)
        var events: [LecturePlaybackBackendEvent] = []
        try backend.play(fromSessionFrame: 1_500) { events.append($0) }

        let expectedCount = Int(total - 1_500)
        let samples = try await render(frames: expectedCount)
        XCTAssertEqual(samples.count, expectedCount)
        assertSessionAudio(samples, startingAt: 1_500)

        XCTAssertEqual(backend.renderedSessionFrame(), total, "position is anchor + rendered frames, clamped to the end")

        _ = try await render(frames: Int(Self.renderBlock) * 2)
        try await waitFor { !events.isEmpty }
        XCTAssertEqual(events, [.reachedEnd])
    }

    func testPositionIsAnchorPlusRenderedFrames() async throws {
        try backend.prepare(source)
        try backend.play(fromSessionFrame: 700) { _ in }
        _ = try await render(frames: Int(Self.renderBlock) * 3)
        XCTAssertEqual(backend.renderedSessionFrame(), 700 + Int64(Self.renderBlock) * 3)
    }

    func testRestartSupersedesOldScheduleAndItsCallbacks() async throws {
        try backend.prepare(source)
        var oldEvents: [LecturePlaybackBackendEvent] = []
        var newEvents: [LecturePlaybackBackendEvent] = []
        try backend.play(fromSessionFrame: 3_900) { oldEvents.append($0) }
        _ = try await render(frames: Int(Self.renderBlock))

        try backend.play(fromSessionFrame: 3_000) { newEvents.append($0) }
        let samples = try await render(frames: Int(total - 3_000))
        assertSessionAudio(samples, startingAt: 3_000)

        _ = try await render(frames: Int(Self.renderBlock) * 2)
        try await waitFor { !newEvents.isEmpty }
        try await drainMainActorHops()
        XCTAssertEqual(newEvents, [.reachedEnd])
        XCTAssertEqual(oldEvents, [], "the superseded schedule's final-chunk callback must never surface")
    }

    func testStopSilencesAndSuppressesCallbacks() async throws {
        try backend.prepare(source)
        var events: [LecturePlaybackBackendEvent] = []
        try backend.play(fromSessionFrame: 4_400) { events.append($0) }
        backend.stop()
        XCTAssertNil(backend.renderedSessionFrame())
        try await drainMainActorHops()
        XCTAssertEqual(events, [])
    }

    func testChunkRemovedAfterLoadFailsAtRefillWithoutTouchingOtherFiles() async throws {
        try backend.prepare(source)
        let removed = paths.chunksDirectory.appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: 3))
        try FileManager.default.removeItem(at: removed)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: paths.chunksDirectory.path).sorted()

        var events: [LecturePlaybackBackendEvent] = []
        try backend.play(fromSessionFrame: 0) { events.append($0) }
        // The failure stops the engine, so render only while it runs.
        var rendered = 0
        while events.isEmpty, engine.isRunning, rendered < 3_000 {
            rendered += try await render(frames: Int(Self.renderBlock)).count
        }
        try await waitFor { !events.isEmpty }

        XCTAssertEqual(events, [.failed(.source(.chunkFileMissing(sequenceNumber: 3)))])
        XCTAssertFalse(engine.isRunning, "a playback failure halts the engine")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.chunksDirectory.path).sorted(), remaining)
    }

    /// Session audio at 44.1 kHz rendered through a 48 kHz output: the
    /// player node's clock must stay in 44.1 kHz session frames, and the
    /// reported position must advance by session frames, not output frames.
    func testPositionStaysInSessionFramesWhenOutputRateDiffers() async throws {
        let sessionRate: Double = 44_100
        let outputRate: Double = 48_000
        let session = try PlaybackTestAudio.makeSession(
            root: root.appendingPathComponent("rates", isDirectory: true),
            frameCounts: [4_410, 4_410, 4_410],
            sampleRate: sessionRate
        )
        let rateSource = try LecturePlaybackSourceLoader.load(
            expectedSessionID: session.manifest.sessionID,
            manifest: session.manifest,
            sessionPaths: session.paths
        )
        let rateEngine = AVAudioEngine()
        let outputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1))
        try rateEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: Self.renderBlock)
        let rateBackend = AVFoundationLecturePlaybackBackend(engine: rateEngine)
        defer { rateBackend.stop() }

        try rateBackend.prepare(rateSource)
        let player = try XCTUnwrap(rateEngine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        XCTAssertEqual(player.outputFormat(forBus: 0).sampleRate, sessionRate, "player connects at the session rate")
        XCTAssertEqual(rateEngine.manualRenderingFormat.sampleRate, outputRate)

        var events: [LecturePlaybackBackendEvent] = []
        try rateBackend.play(fromSessionFrame: 1_000) { events.append($0) }

        // 4_800 output frames = 0.1 s = 4_410 session frames.
        var outputFrames = 0
        while outputFrames < 4_800 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: Self.renderBlock))
            XCTAssertEqual(try rateEngine.renderOffline(Self.renderBlock, to: buffer), .success)
            outputFrames += Int(buffer.frameLength)
            try await drainMainActorHops()
        }

        let nodeTime = try XCTUnwrap(player.lastRenderTime)
        let playerTime = try XCTUnwrap(player.playerTime(forNodeTime: nodeTime))
        XCTAssertEqual(playerTime.sampleRate, sessionRate, "player clock is in session-rate frames")

        let position = try XCTUnwrap(rateBackend.renderedSessionFrame())
        let expected = 1_000 + Int64((Double(outputFrames) / outputRate * sessionRate).rounded(.down))
        // Exact equality isn't possible: the mixer's sample-rate converter
        // pulls source frames in blocks ahead of its output. Output-rate
        // units would read 1_000 + outputFrames, ~400 frames further.
        XCTAssertLessThanOrEqual(abs(position - expected), Int64(Self.renderBlock),
                                 "position \(position) vs expected \(expected)")
        XCTAssertLessThan(position, 1_000 + Int64(outputFrames) - 100)

        // And it still ends at exactly the session's total frame count.
        let total = rateSource.timeline.totalFrameCount
        while events.isEmpty, rateEngine.isRunning, outputFrames < 40_000 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: Self.renderBlock))
            XCTAssertEqual(try rateEngine.renderOffline(Self.renderBlock, to: buffer), .success)
            outputFrames += Int(buffer.frameLength)
            if events.isEmpty, let frame = rateBackend.renderedSessionFrame() {
                XCTAssertLessThanOrEqual(frame, total)
            }
            try await drainMainActorHops()
        }
        try await waitFor { !events.isEmpty }
        XCTAssertEqual(events, [.reachedEnd])
    }

    func testSessionFrameConversionIsIdentityAtSessionRate() throws {
        let timeline = try LecturePlaybackTimeline(manifest: PlaybackTestManifest.make(frameCounts: [44_100, 44_100]))
        XCTAssertEqual(AVFoundationLecturePlaybackBackend.sessionFrame(
            anchorFrame: 1_000, playerSampleTime: 12_345, playerSampleRate: 44_100, timeline: timeline
        ), 13_345)
    }

    func testSessionFrameConversionConvertsOtherRatesThroughElapsedTimeRoundingDown() throws {
        let timeline = try LecturePlaybackTimeline(manifest: PlaybackTestManifest.make(frameCounts: [44_100, 44_100]))
        func convert(_ samples: AVAudioFramePosition, at rate: Double, anchor: Int64 = 1_000) -> Int64 {
            AVFoundationLecturePlaybackBackend.sessionFrame(
                anchorFrame: anchor, playerSampleTime: samples, playerSampleRate: rate, timeline: timeline
            )
        }
        XCTAssertEqual(convert(48_000, at: 48_000), 1_000 + 44_100, "1 s at 48 kHz = 44_100 session frames")
        XCTAssertEqual(convert(1, at: 48_000), 1_000, "0.919 session frames has not yet reached the next frame")
        XCTAssertEqual(convert(160, at: 48_000), 1_000 + 147)
        XCTAssertEqual(convert(22_050, at: 22_050), 1_000 + 44_100, "1 s on a 22.05 kHz clock = 44_100 session frames")
    }

    func testSessionFrameConversionClampsAndRejectsInvalidInput() throws {
        let timeline = try LecturePlaybackTimeline(manifest: PlaybackTestManifest.make(frameCounts: [44_100, 44_100]))
        func convert(_ samples: AVAudioFramePosition, at rate: Double, anchor: Int64 = 1_000) -> Int64 {
            AVFoundationLecturePlaybackBackend.sessionFrame(
                anchorFrame: anchor, playerSampleTime: samples, playerSampleRate: rate, timeline: timeline
            )
        }
        XCTAssertEqual(convert(-500, at: 44_100), 1_000, "negative player time never moves before the anchor")
        XCTAssertEqual(convert(10_000_000, at: 44_100), 88_200, "clamped to the end")
        XCTAssertEqual(convert(.max, at: 44_100, anchor: 88_199), 88_200, "no overflow")
        XCTAssertEqual(convert(.max, at: 48_000), 88_200, "no overflow when scaling")
        for rate in [0, -48_000, .nan, .infinity] as [Double] {
            XCTAssertEqual(convert(4_800, at: rate), 1_000, "invalid player rate \(rate) yields the anchor")
        }
    }

    func testInvalidStartAndUnpreparedPlayAreRejected() throws {
        XCTAssertThrowsError(try backend.play(fromSessionFrame: 0) { _ in }) { error in
            XCTAssertEqual(error as? LecturePlaybackFailure, .notPrepared)
        }
        try backend.prepare(source)
        for frame in [-1, total, total + 1] {
            XCTAssertThrowsError(try backend.play(fromSessionFrame: frame) { _ in }) { error in
                XCTAssertEqual(error as? LecturePlaybackFailure, .invalidStartPosition)
            }
        }
    }
}
