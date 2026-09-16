import FoundationModels
import Foundation

/// The thinnest possible seam between `FoundationModelsLectureNotesGenerator`
/// and the real `FoundationModels` framework. Every real SDK call
/// (`SystemLanguageModel.default.availability`, constructing a fresh
/// `LanguageModelSession`, guided `respond(to:generating:)`) lives only in
/// `RealFoundationModelsSessionDriver` below — the generator itself never
/// imports or references `LanguageModelSession`/`SystemLanguageModel`
/// directly, so deterministic unit tests can substitute a fake conforming
/// to this protocol and never invoke the real on-device model.
nonisolated protocol FoundationModelsSessionDriving: Sendable {
    /// Whether the on-device model is ready to serve a brand-new request
    /// right now. Never itself starts a session or makes a network request.
    func availability() -> LectureNotesGenerationAvailability

    /// The model's total per-session token budget (Apple's on-device
    /// session context is ~4,096 tokens as of Xcode 26.6). Cheap/synchronous
    /// — never itself starts a session.
    var contextTokenBudget: Int { get }

    /// Best-effort real preflight token count for one instructions+prompt+
    /// schema request, via `SystemLanguageModel.tokenCount(for:)`. Returns
    /// `nil` whenever the real API cannot answer (unavailable model, or any
    /// other error) — callers must then fall back to deterministic
    /// serialized-byte budgeting rather than treat `nil` as "fits".
    func estimatedTokenCount<Content: Generable>(
        instructions: String,
        prompt: String,
        generating: Content.Type
    ) async -> Int?

    /// Runs one guided-generation request in a fresh `LanguageModelSession`
    /// (never an accumulated multi-turn conversation — every call here is
    /// independent, matching T5-E's "fresh session per call" requirement).
    func respond<Content: Generable>(
        instructions: String,
        prompt: String,
        generating: Content.Type
    ) async throws -> Content
}

/// Production driver. Every FoundationModels-specific detail (the real
/// `SystemLanguageModel`, session construction, guided generation, and how
/// an `Availability.UnavailableReason` becomes a user-facing description)
/// is confined to this one type.
nonisolated struct RealFoundationModelsSessionDriver: FoundationModelsSessionDriving {
    private let model: SystemLanguageModel

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    func availability() -> LectureNotesGenerationAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(description: Self.description(for: reason))
        }
    }

    var contextTokenBudget: Int { model.contextSize }

    /// `SystemLanguageModel.tokenCount(for:)` is `@available(macOS 26.4, *)`
    /// — this project's macOS 26.5 deployment target is newer, so it is
    /// unconditionally available here (no `if #available` needed). Sums the
    /// real token cost of instructions, prompt, and the guided-generation
    /// schema separately, since the SDK exposes no single "whole request"
    /// overload. Any failure (including "model unavailable") is reduced to
    /// `nil` — real token counting is a best-effort preflight, never a
    /// requirement for `respond` itself to work.
    func estimatedTokenCount<Content: Generable>(
        instructions: String,
        prompt: String,
        generating: Content.Type
    ) async -> Int? {
        do {
            async let instructionsTokens = model.tokenCount(for: Instructions(instructions))
            async let promptTokens = model.tokenCount(for: prompt)
            async let schemaTokens = model.tokenCount(for: Content.generationSchema)
            return try await instructionsTokens + promptTokens + schemaTokens
        } catch {
            return nil
        }
    }

    func respond<Content: Generable>(
        instructions: String,
        prompt: String,
        generating: Content.Type
    ) async throws -> Content {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: prompt, generating: Content.self)
        return response.content
    }

    private static func description(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence, so local Notes generation is unavailable."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings to generate Notes locally."
        case .modelNotReady:
            return "Apple's on-device model is still downloading or preparing. Try again shortly."
        @unknown default:
            return "Apple's on-device model is currently unavailable."
        }
    }
}
