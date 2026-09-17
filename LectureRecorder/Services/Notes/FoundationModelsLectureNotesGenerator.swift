import FoundationModels
import Foundation

nonisolated enum FoundationModelsNotesBackendError: LocalizedError, Sendable, Equatable {
    case invalidSourceReference
    case malformedResponse(String)
    /// `generation.provenance.backendIdentifier` names this backend, but
    /// `generatorIdentifier`/`recipeVersion` do not exactly match what this
    /// implementation actually knows how to run — e.g. a future, different
    /// Apple recipe version. Never silently run against provenance this
    /// exact code wasn't built for, and never rerouted to OpenAI; the
    /// router's own routing already keyed on `backendIdentifier` alone, so
    /// this is the generator's own independent, finer-grained check.
    case incompatibleProvenance
    /// A request could not be made to fit Apple's on-device session
    /// context (real preflight, or the deterministic fallback budget) even
    /// after every subdivision this backend is willing to attempt — an
    /// irreducible single item, or the hierarchical-reduction level cap was
    /// reached first. Never silently submitted anyway: no Foundation
    /// Models request is knowingly sent once its own preflight says it
    /// will not fit. `String` names which stage failed.
    case contextBudgetExceeded(String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceReference:
            return "The local model claimed a source reference outside what it was given."
        case .malformedResponse(let reason):
            return "The local model produced an unusable response: \(reason)."
        case .incompatibleProvenance:
            return "This generation's provenance is not compatible with this Apple Foundation Models backend implementation."
        case .contextBudgetExceeded(let stage):
            return "The local model's context budget could not be satisfied for \(stage), even after subdividing the request."
        }
    }
}

/// Every distinct kind of Foundation Models call this backend makes —
/// exists so response-headroom policy (`FoundationModelsResponseReserves`)
/// and human-readable failure descriptions are centralized per call shape,
/// rather than scattered magic numbers or one universal reserve applied to
/// every request regardless of how large its actual output tends to be.
nonisolated enum FoundationModelsCallStage: Sendable, Equatable {
    /// Transcript units → grounded structured note items. The largest
    /// typical output shape (several full items, each with body/kind/
    /// fidelity/sourceReferences/uncertaintyNote).
    case windowAnalysis
    /// Note items → fewer, denser note items (condensed, for the overview
    /// pipeline only). Smaller than analysis output, but still full items.
    case reduction
    /// Note items → a compact section-organization plan only (headings +
    /// integer index ranges) — no note-item content is ever regenerated.
    case sectionPlan
    /// Note items → one short overview string.
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

/// Centralized, per-stage response-headroom policy: how many tokens of
/// `contextTokenBudget` to reserve for the model's own generated response
/// before comparing an input-token preflight, since different call shapes
/// produce materially different output sizes (see `FoundationModelsCallStage`).
/// Initial implementation parameters conservative for Apple's ~4,096-token
/// on-device session context — not permanent product constants.
nonisolated struct FoundationModelsResponseReserves: Sendable, Equatable {
    var windowAnalysis: Int
    var reduction: Int
    var sectionPlan: Int
    var overview: Int

    static let conservativeDefault = FoundationModelsResponseReserves(
        windowAnalysis: 1_024,
        reduction: 512,
        sectionPlan: 128,
        overview: 256
    )

    func reserve(for stage: FoundationModelsCallStage) -> Int {
        switch stage {
        case .windowAnalysis: return windowAnalysis
        case .reduction: return reduction
        case .sectionPlan: return sectionPlan
        case .overview: return overview
        }
    }
}

/// Apple Foundation Models adapter for the provider-neutral Notes
/// generation protocol — the $0, on-device default backend for every
/// brand-new generation. Performs no planning, persistence, recovery,
/// transcript loading, generation identity creation, or cancellation
/// bookkeeping; those remain owned by `LectureNotesGenerationService`.
///
/// Every real `FoundationModels`/`LanguageModelSession` call is confined to
/// `sessionDriver` (see `FoundationModelsSessionDriving`) — this type only
/// ever builds compact prompts, decodes/validates the driver's structured
/// DTOs against the transcript sources it was actually given, and maps
/// validated results onto the existing provider-neutral domain model.
///
/// `synthesize` deliberately does NOT force an entire (possibly 60–90
/// minute) lecture's worth of detail through one aggressively-reduced final
/// call, and — critically — never asks Foundation Models to *regenerate*
/// already-grounded detailed note-item content merely to organize it into
/// sections. Detailed section content is structurally lossless: the model
/// only ever returns a compact section-organization *plan* (headings +
/// batch-local item index ranges), which is validated and then assembled
/// in Swift directly from the original `LectureNoteItem` values — never
/// reconstructed from a model DTO. Only the short document `overview`
/// intentionally goes through lossy hierarchical reduction, since it is
/// meant to be brief.
nonisolated struct FoundationModelsLectureNotesGenerator: LectureNotesGenerating, NewLectureNotesGenerationAvailabilityChecking {
    private static let maximumGeneratedOutputAttempts = 2

    private struct SectionPlanRequest {
        var batch: [LectureNoteItem]
        var prompt: String
        var schema: GenerationSchema
    }

    static let analysisInstructions = """
    You write grounded technical college-lecture notes from ONLY the numbered transcript lines given, formatted "[sequenceNumber] text". Preserve concepts, definitions, explanations, formulas, code, examples, warnings, and instructor emphasis; do not reduce to a generic summary. Every item's sourceReferences must use only sequenceNumber values that appear in the given lines — never invent, guess, or reuse numbers from outside them. Use fidelity "transcriptSupported" only when directly supported, "reconstructed" for normalized notation/code/equations, or "uncertain" for genuinely ambiguous reconstructions. Every item must populate uncertaintyNote: an empty string for transcriptSupported; for reconstructed, briefly state what was reconstructed or normalized; for uncertain, briefly state the ambiguity.
    """

    /// Used only to condense material for the short document overview —
    /// never for the detailed Notes sections themselves.
    static let reductionInstructions = """
    Condense the given note items, formatted "[sequenceRange] (kind/fidelity) text", into fewer, denser items covering the same material — preserve technical depth, formulas, code, warnings, and fidelity/uncertainty distinctions; remove repetition. Every item's sourceReferences must reuse only sequenceNumber values that already appear in the given items' own ranges — never widen, invent, or combine into a range not actually covered.
    """

    /// Used for detailed section planning: the model chooses grouping and
    /// headings only — it never rewrites, drops, or restates item content,
    /// and its response schema (`AppleSectionPlanDTO`) has no room to.
    static let detailedSectionInstructions = """
    Group the given note items, formatted "[itemIndex] (kind/fidelity) text" and already in lecture order, into one or more contiguous study-note sections with short headings. Every item (index 0 through the highest index given) must belong to exactly one section, in order, with no gaps or overlaps — you are choosing section boundaries and titles only, not rewriting or omitting any item.
    """

    static let overviewInstructions = """
    Write a short overview (a handful of useful takeaways, not padding) summarizing the given note items, formatted "[sequenceRange] (kind/fidelity) text" and already in lecture order. This is a brief overview only — full technical detail belongs in the Notes sections, not here.
    """

    private let sessionDriver: any FoundationModelsSessionDriving
    /// Per-stage response-headroom policy (see `FoundationModelsCallStage`/
    /// `FoundationModelsResponseReserves`) — subtracted from
    /// `contextTokenBudget` before comparing a real preflight input-token
    /// count. Deliberately never implemented as a hard
    /// `GenerationOptions.maximumResponseTokens` cutoff: the real Xcode
    /// 26.6 `GenerationOptions` does expose `maximumResponseTokens`, but
    /// truncating a guided-generation (`Generable`) response mid-structure
    /// can produce output that no longer decodes at all. Response headroom
    /// is enforced purely by keeping the *input* side of every request
    /// context-safe, never by capping the output.
    private let responseReserves: FoundationModelsResponseReserves
    /// Deterministic fallback ceiling (serialized UTF-8 bytes of the
    /// actual encoded prompt) used only when real token counting can't
    /// answer (`estimatedTokenCount` returned `nil`) — a safety/fallback
    /// mechanism, never the primary fit criterion when real counting
    /// works. Shared by every call site; unlike token-based headroom, byte
    /// budgeting has no per-stage "response size" concept to refine.
    private let maxInputBytesPerCall: Int
    /// Secondary fallback guard alongside the byte ceiling above — never
    /// consulted on its own when real token counting succeeds.
    private let maxItemsSafetyCapPerCall: Int
    /// Hard structural bound on hierarchical-reduction/subdivision levels.
    /// Splitting or reducing content cannot always be proven to shrink
    /// monotonically purely from the model's own behavior (e.g. two
    /// already-huge items the model echoes back essentially unchanged), so
    /// this explicit cap — together with the natural base case of a
    /// single, no-longer-divisible item — is the actual termination
    /// guarantee. Once exhausted while a request still does not fit,
    /// `synthesize`/`analyzeWindow` fail with
    /// `.contextBudgetExceeded` rather than ever submitting a request
    /// known to be oversized.
    private let maxReductionLevels: Int

    init(
        sessionDriver: any FoundationModelsSessionDriving = RealFoundationModelsSessionDriver(),
        responseReserves: FoundationModelsResponseReserves = .conservativeDefault,
        maxInputBytesPerCall: Int = 6_000,
        maxItemsSafetyCapPerCall: Int = 12,
        maxReductionLevels: Int = 8
    ) {
        self.sessionDriver = sessionDriver
        self.responseReserves = responseReserves
        self.maxInputBytesPerCall = maxInputBytesPerCall
        self.maxItemsSafetyCapPerCall = maxItemsSafetyCapPerCall
        self.maxReductionLevels = max(1, maxReductionLevels)
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
        // The ~30-second transcript chunk architecture and the 6,000-byte/
        // 8-unit window-planning budget stay exactly as they are (T5-E
        // contract §6) — this is an additional, independent preflight on
        // top of that planning budget, not a replacement for it. An
        // unusual planned window (in particular `isOversizedSingleUnit`)
        // that still does not fit after this exact check fails cleanly
        // rather than ever being sent anyway.
        guard await fits(prompt: prompt, itemCountForFallback: units.count, instructions: Self.analysisInstructions, generating: AppleNoteItemsDTO.self, stage: .windowAnalysis) else {
            throw FoundationModelsNotesBackendError.contextBudgetExceeded("\(FoundationModelsCallStage.windowAnalysis.description) (window #\(window.windowIndex))")
        }
        let allowedSequences = Set(units.map(\.sequenceNumber))
        let items: [LectureNoteItem] = try await withGeneratedOutputRetry {
            let dto = try await sessionDriver.respond(
                instructions: Self.analysisInstructions,
                prompt: prompt,
                generating: AppleNoteItemsDTO.self
            )
            let mapped = try dto.items.map {
                try Self.mapItem(
                    $0,
                    sessionID: generation.sessionID,
                    allowedSequences: allowedSequences
                )
            }
            guard !mapped.isEmpty else {
                throw FoundationModelsNotesBackendError.malformedResponse(
                    "window analysis contained no note items"
                )
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

    /// Builds the final document from every window analysis's items,
    /// flattened in lecture (`windowIndex`) order, via two independent
    /// pipelines:
    ///
    /// 1. Detailed sections: items are packed into context-safe,
    ///    contiguous batches and each batch's *organization only* (section
    ///    headings + item-index ranges) is planned via a fresh session —
    ///    the original `LectureNoteItem` values are then sliced directly
    ///    into `LectureNoteSection`s in Swift, never reconstructed from a
    ///    model response. Full technical detail is therefore structurally
    ///    guaranteed to survive, not merely instructed to.
    /// 2. Overview: the same flattened items are hierarchically reduced
    ///    (condensed, via fresh sessions, never an accumulated
    ///    conversation) only as far as needed to fit one short final
    ///    overview call.
    ///
    /// Every request in both pipelines is preflighted; a request that
    /// cannot be made to fit — because it is already a single,
    /// no-longer-divisible item, or because `maxReductionLevels` was
    /// reached — fails with `.contextBudgetExceeded` rather than ever
    /// being submitted anyway.
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
            throw FoundationModelsNotesBackendError.malformedResponse("synthesis input contained no note items")
        }

        let sections = try await generateDetailedSections(from: allItems)
        guard !sections.isEmpty else {
            throw FoundationModelsNotesBackendError.malformedResponse("document produced no sections")
        }

        let overview = try await generateOverview(from: allItems, generation: generation)

        return LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: overview,
            sections: sections
        )
    }

    // MARK: - Provenance

    private static func validateProvenanceCompatibility(_ generation: LectureNotesGenerationRecord) throws {
        guard
            generation.provenance.backendIdentifier == FoundationModelsNotesConfiguration.backendIdentifier,
            generation.provenance.generatorIdentifier == FoundationModelsNotesConfiguration.generatorIdentifier,
            generation.provenance.recipeVersion == FoundationModelsNotesConfiguration.recipeVersion
        else {
            throw FoundationModelsNotesBackendError.incompatibleProvenance
        }
    }

    private func withGeneratedOutputRetry<Output>(
        _ operation: () async throws -> Output
    ) async throws -> Output {
        for attempt in 1...Self.maximumGeneratedOutputAttempts {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as FoundationModelsNotesBackendError {
                let isRetryable: Bool
                switch error {
                case .malformedResponse, .invalidSourceReference:
                    isRetryable = true
                case .incompatibleProvenance, .contextBudgetExceeded:
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

    // MARK: - Detailed section planning (structurally lossless)

    /// Packs `allItems` into context-safe batches, asks the model only how
    /// to *organize* each batch (a section plan of headings + batch-local
    /// item index ranges — never regenerated item content), validates that
    /// plan, and assembles the final sections in Swift directly from
    /// slices of the original `allItems` — so section content is exactly
    /// the original items, never a model reconstruction of them.
    private func generateDetailedSections(from allItems: [LectureNoteItem]) async throws -> [LectureNoteSection] {
        let requests = try await makeContextSafeSectionPlanRequests(allItems)

        var sections: [LectureNoteSection] = []
        for request in requests {
            try Task.checkCancellation()
            let plannedSections: [LectureNoteSection] = try await withGeneratedOutputRetry {
                let generated = try await sessionDriver.respond(
                    instructions: Self.detailedSectionInstructions,
                    prompt: request.prompt,
                    schema: request.schema
                )
                let plan: AppleSectionPlanDTO
                do {
                    plan = try AppleSectionPlanDTO(generated)
                } catch {
                    throw FoundationModelsNotesBackendError.malformedResponse(
                        "could not decode section plan: \(error.localizedDescription)"
                    )
                }
                return try Self.assembleSections(from: plan, originalBatch: request.batch)
            }
            sections.append(contentsOf: plannedSections)
        }
        return sections
    }

    /// Validates a model-produced section plan against `originalBatch` and
    /// assembles `LectureNoteSection`s using slices of `originalBatch`
    /// directly — the model's own DTO content (beyond headings and index
    /// ranges) is never consulted. A single running `expectedNextIndex`
    /// check simultaneously proves: sections are ordered, ranges do not
    /// overlap, there are no gaps, and coverage is exactly
    /// `0..<originalBatch.count` — any plan that fails any of those is
    /// rejected before any `LectureNoteSection` is constructed.
    private static func assembleSections(
        from plan: AppleSectionPlanDTO,
        originalBatch: [LectureNoteItem]
    ) throws -> [LectureNoteSection] {
        guard !plan.sections.isEmpty else {
            throw FoundationModelsNotesBackendError.malformedResponse("section plan contained no sections")
        }
        var sections: [LectureNoteSection] = []
        var expectedNextIndex = 0
        for range in plan.sections {
            let heading = range.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heading.isEmpty else {
                throw FoundationModelsNotesBackendError.malformedResponse("section plan contained an empty heading")
            }
            guard range.firstItemIndex <= range.lastItemIndex else {
                throw FoundationModelsNotesBackendError.malformedResponse("section plan contained an inverted range")
            }
            guard range.firstItemIndex >= 0, range.lastItemIndex < originalBatch.count else {
                throw FoundationModelsNotesBackendError.malformedResponse("section plan range is out of bounds")
            }
            guard range.firstItemIndex == expectedNextIndex else {
                throw FoundationModelsNotesBackendError.malformedResponse("section plan coverage is not contiguous, ordered, and gap/overlap-free")
            }
            sections.append(LectureNoteSection(heading: range.heading, items: Array(originalBatch[range.firstItemIndex...range.lastItemIndex])))
            expectedNextIndex = range.lastItemIndex + 1
        }
        guard expectedNextIndex == originalBatch.count else {
            throw FoundationModelsNotesBackendError.malformedResponse("section plan does not cover every item exactly once")
        }
        return sections
    }

    // MARK: - Overview (hierarchically reduced; intentionally lossy)

    private func generateOverview(
        from allItems: [LectureNoteItem],
        generation: LectureNotesGenerationRecord
    ) async throws -> String {
        var currentItems = allItems
        var level = 0
        while await !fits(items: currentItems, instructions: Self.overviewInstructions, generating: AppleOverviewDTO.self, stage: .overview) {
            try Task.checkCancellation()
            guard level < maxReductionLevels else {
                throw FoundationModelsNotesBackendError.contextBudgetExceeded(FoundationModelsCallStage.overview.description)
            }
            // Every reduction chunk is itself verified to fit (real
            // preflight first, deterministic packing/bisection fallback)
            // before any of them are sent — a reduction call is never
            // submitted merely because it survived initial packing.
            let batches = try await makeContextSafeBatches(
                currentItems, instructions: Self.reductionInstructions, generating: AppleNoteItemsDTO.self, stage: .reduction
            )
            currentItems = try await reduceChunks(batches, sessionID: generation.sessionID)
            level += 1
        }

        try Task.checkCancellation()
        let prompt = Self.encodeItemsPrompt(currentItems)
        return try await withGeneratedOutputRetry {
            let dto = try await sessionDriver.respond(
                instructions: Self.overviewInstructions,
                prompt: prompt,
                generating: AppleOverviewDTO.self
            )
            let overview = dto.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !overview.isEmpty else {
                throw FoundationModelsNotesBackendError.malformedResponse("overview was empty")
            }
            return overview
        }
    }

    private func reduceChunks(_ chunks: [[LectureNoteItem]], sessionID: UUID) async throws -> [LectureNoteItem] {
        var result: [LectureNoteItem] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let allowedSequences = try Self.allowedSequences(in: chunk)
            let prompt = Self.encodeItemsPrompt(chunk)
            let reducedItems: [LectureNoteItem] = try await withGeneratedOutputRetry {
                let dto = try await sessionDriver.respond(
                    instructions: Self.reductionInstructions,
                    prompt: prompt,
                    generating: AppleNoteItemsDTO.self
                )
                let mapped = try dto.items.map {
                    try Self.mapItem($0, sessionID: sessionID, allowedSequences: allowedSequences)
                }
                guard !mapped.isEmpty else {
                    throw FoundationModelsNotesBackendError.malformedResponse(
                        "reduction contained no note items"
                    )
                }
                return mapped
            }
            result.append(contentsOf: reducedItems)
        }
        return result
    }

    // MARK: - Context-safe batching

    /// Produces the exact request values used for detailed-section dispatch.
    /// Each candidate is checked with its request-specific runtime schema;
    /// successful prompt/schema values are retained so dispatch cannot drift
    /// from the preflighted request.
    private func makeContextSafeSectionPlanRequests(
        _ items: [LectureNoteItem],
        depth: Int = 0
    ) async throws -> [SectionPlanRequest] {
        try Task.checkCancellation()
        let prompt = Self.encodeIndexedItemsPrompt(items)
        let schema = try Self.sectionPlanSchema(inputCount: items.count)
        if await fits(
            prompt: prompt,
            itemCountForFallback: items.count,
            instructions: Self.detailedSectionInstructions,
            schema: schema,
            stage: .sectionPlan
        ) {
            return [SectionPlanRequest(batch: items, prompt: prompt, schema: schema)]
        }
        guard items.count > 1, depth < maxReductionLevels else {
            throw FoundationModelsNotesBackendError.contextBudgetExceeded(
                FoundationModelsCallStage.sectionPlan.description
            )
        }
        var pieces = Self.packItemsForCall(
            items,
            maxBytesPerChunk: maxInputBytesPerCall,
            maxItemsPerChunk: maxItemsSafetyCapPerCall,
            encode: Self.encodeIndexedItemsPrompt
        )
        if pieces.count <= 1 {
            pieces = Self.bisect(items)
        }
        var result: [SectionPlanRequest] = []
        for piece in pieces {
            try Task.checkCancellation()
            result.append(contentsOf: try await makeContextSafeSectionPlanRequests(
                piece,
                depth: depth + 1
            ))
        }
        return result
    }

    /// Verifies whether `items` fits `instructions`/`generating` (encoded
    /// via `encode`) as ONE request first — preferring a real token-count
    /// preflight for the *whole* remaining item list whenever the driver
    /// can answer, so a batch the real model would accept is never
    /// needlessly pre-split merely because it exceeds the deterministic
    /// fallback's item-count ceiling. Only when it does not fit does this
    /// pack `items` into deterministic candidate batches (byte/item caps,
    /// mirroring `NotesWindowPlanner`'s own packing shape) and recursively
    /// verify each piece the same way, falling back to a plain bisection
    /// if packing alone would not have produced more than one piece. Fails
    /// with `.contextBudgetExceeded(stage.description)` for an irreducible
    /// single item that still does not fit, or once `maxReductionLevels`
    /// recursion depth is exhausted — never submits a request known not to
    /// fit.
    private func makeContextSafeBatches<Content: Generable>(
        _ items: [LectureNoteItem],
        instructions: String,
        generating: Content.Type,
        stage: FoundationModelsCallStage,
        encode: @escaping ([LectureNoteItem]) -> String = Self.encodeItemsPrompt,
        depth: Int = 0
    ) async throws -> [[LectureNoteItem]] {
        try Task.checkCancellation()
        if await fits(items: items, instructions: instructions, generating: Content.self, stage: stage, encode: encode) {
            return [items]
        }
        guard items.count > 1, depth < maxReductionLevels else {
            throw FoundationModelsNotesBackendError.contextBudgetExceeded(stage.description)
        }
        var pieces = Self.packItemsForCall(items, maxBytesPerChunk: maxInputBytesPerCall, maxItemsPerChunk: maxItemsSafetyCapPerCall, encode: encode)
        if pieces.count <= 1 {
            pieces = Self.bisect(items)
        }
        var result: [[LectureNoteItem]] = []
        for piece in pieces {
            try Task.checkCancellation()
            result.append(contentsOf: try await makeContextSafeBatches(
                piece, instructions: instructions, generating: Content.self, stage: stage, encode: encode, depth: depth + 1
            ))
        }
        return result
    }

    /// Greedy, contiguous, order-preserving packing of `items` into chunks
    /// under a byte-size ceiling (primary) and an item-count ceiling
    /// (secondary) — the same two-ceiling shape `NotesWindowPlanner.plan`
    /// uses for transcript units, adapted to already-in-memory note items.
    /// Tracks the *actual* joined-prompt byte cost exactly (including the
    /// `"\n"` separator `encode` inserts between items) rather than
    /// summing each item's independently-encoded size, so the packer's own
    /// byte ceiling is never silently under-counted. A single item that
    /// alone exceeds `maxBytesPerChunk` is flushed as its own oversized
    /// chunk rather than being silently combined or dropped, mirroring
    /// `NotesWindowPlanner`'s `isOversizedSingleUnit` handling.
    private static func packItemsForCall(
        _ items: [LectureNoteItem],
        maxBytesPerChunk: Int,
        maxItemsPerChunk: Int,
        encode: ([LectureNoteItem]) -> String
    ) -> [[LectureNoteItem]] {
        var chunks: [[LectureNoteItem]] = []
        var pending: [LectureNoteItem] = []
        var pendingBytes = 0

        func flushPending() {
            guard !pending.isEmpty else { return }
            chunks.append(pending)
            pending = []
            pendingBytes = 0
        }

        for item in items {
            let size = encode([item]).utf8.count
            if size > maxBytesPerChunk {
                flushPending()
                chunks.append([item])
                continue
            }
            // Exact separator accounting: `encode` joins with "\n" (1
            // byte) strictly *between* items, so adding one more item to a
            // non-empty pending batch costs exactly
            // `pendingBytes + 1 + size`, never `pendingBytes + size` alone.
            let separatorCost = pending.isEmpty ? 0 : 1
            let countWouldExceed = pending.count >= maxItemsPerChunk
            let sizeWouldExceed = pendingBytes + separatorCost + size > maxBytesPerChunk
            if !pending.isEmpty && (countWouldExceed || sizeWouldExceed) {
                flushPending()
            }
            pendingBytes += (pending.isEmpty ? 0 : 1) + size
            pending.append(item)
        }
        flushPending()
        return chunks
    }

    /// Deterministic, order-preserving 2-way split.
    private static func bisect(_ items: [LectureNoteItem]) -> [[LectureNoteItem]] {
        guard items.count > 1 else { return [items] }
        let midpoint = items.count / 2
        return [Array(items[..<midpoint]), Array(items[midpoint...])]
    }

    // MARK: - Context-size fit checking

    /// Real-token-preflight-first, deterministic-byte-budget-fallback
    /// decision for whether `items` (encoded via `encode`) safely fits one
    /// request using `instructions`/`generating`, reserving response
    /// headroom appropriate to `stage`.
    private func fits<Content: Generable>(
        items: [LectureNoteItem],
        instructions: String,
        generating: Content.Type,
        stage: FoundationModelsCallStage,
        encode: ([LectureNoteItem]) -> String = Self.encodeItemsPrompt
    ) async -> Bool {
        await fits(prompt: encode(items), itemCountForFallback: items.count, instructions: instructions, generating: Content.self, stage: stage)
    }

    /// Same decision, taking an already-encoded prompt directly (used by
    /// `analyzeWindow`, whose prompt is transcript units, not note items).
    private func fits<Content: Generable>(
        prompt: String,
        itemCountForFallback: Int,
        instructions: String,
        generating: Content.Type,
        stage: FoundationModelsCallStage
    ) async -> Bool {
        if let inputTokens = await sessionDriver.estimatedTokenCount(
            instructions: instructions,
            prompt: prompt,
            generating: Content.self
        ) {
            return inputTokens + responseReserves.reserve(for: stage) <= sessionDriver.contextTokenBudget
        }
        return prompt.utf8.count <= maxInputBytesPerCall && itemCountForFallback <= maxItemsSafetyCapPerCall
    }

    /// Runtime-schema equivalent used by detailed section planning. The
    /// exact schema passed here is retained with the successful request and
    /// reused for dispatch.
    private func fits(
        prompt: String,
        itemCountForFallback: Int,
        instructions: String,
        schema: GenerationSchema,
        stage: FoundationModelsCallStage
    ) async -> Bool {
        if let inputTokens = await sessionDriver.estimatedTokenCount(
            instructions: instructions,
            prompt: prompt,
            schema: schema
        ) {
            return inputTokens + responseReserves.reserve(for: stage) <= sessionDriver.contextTokenBudget
        }
        return prompt.utf8.count <= maxInputBytesPerCall && itemCountForFallback <= maxItemsSafetyCapPerCall
    }

    // MARK: - Prompt encoding

    private static func encodeUnitsPrompt(_ units: [NotesTranscriptSourceUnit]) -> String {
        units.map { "[\($0.sequenceNumber)] \($0.text)" }.joined(separator: "\n")
    }

    /// Includes `uncertaintyNote` (when present) so reconstructed/uncertain
    /// context is never silently dropped between model calls — a
    /// reduction or overview stage that only ever saw `body` would have no
    /// way to preserve *why* an item was reconstructed or uncertain. Used
    /// for reduction and overview, whose responses reference source
    /// `sequenceRange`s.
    private static func encodeItemsPrompt(_ items: [LectureNoteItem]) -> String {
        items.map { item in
            let ranges = item.sourceReferences
                .map { "\($0.firstSequenceNumber)-\($0.lastSequenceNumber)" }
                .joined(separator: ",")
            let title = item.title.map { "\($0): " } ?? ""
            let uncertainty = item.uncertaintyNote.map { " {uncertainty: \($0)}" } ?? ""
            return "[\(ranges)] (\(item.kind.rawValue)/\(item.fidelity.rawValue)) \(title)\(item.body)\(uncertainty)"
        }.joined(separator: "\n")
    }

    /// Same shape as `encodeItemsPrompt`, but labels each line with its
    /// 0-based position within `items` instead of its source sequence
    /// range — used exclusively for detailed section planning, whose
    /// response (`AppleSectionPlanDTO`) references items by that same
    /// batch-local index, never by source sequence number. Still includes
    /// `uncertaintyNote` so the model can make sensible grouping decisions
    /// around uncertain/reconstructed content, even though it never
    /// restates item content in its response.
    private static func encodeIndexedItemsPrompt(_ items: [LectureNoteItem]) -> String {
        items.enumerated().map { index, item in
            let title = item.title.map { "\($0): " } ?? ""
            let uncertainty = item.uncertaintyNote.map { " {uncertainty: \($0)}" } ?? ""
            return "[\(index)] (\(item.kind.rawValue)/\(item.fidelity.rawValue)) \(title)\(item.body)\(uncertainty)"
        }.joined(separator: "\n")
    }

    static func sectionPlanSchema(inputCount: Int) throws -> GenerationSchema {
        guard inputCount > 0 else {
            throw FoundationModelsNotesBackendError.malformedResponse(
                "a request-specific section-plan schema requires at least one input item"
            )
        }
        do {
            let itemIndex = DynamicGenerationSchema(
                type: Int.self,
                guides: [.range(0...(inputCount - 1))]
            )
            let section = DynamicGenerationSchema(
                name: "AppleSectionRange",
                properties: [
                    .init(name: "heading", schema: DynamicGenerationSchema(type: String.self)),
                    .init(name: "firstItemIndex", schema: itemIndex),
                    .init(name: "lastItemIndex", schema: itemIndex)
                ]
            )
            let root = DynamicGenerationSchema(
                name: "AppleSectionPlan",
                properties: [
                    .init(
                        name: "sections",
                        schema: DynamicGenerationSchema(
                            arrayOf: section,
                            minimumElements: 1,
                            maximumElements: inputCount
                        )
                    )
                ]
            )
            return try GenerationSchema(root: root, dependencies: [])
        } catch let error as FoundationModelsNotesBackendError {
            throw error
        } catch {
            throw FoundationModelsNotesBackendError.malformedResponse(
                "could not construct the request-specific section-plan schema: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Response validation/mapping

    private static func mapItem(
        _ dto: AppleNoteItemDTO,
        sessionID: UUID,
        allowedSequences: Set<Int>
    ) throws -> LectureNoteItem {
        let body = dto.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw FoundationModelsNotesBackendError.malformedResponse("note item body was empty")
        }
        guard !dto.sourceReferences.isEmpty else {
            throw FoundationModelsNotesBackendError.malformedResponse("note item omitted source references")
        }
        let references = try dto.sourceReferences.map { reference -> NotesSourceReference in
            guard Self.range(reference.firstSequenceNumber, reference.lastSequenceNumber, isContainedIn: allowedSequences) else {
                throw FoundationModelsNotesBackendError.invalidSourceReference
            }
            return NotesSourceReference(
                sessionID: sessionID,
                firstSequenceNumber: reference.firstSequenceNumber,
                lastSequenceNumber: reference.lastSequenceNumber
            )
        }
        guard let kind = LectureNoteItemKind(rawValue: dto.kind) else {
            throw FoundationModelsNotesBackendError.malformedResponse("unrecognized item kind \(dto.kind)")
        }
        guard let fidelity = LectureNoteContentFidelity(rawValue: dto.fidelity) else {
            throw FoundationModelsNotesBackendError.malformedResponse("unrecognized fidelity \(dto.fidelity)")
        }
        let trimmedUncertaintyNote = dto.uncertaintyNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let uncertaintyNote: String?
        if fidelity == .transcriptSupported {
            // Never required; the schema's documented empty-string
            // convention for this case maps to domain `nil` rather than
            // being stored as an empty string. Never forced to `nil` if
            // the model volunteered a non-empty note anyway.
            uncertaintyNote = trimmedUncertaintyNote.isEmpty ? nil : dto.uncertaintyNote
        } else {
            guard !trimmedUncertaintyNote.isEmpty else {
                throw FoundationModelsNotesBackendError.malformedResponse("reconstructed or uncertain item omitted uncertainty context")
            }
            uncertaintyNote = dto.uncertaintyNote
        }
        return LectureNoteItem(
            kind: kind,
            title: dto.title,
            body: dto.body,
            fidelity: fidelity,
            sourceReferences: references,
            uncertaintyNote: uncertaintyNote
        )
    }

    private static func allowedSequences(in items: [LectureNoteItem]) throws -> Set<Int> {
        var result: Set<Int> = []
        for reference in items.flatMap(\.sourceReferences) {
            guard reference.firstSequenceNumber <= reference.lastSequenceNumber else {
                throw FoundationModelsNotesBackendError.malformedResponse("input item contained an invalid source reference")
            }
            var value = reference.firstSequenceNumber
            while true {
                result.insert(value)
                if value == reference.lastSequenceNumber { break }
                let (next, overflowed) = value.addingReportingOverflow(1)
                guard !overflowed else {
                    throw FoundationModelsNotesBackendError.malformedResponse("input source reference overflowed")
                }
                value = next
            }
        }
        return result
    }

    private static func range(_ first: Int, _ last: Int, isContainedIn allowed: Set<Int>) -> Bool {
        guard first <= last else { return false }
        var value = first
        while true {
            guard allowed.contains(value) else { return false }
            if value == last { return true }
            let (next, overflowed) = value.addingReportingOverflow(1)
            guard !overflowed else { return false }
            value = next
        }
    }
}

// MARK: - Backend-private structured DTOs
//
// "Backend-private" means owned by, and never referenced outside, the
// Apple Foundation Models backend — never exposed to `LectureNotesGenerating`
// callers, never used by `OpenAILectureNotesGenerator`, and never annotated
// onto the persistent Notes domain model. Kept at ordinary (not `private`)
// file visibility only so `@testable import` test code can script responses
// directly at this real driver-boundary type, the same way
// `OpenAILectureNotesGeneratorTests` scripts raw JSON at its HTTP transport
// boundary rather than reaching into that generator's own private DTOs.

nonisolated enum FoundationModelsNoteVocabulary {
    static let itemKinds = [
        "keyConcept", "definition", "explanation", "example",
        "formula", "algorithmOrCode", "warning", "uncertainty", "other"
    ]
    static let fidelities = ["transcriptSupported", "reconstructed", "uncertain"]
}

@Generable
struct AppleSourceReferenceDTO {
    var firstSequenceNumber: Int
    var lastSequenceNumber: Int
}

@Generable
struct AppleNoteItemDTO {
    @Guide(.anyOf(FoundationModelsNoteVocabulary.itemKinds))
    var kind: String
    var title: String?
    var body: String
    @Guide(.anyOf(FoundationModelsNoteVocabulary.fidelities))
    var fidelity: String
    var sourceReferences: [AppleSourceReferenceDTO]
    /// Required (not optional) so guided generation cannot simply omit it
    /// for reconstructed/uncertain content — `mapItem` still independently
    /// enforces non-emptiness for those fidelities; this only removes the
    /// schema-level escape hatch of leaving the field out entirely.
    @Guide(description: "Empty string for transcriptSupported. For reconstructed, briefly state what notation/code/equation/representation was reconstructed or normalized from the transcript. For uncertain, briefly state the ambiguity.")
    var uncertaintyNote: String
}

/// Used for analysis and reduction, where the model genuinely produces
/// (analysis) or condenses (reduction) note-item content.
@Generable
struct AppleNoteItemsDTO {
    var items: [AppleNoteItemDTO]
}

/// One planned section: a heading and the batch-local, inclusive index
/// range of items (as numbered by `encodeIndexedItemsPrompt`) it covers.
/// Carries no item content at all — see `assembleSections`.
@Generable
struct AppleSectionRangeDTO {
    var heading: String
    var firstItemIndex: Int
    var lastItemIndex: Int
}

/// A detailed-section-batch response: organization only. The model never
/// sees a schema slot to restate/rewrite item content in — it can only
/// choose section boundaries and headings.
@Generable
struct AppleSectionPlanDTO {
    var sections: [AppleSectionRangeDTO]
}

/// The short document overview, generated as its own separate, final call
/// — never bundled with the detailed sections.
@Generable
struct AppleOverviewDTO {
    var overview: String
}
