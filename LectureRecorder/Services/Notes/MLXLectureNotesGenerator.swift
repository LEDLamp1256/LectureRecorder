import Foundation

nonisolated enum MLXLectureNotesBackendError: LocalizedError, Sendable, Equatable {
    case invalidSourceReference
    case malformedResponse(String)
    /// `generation.provenance.backendIdentifier` names this backend, but
    /// `generatorIdentifier`/`recipeVersion` do not exactly match what this
    /// implementation actually knows how to run — never silently run
    /// against provenance this exact code wasn't built for, and never
    /// rerouted to another backend.
    case incompatibleProvenance
    /// A request could not be made to fit the operational MLX context
    /// budget even after this backend's own preflight (including after
    /// exhausting bounded recursive splitting/reduction). Never silently
    /// submitted anyway.
    case contextBudgetExceeded(String)
    /// Exact prepared-input-token counting itself failed (the driver threw
    /// rather than answering) — never treated as "fits"; a byte/character
    /// estimate is never an acceptable substitute authorization to
    /// dispatch a model request.
    case contextPreflightUnavailable(String)
    /// A schema/grammar/tokenizer-template configuration problem that
    /// retrying the identical request cannot fix.
    case configurationFailure(String)
    /// An MLX runtime failure this backend did not specifically recognize.
    /// Never assumed retryable.
    case runtimeFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceReference:
            return "The local MLX model claimed a source reference outside what it was given."
        case .malformedResponse(let reason):
            return "The local MLX model produced an unusable response: \(reason)."
        case .incompatibleProvenance:
            return "This generation's provenance is not compatible with this MLX Notes backend implementation."
        case .contextBudgetExceeded(let stage):
            return "The local MLX model's context budget could not be satisfied for \(stage)."
        case .contextPreflightUnavailable(let stage):
            return "Exact input-token preflight was unavailable for \(stage); refusing to dispatch without it."
        case .configurationFailure(let detail):
            return "MLX Notes generation failed due to a configuration problem: \(detail)"
        case .runtimeFailure(let detail):
            return "MLX Notes generation failed: \(detail)"
        }
    }
}

nonisolated enum MLXNotesCallStage: Sendable, Equatable {
    case windowAnalysis
    case reduction
    case sectionPlan
    case overview

    var description: String {
        switch self {
        case .windowAnalysis: return "window analysis"
        case .reduction: return "overview reduction"
        case .sectionPlan: return "detailed section planning"
        case .overview: return "overview generation"
        }
    }
}

/// Per-stage response-token budget: how many tokens of
/// `MLXSessionDriving.operationalContextCeiling` to reserve for the model's
/// generated response before comparing a real preflight input-token count,
/// and — since `MLXGuidedGeneration` takes an explicit `maxTokens` — also
/// the actual generation cap passed to that call.
nonisolated struct MLXNotesResponseReserves: Sendable, Equatable {
    var windowAnalysis: Int
    var reduction: Int
    var sectionPlan: Int
    var overview: Int

    static let conservativeDefault = MLXNotesResponseReserves(
        windowAnalysis: 4_096,
        reduction: 3_072,
        sectionPlan: 1_024,
        overview: 1_024
    )

    func reserve(for stage: MLXNotesCallStage) -> Int {
        switch stage {
        case .windowAnalysis: return windowAnalysis
        case .reduction: return reduction
        case .sectionPlan: return sectionPlan
        case .overview: return overview
        }
    }
}

/// Test/debug-only observability for one context-budget preflight decision
/// — purely additive, mirroring `FoundationModelsNotesDiagnosticEvent`.
nonisolated struct MLXNotesDiagnosticEvent: Sendable, Equatable {
    var stage: MLXNotesCallStage
    var estimatedInputTokens: Int?
    var responseReserve: Int
    var contextLimit: Int
    var fitDirectly: Bool
}

nonisolated enum MLXNoteVocabulary {
    static let itemKinds = [
        "keyConcept", "definition", "explanation", "example",
        "formula", "algorithmOrCode", "warning", "uncertainty", "other",
    ]
    static let fidelities = ["transcriptSupported", "reconstructed", "uncertain"]
}

// MARK: - Model-facing DTOs

/// A window-relative-only source reference: two raw transcript
/// `sequenceNumber`s the model was shown. Never a persistent identity —
/// `mapItem` resolves this into a real `NotesSourceReference` (which also
/// carries `sessionID`) only after checking both numbers fall inside the
/// exact set of sequence numbers this call was given.
nonisolated struct MLXSourceReferenceDTO: Codable, Sendable {
    var firstSequenceNumber: Int
    var lastSequenceNumber: Int
}

nonisolated struct MLXNoteItemDTO: Codable, Sendable {
    var kind: String
    var body: String
    var fidelity: String
    var sourceReferences: [MLXSourceReferenceDTO]
    /// Required (not optional) so the schema cannot simply omit it for
    /// reconstructed/uncertain content — `mapItem` still independently
    /// enforces non-emptiness for those fidelities.
    var uncertaintyNote: String
}

/// Used for both window analysis and reduction — reduction reuses the same
/// item shape, just over already-committed (rather than raw transcript)
/// source material.
nonisolated struct MLXNoteItemsDTO: Codable, Sendable {
    var items: [MLXNoteItemDTO]
}

/// One planned section: a heading and the batch-local, inclusive index
/// range of items (as numbered by `encodeIndexedItemsPrompt`) it covers.
/// Carries no item content at all — `assembleSections` slices the
/// already-committed `LectureNoteItem` values directly, never
/// reconstructing them from this DTO.
nonisolated struct MLXSectionRangeDTO: Codable, Sendable {
    var heading: String
    var firstItemIndex: Int
    var lastItemIndex: Int
}

/// Organization only — headings + index ranges. Never asked to restate or
/// summarize item content, so it has no room to lose or rewrite it.
nonisolated struct MLXSectionPlanDTO: Codable, Sendable {
    var sections: [MLXSectionRangeDTO]
}

/// The short document overview — generated as its own separate, final
/// call, after `generateOverview`'s hierarchical reduction (if any) has
/// already reduced the input to something that fits.
nonisolated struct MLXOverviewDTO: Codable, Sendable {
    var overview: String
}

/// MLX adapter for the provider-neutral Notes generation protocol — the
/// new default backend for every brand-new generation (see
/// `LectureNotesGeneratorRouter`). Performs no planning, persistence,
/// recovery, transcript loading, generation identity creation, or
/// cancellation bookkeeping; those remain owned by
/// `LectureNotesGenerationService`.
///
/// Every real MLX call is confined to `sessionDriver` (see
/// `MLXSessionDriving`) — this type only ever builds compact prompts and a
/// JSON Schema, decodes/validates the driver's raw JSON text against the
/// transcript sources it was actually given, and maps validated results
/// onto the existing provider-neutral domain model. The model never
/// produces a persistent Note ID, transcript ID, or session ID: those are
/// always minted or supplied by Swift (`LectureNoteItem.id`'s own default
/// `UUID()`, and `sessionID` passed into `mapItem`/`NotesSourceReference`).
///
/// Synthesis reuses the exact algorithmic shape of
/// `FoundationModelsLectureNotesGenerator`'s Apple backend — recursive,
/// depth-bounded bisection for detailed-section planning
/// (`makeContextSafeSectionPlanRequests`), and a bounded hierarchical
/// reduce-until-it-fits loop for the overview
/// (`generateOverview`/`makeContextSafeReductionBatches`/`reduceChunks`) —
/// adapted to MLX's own DTOs/guided generation rather than Apple's
/// `@Generable` schema machinery. MLX's much larger operational context
/// (24,576 tokens) means these mechanisms are expected to run far fewer
/// levels than Apple's ~4,096-token budget typically needs — never zero
/// levels unconditionally: every actual dispatch is still individually
/// preflighted, and there is no longer any path where the entire
/// accumulated item set is the only possible synthesis request.
nonisolated struct MLXLectureNotesGenerator: LectureNotesGenerating, NewLectureNotesGenerationAvailabilityChecking {
    private static let maximumGeneratedOutputAttempts = 2

    static let analysisInstructions = """
    You write grounded technical college-lecture notes from ONLY the numbered transcript lines given, formatted "[sequenceNumber] text". Preserve concepts, definitions, explanations, formulas, code, examples, warnings, and instructor emphasis; do not reduce to a generic summary. Every item's sourceReferences must use only sequenceNumber values that appear in the given lines — never invent, guess, or reuse numbers from outside them. Use fidelity "transcriptSupported" only when directly supported, "reconstructed" for normalized notation/code/equations, or "uncertain" for genuinely ambiguous reconstructions. Every item must populate uncertaintyNote: an empty string for transcriptSupported; for reconstructed, briefly state what was reconstructed or normalized; for uncertain, briefly state the ambiguity. Respond with JSON matching the given schema only.
    """

    /// Used only to condense material for the short document overview —
    /// never for the detailed Notes sections themselves.
    static let reductionInstructions = """
    Condense the given note items, formatted "[sequenceRange] (kind/fidelity) text", into fewer, denser items covering the same material — preserve technical depth, formulas, code, warnings, and fidelity/uncertainty distinctions; remove repetition. Every item's sourceReferences must reuse only sequenceNumber values that already appear in the given items' own ranges — never widen, invent, or combine into a range not actually covered. Respond with JSON matching the given schema only.
    """

    /// The model chooses grouping and headings only — it never rewrites,
    /// drops, or restates item content, and its response schema has no
    /// room to.
    static let detailedSectionInstructions = """
    Group the given note items, formatted "[itemIndex] (kind/fidelity) text" and already in lecture order, into one or more contiguous study-note sections with short headings. Every item (index 0 through the highest index given) must belong to exactly one section, in order, with no gaps or overlaps — you are choosing section boundaries and titles only, not rewriting or omitting any item. Respond with JSON matching the given schema only.
    """

    static let overviewInstructions = """
    Write a short overview (a handful of useful takeaways, not padding) summarizing the given note items, formatted "[sequenceRange] (kind/fidelity) text" and already in lecture order. This is a brief overview only — full technical detail belongs in the Notes sections, not here. Respond with JSON matching the given schema only.
    """

    private let sessionDriver: any MLXSessionDriving
    private let responseReserves: MLXNotesResponseReserves
    /// Hard structural bound on hierarchical-reduction/bisection depth —
    /// together with the natural base case of a single, no-longer-
    /// divisible item, this is the actual termination guarantee for
    /// `makeContextSafeSectionPlanRequests`/`makeContextSafeReductionBatches`.
    /// Mirrors `FoundationModelsLectureNotesGenerator.maxReductionLevels`.
    private let maxReductionLevels: Int
    private let diagnosticRecorder: (@Sendable (MLXNotesDiagnosticEvent) -> Void)?

    init(
        sessionDriver: any MLXSessionDriving = RealMLXSessionDriver(),
        responseReserves: MLXNotesResponseReserves = .conservativeDefault,
        maxReductionLevels: Int = 8,
        diagnosticRecorder: (@Sendable (MLXNotesDiagnosticEvent) -> Void)? = nil
    ) {
        self.sessionDriver = sessionDriver
        self.responseReserves = responseReserves
        self.maxReductionLevels = max(1, maxReductionLevels)
        self.diagnosticRecorder = diagnosticRecorder
    }

    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability {
        sessionDriver.availability()
    }

    // MARK: - Window analysis

    func analyzeWindow(
        units: [NotesTranscriptSourceUnit],
        window: NotesInputWindow,
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesWindowAnalysis {
        try Task.checkCancellation()
        try Self.validateProvenanceCompatibility(generation)
        let prompt = Self.encodeUnitsPrompt(units)
        try await requirePreparedInputFits(instructions: Self.analysisInstructions, prompt: prompt, stage: .windowAnalysis)

        let allowedSequences = Set(units.map(\.sequenceNumber))
        let items: [LectureNoteItem] = try await withGeneratedOutputRetry {
            let outcome = try await dispatch(
                instructions: Self.analysisInstructions,
                prompt: prompt,
                jsonSchema: Self.noteItemsJSONSchema,
                maxOutputTokens: responseReserves.reserve(for: .windowAnalysis)
            )
            let dto = try Self.decode(MLXNoteItemsDTO.self, from: outcome.jsonText)
            let mapped = try dto.items.map {
                try Self.mapItem($0, sessionID: generation.sessionID, allowedSequences: allowedSequences)
            }
            guard !mapped.isEmpty else {
                throw MLXLectureNotesBackendError.malformedResponse("window analysis contained no note items")
            }
            return mapped
        }
        return LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: window.windowIndex,
            ownedRange: NotesSourceReference(
                sessionID: generation.sessionID,
                firstSequenceNumber: window.firstSequenceNumber,
                lastSequenceNumber: window.lastSequenceNumber
            ),
            items: items
        )
    }

    // MARK: - Synthesis

    /// Builds the final document via two independent pipelines, exactly
    /// mirroring the Apple backend's own split:
    ///
    /// 1. Detailed sections: items are packed into context-safe,
    ///    contiguous batches (splitting/bisecting recursively, bounded by
    ///    `maxReductionLevels`, whenever a candidate batch does not fit)
    ///    and each batch's *organization only* is planned — the original
    ///    `LectureNoteItem` values are then sliced directly into
    ///    `LectureNoteSection`s in Swift, never reconstructed from a model
    ///    response.
    /// 2. Overview: the same flattened items are hierarchically reduced
    ///    (condensed, via fresh calls) only as far as needed to fit one
    ///    short final overview call.
    ///
    /// Every request in both pipelines is individually preflighted via
    /// `requirePreparedInputFits`; a request that cannot be made to fit —
    /// because it is already a single, no-longer-divisible item, or
    /// because `maxReductionLevels` was reached — fails with
    /// `.contextBudgetExceeded` rather than ever being submitted anyway.
    /// There is no path where the full accumulated item set is the only
    /// possible synthesis request.
    func synthesize(
        analyses: [LectureNotesWindowAnalysis],
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesDocument {
        try Task.checkCancellation()
        try Self.validateProvenanceCompatibility(generation)
        let allItems: [LectureNoteItem] = analyses
            .sorted { $0.windowIndex < $1.windowIndex }
            .flatMap(\.items)
        guard !allItems.isEmpty else {
            throw MLXLectureNotesBackendError.malformedResponse("synthesis input contained no note items")
        }

        let sections = try await generateDetailedSections(from: allItems)
        guard !sections.isEmpty else {
            throw MLXLectureNotesBackendError.malformedResponse("document produced no sections")
        }

        let overview = try await generateOverview(from: allItems)

        return LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: overview,
            sections: sections
        )
    }

    // MARK: - Detailed sections (context-safe bisection)

    private struct SectionPlanRequest {
        var batch: [LectureNoteItem]
        var prompt: String
    }

    private func generateDetailedSections(from allItems: [LectureNoteItem]) async throws -> [LectureNoteSection] {
        let requests = try await makeContextSafeSectionPlanRequests(allItems, depth: 0)
        var sections: [LectureNoteSection] = []
        for request in requests {
            try Task.checkCancellation()
            let planned: [LectureNoteSection] = try await withGeneratedOutputRetry {
                let outcome = try await dispatch(
                    instructions: Self.detailedSectionInstructions,
                    prompt: request.prompt,
                    jsonSchema: Self.sectionPlanJSONSchema,
                    maxOutputTokens: responseReserves.reserve(for: .sectionPlan)
                )
                let dto = try Self.decode(MLXSectionPlanDTO.self, from: outcome.jsonText)
                return try Self.assembleSections(dto.sections, items: request.batch)
            }
            sections.append(contentsOf: planned)
        }
        return sections
    }

    /// Produces the exact request values used for detailed-section
    /// dispatch. A candidate that does not individually fit is bisected
    /// and each half is recursively re-checked — never submitted anyway,
    /// and never given up on before either an irreducible single item or
    /// `maxReductionLevels` is reached.
    private func makeContextSafeSectionPlanRequests(
        _ items: [LectureNoteItem], depth: Int
    ) async throws -> [SectionPlanRequest] {
        try Task.checkCancellation()
        let prompt = Self.encodeIndexedItemsPrompt(items)
        do {
            try await requirePreparedInputFits(instructions: Self.detailedSectionInstructions, prompt: prompt, stage: .sectionPlan)
            return [SectionPlanRequest(batch: items, prompt: prompt)]
        } catch let error as MLXLectureNotesBackendError {
            guard case .contextBudgetExceeded = error else { throw error }
            guard items.count > 1, depth < maxReductionLevels else { throw error }
        }
        var result: [SectionPlanRequest] = []
        for piece in Self.bisect(items) {
            try Task.checkCancellation()
            result.append(contentsOf: try await makeContextSafeSectionPlanRequests(piece, depth: depth + 1))
        }
        return result
    }

    // MARK: - Overview (hierarchically reduced; intentionally lossy)

    private func generateOverview(from allItems: [LectureNoteItem]) async throws -> String {
        var currentItems = allItems
        var level = 0
        while true {
            let prompt = Self.encodeItemsPrompt(currentItems)
            do {
                try await requirePreparedInputFits(instructions: Self.overviewInstructions, prompt: prompt, stage: .overview)
                break
            } catch let error as MLXLectureNotesBackendError {
                guard case .contextBudgetExceeded = error else { throw error }
                guard level < maxReductionLevels else { throw error }
            }
            try Task.checkCancellation()
            let batches = try await makeContextSafeReductionBatches(currentItems, depth: 0)
            currentItems = try await reduceChunks(batches)
            level += 1
        }

        try Task.checkCancellation()
        let prompt = Self.encodeItemsPrompt(currentItems)
        return try await withGeneratedOutputRetry {
            let outcome = try await dispatch(
                instructions: Self.overviewInstructions,
                prompt: prompt,
                jsonSchema: Self.overviewJSONSchema,
                maxOutputTokens: responseReserves.reserve(for: .overview)
            )
            let dto = try Self.decode(MLXOverviewDTO.self, from: outcome.jsonText)
            let overview = dto.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !overview.isEmpty else {
                throw MLXLectureNotesBackendError.malformedResponse("overview was empty")
            }
            return overview
        }
    }

    /// Splits `items` into context-safe reduction batches — same
    /// fit-or-bisect-and-recurse shape as
    /// `makeContextSafeSectionPlanRequests`, sized against the
    /// `.reduction` stage's own reserve rather than `.sectionPlan`'s.
    private func makeContextSafeReductionBatches(
        _ items: [LectureNoteItem], depth: Int
    ) async throws -> [[LectureNoteItem]] {
        try Task.checkCancellation()
        let prompt = Self.encodeItemsPrompt(items)
        do {
            try await requirePreparedInputFits(instructions: Self.reductionInstructions, prompt: prompt, stage: .reduction)
            return [items]
        } catch let error as MLXLectureNotesBackendError {
            guard case .contextBudgetExceeded = error else { throw error }
            guard items.count > 1, depth < maxReductionLevels else { throw error }
        }
        var result: [[LectureNoteItem]] = []
        for piece in Self.bisect(items) {
            try Task.checkCancellation()
            result.append(contentsOf: try await makeContextSafeReductionBatches(piece, depth: depth + 1))
        }
        return result
    }

    private func reduceChunks(_ chunks: [[LectureNoteItem]]) async throws -> [LectureNoteItem] {
        var result: [LectureNoteItem] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let allowedSequences = Self.allowedSequences(in: chunk)
            let prompt = Self.encodeItemsPrompt(chunk)
            let reduced: [LectureNoteItem] = try await withGeneratedOutputRetry {
                let outcome = try await dispatch(
                    instructions: Self.reductionInstructions,
                    prompt: prompt,
                    jsonSchema: Self.noteItemsJSONSchema,
                    maxOutputTokens: responseReserves.reserve(for: .reduction)
                )
                let dto = try Self.decode(MLXNoteItemsDTO.self, from: outcome.jsonText)
                let mapped = try dto.items.map { item in
                    try Self.mapItem(item, sessionID: chunk[0].sourceReferences[0].sessionID, allowedSequences: allowedSequences)
                }
                guard !mapped.isEmpty else {
                    throw MLXLectureNotesBackendError.malformedResponse("reduction contained no note items")
                }
                return mapped
            }
            result.append(contentsOf: reduced)
        }
        return result
    }

    private static func allowedSequences(in items: [LectureNoteItem]) -> Set<Int> {
        var sequences = Set<Int>()
        for item in items {
            for reference in item.sourceReferences where reference.firstSequenceNumber <= reference.lastSequenceNumber {
                sequences.formUnion(reference.firstSequenceNumber...reference.lastSequenceNumber)
            }
        }
        return sequences
    }

    /// Splits `items` into two roughly-equal, order-preserving halves.
    /// Callers only ever bisect when `items.count > 1`, so both halves are
    /// always non-empty.
    private static func bisect(_ items: [LectureNoteItem]) -> [[LectureNoteItem]] {
        let midpoint = items.count / 2
        return [Array(items[..<midpoint]), Array(items[midpoint...])]
    }

    // MARK: - Provenance

    private static func validateProvenanceCompatibility(_ generation: LectureNotesGenerationRecord) throws {
        guard
            generation.provenance.backendIdentifier == MLXNotesConfiguration.backendIdentifier,
            generation.provenance.generatorIdentifier == MLXNotesConfiguration.generatorIdentifier,
            generation.provenance.recipeVersion == MLXNotesConfiguration.recipeVersion
        else {
            throw MLXLectureNotesBackendError.incompatibleProvenance
        }
    }

    // MARK: - Retry

    private func withGeneratedOutputRetry<Output>(
        _ operation: () async throws -> Output
    ) async throws -> Output {
        for attempt in 1...Self.maximumGeneratedOutputAttempts {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MLXLectureNotesBackendError {
                let isRetryable: Bool
                switch error {
                case .malformedResponse, .invalidSourceReference:
                    isRetryable = true
                case .incompatibleProvenance, .contextBudgetExceeded, .contextPreflightUnavailable,
                     .configurationFailure, .runtimeFailure:
                    isRetryable = false
                }
                guard attempt < Self.maximumGeneratedOutputAttempts, isRetryable else {
                    throw error
                }
                try Task.checkCancellation()
            }
        }
        preconditionFailure("generated-output retry loop exhausted without returning or throwing")
    }

    // MARK: - Dispatch (MLX runtime error classification)

    /// Runs one guided-generation call, converting the MLX runtime layer's
    /// own generic `MLXGuidedGenerationRuntimeError` classification into
    /// this backend's typed error model — never letting an unclassified
    /// framework error escape, and never turning every runtime failure
    /// into a retry.
    private func dispatch(
        instructions: String, prompt: String, jsonSchema: String, maxOutputTokens: Int
    ) async throws -> MLXGuidedGenerationOutcome {
        do {
            return try await sessionDriver.respond(
                instructions: instructions, prompt: prompt, jsonSchema: jsonSchema, maxOutputTokens: maxOutputTokens
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MLXGuidedGenerationRuntimeError {
            switch error {
            case .incompleteOutput(let detail):
                throw MLXLectureNotesBackendError.malformedResponse("generation was truncated before completing valid structured output: \(detail)")
            case .configurationFailure(let detail):
                throw MLXLectureNotesBackendError.configurationFailure(detail)
            case .unclassified(let detail):
                throw MLXLectureNotesBackendError.runtimeFailure(detail)
            }
        }
    }

    // MARK: - Context-budget preflight

    /// Exact prepared-input-token preflight for one candidate request.
    /// Throws `.contextBudgetExceeded` when the real count does not fit,
    /// or `.contextPreflightUnavailable` when exact token counting itself
    /// fails — a byte/character estimate is never an acceptable
    /// authorization to dispatch (Correction 2): token-count failure
    /// always fails closed, never falls back to counting bytes.
    private func requirePreparedInputFits(
        instructions: String, prompt: String, stage: MLXNotesCallStage
    ) async throws {
        let reserve = responseReserves.reserve(for: stage)
        let ceiling = sessionDriver.operationalContextCeiling
        let limit = ceiling - reserve
        guard limit > 0 else {
            diagnosticRecorder?(MLXNotesDiagnosticEvent(
                stage: stage, estimatedInputTokens: nil, responseReserve: reserve, contextLimit: ceiling, fitDirectly: false
            ))
            throw MLXLectureNotesBackendError.contextBudgetExceeded("\(stage.description) (response reserve exceeds operational ceiling)")
        }

        let count: Int
        do {
            count = try await sessionDriver.preparedInputTokenCount(instructions: instructions, prompt: prompt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnosticRecorder?(MLXNotesDiagnosticEvent(
                stage: stage, estimatedInputTokens: nil, responseReserve: reserve, contextLimit: ceiling, fitDirectly: false
            ))
            throw MLXLectureNotesBackendError.contextPreflightUnavailable(stage.description)
        }

        let fitDirectly = count <= limit
        diagnosticRecorder?(MLXNotesDiagnosticEvent(
            stage: stage, estimatedInputTokens: count, responseReserve: reserve, contextLimit: ceiling, fitDirectly: fitDirectly
        ))
        guard fitDirectly else {
            throw MLXLectureNotesBackendError.contextBudgetExceeded(stage.description)
        }
    }

    // MARK: - Prompt encoding

    private static func encodeUnitsPrompt(_ units: [NotesTranscriptSourceUnit]) -> String {
        units.map { "[\($0.sequenceNumber)] \($0.text)" }.joined(separator: "\n")
    }

    /// Labels each line with its 0-based position within `items` — used
    /// exclusively for detailed section planning, whose response
    /// references items by that same batch-local index, never by source
    /// sequence number.
    private static func encodeIndexedItemsPrompt(_ items: [LectureNoteItem]) -> String {
        items.enumerated().map { index, item in
            let uncertainty = item.uncertaintyNote.map { " {uncertainty: \($0)}" } ?? ""
            return "[\(index)] (\(item.kind.rawValue)/\(item.fidelity.rawValue)) \(item.body)\(uncertainty)"
        }.joined(separator: "\n")
    }

    /// Labels each line with its source sequence range — used for
    /// reduction and overview, whose responses reference source
    /// `sequenceRange`s, never a batch-local index.
    private static func encodeItemsPrompt(_ items: [LectureNoteItem]) -> String {
        items.map { item in
            let ranges = item.sourceReferences
                .map { "\($0.firstSequenceNumber)-\($0.lastSequenceNumber)" }
                .joined(separator: ",")
            let uncertainty = item.uncertaintyNote.map { " {uncertainty: \($0)}" } ?? ""
            return "[\(ranges)] (\(item.kind.rawValue)/\(item.fidelity.rawValue)) \(item.body)\(uncertainty)"
        }.joined(separator: "\n")
    }

    // MARK: - Response decoding/mapping

    private static func decode<T: Decodable>(_ type: T.Type, from jsonText: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(jsonText.utf8))
        } catch {
            throw MLXLectureNotesBackendError.malformedResponse("could not decode JSON: \(error.localizedDescription)")
        }
    }

    private static func mapItem(
        _ dto: MLXNoteItemDTO,
        sessionID: UUID,
        allowedSequences: Set<Int>
    ) throws -> LectureNoteItem {
        let body = dto.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw MLXLectureNotesBackendError.malformedResponse("note item body was empty")
        }
        guard !dto.sourceReferences.isEmpty else {
            throw MLXLectureNotesBackendError.malformedResponse("note item omitted source references")
        }
        let references = try dto.sourceReferences.map { reference -> NotesSourceReference in
            guard Self.range(reference.firstSequenceNumber, reference.lastSequenceNumber, isContainedIn: allowedSequences) else {
                throw MLXLectureNotesBackendError.invalidSourceReference
            }
            return NotesSourceReference(
                sessionID: sessionID,
                firstSequenceNumber: reference.firstSequenceNumber,
                lastSequenceNumber: reference.lastSequenceNumber
            )
        }
        guard let kind = LectureNoteItemKind(rawValue: dto.kind) else {
            throw MLXLectureNotesBackendError.malformedResponse("unrecognized item kind \(dto.kind)")
        }
        guard let fidelity = LectureNoteContentFidelity(rawValue: dto.fidelity) else {
            throw MLXLectureNotesBackendError.malformedResponse("unrecognized fidelity \(dto.fidelity)")
        }
        let trimmedUncertaintyNote = dto.uncertaintyNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let uncertaintyNote: String?
        if fidelity == .transcriptSupported {
            uncertaintyNote = trimmedUncertaintyNote.isEmpty ? nil : dto.uncertaintyNote
        } else {
            guard !trimmedUncertaintyNote.isEmpty else {
                throw MLXLectureNotesBackendError.malformedResponse("reconstructed or uncertain item omitted uncertainty context")
            }
            uncertaintyNote = dto.uncertaintyNote
        }
        return LectureNoteItem(
            kind: kind,
            title: nil,
            body: body,
            fidelity: fidelity,
            sourceReferences: references,
            uncertaintyNote: uncertaintyNote
        )
    }

    private static func range(_ first: Int, _ last: Int, isContainedIn allowed: Set<Int>) -> Bool {
        guard first <= last else { return false }
        for sequence in first...last where !allowed.contains(sequence) {
            return false
        }
        return true
    }

    /// Slices `items` directly into `LectureNoteSection`s using `ranges`'
    /// index boundaries only — section content always comes from the
    /// already-committed `items`, never regenerated from `ranges`. Fails
    /// closed on any gap, overlap, out-of-bounds index, or empty heading;
    /// requires the ranges to cover exactly `0..<items.count` with no
    /// missing or duplicated index.
    private static func assembleSections(
        _ ranges: [MLXSectionRangeDTO], items: [LectureNoteItem]
    ) throws -> [LectureNoteSection] {
        guard !ranges.isEmpty else {
            throw MLXLectureNotesBackendError.malformedResponse("section plan contained no sections")
        }
        let ordered = ranges.sorted { $0.firstItemIndex < $1.firstItemIndex }
        var expectedNextIndex = 0
        var sections: [LectureNoteSection] = []
        for range in ordered {
            guard
                range.firstItemIndex == expectedNextIndex,
                range.lastItemIndex >= range.firstItemIndex,
                range.lastItemIndex < items.count
            else {
                throw MLXLectureNotesBackendError.malformedResponse(
                    "section item-index range is invalid, out of bounds, or leaves a gap/overlap"
                )
            }
            let heading = range.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heading.isEmpty else {
                throw MLXLectureNotesBackendError.malformedResponse("section heading was empty")
            }
            sections.append(LectureNoteSection(heading: heading, items: Array(items[range.firstItemIndex...range.lastItemIndex])))
            expectedNextIndex = range.lastItemIndex + 1
        }
        guard expectedNextIndex == items.count else {
            throw MLXLectureNotesBackendError.malformedResponse("section plan did not cover every item exactly once")
        }
        return sections
    }

    // MARK: - JSON Schemas

    static let noteItemsJSONSchema = """
    {
      "type": "object",
      "properties": {
        "items": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "kind": { "type": "string", "enum": \(Self.jsonArray(MLXNoteVocabulary.itemKinds)) },
              "body": { "type": "string" },
              "fidelity": { "type": "string", "enum": \(Self.jsonArray(MLXNoteVocabulary.fidelities)) },
              "sourceReferences": {
                "type": "array",
                "items": {
                  "type": "object",
                  "properties": {
                    "firstSequenceNumber": { "type": "integer" },
                    "lastSequenceNumber": { "type": "integer" }
                  },
                  "required": ["firstSequenceNumber", "lastSequenceNumber"]
                }
              },
              "uncertaintyNote": { "type": "string" }
            },
            "required": ["kind", "body", "fidelity", "sourceReferences", "uncertaintyNote"]
          }
        }
      },
      "required": ["items"]
    }
    """

    static let sectionPlanJSONSchema = """
    {
      "type": "object",
      "properties": {
        "sections": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "heading": { "type": "string" },
              "firstItemIndex": { "type": "integer" },
              "lastItemIndex": { "type": "integer" }
            },
            "required": ["heading", "firstItemIndex", "lastItemIndex"]
          }
        }
      },
      "required": ["sections"]
    }
    """

    static let overviewJSONSchema = """
    {
      "type": "object",
      "properties": {
        "overview": { "type": "string" }
      },
      "required": ["overview"]
    }
    """

    private static func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }
}
