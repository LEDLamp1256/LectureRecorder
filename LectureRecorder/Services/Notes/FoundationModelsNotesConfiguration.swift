import Foundation

/// Static, backend-identifying configuration for the Apple Foundation
/// Models Notes backend — the local/zero-cost default for every brand-new
/// generation. Unlike `OpenAINotesConfigurationSource`, this backend needs
/// no per-request credential or endpoint: `SystemLanguageModel.default` is
/// always the model, so there is nothing here to resolve lazily.
nonisolated enum FoundationModelsNotesConfiguration {
    /// Bumped v2 → v3 alongside the fix for a real on-device
    /// `exceededContextWindowSize` failure at the 4,091/4,096-token
    /// boundary: `RealFoundationModelsSessionDriver.estimatedTokenCount`
    /// now measures the actual assembled `Transcript` (via
    /// `tokenCount(for: transcriptEntries:)`) instead of summing
    /// independently-tokenized instructions/prompt/schema, and
    /// `FoundationModelsLectureNotesGenerator` now maps a framework-level
    /// `exceededContextWindowSize` backstop to `.contextBudgetExceeded`.
    /// The more accurate estimate can classify a batch that previously
    /// preflighted as "fits" as too large for the same input, which the
    /// existing deterministic splitting/reduction paths then subdivide
    /// further — a production batching/context-budget recipe change,
    /// following the same v1 → v2 precedent set when per-stage response
    /// reserves were first added.
    static let recipeVersion = "t5e-apple-local-notes-v3"
    static let generatorIdentifier = "system-language-model"
    static let backendIdentifier = "apple-foundation-models"

    /// `generatorVersion` is deliberately left `nil`: the installed
    /// Xcode 26.6 `FoundationModels` SDK exposes no stable, truthful
    /// model-build identifier to report here, and routing never depends on
    /// one (see `LectureNotesGeneratorRouter`, which keys purely off
    /// `backendIdentifier`).
    static var generationProvenance: LectureNotesGenerationProvenance {
        LectureNotesGenerationProvenance(
            recipeVersion: recipeVersion,
            generatorIdentifier: generatorIdentifier,
            generatorVersion: nil,
            backendIdentifier: backendIdentifier
        )
    }

    /// Conservative initial local-model window budget. Apple's on-device
    /// session context is roughly 4,096 tokens shared across instructions,
    /// generated schema, prompt, and output — far smaller than the
    /// OpenAI-oriented default (48,000 bytes / 24 units). Only ever used to
    /// plan a *brand-new* generation; already-persisted generations keep
    /// their own frozen `NotesWindowPlan` regardless of this value (see
    /// `LectureNotesGenerationService.run()`). Treated as an initial
    /// implementation parameter, not a permanent product constant.
    static var windowBudget: NotesWindowBudget {
        try! NotesWindowBudget(maxUTF8BytesPerWindow: 6_000, maxUnitsPerWindow: 8)
    }
}
