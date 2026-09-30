import Combine
import Foundation

/// A running position poll; `cancel()` stops further ticks.
@MainActor
protocol PlaybackPositionPolling: AnyObject {
    func cancel()
}

/// Starts repeating position polls. Injectable so tests can fire ticks
/// deterministically instead of waiting on real time.
@MainActor
protocol PlaybackPositionPollScheduling {
    func schedule(every interval: Duration, _ tick: @escaping @MainActor () -> Void) -> any PlaybackPositionPolling
}

/// Production poll: a main-actor `Task` that sleeps `interval` between
/// ticks. The sleep only paces sampling — it is never a playback position.
@MainActor
final class TaskPlaybackPositionPollScheduler: PlaybackPositionPollScheduling {
    private final class Poll: PlaybackPositionPolling {
        private let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }

        func cancel() {
            task.cancel()
        }
    }

    func schedule(every interval: Duration, _ tick: @escaping @MainActor () -> Void) -> any PlaybackPositionPolling {
        Poll(task: Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                tick()
            }
        })
    }
}

/// One transcript view's playback presentation: prepares a
/// `LecturePlaybackSource` off the main actor, owns the single
/// `LecturePlaybackController` for the displayed session, and republishes
/// its phase and position for SwiftUI.
///
/// Not a second playback state machine: every command goes straight to the
/// controller and the published state is re-read from it afterwards. The
/// controller (and beneath it the backend's render clock) stays the only
/// position authority. While — and only while — the controller is
/// `.playing`, a poll samples `currentSessionFrame` every
/// `positionPollInterval`; each sample also refreshes the AVFoundation
/// backend's last observed frame, which is what an output-route change
/// falls back to.
///
/// Stale-preparation protection mirrors `SessionTranscriptPresenter`:
/// `prepare(for:)` and `tearDown()` bump `generation`, and a source load
/// that finishes after a newer call is discarded without ever creating a
/// controller. Preparing a new session, or tearing down, stops and drops
/// the previous controller first, so old audio never keeps playing.
@MainActor
final class SessionPlaybackPresenter: ObservableObject {
    enum Status: Equatable {
        /// Nothing prepared (initial, or after `tearDown()`).
        case idle
        case preparing
        /// The source failed T6-B validation; no controller exists.
        case unavailable(String)
        case available(LecturePlaybackPhase)
    }

    typealias SourceLoader = @Sendable (UUID, SessionManifest, SessionPaths) async throws -> LecturePlaybackSource
    typealias BackendFactory = @MainActor () -> any LectureAudioPlaybackBackend

    static let positionPollInterval: Duration = .milliseconds(100)

    /// Runs `LecturePlaybackSourceLoader.load` (synchronous file I/O) on a
    /// detached task so it never blocks the main actor.
    nonisolated static let productionSourceLoader: SourceLoader = { sessionID, manifest, sessionPaths in
        try await Task.detached(priority: .userInitiated) {
            try LecturePlaybackSourceLoader.load(
                expectedSessionID: sessionID,
                manifest: manifest,
                sessionPaths: sessionPaths
            )
        }.value
    }

    @Published private(set) var displayedSessionID: UUID?
    @Published private(set) var status: Status = .idle
    @Published private(set) var currentSessionFrame: Int64 = 0
    @Published private(set) var currentSessionTime: Double = 0
    @Published private(set) var durationSeconds: Double?

    private let sourceLoader: SourceLoader
    private let backendFactory: BackendFactory
    private let pollScheduler: any PlaybackPositionPollScheduling

    private var controller: LecturePlaybackController?
    private var phaseSubscription: AnyCancellable?
    private var poll: (any PlaybackPositionPolling)?
    private var generation = 0

    init(
        sourceLoader: @escaping SourceLoader = SessionPlaybackPresenter.productionSourceLoader,
        backendFactory: @escaping BackendFactory = { AVFoundationLecturePlaybackBackend() },
        pollScheduler: (any PlaybackPositionPollScheduling)? = nil
    ) {
        self.sourceLoader = sourceLoader
        self.backendFactory = backendFactory
        self.pollScheduler = pollScheduler ?? TaskPlaybackPositionPollScheduler()
    }

    var isPolling: Bool { poll != nil }

    var phase: LecturePlaybackPhase? {
        if case .available(let phase) = status { return phase }
        return nil
    }

    var isPlaying: Bool { phase == .playing }

    var canPlayOrPause: Bool {
        switch phase {
        case .ready, .playing, .paused, .ended: return true
        case .failed, nil: return false
        }
    }

    var canStop: Bool {
        switch phase {
        case .playing, .paused, .ended: return true
        case .ready, .failed, nil: return false
        }
    }

    var canSeek: Bool { canPlayOrPause }

    // MARK: - Lifecycle

    /// Stops any previous session's playback, then prepares `entry`'s audio.
    /// Never starts playback.
    func prepare(for entry: CompletedSessionEntry) async {
        generation += 1
        let myGeneration = generation
        let sessionID = entry.manifest.sessionID

        discardController()
        displayedSessionID = sessionID
        status = .preparing
        publishPosition(frame: 0, time: 0)
        durationSeconds = nil

        let source: LecturePlaybackSource
        do {
            source = try await sourceLoader(sessionID, entry.manifest, entry.sessionPaths)
        } catch {
            guard myGeneration == generation else { return }
            status = .unavailable(Self.message(for: error))
            return
        }
        guard myGeneration == generation else { return }

        let controller = LecturePlaybackController(source: source, backend: backendFactory())
        self.controller = controller
        durationSeconds = controller.durationSeconds
        // `@Published` emits before the controller stores the new phase.
        // Sampling here is still exact: the controller settles its retained
        // frame before changing phase, and every transition out of
        // `.playing` stops the backend first, so its render clock reports
        // nothing and the retained frame is what gets read.
        phaseSubscription = controller.$phase.sink { [weak self] phase in
            self?.apply(phase: phase)
        }
    }

    /// Stops playback and forgets the session — for the view disappearing.
    func tearDown() {
        generation += 1
        discardController()
        displayedSessionID = nil
        status = .idle
        publishPosition(frame: 0, time: 0)
        durationSeconds = nil
    }

    // MARK: - Commands

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        controller?.play()
        syncFromController()
    }

    func pause() {
        controller?.pause()
        syncFromController()
    }

    func stop() {
        controller?.stop()
        syncFromController()
    }

    /// Moves playback to `seconds` without changing whether it plays — the
    /// time slider's seek. Delegates to `LecturePlaybackController.seek`, so
    /// its semantics apply unchanged: ready and paused keep their phase,
    /// playing reschedules and keeps playing, ended becomes paused, the time
    /// is clamped to `0...duration` (the end itself settles as ended), and a
    /// non-finite time is rejected. Returns `false` (changing nothing) when
    /// there is no usable controller or the controller rejects the seek.
    @discardableResult
    func seek(toSessionTime seconds: Double) -> Bool {
        guard let controller, controller.seek(toSessionTime: seconds) else { return false }
        syncFromController()
        return true
    }

    /// Seeks to `item`'s exact start and plays from there: from ready,
    /// paused, or ended it seeks then starts; while playing it reschedules
    /// and keeps playing. Returns `false` (changing nothing) when there is
    /// no usable controller, the navigation belongs to another session, or
    /// the target is outside the timeline.
    @discardableResult
    func navigate(to item: TranscriptPlaybackItem, in navigation: TranscriptPlaybackNavigation) -> Bool {
        guard let controller, navigation.sessionID == controller.timeline.sessionID else { return false }
        let timeline = controller.timeline
        guard navigation.sampleRate == timeline.sampleRate,
              item.startSessionFrame >= 0, item.startSessionFrame < timeline.totalFrameCount else {
            return false
        }

        // Frame → seconds → frame is exact under the timeline's
        // nearest-frame rounding; the check keeps it so.
        let seconds = timeline.sessionTime(forSessionFrame: item.startSessionFrame)
        guard timeline.sessionFrame(forSessionTime: seconds) == item.startSessionFrame,
              controller.seek(toSessionTime: seconds) else {
            return false
        }
        if controller.phase != .playing {
            controller.play()
        }
        syncFromController()
        return true
    }

    // MARK: - Private

    private func syncFromController() {
        guard let controller else { return }
        apply(phase: controller.phase)
    }

    private func apply(phase: LecturePlaybackPhase) {
        let newStatus = Status.available(phase)
        if status != newStatus {
            status = newStatus
        }
        samplePosition()
        if phase == .playing {
            startPollingIfNeeded()
        } else {
            stopPolling()
        }
    }

    private func samplePosition() {
        guard let controller else { return }
        let frame = controller.currentSessionFrame
        publishPosition(frame: frame, time: controller.timeline.sessionTime(forSessionFrame: frame))
    }

    private func pollTick() {
        guard let controller, controller.phase == .playing else {
            stopPolling()
            return
        }
        samplePosition()
    }

    private func startPollingIfNeeded() {
        guard poll == nil else { return }
        poll = pollScheduler.schedule(every: Self.positionPollInterval) { [weak self] in
            self?.pollTick()
        }
    }

    private func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    private func discardController() {
        stopPolling()
        phaseSubscription?.cancel()
        phaseSubscription = nil
        controller?.stop()
        controller = nil
    }

    private func publishPosition(frame: Int64, time: Double) {
        if currentSessionFrame != frame {
            currentSessionFrame = frame
        }
        if currentSessionTime != time {
            currentSessionTime = time
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Playback is unavailable for this session."
    }
}
