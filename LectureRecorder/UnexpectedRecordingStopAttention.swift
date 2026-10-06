import AppKit
import Combine

/// The app-level owner of attention for an unexpectedly stopped recording:
/// for each new `UnexpectedRecordingStop` (by `id`) it performs the attention
/// side effect exactly once, however many times the same event is
/// re-observed and regardless of which recorder windows exist. Owned by
/// `AppTerminationDelegate` for the app's lifetime; `SessionManager` never
/// touches AppKit. Memory-only.
@MainActor
final class UnexpectedRecordingStopAttention {
    /// Dock bounce plus one beep. Never repeated by this type. `nonisolated`
    /// so it can be the `init` default argument; the closure itself runs on
    /// the main actor.
    nonisolated static let requestAttention: @MainActor @Sendable () -> Void = {
        _ = NSApp.requestUserAttention(.criticalRequest)
        NSSound.beep()
    }

    private let performAttention: @MainActor () -> Void
    private var lastAttendedEventID: UUID?
    private var subscription: AnyCancellable?

    init<Events: Publisher>(
        events: Events,
        performAttention: @escaping @MainActor () -> Void = UnexpectedRecordingStopAttention.requestAttention
    ) where Events.Output == UnexpectedRecordingStop?, Events.Failure == Never {
        self.performAttention = performAttention
        subscription = events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
    }

    /// Performs attention once per distinct event ID; `nil` and an
    /// already-attended event are ignored.
    func handle(_ event: UnexpectedRecordingStop?) {
        guard let event, event.id != lastAttendedEventID else { return }
        lastAttendedEventID = event.id
        performAttention()
    }
}
