import os
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
    func testExactlyOneSharedCatalogTranscriptionAndNotesServiceInstance() {
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

        let notesServiceA = environment.lectureNotesGenerationService
        let notesServiceB = environment.lectureNotesGenerationService
        XCTAssertTrue(notesServiceA === notesServiceB)
    }

    /// MLX-3 regression coverage: proves the composition root defaults
    /// every brand-new Notes generation to the current MLX backend,
    /// mirroring Summary's own already-correct default
    /// (`MLXSummaryConfiguration.generationProvenance` at the Summary
    /// construction site in `AppEnvironment.init`). Before this fix,
    /// `AppEnvironment` wired `FoundationModelsNotesConfiguration
    /// .generationProvenance` here instead, so a brand-new Notes
    /// generation from the real app silently routed to Apple Foundation
    /// Models rather than MLX. Purely structural: never touches a real
    /// session, model, or async generation run.
    func testFreshEnvironmentDefaultsBrandNewNotesGenerationsToMLX() {
        let environment = AppEnvironment()
        XCTAssertEqual(
            environment.lectureNotesGenerationService.generationProvenanceForTesting.backendIdentifier,
            MLXNotesConfiguration.backendIdentifier
        )
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

    /// T7-B: application termination closes recording Start admission and
    /// shuts down every downstream service through one combined, bounded
    /// call. (Termination *during* a live recording is proven with fakes in
    /// `SessionManagerTests`; starting real capture here is avoided.)
    func testTerminationShutsDownRecordingAndAllDownstreamServices() async {
        let environment = AppEnvironment()

        let clock = ContinuousClock()
        let start = clock.now
        await environment.shutdownForTermination(recordingTimeout: 1)
        let elapsed = clock.now - start

        XCTAssertTrue(environment.sessionManager.isApplicationTerminating)
        XCTAssertFalse(environment.sessionManager.canStart)
        XCTAssertTrue(environment.completedSessionTranscriptionService.isShuttingDown)
        XCTAssertTrue(environment.lectureNotesGenerationService.isShuttingDown)
        XCTAssertTrue(environment.lectureSummaryGenerationService.isShuttingDown)
        XCTAssertTrue(environment.sessionDiarizationService.isShuttingDown)
        XCTAssertLessThan(elapsed, .seconds(1), "an idle environment releases immediately")
        XCTAssertEqual(
            environment.completedSessionTranscriptionService.transcribe(sessionID: UUID()),
            .shuttingDown
        )
        XCTAssertEqual(environment.sessionDiarizationService.diarize(sessionID: UUID()), .shuttingDown)
    }

    /// T6-D3: one app-wide diarization owner, composed idle — constructing
    /// the environment admits nothing and starts no diarization work.
    func testFreshEnvironmentComposesOneIdleDiarizationService() {
        let environment = AppEnvironment()
        XCTAssertTrue(environment.sessionDiarizationService === environment.sessionDiarizationService)
        XCTAssertEqual(environment.sessionDiarizationService.phase, .idle)
        XCTAssertEqual(environment.sessionDiarizationService.operationEpoch, 0)
        XCTAssertNil(environment.sessionDiarizationService.activeSessionID)
        XCTAssertNil(environment.sessionDiarizationService.lastReleasedOperation)
        XCTAssertFalse(environment.sessionDiarizationService.isShuttingDown)
    }

    /// The production backend `AppEnvironment` composes is lazy: merely
    /// constructing it never resolves (let alone verifies or loads) the
    /// diarization model.
    func testConstructingTheProductionDiarizerNeverResolvesTheModel() {
        let resolved = OSAllocatedUnfairLock(initialState: false)
        _ = FluidAudioSpeakerDiarizer(modelDirectory: {
            resolved.withLock { $0 = true }
            throw FluidAudioDiarizationModelError.modelDirectoryUnavailable
        })
        XCTAssertFalse(resolved.withLock { $0 })
    }

    /// The synchronous termination half closes diarization admission before
    /// any `await`, alongside every other app-wide owner.
    func testBeginTerminationSynchronouslyClosesDiarizationAdmission() async {
        let environment = AppEnvironment()
        environment.beginTermination()
        XCTAssertTrue(environment.sessionDiarizationService.isShuttingDown)
        XCTAssertEqual(environment.sessionDiarizationService.diarize(sessionID: UUID()), .shuttingDown)
        XCTAssertTrue(environment.completedSessionTranscriptionService.isShuttingDown)
        XCTAssertTrue(environment.lectureNotesGenerationService.isShuttingDown)
        XCTAssertTrue(environment.lectureSummaryGenerationService.isShuttingDown)
        await environment.shutdownForTermination(recordingTimeout: 1)
    }
}
