import Foundation
@testable import LectureRecorder

/// Records calls and lets a test deliver events to any schedule it was
/// given — including superseded ones — so the controller's own stale-event
/// filtering is what gets exercised.
@MainActor
final class FakeLectureAudioPlaybackBackend: LectureAudioPlaybackBackend {
    enum Call: Equatable {
        case prepare(LecturePlaybackSource)
        case play(fromSessionFrame: Int64)
        case stop
    }

    private(set) var calls: [Call] = []
    private(set) var eventHandlers: [@MainActor (LecturePlaybackBackendEvent) -> Void] = []
    var prepareError: Error?
    var playError: Error?
    /// Returned by `renderedSessionFrame()`; `nil` models "no render yet".
    var renderedFrame: Int64?

    func prepare(_ source: LecturePlaybackSource) throws {
        calls.append(.prepare(source))
        if let prepareError { throw prepareError }
    }

    func play(
        fromSessionFrame frame: Int64,
        onEvent: @escaping @MainActor (LecturePlaybackBackendEvent) -> Void
    ) throws {
        calls.append(.play(fromSessionFrame: frame))
        if let playError { throw playError }
        eventHandlers.append(onEvent)
        renderedFrame = nil
    }

    func stop() {
        calls.append(.stop)
    }

    func renderedSessionFrame() -> Int64? {
        renderedFrame
    }

    /// Delivers `event` to the `index`th successful `play` schedule.
    func deliver(_ event: LecturePlaybackBackendEvent, toSchedule index: Int) {
        eventHandlers[index](event)
    }

    var playCalls: [Int64] {
        calls.compactMap {
            if case .play(let frame) = $0 { return frame }
            return nil
        }
    }
}
