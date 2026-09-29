import Foundation

/// Static, backend-identifying configuration for the MLX Summary backend —
/// the new default for every brand-new Summary generation (see
/// `LectureSummaryGeneratorRouter`). Mirrors `MLXNotesConfiguration`'s role
/// for the MLX Notes backend, and `FoundationModelsSummaryConfiguration`'s
/// role for the Apple Summary backend.
nonisolated enum MLXSummaryConfiguration {
    /// v3 = v2 plus plain-text/Unicode mathematics (no backslash LaTeX) and
    /// rejection of generated text containing control characters.
    /// v4 = v3 plus batch analysis that may return one passage per source
    /// item (v3 capped every batch at 8 passages for up to 12 items, so the
    /// last items of a full batch could never be cited) and is asked to
    /// consider the whole batch, combining related items into one passage.
    /// v5 = v4's batch analysis plus the source Notes sections as the
    /// Summary's structure: batches never cross a Notes section, and each
    /// non-empty Notes section becomes one Summary section, headed by its
    /// Notes title and written only from its own batches' passages — no
    /// model-planned section boundaries or headings.
    /// v6 = v5 with generated passages held to one plain paragraph: no line
    /// break, tab, `$`, or backslash (a JSON-decoded `\nabla` arrives as a
    /// line feed plus `abla`), rejected rather than repaired.
    static let recipeVersion = "mlx2-summary-v6"
    /// Recipes whose batch plans are partitioned by Notes section (see
    /// `LectureSummaryPlanPartition`); every other plan stays contiguous.
    static let notesSectionPartitionedRecipeVersions: Set<String> = ["mlx2-summary-v5", "mlx2-summary-v6"]
    /// Same model identity fields as `MLXNotesConfiguration` — folded into
    /// the existing open-string `generatorIdentifier`/`generatorVersion`
    /// provenance fields, no storage-schema change. Both Notes and Summary
    /// currently share the one pinned MLX model.
    static let generatorIdentifier = MLXModelDescriptor.qwen3_8b_4bit.modelIdentifier
    static let generatorVersion = MLXModelDescriptor.qwen3_8b_4bit.modelRevision
    static let backendIdentifier = "mlx"

    static var generationProvenance: LectureNotesGenerationProvenance {
        generationProvenance(for: .qwen3_8b_4bit)
    }

    /// Provenance for a generation produced with `descriptor`. Production
    /// always uses the 8B default above; only the opt-in MLX-3 acceptance
    /// harness passes another pinned descriptor.
    static func generationProvenance(for descriptor: MLXModelDescriptor) -> LectureNotesGenerationProvenance {
        LectureNotesGenerationProvenance(
            recipeVersion: recipeVersion,
            generatorIdentifier: descriptor.modelIdentifier,
            generatorVersion: descriptor.modelRevision,
            backendIdentifier: backendIdentifier
        )
    }
}
