import Combine
import Foundation

nonisolated enum LecturePlaybackPhase: Equatable, Sendable {
    /// Prepared and not yet started (or reset by `stop()`).
    case ready
    case playing
    case paused
    /// The retained position is the session's end.
    case ended
    /// Terminal for this controller: preparing or playing failed. A fresh
    /// source/controller is needed to try again.
    case failed(LecturePlaybackFailure)
}

/// Non-UI playback state for one completed session, on one logical
/// session timeline. Callers (later T6 navigation and SwiftUI) speak only
/// session-relative seconds; chunk files are hidden beneath the backend.
///
/// Semantics:
/// - `play()` from `.ready`/`.paused` starts at the retained position;
///   from `.ended` it replays from 0. No-op while `.playing` or `.failed`.
/// - `pause()` retains the exact position last rendered.
/// - `seek(toSessionTime:)` clamps to `0...duration` (non-finite is
///   rejected and changes nothing). While playing it reschedules and keeps
///   playing; otherwise it only moves the retained position (`.ended`
///   becomes `.paused`). Seeking to the end yields `.ended` from any
///   non-failed phase.
/// - Natural completion yields `.ended` at the end position.
/// - `stop()` silences playback and resets to `.ready` at 0.
/// - Backend failure yields `.failed`; nothing on disk is touched.
///
/// Stale-event protection: each backend `play` gets a fresh token, and an
/// event is honoured only while its token is current and the phase is
/// still `.playing`, so a superseded schedule can never end or fail the
/// current one.
@MainActor
final class LecturePlaybackController: ObservableObject {
    let timeline: LecturePlaybackTimeline
    private let backend: any LectureAudioPlaybackBackend

    @Published private(set) var phase: LecturePlaybackPhase
    /// Authoritative position whenever not playing; the play anchor while
    /// playing.
    private var retainedFrame: Int64 = 0
    private var playToken = 0

    init(source: LecturePlaybackSource, backend: any LectureAudioPlaybackBackend) {
        self.timeline = source.timeline
        self.backend = backend
        do {
            try backend.prepare(source)
            phase = .ready
        } catch {
            phase = .failed(Self.failure(from: error))
        }
    }

    var durationSeconds: Double { timeline.durationSeconds }

    /// Session-relative position. While playing this samples the backend's
    /// render clock (falling back to the play anchor before the first
    /// render); a UI timer may poll it.
    var currentSessionFrame: Int64 {
        guard phase == .playing, let rendered = backend.renderedSessionFrame() else {
            return retainedFrame
        }
        return min(max(rendered, 0), timeline.totalFrameCount)
    }

    var currentSessionTime: Double {
        timeline.sessionTime(forSessionFrame: currentSessionFrame)
    }

    func play() {
        switch phase {
        case .playing, .failed:
            return
        case .ended:
            startBackend(at: 0)
        case .ready, .paused:
            startBackend(at: retainedFrame)
        }
    }

    func pause() {
        guard phase == .playing else { return }
        let frame = currentSessionFrame
        halt()
        settle(at: frame, phase: .paused)
    }

    /// Returns `false` (changing nothing) for a non-finite time or while
    /// `.failed`.
    @discardableResult
    func seek(toSessionTime seconds: Double) -> Bool {
        if case .failed = phase { return false }
        guard let frame = timeline.sessionFrame(forSessionTime: seconds) else { return false }

        if frame == timeline.totalFrameCount {
            halt()
            settle(at: frame, phase: .ended)
            return true
        }

        switch phase {
        case .playing:
            startBackend(at: frame)
        case .ended:
            retainedFrame = frame
            phase = .paused
        case .ready, .paused, .failed:
            retainedFrame = frame
        }
        return true
    }

    func stop() {
        if case .failed = phase { return }
        halt()
        settle(at: 0, phase: .ready)
    }

    // MARK: - Private

    private func startBackend(at frame: Int64) {
        playToken += 1
        let token = playToken
        do {
            try backend.play(fromSessionFrame: frame) { [weak self] event in
                self?.handle(event, token: token)
            }
        } catch {
            halt()
            settle(at: frame, phase: .failed(Self.failure(from: error)))
            return
        }
        settle(at: frame, phase: .playing)
    }

    private func handle(_ event: LecturePlaybackBackendEvent, token: Int) {
        guard token == playToken, phase == .playing else { return }
        switch event {
        case .reachedEnd:
            halt()
            settle(at: timeline.totalFrameCount, phase: .ended)
        case .interrupted(let frame):
            halt()
            settle(at: min(max(frame, 0), timeline.totalFrameCount), phase: .paused)
        case .failed(let failure):
            let frame = currentSessionFrame
            halt()
            settle(at: frame, phase: .failed(failure))
        }
    }

    /// Invalidates the current token and silences the backend.
    private func halt() {
        playToken += 1
        backend.stop()
    }

    private func settle(at frame: Int64, phase newPhase: LecturePlaybackPhase) {
        retainedFrame = frame
        if phase != newPhase {
            phase = newPhase
        }
    }

    private static func failure(from error: Error) -> LecturePlaybackFailure {
        if let failure = error as? LecturePlaybackFailure { return failure }
        if let sourceError = error as? LecturePlaybackSourceError { return .source(sourceError) }
        return .engineStartFailed(error.localizedDescription)
    }
}
