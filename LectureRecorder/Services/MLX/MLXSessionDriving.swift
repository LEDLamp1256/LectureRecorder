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
    /// request right now. Never loads the model, never starts a
    /// generation. Asynchronous because verification may hash gigabytes of
    /// model files, which must never block the caller's actor.
    func availability() async -> LectureNotesGenerationAvailability

    /// The exact number of tokens the real tokenizer produces for the
    /// actual chat-formatted request `instructions`/`prompt` would
    /// assemble into — never a character/byte estimate. Loads the model
    /// (once) if it is not already loaded.
    func preparedInputTokenCount(instructions: String, prompt: String) async throws -> Int

    /// Runs one grammar-constrained generation request, bounded to
    /// `maxOutputTokens`. `jsonSchema` is a JSON Schema string describing
    /// exactly the structured shape the caller expects back; the returned
    /// `jsonText` is the model's raw (unvalidated) JSON — the caller
    /// decodes and validates it. `sampling` chooses token selection for
    /// this call only: `nil` is greedy; otherwise a fresh sampler seeded
    /// from it serves exactly this call. Required, so every forwarding
    /// conformer must pass it on.
    func respond(
        instructions: String,
        prompt: String,
        jsonSchema: String,
        maxOutputTokens: Int,
        sampling: MLXGuidedSampling?
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

/// Sampled token selection for one guided-generation call, applied after
/// grammar masking and the loop's biases. Callers that pass none stay
/// greedy.
nonisolated struct MLXGuidedSampling: Sendable, Equatable, Codable {
    var temperature: Float
    var topP: Float
    var topK: Int
    var minP: Float
    var seed: UInt64

    /// A fresh sampler per call, so every call starts from `seed`.
    func makeSampler() -> any LogitSampler {
        TopPSampler(temperature: temperature, topP: topP, topK: topK, minP: minP, seed: seed)
    }
}

/// Host-side form of the vocabulary-derived closing/whitespace logit
/// biases. Plain `Sendable` values, so it can be cached by
/// `RealMLXSessionDriver` and passed into `ModelContainer.perform`; the
/// corresponding `MLXArray`s are built only inside that closure.
nonisolated private struct TokenizerBiasHostValues: Sendable {
    let closing: [Float]
    let whitespace: [Float]
    let whitespaceTokenIDs: Set<Int>
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
///
/// Verification and loading are each single-flight: concurrent cold
/// callers (Notes and Summary share this driver) await one shared full
/// verification (`MLXModelVerificationCache`, also reused by
/// `availability()`) and one shared model load (`modelLoad`), so they
/// always share one `ModelContainer` and therefore its serializing mutex.
actor RealMLXSessionDriver: MLXSessionDriving {
    private let descriptor: MLXModelDescriptor
    private let applicationSupportRootResolver: @Sendable () throws -> URL
    private let verificationCache: MLXModelVerificationCache
    private let diagnostics: AcceptanceDiagnosticLogger

    nonisolated let nativeContextLength: Int
    nonisolated let operationalContextCeiling: Int

    /// Keyed by model identifier/revision; this driver only ever loads its
    /// own `descriptor`, and the loaded model stays resident for the
    /// process once loaded.
    private let modelLoad = MLXSingleFlight<String, ModelContainer>()
    /// Built once per loaded model (the grammar tokenizer depends only on
    /// the model's own vocabulary, never on a particular schema or
    /// generation) — safe to cache and reuse, unlike `GrammarConstraint`
    /// below.
    private var grammarTokenizer: GrammarTokenizer?
    /// Closing/whitespace logit biases derived only from the model's own
    /// vocabulary (never from a particular schema or generation) — safe to
    /// cache and reuse, mirroring the pinned upstream
    /// `MLXFoundationModels.ModelContextCache.makeTokenizerBias`'s own
    /// per-model caching of this exact data. Cached as host values only:
    /// `MLXArray` is not `Sendable`, so the arrays themselves are rebuilt
    /// inside each `container.perform` that consumes them and never leave it.
    private var tokenizerBias: TokenizerBiasHostValues?

    init(
        descriptor: MLXModelDescriptor = .qwen3_8b_4bit,
        applicationSupportRootResolver: @escaping @Sendable () throws -> URL = {
            try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        },
        /// Injectable only for tests; production uses the default, which
        /// performs real `MLXModelVerifier` verification of `descriptor`.
        verificationCache: MLXModelVerificationCache? = nil,
        diagnostics: AcceptanceDiagnosticLogger = .shared
    ) {
        self.descriptor = descriptor
        self.applicationSupportRootResolver = applicationSupportRootResolver
        self.verificationCache = verificationCache
            ?? MLXModelVerificationCache(descriptor: descriptor, diagnostics: diagnostics)
        self.diagnostics = diagnostics
        self.nativeContextLength = descriptor.nativeContextLength
        self.operationalContextCeiling = descriptor.operationalContextCeiling
    }

    /// Touches only immutable state and local filesystem verification —
    /// never loads the model. Full verification runs off the caller's
    /// actor (see `MLXModelVerificationCache`), so awaiting this from
    /// `@MainActor` never blocks it while gigabytes are hashed.
    nonisolated func availability() async -> LectureNotesGenerationAvailability {
        do {
            let root = try applicationSupportRootResolver()
            _ = try await verificationCache.verifiedModelDirectory(applicationSupportRoot: root)
            return .available
        } catch is CancellationError {
            return .unavailable(description: "The local MLX model check was cancelled.")
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
        maxOutputTokens: Int,
        sampling: MLXGuidedSampling?
    ) async throws -> MLXGuidedGenerationOutcome {
        try Task.checkCancellation()
        let container = try await loadedModelContainer()
        do {
            let grammarTok = try await cachedGrammarTokenizer(container: container)
            let bias = try await cachedTokenizerBias(container: container)

            return try await container.perform { context in
                try Task.checkCancellation()
                let tokenIDs = try Self.chatTokenIDs(
                    instructions: instructions, prompt: prompt, tokenizer: context.tokenizer
                )
                let promptTokenCount = tokenIDs.count
                let input = LMInput(text: LMInput.Text(tokens: MLXArray(tokenIDs.map { Int32($0) })))

                // A fresh matcher for every call (Correction: `GrammarConstraint`
                // owns mutable xgrammar matcher state that `computeMask()`/
                // `commitToken()` advance — a constraint that already
                // completed one generation must never be reused for another
                // generation or retry). Only the vocabulary-derived
                // `GrammarTokenizer` above is safe to cache. `fastForward:
                // true` matches `GuidedGenerationLoop.run`'s own documented
                // contract ("constraint ... must have fastForward: true"),
                // with `hostTokenizer` set to the exact same tokenizer
                // instance (`context.tokenizer`) whose vocabulary built
                // `grammarTok`.
                let constraint = try GrammarConstraint(
                    tokenizer: grammarTok, jsonSchema: jsonSchema, fastForward: true, hostTokenizer: context.tokenizer
                )
                let vocabSize = grammarTok.vocabSize

                // Completion controls, computed exactly as the pinned
                // upstream `MLXFoundationModels.MLXLanguageModel` production
                // integration does (never invented here): without these,
                // `GuidedGenerationLoop.run` has no mechanism nudging the
                // model toward closing its JSON before `maxTokens`, and a
                // real model can exhaust the entire token budget without
                // ever reaching a grammar-accepting stop state.
                let structuralReserve = CompletionReserve.estimate(
                    schemaJSON: jsonSchema, tokenizer: context.tokenizer
                )
                let completionReserve = max(structuralReserve * 3, maxOutputTokens / 4)
                let hardReserve = structuralReserve * 8

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
                    vocabSize: vocabSize,
                    completionReserve: completionReserve,
                    hardReserve: hardReserve,
                    closingBias: MLXArray(bias.closing),
                    whitespaceBias: MLXArray(bias.whitespace),
                    whitespaceTokenIDs: bias.whitespaceTokenIDs,
                    // Built inside this call: every request starts from its
                    // own seed and never depends on earlier requests.
                    sampler: sampling?.makeSampler()
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

    /// One shared load per driver: concurrent cold callers await the same
    /// flight rather than each loading a separate multi-gigabyte container
    /// (this actor is reentrant across the load's suspension points). A
    /// failed load is not cached, so a later call retries. Throws
    /// `CancellationError` if this caller was cancelled while waiting,
    /// without affecting other waiters.
    private func loadedModelContainer() async throws -> ModelContainer {
        let key = "\(descriptor.modelIdentifier)@\(descriptor.modelRevision)"
        return try await modelLoad.value(for: key) {
            [applicationSupportRootResolver, verificationCache, diagnostics, descriptor] in
            let root = try applicationSupportRootResolver()
            // Reuses a successful availability() verification of unchanged
            // files instead of hashing them again.
            let modelDirectory = try await verificationCache.verifiedModelDirectory(applicationSupportRoot: root)
            diagnostics.log(
                AcceptanceDiagnosticEvent.MLX.modelLoadStarted,
                metadata: ["modelIdentifier": .string(descriptor.modelIdentifier)]
            )
            let start = AcceptanceDiagnosticLogger.startInstant()
            do {
                let container = try await loadModelContainer(
                    from: modelDirectory, using: SwiftTransformersTokenizerLoader()
                )
                diagnostics.log(
                    AcceptanceDiagnosticEvent.MLX.modelLoadCompleted,
                    metadata: ["modelIdentifier": .string(descriptor.modelIdentifier)],
                    elapsedSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start)
                )
                return container
            } catch {
                diagnostics.log(
                    AcceptanceDiagnosticEvent.MLX.modelLoadFailed,
                    metadata: [
                        "modelIdentifier": .string(descriptor.modelIdentifier),
                        "errorType": .string(String(describing: type(of: error))),
                    ],
                    elapsedSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start)
                )
                throw error
            }
        }
    }

    /// The vocabulary-derived `GrammarTokenizer` is immutable per loaded
    /// model and safe to build once and reuse — unlike `GrammarConstraint`
    /// (see `respond`'s own comment), which owns per-generation mutable
    /// matcher state and is always constructed fresh.
    private func cachedGrammarTokenizer(container: ModelContainer) async throws -> GrammarTokenizer {
        if let grammarTokenizer { return grammarTokenizer }
        let built = try await container.perform { context -> GrammarTokenizer in
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
            return try GrammarTokenizer(
                vocab: vocab.vocab,
                vocabType: vocab.vocabType,
                eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0)
            )
        }
        self.grammarTokenizer = built
        return built
    }

    /// The closing/whitespace logit biases are derived only from the
    /// model's own vocabulary — immutable per loaded model, and safe to
    /// build once and reuse, exactly like `cachedGrammarTokenizer` above.
    private func cachedTokenizerBias(
        container: ModelContainer
    ) async throws -> TokenizerBiasHostValues {
        if let tokenizerBias { return tokenizerBias }
        let built = await container.perform { context -> TokenizerBiasHostValues in
            let closing = ClosingTokenBias.compute(
                tokenizer: context.tokenizer, eosTokenId: context.tokenizer.eosTokenId
            )
            let (whitespace, whitespaceTokenIDs) = WhitespaceTokenBias.compute(tokenizer: context.tokenizer)
            return TokenizerBiasHostValues(
                closing: closing.asArray(Float.self),
                whitespace: whitespace.asArray(Float.self),
                whitespaceTokenIDs: whitespaceTokenIDs
            )
        }
        self.tokenizerBias = built
        return built
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
