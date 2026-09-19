import Foundation

/// Static, backend-identifying configuration for the MLX Notes backend —
/// the new default for every brand-new Notes generation (see
/// `LectureNotesGeneratorRouter`). Mirrors
/// `FoundationModelsNotesConfiguration`'s role for the Apple backend.
nonisolated enum MLXNotesConfiguration {
    static let recipeVersion = "mlx1-notes-v1"
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
        LectureNotesGenerationProvenance(
            recipeVersion: recipeVersion,
            generatorIdentifier: generatorIdentifier,
            generatorVersion: generatorVersion,
            backendIdentifier: backendIdentifier
        )
    }

    /// MLX's operational context ceiling (24,576 tokens — see
    /// `MLXModelDescriptor`) is far larger than Apple's on-device ~4,096, so
    /// this byte/unit pre-plan budget is deliberately generous: real
    /// per-window token fitting against the actual tokenizer
    /// (`MLXLectureNotesGenerator.fits`) is what actually governs window
    /// count for MLX, not this value alone. Only ever used to plan a
    /// *brand-new* generation; already-persisted generations keep their own
    /// frozen `NotesWindowPlan` regardless of this value.
    static var windowBudget: NotesWindowBudget {
        try! NotesWindowBudget(maxUTF8BytesPerWindow: 60_000)
    }
}
