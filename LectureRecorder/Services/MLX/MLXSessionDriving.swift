import MLXRuntimeMLX
import MLXRuntimeGuidedGeneration
import MLXRuntimeLLM
import MLXRuntimeLMCommon
import Foundation

/// Best-effort MLX memory measurements for one generation call — never
/// required for correctness, only diagnostics. `nil` fields mean the
/// measurement was unavailable in this build/runtime, never a zero
/// reading.
nonisolated struct MLXMemorySnapshot: Sendable, Equatable {
    var activeMemoryBytes: Int?
    var peakMemoryBytes: Int?
}

/// The full result of one guided-generation call through an
/// `MLXSessionDriving` conformer. Timing/metrics fields are best-effort
/// diagnostics — never consulted by any generation-outcome or validation
/// decision.
nonisolated struct MLXGuidedGenerationOutcome: Sendable, Equatable {
    /// Raw JSON text produced by grammar-constrained generation. The
    /// caller (`MLXLectureNotesGenerator`) is responsible for decoding
    /// this into its own Codable DTOs and then validating them.
    var jsonText: String
    var promptTokenCount: Int
    var generatedTokenCount: Int
    var generationSeconds: Double?
    var memory: MLXMemorySnapshot?
}

/// The thinnest possible seam between provider-neutral Notes code and the
/// real MLX runtime — mirrors `FoundationModelsSessionDriving`'s role for
/// the Apple backend. Every real MLX/`MLXLMCommon`/`MLXGuidedGeneration`
/// call lives only in `RealMLXSessionDriver` below; provider-neutral code
/// (in particular `MLXLectureNotesGenerator`) never imports an MLX module
/// directly, so deterministic unit tests can substitute a fake conforming
/// to this protocol and never load the real ~4–5 GB model.
nonisolated protocol MLXSessionDriving: Sendable {
    /// The model's native maximum context length (never the operational
    /// ceiling — see `MLXModelDescriptor`).
    var nativeContextLength: Int { get }
    /// This project's own, more conservative usable-context ceiling.
    var operationalContextCeiling: Int { get }

    /// Whether the local model is verified and ready to serve a brand-new
    /// request right now. Synchronous and side-effect-free: never loads
    /// the model, never starts a generation.
    func availability() -> LectureNotesGenerationAvailability

    /// The exact number of tokens the real tokenizer produces for the
    /// actual chat-formatted request `instructions`/`prompt` would
    /// assemble into — never a character/byte estimate. Loads the model
    /// (once) if it is not already loaded.
    func preparedInputTokenCount(instructions: String, prompt: String) async throws -> Int

    /// Runs one grammar-constrained generation request, bounded to
    /// `maxOutputTokens`. `jsonSchema` is a JSON Schema string describing
    /// exactly the structured shape the caller expects back; the returned
    /// `jsonText` is the model's raw (unvalidated) JSON — the caller
    /// decodes and validates it.
    func respond(
        instructions: String,
        prompt: String,
        jsonSchema: String,
        maxOutputTokens: Int
    ) async throws -> MLXGuidedGenerationOutcome
}

nonisolated enum MLXSessionDriverError: LocalizedError, Sendable, Equatable {
    case tokenizerLacksChatTemplate

    var errorDescription: String? {
        switch self {
        case .tokenizerLacksChatTemplate:
            return "The local MLX model's tokenizer has no chat template."
        }
    }
}

/// Backend-agnostic classification of what a failure at the real MLX
/// guided-generation boundary actually means — shared by the MLX Notes
/// generator today, and available to any future MLX-backed generator
/// (e.g. Summary) without coupling this file to Notes-specific error
/// types. `MLXGuidedGenerationErrorClassifier.classify` is the pure,
/// independently-testable mapping from an arbitrary thrown `Error` to one
/// of these kinds; no model load is required to exercise it.
nonisolated enum MLXGuidedGenerationFailureKind: Sendable, Equatable {
    /// Generation stopped before the grammar reached a valid stop state
    /// (`GuidedGenerationError.incompleteOutput`/`.prematureEOS` — max
    /// tokens exhausted, or premature EOS). The raw output is incomplete,
    /// but retrying the identical request is reasonable.
    case incompleteOutput
    /// A schema/grammar/tokenizer-template configuration problem
    /// (`MLXGuidedGeneration.GrammarError`, or a tokenizer with no chat
    /// template) that retrying the identical request cannot fix.
    case configurationFailure
    /// Any other failure this classifier does not specifically recognize.
    case unclassified
}

nonisolated enum MLXGuidedGenerationErrorClassifier {
    static func classify(_ error: Error) -> MLXGuidedGenerationFailureKind {
        switch error {
        case GuidedGenerationError.incompleteOutput, GuidedGenerationError.prematureEOS:
            return .incompleteOutput
        case is GrammarError:
            return .configurationFailure
        case MLXSessionDriverError.tokenizerLacksChatTemplate:
            return .configurationFailure
        default:
            return .unclassified
        }
    }
}

/// The MLX runtime/session-driver boundary's own typed error, produced by
/// classifying whatever `RealMLXSessionDriver.respond` actually caught.
/// Deliberately generic (not Notes-specific) — `MLXLectureNotesGenerator`
/// maps this into its own `MLXLectureNotesBackendError`/retry policy;
/// `CancellationError` is never wrapped in this type and always
/// propagates unchanged.
nonisolated enum MLXGuidedGenerationRuntimeError: LocalizedError, Sendable, Equatable {
    case incompleteOutput(String)
    case configurationFailure(String)
    case unclassified(String)

    var errorDescription: String? {
        switch self {
        case .incompleteOutput(let detail):
            return "MLX guided generation produced incomplete output: \(detail)"
        case .configurationFailure(let detail):
            return "MLX guided generation failed due to a configuration problem: \(detail)"
        case .unclassified(let detail):
            return "MLX guided generation failed: \(detail)"
        }
    }

    init(classifying error: Error) {
        switch MLXGuidedGenerationErrorClassifier.classify(error) {
        case .incompleteOutput: self = .incompleteOutput(String(describing: error))
        case .configurationFailure: self = .configurationFailure(String(describing: error))
        case .unclassified: self = .unclassified(String(describing: error))
        }
    }
}

/// Production driver. Owns local model verification/loading, tokenizer
/// access, exact token counting, chat-template request preparation,
/// grammar-constrained generation, and best-effort timing/memory
/// diagnostics. An `actor` (not `@MainActor`) so every method already runs
/// off the main actor by construction — including grammar compilation,
/// which can block for hundreds of milliseconds on a cold compile (see
/// `MLXGuidedGeneration`'s own documentation) and must never run on
/// `@MainActor`. `ModelContainer` itself additionally serializes access to
/// the underlying model/tokenizer.
actor RealMLXSessionDriver: MLXSessionDriving {
    private let descriptor: MLXModelDescriptor
    private let applicationSupportRootResolver: @Sendable () throws -> URL

    nonisolated let nativeContextLength: Int
    nonisolated let operationalContextCeiling: Int

    private var loadedContainer: ModelContainer?
    /// Built once per loaded model (the grammar tokenizer depends only on
    /// the model's own vocabulary, never on a particular schema).
    private var grammarTokenizer: GrammarTokenizer?
    /// Compiled grammar constraints, keyed by JSON Schema string — grammar
    /// compilation is the potentially slow step
    /// (`MLXGuidedGeneration.GrammarConstraint.init`), so a schema this
    /// driver has already compiled once is never recompiled.
    private var grammarConstraints: [String: GrammarConstraint] = [:]

    init(
        descriptor: MLXModelDescriptor = .qwen3_8b_4bit,
        applicationSupportRootResolver: @escaping @Sendable () throws -> URL = {
            try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        }
    ) {
        self.descriptor = descriptor
        self.applicationSupportRootResolver = applicationSupportRootResolver
        self.nativeContextLength = descriptor.nativeContextLength
        self.operationalContextCeiling = descriptor.operationalContextCeiling
    }

    /// Touches only `descriptor`/`applicationSupportRootResolver` (both
    /// immutable) and does local filesystem verification only — never
    /// loads the model or touches actor-isolated mutable state, so this
    /// can safely be `nonisolated` and called synchronously, matching
    /// `FoundationModelsSessionDriving.availability()`'s contract.
    nonisolated func availability() -> LectureNotesGenerationAvailability {
        do {
            let root = try applicationSupportRootResolver()
            _ = try MLXModelVerifier.verify(descriptor: descriptor, applicationSupportRoot: root)
            return .available
        } catch {
            return .unavailable(description: "The local MLX model is not ready: \(error.localizedDescription)")
        }
    }

    func preparedInputTokenCount(instructions: String, prompt: String) async throws -> Int {
        let container = try await loadedModelContainer()
        return try await container.perform { context in
            try Self.chatTokenIDs(instructions: instructions, prompt: prompt, tokenizer: context.tokenizer).count
        }
    }

    func respond(
        instructions: String,
        prompt: String,
        jsonSchema: String,
        maxOutputTokens: Int
    ) async throws -> MLXGuidedGenerationOutcome {
        try Task.checkCancellation()
        let container = try await loadedModelContainer()
        do {
            let (constraint, vocabSize) = try await constraint(forJSONSchema: jsonSchema, container: container)

            return try await container.perform { context in
                try Task.checkCancellation()
                let tokenIDs = try Self.chatTokenIDs(
                    instructions: instructions, prompt: prompt, tokenizer: context.tokenizer
                )
                let promptTokenCount = tokenIDs.count
                let input = LMInput(text: LMInput.Text(tokens: MLXArray(tokenIDs.map { Int32($0) })))

                // Mirrors `MLXLMCommon.WiredMemoryUtils.tune`'s own measurement
                // convention: `Memory.peakMemory` is a process-global counter,
                // so it is reset immediately before the measured region and
                // read back as `max(peakMemory, startActive)` afterward.
                let startActiveMemory = Memory.activeMemory
                Memory.peakMemory = 0
                let clock = ContinuousClock()
                let start = clock.now

                var jsonText = ""
                let generatedTokenCount = try GuidedGenerationLoop.run(
                    input: input,
                    context: context,
                    constraint: constraint,
                    maxTokens: maxOutputTokens,
                    vocabSize: vocabSize
                ) { delta in
                    jsonText += delta
                    return true
                }

                let elapsed = clock.now - start
                let generationSeconds =
                    Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                let peakActiveMemory = max(Memory.peakMemory, startActiveMemory)

                return MLXGuidedGenerationOutcome(
                    jsonText: jsonText,
                    promptTokenCount: promptTokenCount,
                    generatedTokenCount: generatedTokenCount,
                    generationSeconds: generationSeconds,
                    memory: MLXMemorySnapshot(
                        activeMemoryBytes: Memory.activeMemory,
                        peakMemoryBytes: peakActiveMemory
                    )
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Classify every failure from grammar/constraint construction
            // or the guided-generation loop itself into this MLX layer's
            // own generic runtime-error model — never let it escape as an
            // arbitrary, unclassified framework error (Correction 3).
            throw MLXGuidedGenerationRuntimeError(classifying: error)
        }
    }

    // MARK: - Loading

    private func loadedModelContainer() async throws -> ModelContainer {
        if let loadedContainer { return loadedContainer }
        let root = try applicationSupportRootResolver()
        let modelDirectory = try MLXModelVerifier.verify(descriptor: descriptor, applicationSupportRoot: root)
        let container = try await loadModelContainer(
            from: modelDirectory, using: SwiftTransformersTokenizerLoader()
        )
        loadedContainer = container
        return container
    }

    private func constraint(
        forJSONSchema jsonSchema: String, container: ModelContainer
    ) async throws -> (GrammarConstraint, Int) {
        if let existing = grammarConstraints[jsonSchema], let grammarTokenizer {
            return (existing, grammarTokenizer.vocabSize)
        }

        let tokenizer =
            if let grammarTokenizer {
                grammarTokenizer
            } else {
                try await container.perform { context -> GrammarTokenizer in
                    let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
                    return try GrammarTokenizer(
                        vocab: vocab.vocab,
                        vocabType: vocab.vocabType,
                        eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0)
                    )
                }
            }
        self.grammarTokenizer = tokenizer

        let constraint = try GrammarConstraint(
            tokenizer: tokenizer, jsonSchema: jsonSchema, fastForward: false
        )
        grammarConstraints[jsonSchema] = constraint
        return (constraint, tokenizer.vocabSize)
    }

    // MARK: - Chat formatting

    /// Builds the exact token sequence a fresh chat request would dispatch:
    /// a system + user message pair, chat-templated by the real tokenizer.
    /// `enable_thinking: false` disables Qwen3's reasoning mode so no
    /// `<think>` content can ever reach — or contaminate — the
    /// grammar-constrained JSON output; this project deliberately never
    /// exposes hidden reasoning text for schema-constrained Notes
    /// extraction/synthesis.
    private static func chatTokenIDs(
        instructions: String, prompt: String, tokenizer: any Tokenizer
    ) throws -> [Int] {
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": instructions],
            ["role": "user", "content": prompt],
        ]
        do {
            return try tokenizer.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: ["enable_thinking": false]
            )
        } catch TokenizerError.missingChatTemplate {
            throw MLXSessionDriverError.tokenizerLacksChatTemplate
        }
    }
}
