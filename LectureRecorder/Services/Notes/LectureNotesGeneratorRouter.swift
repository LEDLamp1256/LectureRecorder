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
/// own generation's persisted `provenance.backendIdentifier` names — Apple
/// Foundation Models for new generations, the existing OpenAI generator for
/// legacy ones. Deliberately small and fixed to these two known routes
/// (T5-E scope explicitly excludes a general provider registry/picker); a
/// future `MLXLectureNotesGenerator` route can be added the same way
/// without touching this shape.
///
/// Never falls back from one backend to the other: a failure the routed
/// backend throws is reported as-is, and unrecognized provenance fails
/// closed via `LectureNotesGeneratorRoutingError.unknownBackend`.
nonisolated struct LectureNotesGeneratorRouter: LectureNotesGenerating, NewLectureNotesGenerationAvailabilityChecking {
    private let appleGenerator: any (LectureNotesGenerating & NewLectureNotesGenerationAvailabilityChecking)
    private let openAIGenerator: any LectureNotesGenerating
    private let appleBackendIdentifier: String
    private let openAIBackendIdentifier: String

    init(
        appleGenerator: any (LectureNotesGenerating & NewLectureNotesGenerationAvailabilityChecking),
        openAIGenerator: any LectureNotesGenerating,
        appleBackendIdentifier: String = FoundationModelsNotesConfiguration.backendIdentifier,
        openAIBackendIdentifier: String = OpenAINotesConfiguration.backendIdentifier
    ) {
        self.appleGenerator = appleGenerator
        self.openAIGenerator = openAIGenerator
        self.appleBackendIdentifier = appleBackendIdentifier
        self.openAIBackendIdentifier = openAIBackendIdentifier
    }

    /// Apple is the sole backend this router ever mints provenance for on a
    /// brand-new generation (see `FoundationModelsNotesConfiguration
    /// .generationProvenance`), so admission-time availability is always the
    /// Apple generator's own answer — never the OpenAI generator's.
    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability {
        appleGenerator.availabilityForNewGeneration()
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
        case appleBackendIdentifier:
            return appleGenerator
        case openAIBackendIdentifier:
            return openAIGenerator
        default:
            throw LectureNotesGeneratorRoutingError.unknownBackend(generation.provenance.backendIdentifier)
        }
    }
}
