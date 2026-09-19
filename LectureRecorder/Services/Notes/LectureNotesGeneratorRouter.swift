import Foundation

nonisolated enum LectureNotesGeneratorRoutingError: LocalizedError, Sendable, Equatable {
    /// `generation.provenance.backendIdentifier` matched neither the Apple
    /// nor the OpenAI route this router knows about. Fails closed — never
    /// guesses a default backend for unrecognized provenance.
    case unknownBackend(String?)

    var errorDescription: String? {
        switch self {
        case .unknownBackend(let identifier):
            return "No Notes generation backend is registered for provenance backendIdentifier \(identifier ?? "nil")."
        }
    }
}

/// Routes every `LectureNotesGenerating` call to exactly the backend its
/// own generation's persisted `provenance.backendIdentifier` names — MLX
/// for new generations, Apple Foundation Models and the existing OpenAI
/// generator preserved for legacy ones. Deliberately small and fixed to
/// these three known routes (T5-E scope explicitly excluded a general
/// provider registry/picker; MLX-1 extends the same fixed shape rather
/// than replacing it).
///
/// Never falls back from one backend to another: a failure the routed
/// backend throws is reported as-is, and unrecognized provenance fails
/// closed via `LectureNotesGeneratorRoutingError.unknownBackend`.
nonisolated struct LectureNotesGeneratorRouter: LectureNotesGenerating, NewLectureNotesGenerationAvailabilityChecking {
    private let appleGenerator: any LectureNotesGenerating
    private let openAIGenerator: any LectureNotesGenerating
    private let mlxGenerator: any (LectureNotesGenerating & NewLectureNotesGenerationAvailabilityChecking)
    private let appleBackendIdentifier: String
    private let openAIBackendIdentifier: String
    private let mlxBackendIdentifier: String

    init(
        appleGenerator: any LectureNotesGenerating,
        openAIGenerator: any LectureNotesGenerating,
        mlxGenerator: any (LectureNotesGenerating & NewLectureNotesGenerationAvailabilityChecking),
        appleBackendIdentifier: String = FoundationModelsNotesConfiguration.backendIdentifier,
        openAIBackendIdentifier: String = OpenAINotesConfiguration.backendIdentifier,
        mlxBackendIdentifier: String = MLXNotesConfiguration.backendIdentifier
    ) {
        self.appleGenerator = appleGenerator
        self.openAIGenerator = openAIGenerator
        self.mlxGenerator = mlxGenerator
        self.appleBackendIdentifier = appleBackendIdentifier
        self.openAIBackendIdentifier = openAIBackendIdentifier
        self.mlxBackendIdentifier = mlxBackendIdentifier
    }

    /// MLX is the sole backend this router ever mints provenance for on a
    /// brand-new generation (see `MLXNotesConfiguration
    /// .generationProvenance`), so admission-time availability is always
    /// the MLX generator's own answer — never Apple's or OpenAI's.
    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability {
        mlxGenerator.availabilityForNewGeneration()
    }

    func analyzeWindow(
        units: [NotesTranscriptSourceUnit],
        window: NotesInputWindow,
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesWindowAnalysis {
        try await route(for: generation).analyzeWindow(units: units, window: window, generation: generation)
    }

    func synthesize(
        analyses: [LectureNotesWindowAnalysis],
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesDocument {
        try await route(for: generation).synthesize(analyses: analyses, generation: generation)
    }

    private func route(for generation: LectureNotesGenerationRecord) throws -> any LectureNotesGenerating {
        switch generation.provenance.backendIdentifier {
        case mlxBackendIdentifier:
            return mlxGenerator
        case appleBackendIdentifier:
            return appleGenerator
        case openAIBackendIdentifier:
            return openAIGenerator
        default:
            throw LectureNotesGeneratorRoutingError.unknownBackend(generation.provenance.backendIdentifier)
        }
    }
}
