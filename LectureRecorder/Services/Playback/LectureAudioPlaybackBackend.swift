import AVFoundation
import Foundation

nonisolated enum LecturePlaybackFailure: LocalizedError, Sendable, Equatable {
    /// A chunk failed read-only validation when prepared or scheduled.
    case source(LecturePlaybackSourceError)
    case notPrepared
    /// A start position that does not address a playable frame.
    case invalidStartPosition
    case engineStartFailed(String)
    /// A validated chunk could not be scheduled on the player (format
    /// incompatible with the player connection, or an unrepresentable
    /// segment length).
    case schedulingFailed(sequenceNumber: Int)

    var errorDescription: String? {
        switch self {
        case .source(let underlying):
            return underlying.errorDescription
        case .notPrepared:
            return "Playback was not prepared."
        case .invalidStartPosition:
            return "The playback position does not address recorded audio."
        case .engineStartFailed(let description):
            return "Audio playback could not start: \(description)"
        case .schedulingFailed(let sequenceNumber):
            return "Chunk #\(sequenceNumber) could not be scheduled for playback."
        }
    }
}

/// Something that happened to one `play(fromSessionFrame:onEvent:)`
/// schedule after it started. Delivered on the main actor, and only for
/// the schedule currently in effect — never after it was superseded by
/// another `play` or by `stop()`.
nonisolated enum LecturePlaybackBackendEvent: Equatable, Sendable {
    /// The session's final frame has played.
    case reachedEnd
    /// The audio route changed and the engine stopped; playback halted at
    /// approximately this session frame.
    case interrupted(atSessionFrame: Int64)
    case failed(LecturePlaybackFailure)
}

/// The physical audio engine beneath `LecturePlaybackController`. Speaks
/// only session-relative frames; chunk files stay hidden below it.
@MainActor
protocol LectureAudioPlaybackBackend: AnyObject {
    /// Binds the backend to one validated session. Does not start audio.
    func prepare(_ source: LecturePlaybackSource) throws
    /// Starts (or restarts) audible playback at `frame`, which must address
    /// a playable frame (`0..<totalFrameCount`). Supersedes any schedule in
    /// effect; the superseded schedule's `onEvent` is never called again.
    func play(
        fromSessionFrame frame: Int64,
        onEvent: @escaping @MainActor (LecturePlaybackBackendEvent) -> Void
    ) throws
    /// Silences playback and supersedes any schedule in effect. Idempotent.
    func stop()
    /// The session frame most recently rendered by the schedule in effect,
    /// or `nil` when nothing is playing or the render clock is not yet
    /// valid.
    func renderedSessionFrame() -> Int64?
}

/// `AVAudioEngine` + `AVAudioPlayerNode` playback over a session's
/// durable `.caf` chunks, read in place.
///
/// Scheduling: `play` schedules the remainder of the start chunk as a
/// segment beginning at the exact chunk-relative frame, then whole
/// following chunks up to `scheduledChunkLookahead` ahead. Each non-final
/// chunk's consumed callback schedules the next one, so the player always
/// holds queued audio past the current chunk (no inter-chunk gap) while
/// only a few chunk files are open at once. The final chunk's played-back
/// callback reports the natural end. No file is copied, converted, or
/// written.
///
/// Position: session frame = the schedule's anchor frame + the player
/// node's rendered sample time since that schedule's `play()`, converted
/// to session-rate frames and clamped to the timeline (see
/// `sessionFrame(anchorFrame:playerSampleTime:playerSampleRate:timeline:)`).
/// No wall-clock time is involved.
///
/// Stale callbacks: every schedule carries a generation. `play` and `stop`
/// bump it before stopping the player (which itself fires the old
/// schedule's completion handlers), and every callback re-checks it on the
/// main actor before touching state. AVFoundation callbacks only hop to
/// the main actor; no engine work runs on a render or callback thread.
@MainActor
final class AVFoundationLecturePlaybackBackend: NSObject, LectureAudioPlaybackBackend {
    static let scheduledChunkLookahead = 2

    private struct ActiveSchedule {
        let generation: Int
        let anchorFrame: Int64
        var nextChunkIndexToSchedule: Int
        let onEvent: @MainActor (LecturePlaybackBackendEvent) -> Void
    }

    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var source: LecturePlaybackSource?
    private var connectionFormat: AVAudioFormat?
    private var generation = 0
    private var active: ActiveSchedule?
    private var lastObservedSessionFrame: Int64?

    /// `engine` is injectable so deterministic tests can drive a
    /// manual-rendering engine instead of an audio device.
    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        super.init()
        engine.attach(player)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(engineConfigurationChanged(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    func prepare(_ source: LecturePlaybackSource) throws {
        stop()
        guard let firstChunk = source.timeline.chunks.first, let firstURL = source.chunkURLs.first,
              source.chunkURLs.count == source.timeline.chunks.count else {
            throw LecturePlaybackFailure.notPrepared
        }
        let file = try openChunk(at: firstURL, chunk: firstChunk, source: source)
        let format = file.processingFormat
        file.close()

        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        self.source = source
        self.connectionFormat = format
    }

    func play(
        fromSessionFrame frame: Int64,
        onEvent: @escaping @MainActor (LecturePlaybackBackendEvent) -> Void
    ) throws {
        cancelSchedule()
        guard let source else { throw LecturePlaybackFailure.notPrepared }
        guard case .chunk(let chunkIndex, let frameOffset)? = source.timeline.location(forSessionFrame: frame) else {
            throw LecturePlaybackFailure.invalidStartPosition
        }

        generation += 1
        active = ActiveSchedule(
            generation: generation,
            anchorFrame: frame,
            nextChunkIndexToSchedule: chunkIndex,
            onEvent: onEvent
        )
        lastObservedSessionFrame = frame

        do {
            try scheduleNextChunk(frameOffset: frameOffset)
            for _ in 0..<Self.scheduledChunkLookahead {
                try scheduleNextChunk(frameOffset: 0)
            }
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    throw LecturePlaybackFailure.engineStartFailed(error.localizedDescription)
                }
            }
        } catch {
            cancelSchedule()
            throw error
        }
        player.play()
    }

    func stop() {
        cancelSchedule()
        if engine.isRunning {
            engine.stop()
        }
    }

    func renderedSessionFrame() -> Int64? {
        guard let active, let source, player.isPlaying,
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid else {
            return nil
        }
        let frame = Self.sessionFrame(
            anchorFrame: active.anchorFrame,
            playerSampleTime: playerTime.sampleTime,
            playerSampleRate: playerTime.sampleRate,
            timeline: source.timeline
        )
        lastObservedSessionFrame = frame
        return frame
    }

    /// Converts the player's rendered sample time into a session frame:
    /// `anchorFrame + elapsed`, where `elapsed` is expressed at the
    /// session's own `timeline.sampleRate`. The player's clock runs at the
    /// rate of its output connection — the chunk files' processing format,
    /// i.e. the session rate — so the conversion is normally the identity;
    /// any other rate is converted through elapsed seconds
    /// (`samples * sessionRate / playerRate`, multiplied first so exact
    /// multiples stay exact) rounded down, since a frame
    /// has not been reached until it has fully rendered. The result is
    /// clamped to `anchorFrame...totalFrameCount`; an invalid player rate
    /// yields the anchor.
    nonisolated static func sessionFrame(
        anchorFrame: Int64,
        playerSampleTime: AVAudioFramePosition,
        playerSampleRate: Double,
        timeline: LecturePlaybackTimeline
    ) -> Int64 {
        let renderedSamples = max(0, playerSampleTime)
        let remaining = timeline.totalFrameCount - anchorFrame
        let elapsed: Int64
        if playerSampleRate == timeline.sampleRate {
            elapsed = renderedSamples
        } else if playerSampleRate.isFinite, playerSampleRate > 0 {
            let scaled = (Double(renderedSamples) * timeline.sampleRate / playerSampleRate).rounded(.down)
            elapsed = scaled < Double(remaining) ? Int64(scaled) : remaining
        } else {
            elapsed = 0
        }
        return anchorFrame + min(elapsed, remaining)
    }

    // MARK: - Scheduling

    /// Supersedes the schedule in effect. The generation bump happens
    /// before `player.stop()`, whose completion callbacks therefore arrive
    /// already stale.
    private func cancelSchedule() {
        generation += 1
        active = nil
        player.stop()
    }

    /// Schedules `active.nextChunkIndexToSchedule` (from `frameOffset`) and
    /// advances it; a no-op once every chunk is scheduled.
    private func scheduleNextChunk(frameOffset: Int64) throws {
        guard var schedule = active, let source, let connectionFormat else { return }
        let index = schedule.nextChunkIndexToSchedule
        guard index < source.timeline.chunks.count else { return }

        let chunk = source.timeline.chunks[index]
        let file = try openChunk(at: source.chunkURLs[index], chunk: chunk, source: source)
        let remaining = chunk.frameCount - frameOffset
        guard file.processingFormat == connectionFormat, frameOffset >= 0, remaining > 0,
              let frameCount = AVAudioFrameCount(exactly: remaining) else {
            file.close()
            throw LecturePlaybackFailure.schedulingFailed(sequenceNumber: chunk.sequenceNumber)
        }

        player.scheduleSegment(
            file,
            startingFrame: AVAudioFramePosition(frameOffset),
            frameCount: frameCount,
            at: nil,
            completionCallbackType: completionCallbackType(isFinalChunk: index == source.timeline.chunks.count - 1),
            completionHandler: Self.makeChunkCompletionHandler(
                backend: self,
                generation: schedule.generation,
                chunkIndex: index
            )
        )
        schedule.nextChunkIndexToSchedule = index + 1
        active = schedule
    }

    /// A non-final chunk refills the look-ahead as soon as the player has
    /// consumed it. The final chunk reports the end only once it has
    /// actually played back through the device — or, in manual rendering
    /// mode (no device; rendering is the output), once rendered, since
    /// played-back callbacks never fire there.
    private func completionCallbackType(isFinalChunk: Bool) -> AVAudioPlayerNodeCompletionCallbackType {
        guard isFinalChunk else { return .dataConsumed }
        return engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack
    }

    private func openChunk(at url: URL, chunk: LecturePlaybackChunk, source: LecturePlaybackSource) throws -> AVAudioFile {
        do {
            return try LecturePlaybackSourceLoader.openValidatedChunkFile(
                at: url,
                chunk: chunk,
                sampleRate: source.timeline.sampleRate,
                channelCount: source.channelCount
            )
        } catch let error as LecturePlaybackSourceError {
            throw LecturePlaybackFailure.source(error)
        }
    }

    private func chunkCompleted(generation callbackGeneration: Int, chunkIndex: Int) {
        guard let schedule = active, schedule.generation == callbackGeneration, let source else { return }

        if chunkIndex == source.timeline.chunks.count - 1 {
            lastObservedSessionFrame = source.timeline.totalFrameCount
            schedule.onEvent(.reachedEnd)
            return
        }

        do {
            try scheduleNextChunk(frameOffset: 0)
        } catch {
            let failure = error as? LecturePlaybackFailure ?? .notPrepared
            stop()
            schedule.onEvent(.failed(failure))
        }
    }

    private func handleConfigurationChange() {
        guard let schedule = active else { return }
        let frame = renderedSessionFrame() ?? lastObservedSessionFrame ?? schedule.anchorFrame
        stop()
        schedule.onEvent(.interrupted(atSessionFrame: frame))
    }

    // MARK: - AVFoundation callbacks (arbitrary threads)

    /// Built outside main-actor isolation so the closure itself is never
    /// main-actor-isolated; it only hops.
    private nonisolated static func makeChunkCompletionHandler(
        backend: AVFoundationLecturePlaybackBackend,
        generation: Int,
        chunkIndex: Int
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak backend] _ in
            guard let backend else { return }
            Task { @MainActor in
                backend.chunkCompleted(generation: generation, chunkIndex: chunkIndex)
            }
        }
    }

    @objc private nonisolated func engineConfigurationChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleConfigurationChange()
        }
    }
}
