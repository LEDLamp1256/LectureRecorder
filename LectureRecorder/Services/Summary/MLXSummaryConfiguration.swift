import Foundation

/// Static, backend-identifying configuration for the MLX Summary backend —
/// the new default for every brand-new Summary generation (see
/// `LectureSummaryGeneratorRouter`). Mirrors `MLXNotesConfiguration`'s role
/// for the MLX Notes backend, and `FoundationModelsSummaryConfiguration`'s
/// role for the Apple Summary backend.
nonisolated enum MLXSummaryConfiguration {
    static let recipeVersion = "mlx2-summary-v1"
    /// Same model identity fields as `MLXNotesConfiguration` — folded into
    /// the existing open-string `generatorIdentifier`/`generatorVersion`
    /// provenance fields, no storage-schema change. Both Notes and Summary
    /// currently share the one pinned MLX model.
    static let generatorIdentifier = MLXModelDescriptor.qwen3_8b_4bit.modelIdentifier
    static let generatorVersion = MLXModelDescriptor.qwen3_8b_4bit.modelRevision
    static let backendIdentifier = "mlx"

    static var generationProvenance: LectureNotesGenerationProvenance {
        LectureNotesGenerationProvenance(
            recipeVersion: recipeVersion,
            generatorIdentifier: generatorIdentifier,
            generatorVersion: generatorVersion,
            backendIdentifier: backendIdentifier
        )
    }
}
