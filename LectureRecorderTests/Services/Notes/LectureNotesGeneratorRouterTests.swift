import XCTest
@testable import LectureRecorder

final class LectureNotesGeneratorRouterTests: XCTestCase {

    private func window() -> NotesInputWindow {
        NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 0, unitCount: 1, isOversizedSingleUnit: false)
    }

    private func generation(backendIdentifier: String?, sessionID: UUID = UUID()) -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: []),
            windowPlan: NotesWindowPlan(windows: [window()]),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-v1", backendIdentifier: backendIdentifier)
        )
    }

    private func makeRouter(
        apple: RecordingLectureNotesGenerator,
        openAI: RecordingLectureNotesGenerator,
        mlx: RecordingLectureNotesGenerator
    ) -> LectureNotesGeneratorRouter {
        LectureNotesGeneratorRouter(appleGenerator: apple, openAIGenerator: openAI, mlxGenerator: mlx)
    }

    func testAppleProvenanceRoutesOnlyToApple() async throws {
        let apple = RecordingLectureNotesGenerator()
        let openAI = RecordingLectureNotesGenerator()
        let mlx = RecordingLectureNotesGenerator()
        let router = makeRouter(apple: apple, openAI: openAI, mlx: mlx)
        let generationRecord = generation(backendIdentifier: FoundationModelsNotesConfiguration.backendIdentifier)

        _ = try await router.analyzeWindow(units: [], window: window(), generation: generationRecord)
        _ = try await router.synthesize(analyses: [], generation: generationRecord)

        XCTAssertEqual(apple.analyzeCallCount, 1)
        XCTAssertEqual(apple.synthesizeCallCount, 1)
        XCTAssertEqual(openAI.analyzeCallCount, 0)
        XCTAssertEqual(openAI.synthesizeCallCount, 0)
        XCTAssertEqual(mlx.analyzeCallCount, 0)
        XCTAssertEqual(mlx.synthesizeCallCount, 0)
    }

    func testOpenAIProvenanceRoutesOnlyToOpenAI() async throws {
        let apple = RecordingLectureNotesGenerator()
        let openAI = RecordingLectureNotesGenerator()
        let mlx = RecordingLectureNotesGenerator()
        let router = makeRouter(apple: apple, openAI: openAI, mlx: mlx)
        let generationRecord = generation(backendIdentifier: OpenAINotesConfiguration.backendIdentifier)

        _ = try await router.analyzeWindow(units: [], window: window(), generation: generationRecord)
        _ = try await router.synthesize(analyses: [], generation: generationRecord)

        XCTAssertEqual(openAI.analyzeCallCount, 1)
        XCTAssertEqual(openAI.synthesizeCallCount, 1)
        XCTAssertEqual(apple.analyzeCallCount, 0)
        XCTAssertEqual(apple.synthesizeCallCount, 0)
        XCTAssertEqual(mlx.analyzeCallCount, 0)
        XCTAssertEqual(mlx.synthesizeCallCount, 0)
    }

    func testMLXProvenanceRoutesOnlyToMLX() async throws {
        let apple = RecordingLectureNotesGenerator()
        let openAI = RecordingLectureNotesGenerator()
        let mlx = RecordingLectureNotesGenerator()
        let router = makeRouter(apple: apple, openAI: openAI, mlx: mlx)
        let generationRecord = generation(backendIdentifier: MLXNotesConfiguration.backendIdentifier)

        _ = try await router.analyzeWindow(units: [], window: window(), generation: generationRecord)
        _ = try await router.synthesize(analyses: [], generation: generationRecord)

        XCTAssertEqual(mlx.analyzeCallCount, 1)
        XCTAssertEqual(mlx.synthesizeCallCount, 1)
        XCTAssertEqual(apple.analyzeCallCount, 0)
        XCTAssertEqual(apple.synthesizeCallCount, 0)
        XCTAssertEqual(openAI.analyzeCallCount, 0)
        XCTAssertEqual(openAI.synthesizeCallCount, 0)
    }

    func testUnknownProvenanceFailsClosed() async throws {
        let apple = RecordingLectureNotesGenerator()
        let openAI = RecordingLectureNotesGenerator()
        let mlx = RecordingLectureNotesGenerator()
        let router = makeRouter(apple: apple, openAI: openAI, mlx: mlx)
        let generationRecord = generation(backendIdentifier: "some-unregistered-backend")

        do {
            _ = try await router.analyzeWindow(units: [], window: window(), generation: generationRecord)
            XCTFail("expected a routing failure for unrecognized provenance")
        } catch {
            XCTAssertEqual(error as? LectureNotesGeneratorRoutingError, .unknownBackend("some-unregistered-backend"))
        }
        XCTAssertEqual(apple.analyzeCallCount, 0)
        XCTAssertEqual(openAI.analyzeCallCount, 0)
        XCTAssertEqual(mlx.analyzeCallCount, 0)
    }

    func testNilProvenanceFailsClosed() async throws {
        let apple = RecordingLectureNotesGenerator()
        let openAI = RecordingLectureNotesGenerator()
        let mlx = RecordingLectureNotesGenerator()
        let router = makeRouter(apple: apple, openAI: openAI, mlx: mlx)
        let generationRecord = generation(backendIdentifier: nil)

        do {
            _ = try await router.synthesize(analyses: [], generation: generationRecord)
            XCTFail("expected a routing failure for nil provenance")
        } catch {
            XCTAssertEqual(error as? LectureNotesGeneratorRoutingError, .unknownBackend(nil))
        }
    }

    func testAppleFailureDoesNotFallBackToOpenAIOrMLX() async throws {
        let apple = RecordingLectureNotesGenerator()
        apple.synthesizeFailure = RecordingGeneratorFailure(message: "apple unavailable")
        let openAI = RecordingLectureNotesGenerator()
        let mlx = RecordingLectureNotesGenerator()
        let router = makeRouter(apple: apple, openAI: openAI, mlx: mlx)
        let generationRecord = generation(backendIdentifier: FoundationModelsNotesConfiguration.backendIdentifier)

        do {
            _ = try await router.synthesize(analyses: [], generation: generationRecord)
            XCTFail("expected the apple generator's failure to propagate")
        } catch {
            XCTAssertEqual(error as? RecordingGeneratorFailure, RecordingGeneratorFailure(message: "apple unavailable"))
        }
        XCTAssertEqual(openAI.synthesizeCallCount, 0)
        XCTAssertEqual(mlx.synthesizeCallCount, 0)
    }

    func testOpenAIFailureDoesNotFallBackToAppleOrMLX() async throws {
        let apple = RecordingLectureNotesGenerator()
        let openAI = RecordingLectureNotesGenerator()
        openAI.synthesizeFailure = RecordingGeneratorFailure(message: "openai failed")
        let mlx = RecordingLectureNotesGenerator()
        let router = makeRouter(apple: apple, openAI: openAI, mlx: mlx)
        let generationRecord = generation(backendIdentifier: OpenAINotesConfiguration.backendIdentifier)

        do {
            _ = try await router.synthesize(analyses: [], generation: generationRecord)
            XCTFail("expected the OpenAI generator's failure to propagate")
        } catch {
            XCTAssertEqual(error as? RecordingGeneratorFailure, RecordingGeneratorFailure(message: "openai failed"))
        }
        XCTAssertEqual(apple.synthesizeCallCount, 0)
        XCTAssertEqual(mlx.synthesizeCallCount, 0)
    }

    func testMLXFailureDoesNotFallBackToAppleOrOpenAI() async throws {
        let apple = RecordingLectureNotesGenerator()
        let openAI = RecordingLectureNotesGenerator()
        let mlx = RecordingLectureNotesGenerator()
        mlx.synthesizeFailure = RecordingGeneratorFailure(message: "mlx failed")
        let router = makeRouter(apple: apple, openAI: openAI, mlx: mlx)
        let generationRecord = generation(backendIdentifier: MLXNotesConfiguration.backendIdentifier)

        do {
            _ = try await router.synthesize(analyses: [], generation: generationRecord)
            XCTFail("expected the MLX generator's failure to propagate")
        } catch {
            XCTAssertEqual(error as? RecordingGeneratorFailure, RecordingGeneratorFailure(message: "mlx failed"))
        }
        XCTAssertEqual(apple.synthesizeCallCount, 0)
        XCTAssertEqual(openAI.synthesizeCallCount, 0)
    }

    func testAvailabilityForNewGenerationDelegatesOnlyToMLX() {
        let apple = RecordingLectureNotesGenerator()
        apple.availabilityResult = .available
        let openAI = RecordingLectureNotesGenerator()
        openAI.availabilityResult = .available
        let mlx = RecordingLectureNotesGenerator()
        mlx.availabilityResult = .unavailable(description: "model assets not ready")
        let router = makeRouter(apple: apple, openAI: openAI, mlx: mlx)

        XCTAssertEqual(router.availabilityForNewGeneration(), .unavailable(description: "model assets not ready"))
    }
}
