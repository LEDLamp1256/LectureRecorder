import Foundation

/// Compatibility identity and initial safety policy for the local Apple
/// Foundation Models Summary pipeline. The recipe string versions every
/// prompt/schema phase owned by this implementation; it deliberately does
/// not claim an Apple model-weight version the public framework cannot report.
nonisolated enum FoundationModelsSummaryConfiguration {
    static let pipelineVersion = 2
    static let batchPromptVersion = 1
    static let reductionPromptVersion = 1
    static let finalStructurePromptVersion = 1
    static let finalSectionPromptVersion = 2
    static let generatedContractVersion = 5
    /// Versions this backend's compatibility assumptions about the shared
    /// Foundation Models driver/runtime — distinct from `*PromptVersion`
    /// (prompt wording) and `generatedContractVersion` (generated DTO/
    /// schema shape). Bumped 1 → 2 because
    /// `RealFoundationModelsSessionDriver.estimatedTokenCount` (shared with
    /// Notes) now measures the real assembled `Transcript` via
    /// `tokenCount(for: transcriptEntries:)` instead of summing
    /// independently-tokenized instructions/prompt/schema — a more accurate
    /// estimate that can change batching/reduction-grouping/request-boundary
    /// decisions for identical source content, even though no Summary
    /// schema, prompt, retry, or fidelity logic changed.
    static let foundationModelsCompatibilityEpoch = 2

    static let generatorIdentifier = "system-language-model"
    static let backendIdentifier = "apple-foundation-models"
    static let recipeVersion = "t5f2-summary-p2-b1-r1-structure1-section2-schema5-fm2"

    static var generationProvenance: LectureNotesGenerationProvenance {
        LectureNotesGenerationProvenance(
            recipeVersion: recipeVersion,
            generatorIdentifier: generatorIdentifier,
            generatorVersion: nil,
            backendIdentifier: backendIdentifier
        )
    }
}
