import Foundation

nonisolated enum LectureSummaryGeneratorRoutingError: LocalizedError, Sendable, Equatable {
    /// `generation.provenance.backendIdentifier` matched neither the MLX
    /// nor the Apple route this router knows about. Fails closed — never
    /// guesses a default backend for unrecognized provenance.
    case unknownBackend(String?)

    var errorDescription: String? {
        switch self {
        case .unknownBackend(let identifier):
            return "No Summary generation backend is registered for provenance backendIdentifier \(identifier ?? "nil")."
        }
    }
}

/// Routes every `LectureSummaryGenerating` call to exactly the backend its
/// own generation's persisted `provenance.backendIdentifier` names — MLX for
/// new generations, Apple Foundation Models preserved for legacy ones.
/// Mirrors `LectureNotesGeneratorRouter`'s fixed, closed-set routing
/// contract; there is no OpenAI route here since Summary has never had one.
///
/// Never falls back from one backend to another: a failure the routed
/// backend throws is reported as-is, and unrecognized provenance fails
/// closed via `LectureSummaryGeneratorRoutingError.unknownBackend`.
nonisolated struct LectureSummaryGeneratorRouter: LectureSummaryGenerating, NewLectureNotesGenerationAvailabilityChecking {
    private let appleGenerator: any LectureSummaryGenerating
    private let mlxGenerator: any (LectureSummaryGenerating & NewLectureNotesGenerationAvailabilityChecking)
    private let appleBackendIdentifier: String
    private let mlxBackendIdentifier: String

    init(
        appleGenerator: any LectureSummaryGenerating,
        mlxGenerator: any (LectureSummaryGenerating & NewLectureNotesGenerationAvailabilityChecking),
        appleBackendIdentifier: String = FoundationModelsSummaryConfiguration.backendIdentifier,
        mlxBackendIdentifier: String = MLXSummaryConfiguration.backendIdentifier
    ) {
        self.appleGenerator = appleGenerator
        self.mlxGenerator = mlxGenerator
        self.appleBackendIdentifier = appleBackendIdentifier
        self.mlxBackendIdentifier = mlxBackendIdentifier
    }

    /// MLX is the sole backend this router ever mints provenance for on a
    /// brand-new generation — never operationally consulted (the
    /// orchestration service always stamps new records from its own
    /// injected `generationProvenance`), but kept consistent with that same
    /// fact for protocol conformance.
    var provenance: LectureNotesGenerationProvenance { mlxGenerator.provenance }

    /// MLX is the sole backend this router ever mints provenance for on a
    /// brand-new generation, so admission-time availability is always the
    /// MLX generator's own answer — never Apple's. Mirrors
    /// `LectureNotesGeneratorRouter.availabilityForNewGeneration`.
    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability {
        mlxGenerator.availabilityForNewGeneration()
    }

    /// Planning a brand-new generation has no `generation` record yet to
    /// route by — it always happens before one exists (see
    /// `LectureSummaryGenerationService.run()`). Since MLX is the sole
    /// backend a brand-new generation ever uses, planning always delegates
    /// to it, mirroring `availabilityForNewGeneration` above.
    func makePlan(for source: LectureSummarySourceSnapshot) async throws -> LectureSummaryPlan {
        try await mlxGenerator.makePlan(for: source)
    }

    func generateAnalysis(
        for batch: LectureSummaryBatch,
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) async throws -> LectureSummaryAnalysis {
        try await route(for: generation).generateAnalysis(for: batch, generation: generation, source: source)
    }

    func generateDocument(
        from analyses: [LectureSummaryAnalysis],
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) async throws -> LectureSummaryDocument {
        try await route(for: generation).generateDocument(from: analyses, generation: generation, source: source)
    }

    private func route(for generation: LectureSummaryGenerationRecord) throws -> any LectureSummaryGenerating {
        switch generation.provenance.backendIdentifier {
        case mlxBackendIdentifier:
            return mlxGenerator
        case appleBackendIdentifier:
            return appleGenerator
        default:
            throw LectureSummaryGeneratorRoutingError.unknownBackend(generation.provenance.backendIdentifier)
        }
    }
}
