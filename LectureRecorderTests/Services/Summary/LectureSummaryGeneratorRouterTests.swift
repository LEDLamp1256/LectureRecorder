import XCTest
@testable import LectureRecorder

final class LectureSummaryGeneratorRouterTests: XCTestCase {

    private func generation(backendIdentifier: String?, source: LectureSummarySourceSnapshot) throws -> LectureSummaryGenerationRecord {
        let plan = try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 10_000, maxItemsPerBatch: 12)
        )
        return LectureSummaryGenerationRecord.newGeneration(
            sessionID: source.sessionID,
            sourceNotesGenerationID: source.sourceNotesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint,
            sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchPlan: plan,
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-v1", backendIdentifier: backendIdentifier)
        )
    }

    private func makeRouter(
        apple: RecordingLectureSummaryGenerator,
        mlx: RecordingLectureSummaryGenerator
    ) -> LectureSummaryGeneratorRouter {
        LectureSummaryGeneratorRouter(appleGenerator: apple, mlxGenerator: mlx)
    }

    private func makeGenerators() -> (apple: RecordingLectureSummaryGenerator, mlx: RecordingLectureSummaryGenerator) {
        (
            RecordingLectureSummaryGenerator(provenance: FoundationModelsSummaryConfiguration.generationProvenance),
            RecordingLectureSummaryGenerator(provenance: MLXSummaryConfiguration.generationProvenance)
        )
    }

    func testAppleProvenanceRoutesOnlyToApple() async throws {
        let source = try SummaryTestSupport.source()
        let (apple, mlx) = makeGenerators()
        let router = makeRouter(apple: apple, mlx: mlx)
        let generationRecord = try generation(backendIdentifier: FoundationModelsSummaryConfiguration.backendIdentifier, source: source)
        let batch = generationRecord.batchPlan.batches[0]

        _ = try await router.generateAnalysis(for: batch, generation: generationRecord, source: source)
        _ = try await router.generateDocument(from: [], generation: generationRecord, source: source)

        XCTAssertEqual(apple.generateAnalysisCallCount, 1)
        XCTAssertEqual(apple.generateDocumentCallCount, 1)
        XCTAssertEqual(mlx.generateAnalysisCallCount, 0)
        XCTAssertEqual(mlx.generateDocumentCallCount, 0)
    }

    func testMLXProvenanceRoutesOnlyToMLX() async throws {
        let source = try SummaryTestSupport.source()
        let (apple, mlx) = makeGenerators()
        let router = makeRouter(apple: apple, mlx: mlx)
        let generationRecord = try generation(backendIdentifier: MLXSummaryConfiguration.backendIdentifier, source: source)
        let batch = generationRecord.batchPlan.batches[0]

        _ = try await router.generateAnalysis(for: batch, generation: generationRecord, source: source)
        _ = try await router.generateDocument(from: [], generation: generationRecord, source: source)

        XCTAssertEqual(mlx.generateAnalysisCallCount, 1)
        XCTAssertEqual(mlx.generateDocumentCallCount, 1)
        XCTAssertEqual(apple.generateAnalysisCallCount, 0)
        XCTAssertEqual(apple.generateDocumentCallCount, 0)
    }

    func testUnknownProvenanceFailsClosed() async throws {
        let source = try SummaryTestSupport.source()
        let (apple, mlx) = makeGenerators()
        let router = makeRouter(apple: apple, mlx: mlx)
        let generationRecord = try generation(backendIdentifier: "some-unregistered-backend", source: source)
        let batch = generationRecord.batchPlan.batches[0]

        do {
            _ = try await router.generateAnalysis(for: batch, generation: generationRecord, source: source)
            XCTFail("expected a routing failure for unrecognized provenance")
        } catch {
            XCTAssertEqual(error as? LectureSummaryGeneratorRoutingError, .unknownBackend("some-unregistered-backend"))
        }
        XCTAssertEqual(apple.generateAnalysisCallCount, 0)
        XCTAssertEqual(mlx.generateAnalysisCallCount, 0)
    }

    func testNilProvenanceFailsClosed() async throws {
        let source = try SummaryTestSupport.source()
        let (apple, mlx) = makeGenerators()
        let router = makeRouter(apple: apple, mlx: mlx)
        let generationRecord = try generation(backendIdentifier: nil, source: source)

        do {
            _ = try await router.generateDocument(from: [], generation: generationRecord, source: source)
            XCTFail("expected a routing failure for nil provenance")
        } catch {
            XCTAssertEqual(error as? LectureSummaryGeneratorRoutingError, .unknownBackend(nil))
        }
    }

    func testAppleFailureDoesNotFallBackToMLX() async throws {
        let source = try SummaryTestSupport.source()
        let (apple, mlx) = makeGenerators()
        apple.generateDocumentFailure = RecordingGeneratorFailure(message: "apple unavailable")
        let router = makeRouter(apple: apple, mlx: mlx)
        let generationRecord = try generation(backendIdentifier: FoundationModelsSummaryConfiguration.backendIdentifier, source: source)

        do {
            _ = try await router.generateDocument(from: [], generation: generationRecord, source: source)
            XCTFail("expected the apple generator's failure to propagate")
        } catch {
            XCTAssertEqual(error as? RecordingGeneratorFailure, RecordingGeneratorFailure(message: "apple unavailable"))
        }
        XCTAssertEqual(mlx.generateDocumentCallCount, 0)
    }

    func testMLXFailureDoesNotFallBackToApple() async throws {
        let source = try SummaryTestSupport.source()
        let (apple, mlx) = makeGenerators()
        mlx.generateDocumentFailure = RecordingGeneratorFailure(message: "mlx failed")
        let router = makeRouter(apple: apple, mlx: mlx)
        let generationRecord = try generation(backendIdentifier: MLXSummaryConfiguration.backendIdentifier, source: source)

        do {
            _ = try await router.generateDocument(from: [], generation: generationRecord, source: source)
            XCTFail("expected the MLX generator's failure to propagate")
        } catch {
            XCTAssertEqual(error as? RecordingGeneratorFailure, RecordingGeneratorFailure(message: "mlx failed"))
        }
        XCTAssertEqual(apple.generateDocumentCallCount, 0)
    }

    func testAvailabilityForNewGenerationDelegatesOnlyToMLX() {
        let (apple, mlx) = makeGenerators()
        apple.availabilityResult = .available
        mlx.availabilityResult = .unavailable(description: "model assets not ready")
        let router = makeRouter(apple: apple, mlx: mlx)

        XCTAssertEqual(router.availabilityForNewGeneration(), .unavailable(description: "model assets not ready"))
    }

    /// Planning a brand-new generation has no `generation` record yet to
    /// route by, so it must always delegate to MLX — the sole backend a
    /// brand-new generation ever uses — regardless of what any prior
    /// generation on the same session used.
    func testMakePlanAlwaysDelegatesToMLX() async throws {
        let source = try SummaryTestSupport.source()
        let (apple, mlx) = makeGenerators()
        let router = makeRouter(apple: apple, mlx: mlx)

        _ = try await router.makePlan(for: source)

        XCTAssertEqual(mlx.makePlanCallCount, 1)
        XCTAssertEqual(apple.makePlanCallCount, 0)
    }
}
