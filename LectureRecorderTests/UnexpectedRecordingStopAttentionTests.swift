import Combine
import XCTest
@testable import LectureRecorder

/// T7-C3: the app-level attention owner performs its side effect exactly
/// once per distinct unexpected-stop event. The side effect is injected, so
/// these tests never beep or bounce the Dock.
@MainActor
final class UnexpectedRecordingStopAttentionTests: XCTestCase {
    private func event(_ id: UUID = UUID()) -> UnexpectedRecordingStop {
        UnexpectedRecordingStop(id: id, sessionID: UUID(), reason: "Audio couldn't be written to disk.", finalizationConfirmed: true)
    }

    private func drainMainQueue() async {
        // `receive(on: DispatchQueue.main)` delivers asynchronously.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testNewEventPerformsAttentionExactlyOnce() async {
        let subject = CurrentValueSubject<UnexpectedRecordingStop?, Never>(nil)
        var count = 0
        let attention = UnexpectedRecordingStopAttention(events: subject) { count += 1 }

        subject.send(event())
        await drainMainQueue()

        XCTAssertEqual(count, 1)
        withExtendedLifetime(attention) {}
    }

    func testReobservingTheSameEventNeverRepeatsAttention() async {
        let subject = CurrentValueSubject<UnexpectedRecordingStop?, Never>(nil)
        var count = 0
        let attention = UnexpectedRecordingStopAttention(events: subject) { count += 1 }
        let stale = event()

        subject.send(stale)
        subject.send(stale)
        subject.send(nil)
        subject.send(stale)
        await drainMainQueue()
        attention.handle(stale)

        XCTAssertEqual(count, 1)
    }

    func testAlreadyPublishedEventAtSubscriptionIsAttendedOnceNotAgainOnRepeat() async {
        let existing = event()
        let subject = CurrentValueSubject<UnexpectedRecordingStop?, Never>(existing)
        var count = 0
        let attention = UnexpectedRecordingStopAttention(events: subject) { count += 1 }
        await drainMainQueue()
        subject.send(existing)
        await drainMainQueue()

        XCTAssertEqual(count, 1)
        withExtendedLifetime(attention) {}
    }

    func testSecondDistinctEventPerformsAttentionAgain() async {
        let subject = CurrentValueSubject<UnexpectedRecordingStop?, Never>(nil)
        var count = 0
        let attention = UnexpectedRecordingStopAttention(events: subject) { count += 1 }

        subject.send(event())
        subject.send(nil)
        subject.send(event())
        await drainMainQueue()

        XCTAssertEqual(count, 2)
        withExtendedLifetime(attention) {}
    }

    func testNilNeverPerformsAttention() async {
        let subject = CurrentValueSubject<UnexpectedRecordingStop?, Never>(nil)
        var count = 0
        let attention = UnexpectedRecordingStopAttention(events: subject) { count += 1 }
        subject.send(nil)
        await drainMainQueue()
        XCTAssertEqual(count, 0)
        withExtendedLifetime(attention) {}
    }

    func testAlertWordingCarriesTheSanitizedReasonAndNeverPromisesARestart() {
        let saved = UnexpectedRecordingStop(id: UUID(), sessionID: UUID(), reason: "The audio input changed or stopped working.", finalizationConfirmed: true)
        XCTAssertEqual(UnexpectedRecordingStopMessage.title, "Recording Stopped Unexpectedly")
        XCTAssertEqual(
            UnexpectedRecordingStopMessage.message(for: saved),
            "The audio input changed or stopped working.\n\nAudio saved before the problem occurred has been kept. Press Start to begin a new recording."
        )
        let unconfirmed = UnexpectedRecordingStop(id: UUID(), sessionID: UUID(), reason: "Audio couldn't be written to disk.", finalizationConfirmed: false)
        let message = UnexpectedRecordingStopMessage.message(for: unconfirmed)
        XCTAssertFalse(message.contains("has been kept"))
        XCTAssertFalse(message.lowercased().contains("resum"))
    }
}
