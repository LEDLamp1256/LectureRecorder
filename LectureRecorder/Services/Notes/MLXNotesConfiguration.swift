import Foundation

/// Static, backend-identifying configuration for the MLX Notes backend —
/// the new default for every brand-new Notes generation (see
/// `LectureNotesGeneratorRouter`). Mirrors
/// `FoundationModelsNotesConfiguration`'s role for the Apple backend.
nonisolated enum MLXNotesConfiguration {
    /// v15 = v10's window analysis unchanged (the v8 prompt, schema, and
    /// 8-unit windows, sampled with exactly `windowAnalysisSampling`) plus
    /// synthesis that summarizes each section in its own request as one or
    /// two concise sentences (no numeric target), validated to at most
    /// `MLXLectureNotesGenerator.maximumSectionSummaryLength` (600)
    /// characters under a 768-character grammar ceiling, and titles each
    /// section validated to at most
    /// `MLXLectureNotesGenerator.maximumSectionTitleLength` (80) characters
    /// under a 112-character grammar ceiling, rejecting a title the ceiling
    /// cut. Any change to that sampling (including its seed) or to the
    /// synthesis pipeline needs a new recipe version.
    static let recipeVersion = "mlx1-notes-v15"
    static let maximumUnitsPerWindow = 8
    /// Qwen3 non-thinking sampling for window analysis only; synthesis
    /// calls stay greedy. Each call gets a fresh sampler from this fixed
    /// seed, so a resumed generation repeats an uninterrupted one.
    static let windowAnalysisSampling = MLXGuidedSampling(
        temperature: 0.7, topP: 0.8, topK: 20, minP: 0, seed: 20_260_928
    )
    /// The exact model identity a generation was produced with, folded into
    /// the existing open-string `generatorIdentifier`/`generatorVersion`
    /// provenance fields — no storage-schema change. `generatorIdentifier`
    /// is the model's Hugging Face repository id, which for
    /// `mlx-community`-style repos already names the quantization (there is
    /// no separate quantization field to keep in sync with it).
    /// `generatorVersion` is the pinned model revision.
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

    /// The byte ceiling remains generous for MLX's 24,576-token operational
    /// context, while the eight-unit cap keeps transcript-analysis windows
    /// bounded to roughly four minutes with the current ~30-second chunking.
    /// Exact tokenizer preflight (`MLXLectureNotesGenerator.fits`) still
    /// protects MLX context capacity. Only ever used to plan a *brand-new*
    /// generation; already-persisted generations keep their own frozen
    /// `NotesWindowPlan` regardless of this value.
    static var windowBudget: NotesWindowBudget {
        try! NotesWindowBudget(
            maxUTF8BytesPerWindow: 60_000,
            maxUnitsPerWindow: maximumUnitsPerWindow
        )
    }
}
