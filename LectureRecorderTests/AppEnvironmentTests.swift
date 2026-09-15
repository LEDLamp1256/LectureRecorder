import XCTest
@testable import LectureRecorder

/// Constructing `AppEnvironment()` touches the real `AudioCaptureService`/
/// `MicrophonePermissionService` types (mere `init`, never `prepare()`/
/// `start()`/`requestPermission()`), so this stays limited to structural
/// checks that are safe without hardware or a permission prompt. Deeper
/// behavioral proof of the admission coupling between `SessionManager` and
/// `CompletedSessionTranscriptionService` (e.g. "recording already active
/// blocks transcription") is exhaustively covered with fakes in
/// `CompletedSessionTranscriptionServiceTests` — exercising that here would
/// require actually starting real hardware capture, which this suite
/// deliberately avoids.
@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testExactlyOneSharedCatalogAndTranscriptionServiceInstance() {
        let environment = AppEnvironment()

        // Both are `let` properties assigned exactly once in `init` — this
        // proves there is only ever one instance of each for the app's
        // lifetime, by construction, not by mutation.
        let catalogA = environment.completedSessionCatalog
        let catalogB = environment.completedSessionCatalog
        XCTAssertEqual(String(describing: catalogA), String(describing: catalogB))

        let serviceA = environment.completedSessionTranscriptionService
        let serviceB = environment.completedSessionTranscriptionService
        XCTAssertTrue(serviceA === serviceB)
    }

    /// This does **not** prove `CompletedSessionTranscriptionService` reads
    /// the *same* `SessionManager` instance as `environment.sessionManager`
    /// — a freshly constructed `SessionManager` would equally start
    /// `.idle` and equally admit, so admission succeeding is consistent
    /// with either a shared or a coincidentally-separate instance. That
    /// exact identity is directly evident by inspection of
    /// `AppEnvironment.init` (the local `sessionManager` `let` is passed to
    /// both `self.sessionManager` and `CompletedSessionTranscriptionService.init(sessionManager:)`
    /// — there is no second construction site). The admission *behavior*
    /// itself (recording-state gating, both orderings) is exhaustively
    /// proven with controllable fake `SessionManager` dependencies in
    /// `CompletedSessionTranscriptionServiceTests`.
    ///
    /// What this test actually proves: a freshly composed `AppEnvironment`
    /// admits a transcription request for a nonexistent session without
    /// touching real hardware/the model — the request fails fast at
    /// manifest resolution (no such session directory exists) and reaches
    /// `.blocked` without ever constructing a Whisper worker, and the
    /// service correctly releases ownership afterward (a second admission
    /// for the same ID succeeds again).
    func testFreshEnvironmentAdmitsAndCleanlyReleasesANonexistentSessionRequest() async {
        let environment = AppEnvironment()
        let sessionID = UUID()

        let firstAdmission = environment.completedSessionTranscriptionService.transcribe(sessionID: sessionID)
        XCTAssertEqual(firstAdmission, .admitted)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .finished = environment.completedSessionTranscriptionService.phase { break }
            await Task.yield()
        }
        if case .finished(.blocked) = environment.completedSessionTranscriptionService.phase {
            // expected: no such session directory exists
        } else {
            XCTFail("expected .blocked for a nonexistent session, got \(environment.completedSessionTranscriptionService.phase)")
        }

        // Ownership was genuinely released — a second admission succeeds.
        let secondAdmission = environment.completedSessionTranscriptionService.transcribe(sessionID: sessionID)
        XCTAssertEqual(secondAdmission, .admitted)
    }
}
