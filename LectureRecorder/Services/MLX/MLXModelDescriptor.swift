import Foundation

/// Identity of one local MLX model asset this app can load — never
/// architecturally hardwired to a specific model family. Everything above
/// this type (the session driver, the Notes generator) treats a model only
/// through this descriptor plus `MLXModelCatalog`/`MLXModelVerifier`, never
/// by name.
nonisolated struct MLXModelDescriptor: Sendable, Equatable {
    /// Hugging Face repository identifier, e.g. "mlx-community/Qwen3-8B-4bit".
    /// Also the display-facing model name; quantization is already part of
    /// this identifier for `mlx-community`-style repos, so there is no
    /// separate `quantization` field to keep in sync with it.
    var modelIdentifier: String
    /// Pinned upstream repository revision (commit hash). Never "main" or
    /// any other floating ref — the whole point of pinning is that this
    /// exact string identifies exactly one set of files.
    var modelRevision: String
    /// The model's native maximum position-embedding context length, as
    /// documented by its own model card/config — never inferred from
    /// tokenizer metadata (which can advertise a YaRN-extended length the
    /// model was not loaded to actually support). See
    /// `MLXNotesConfiguration` for why this project deliberately does not
    /// enable YaRN/RoPE extension in MLX-1.
    var nativeContextLength: Int
    /// This project's own, more conservative operational ceiling on how
    /// much of `nativeContextLength` planning is allowed to use — strictly
    /// less than `nativeContextLength`, enforced by `validate()`.
    var operationalContextCeiling: Int

    enum ValidationError: LocalizedError, Sendable, Equatable {
        case emptyModelIdentifier
        case emptyModelRevision
        case nonPositiveContextLength(Int)
        case operationalCeilingNotBelowNative(ceiling: Int, native: Int)

        var errorDescription: String? {
            switch self {
            case .emptyModelIdentifier:
                return "MLX model descriptor has an empty modelIdentifier."
            case .emptyModelRevision:
                return "MLX model descriptor has an empty modelRevision."
            case .nonPositiveContextLength(let value):
                return "MLX model descriptor nativeContextLength must be positive; got \(value)."
            case .operationalCeilingNotBelowNative(let ceiling, let native):
                return "MLX model descriptor operationalContextCeiling (\(ceiling)) must be positive and strictly less than nativeContextLength (\(native))."
            }
        }
    }

    func validate() throws {
        guard !modelIdentifier.isEmpty else { throw ValidationError.emptyModelIdentifier }
        guard !modelRevision.isEmpty else { throw ValidationError.emptyModelRevision }
        guard nativeContextLength > 0 else {
            throw ValidationError.nonPositiveContextLength(nativeContextLength)
        }
        guard operationalContextCeiling > 0, operationalContextCeiling < nativeContextLength else {
            throw ValidationError.operationalCeilingNotBelowNative(
                ceiling: operationalContextCeiling, native: nativeContextLength
            )
        }
    }

    /// The initial MLX-1 model candidate. Model identity is deliberately
    /// factored into this one static value rather than hardwired anywhere
    /// else — see `MLXNotesConfiguration`.
    static let qwen3_8b_4bit = MLXModelDescriptor(
        modelIdentifier: "mlx-community/Qwen3-8B-4bit",
        modelRevision: "545dc4251c05440727734bcd94334791f6ab0192",
        // Qwen3-8B's own documented native context. This project does not
        // enable YaRN/RoPE extension in MLX-1, so this is the ceiling that
        // actually matters at inference time — never the larger value a
        // tokenizer config might separately advertise.
        nativeContextLength: 32_768,
        // Intentionally 75% of nativeContextLength for initial acceptance
        // (see the MLX-1 task contract) — leaves consistent headroom below
        // the model's real limit for every request this project assembles,
        // independent of any one stage's own response reserve.
        operationalContextCeiling: 24_576
    )
}
