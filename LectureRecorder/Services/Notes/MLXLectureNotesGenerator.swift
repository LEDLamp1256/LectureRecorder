import Foundation

nonisolated enum MLXLectureNotesBackendError: LocalizedError, Sendable, Equatable {
    case invalidSourceReference(
        firstSequenceNumber: Int,
        lastSequenceNumber: Int,
        allowedSequenceNumbers: [Int]
    )
    case malformedResponse(String)
    /// Guided generation exhausted its bounded response budget before its
    /// grammar reached a valid stop state. Retrying the same deterministic
    /// request cannot make that request smaller, so this remains distinct
    /// from malformed model text and is never retried.
    case incompleteOutput(String)
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
        case .incompleteOutput(let detail):
            return "The local MLX model produced an unusable response: generation was truncated before completing valid structured output: \(detail)."
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
    case sectionSummaries
    case windowTopics
    case sectionTitles

    var description: String {
        switch self {
        case .windowAnalysis: return "window analysis"
        case .reduction: return "section summary reduction"
        case .sectionSummaries: return "section summary generation"
        case .windowTopics: return "window topic labeling"
        case .sectionTitles: return "section title generation"
        }
    }
}

/// Per-stage response-token budget: how many tokens of
/// `MLXSessionDriving.operationalContextCeiling` to reserve for the model's
/// generated response before comparing a real preflight input-token count,
/// and — since `MLXGuidedGeneration` takes an explicit `maxTokens` — also
/// the actual generation cap passed to that call.
///
/// The section-summary and window-topic reserves cover their schemas'
/// largest valid output, counting text at one token per character: one
/// section's summary string of at most `sectionSummaryGrammarCeiling` (768)
/// characters plus its JSON structure — about 790 tokens per section call —
/// and one window's 1 to
/// 3 topic terms of at most `windowTopicTermSchemaMaxLength` characters
/// each plus their JSON structure — about 160 tokens per window call — and
/// one section title of at most `sectionTitleGrammarCeiling` (112)
/// characters — about 130 tokens per section call; all well inside 2,048. (The pinned grammar still permits whitespace between JSON
/// tokens; the runtime's whitespace bias, not these reserves, governs that.)
nonisolated struct MLXNotesResponseReserves: Sendable, Equatable {
    var windowAnalysis: Int
    var reduction: Int
    var sectionSummaries: Int
    var windowTopics: Int
    var sectionTitles: Int

    static let conservativeDefault = MLXNotesResponseReserves(
        windowAnalysis: 4_096,
        reduction: 3_072,
        sectionSummaries: 2_048,
        windowTopics: 2_048,
        sectionTitles: 2_048
    )

    func reserve(for stage: MLXNotesCallStage) -> Int {
        switch stage {
        case .windowAnalysis: return windowAnalysis
        case .reduction: return reduction
        case .sectionSummaries: return sectionSummaries
        case .windowTopics: return windowTopics
        case .sectionTitles: return sectionTitles
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
    /// The item kinds a new MLX Notes item may be generated with. The
    /// persisted `LectureNoteItemKind.uncertainty` case is kept for stored
    /// data, but is not offered: a hedged "uncertainty" item would bypass
    /// abstention, and new Notes omit unrecoverable material instead.
    static let itemKinds = [
        "keyConcept", "definition", "explanation", "example",
        "formula", "algorithmOrCode", "warning", "other",
    ]
    static let fidelities = ["transcriptSupported", "reconstructed", "uncertain"]
    /// The fidelities overview reduction may condense items into. New MLX
    /// window analysis never generates fidelity at all — every new item is
    /// transcriptSupported (see `mapAnalysisItem`). The persisted
    /// `reconstructed` and `uncertain` cases remain for stored data (and
    /// `fidelities` above is still what Summary's schema offers).
    static let generatedNoteFidelities = ["transcriptSupported", "reconstructed"]
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

/// A window-analysis item: what the note says and which of this window's
/// transcript units it is grounded in. It carries no fidelity — every
/// accepted new item is transcriptSupported.
nonisolated struct MLXAnalysisNoteItemDTO: Codable, Sendable {
    var kind: String
    var body: String
    var sourceReferences: [MLXSourceReferenceDTO]
}

nonisolated struct MLXAnalysisNoteItemsDTO: Codable, Sendable {
    var items: [MLXAnalysisNoteItemDTO]
}

nonisolated struct MLXNoteItemDTO: Codable, Sendable {
    var kind: String
    var body: String
    var fidelity: String
    var sourceReferences: [MLXSourceReferenceDTO]
    /// Required by the reduction schema; empty for transcriptSupported.
    var uncertaintyNote: String?
}

/// Used by reduction, over already-committed (rather than raw transcript)
/// source material. Window analysis uses `MLXAnalysisNoteItemsDTO`.
nonisolated struct MLXNoteItemsDTO: Codable, Sendable {
    var items: [MLXNoteItemDTO]
}

/// One section's summary: `sectionSummaries` holds exactly one string of one
/// or two sentences. Each deterministic section (see
/// `MLXLectureNotesGenerator.sectionItemGroups`) gets its own request, so the
/// loop position — never the model — decides which section a summary belongs
/// to. Swift validates each summary and joins them, in section order, into
/// the stored overview string.
nonisolated struct MLXSectionSummariesDTO: Codable, Sendable {
    var sectionSummaries: [String]
}

/// The single-window topic response is exactly `{"topicTerms": [...]}`, 1 to
/// 3 short English topic terms (which may contain spaces) — see
/// `MLXLectureNotesGenerator.windowTopicJSONSchema` and
/// `validatedWindowTopicTerms(fromJSON:)`. It carries no window, section,
/// item, or range identity: the Swift loop that issued the request supplies
/// it.

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
/// Synthesis partitions detailed sections deterministically, summarizes
/// each section in one or two sentences from its own request (the
/// overview), and labels each analysis
/// window with a short topic, from which Swift composes section headings.
/// Summary input that does not fit is condensed per section with
/// `FoundationModelsLectureNotesGenerator`'s bounded hierarchical
/// reduce-until-it-fits approach
/// (`generateSectionSummaries`/`makeContextSafeReductionBatches`/`reduceChunks`),
/// adapted to MLX's own DTOs/guided generation. Every actual dispatch is
/// individually preflighted.
nonisolated struct MLXLectureNotesGenerator: LectureNotesGenerating, NewLectureNotesGenerationAvailabilityChecking {
    private static let maximumGeneratedOutputAttempts = 2
    static let maximumWindowAnalysisItems = 12
    static let maximumWindowAnalysisBodyLength = 600
    static let maximumWindowAnalysisUncertaintyNoteLength = 200
    static let maximumWindowAnalysisSourceReferences = 3
    /// Detailed sections are a deterministic, balanced partition of the
    /// analysis windows (see `balancedSectionWindowRanges`): about
    /// `preferredWindowsPerSection` windows each, 1 to
    /// `maximumWindowsPerSection` (about 4–12 minutes of a lecture), and at
    /// most `maximumSectionsPerDocument` sections — 6 for a 60-minute,
    /// 15-window lecture.
    static let preferredWindowsPerSection = 2.5
    static let maximumWindowsPerSection = 3
    static let maximumSectionsPerDocument = 8
    /// A window's topic is `windowTopicTermCount` short topic terms, never a
    /// character- or word-counted phrase: the model fills semantic slots, and
    /// `windowTopicTermSchemaMaxLength` is only a generous grammar safety
    /// ceiling — there is no smaller Swift limit. A section's topics are its
    /// windows' terms, in order.
    static let windowTopicTermCount = 1...3
    static let windowTopicTermSchemaMaxLength = 48
    /// A section's title (stored as its `heading`) names only its dominant
    /// theme — the section's `topics` carry the detail.
    /// A title is validated to at most `maximumSectionTitleLength`
    /// characters — a safety bound, not a target; the model is asked only
    /// for a concise noun phrase. `sectionTitleGrammarCeiling` is a looser
    /// emergency ceiling for the grammar, never a product limit: guided
    /// decoding closes a string that reaches its `maxLength`, so a title
    /// that fills the ceiling was cut, and is rejected rather than kept.
    static let maximumSectionTitleLength = 80
    static let sectionTitleGrammarCeiling = 112
    /// A section summary is one or two complete sentences, validated to at
    /// most `maximumSectionSummaryLength` characters — a safety bound, not a
    /// target; the model is asked only for concise prose. The overview is
    /// the summaries joined with single spaces, so it is bounded by
    /// construction (at most `maximumSectionsPerDocument` of them); there is
    /// no separate aggregate limit.
    static let maximumSectionSummaryLength = 600
    static let maximumSectionSummarySentences = 2
    /// The schema's hard string limit: above the accepted length only so a
    /// runaway reply is stopped. Nothing in this headroom is ever accepted.
    static let sectionSummaryGrammarCeiling = 768
    /// Abbreviations whose trailing period never ends a sentence when
    /// counting a section summary's sentences.
    static let sectionSummaryAbbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "st", "vs", "etc", "e.g", "i.e", "cf", "fig", "eq", "no", "approx",
    ]

    static let analysisInstructions = """
    You write useful college-lecture study notes from ONLY the numbered transcript lines given, formatted "[sequenceNumber] text". The lines come from automatic speech recognition and may contain transcription errors.

    Create note items for what the lecture actually teaches that is worth retaining for study: concepts, definitions, explanations, formulas, code or algorithms, examples, warnings, and instructor emphasis. Never create a note item from advertisements, promotional material, sponsorships, administrative remarks, or noise with no study value. A change of subject is not by itself a reason to omit material.

    Write each note in clear study-note form: paraphrasing, grammatical cleanup, shortening, removing filler, restructuring spoken language, and writing clearly spoken mathematics in standard notation are all fine. State only what the lecturer provides: do not add definitions, formulas, consequences, or domain knowledge the lecturer did not give, and a question or passing mention of a topic is not a reason to explain it. If a passage is too garbled or ambiguous to understand confidently, leave out that note and keep using the other clear material in the window. Not every line or window needs a note; an empty items array is a valid answer.

    Consolidate overlapping or repeated material into one item. Prefer fewer, denser items. Keep each body concise, normally about 1–3 sentences; formulas or code/algorithms may use additional space only when necessary for correctness. Output no more than \(Self.maximumWindowAnalysisItems) items for one analysis window.

    Every item's sourceReferences must cite the lines that support it, using only sequenceNumber values that appear in the given lines; never invent, guess, or reuse numbers from outside them. Respond with JSON matching the given schema only.
    """

    /// Used only to condense a section's material for its overview summary
    /// — never for the detailed Notes sections themselves.
    static let reductionInstructions = """
    Condense the given note items, formatted "[sequenceRange] (kind/fidelity) text", into fewer, denser items covering the same material — preserve technical depth, formulas, code, and warnings; remove repetition. A condensed item that draws on any reconstructed item must itself be reconstructed, with an uncertaintyNote stating what was reconstructed. Every item's sourceReferences must reuse only sequenceNumber values that already appear in the given items' own ranges — never widen, invent, or combine into a range not actually covered. Respond with JSON matching the given schema only.
    """

    /// One section's summary only — the model never rewrites, drops, or
    /// restates item content, and its response schema has no room to.
    static let sectionSummaryInstructions = """
    Summarize one section of a lecture's study notes, using only the notes given for that section. Write one or two concise, complete prose sentences that capture the section's main throughline: its dominant academic concepts and, where useful, the important relationships between them. Do not enumerate the individual notes or try to mention every detail; secondary details are covered separately by the section's topics. Give academic content priority over course logistics and administration, and summarize a section that is genuinely administrative compactly. Write natural English prose, and finish the final sentence with a period, question mark, or exclamation mark. Do not reproduce the input's format, and do not mention kinds, fidelity, ranges, source references, indices, labels, or any other metadata. Respond with JSON matching the given schema only.
    """

    static let windowTopicInstructions = """
    Give 1 to 3 concise English topic terms for a single segment of a lecture, from the study notes given for that segment only. Each array entry is one topic term: a concise noun phrase or technical term, which may be several words long, naming a substantial academic topic of the segment. When the segment genuinely covers more than one substantial topic, use a separate entry for each, and never drop a substantial topic because it comes late in the notes; a segment that is mainly course logistics or administration may be named by an administrative term. Do not write sentences. Use English only, and never switch to another language or script to compress meaning. Do not mention kinds, fidelity, ranges, source references, indices, or any other metadata. Respond with JSON matching the given schema only.
    """

    /// Appended to a window's topic prompt for its single retry after an
    /// invalid response, so the retry is not an identical greedy request. It
    /// states the contract only and never echoes the rejected response.
    static let windowTopicRetryNote = "The previous response violated the topic-term format. Return 1 to 3 concise English topic terms, with one topic term per array entry."

    static let sectionTitleInstructions = """
    Write one concise English navigation title for a single section of a lecture, from the short summary given for that section only. The title must describe the section's dominant academic theme as a normal short noun phrase; it does not need to name every topic in the section, and must not enumerate them. Use English only, and never switch to another language or script. Do not mention kinds, fidelity, ranges, source references, indices, or any other metadata. Respond with JSON matching the given schema only.
    """

    private let sessionDriver: any MLXSessionDriving
    /// The model identity this generator accepts in a generation's
    /// provenance. Must describe the same model `sessionDriver` loads;
    /// production leaves both at their 8B defaults.
    private let modelDescriptor: MLXModelDescriptor
    private let responseReserves: MLXNotesResponseReserves
    /// Hard structural bound on hierarchical-reduction/bisection depth —
    /// together with the natural base case of a single, no-longer-
    /// divisible item, this is the actual termination guarantee for
    /// `makeContextSafeReductionBatches` and the overview reduction loop.
    /// Mirrors `FoundationModelsLectureNotesGenerator.maxReductionLevels`.
    private let maxReductionLevels: Int
    private let diagnosticRecorder: (@Sendable (MLXNotesDiagnosticEvent) -> Void)?

    init(
        sessionDriver: any MLXSessionDriving = RealMLXSessionDriver(),
        modelDescriptor: MLXModelDescriptor = .qwen3_8b_4bit,
        responseReserves: MLXNotesResponseReserves = .conservativeDefault,
        maxReductionLevels: Int = 8,
        diagnosticRecorder: (@Sendable (MLXNotesDiagnosticEvent) -> Void)? = nil
    ) {
        self.sessionDriver = sessionDriver
        self.modelDescriptor = modelDescriptor
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
        try validateProvenanceCompatibility(generation)

        let prompt = Self.encodeUnitsPrompt(units)
        try await requirePreparedInputFits(instructions: Self.analysisInstructions, prompt: prompt, stage: .windowAnalysis)

        let sequenceNumbers = units.map(\.sequenceNumber)
        let allowedSequences = Set(sequenceNumbers)
        let items: [LectureNoteItem] = try await withGeneratedOutputRetry {
            let outcome = try await dispatch(
                instructions: Self.analysisInstructions,
                prompt: prompt,
                jsonSchema: Self.windowAnalysisJSONSchema(allowedSequenceNumbers: sequenceNumbers),
                maxOutputTokens: responseReserves.reserve(for: .windowAnalysis),
                sampling: MLXNotesConfiguration.windowAnalysisSampling
            )
            let dto = try Self.decode(MLXAnalysisNoteItemsDTO.self, from: outcome.jsonText)
            return try dto.items.map {
                try Self.mapAnalysisItem($0, sessionID: generation.sessionID, allowedSequences: allowedSequences)
            }
        }
        // An empty item list is a valid window analysis: the model may
        // abstain from a window with no usable lecture content.
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

    /// Builds the final document in order:
    ///
    /// 1. Swift partitions the analysis windows into balanced contiguous
    ///    sections and groups the original `LectureNoteItem` values
    ///    accordingly — never reconstructed from a model response.
    /// 2. One call per section, seeing only that section's plain note
    ///    bodies (condensed first only if they do not fit), returns its
    ///    one- or two-sentence summary; the validated summaries, joined in
    ///    section order, are the overview.
    /// 3. One call per analysis window, seeing only that window's notes,
    ///    returns its topic terms; each section's `topics` are its windows'
    ///    terms, in order.
    /// 4. One call per section, seeing only that section's validated
    ///    summary, returns its concise title (stored as `heading`).
    /// 5. The document pairs each title and topic list with its fixed
    ///    section.
    ///
    /// Every request is individually preflighted via
    /// `requirePreparedInputFits`; a request that cannot be made to fit —
    /// the window-topic request, a single no-longer-divisible reduction
    /// item, or a reduction that reached `maxReductionLevels` — fails with
    /// `.contextBudgetExceeded` rather than ever being submitted anyway.
    func synthesize(
        analyses: [LectureNotesWindowAnalysis],
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesDocument {
        try Task.checkCancellation()
        try validateProvenanceCompatibility(generation)
        // Windows that abstained contribute no items and are not partitioned.
        let windowItems: [[LectureNoteItem]] = analyses
            .sorted { $0.windowIndex < $1.windowIndex }
            .map(\.items)
            .filter { !$0.isEmpty }
        let allItems = windowItems.flatMap { $0 }
        // Every window abstained: a valid, empty document — no model call,
        // and no placeholder content presented as lecture notes.
        guard !allItems.isEmpty else {
            return LectureNotesDocument(
                generationID: generation.generationID,
                sessionID: generation.sessionID,
                transcriptFingerprint: generation.transcriptFingerprint,
                provenance: generation.provenance,
                overview: "",
                sections: []
            )
        }

        // The partition and item mapping happen before any model call.
        let sectionItems = try Self.sectionItemGroups(windowItems: windowItems)
        let summaries = try await generateSectionSummaries(sectionItems: sectionItems)
        let windowTopicTerms = try await generateWindowTopicTerms(windowItems: windowItems)
        let topics = try Self.sectionTopics(windowTopicTerms: windowTopicTerms)
        let titles = try await generateSectionTitles(sectionSummaries: summaries)
        let sections = sectionItems.indices.map { index in
            LectureNoteSection(heading: titles[index], items: sectionItems[index], topics: topics[index])
        }
        let overview = summaries.joined(separator: " ")

        return LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: overview,
            sections: sections
        )
    }

    // MARK: - Section topics (from per-window topic terms)

    /// Each window's topic terms, in window order, each from its own request
    /// that sees only that window's notes — so terms `i` can only describe
    /// window `i`, and the loop position, never the model, supplies their
    /// identity. Calls run sequentially; any window's failure aborts
    /// synthesis (no placeholder or borrowed terms). The model never chooses
    /// boundaries: Swift gathers each fixed section's topics from its
    /// windows' terms (`sectionTopics(windowTopicTerms:)`).
    private func generateWindowTopicTerms(windowItems: [[LectureNoteItem]]) async throws -> [[String]] {
        var terms: [[String]] = []
        for items in windowItems {
            try Task.checkCancellation()
            terms.append(try await generateWindowTopicTerms(windowNotes: items))
        }
        return terms
    }

    /// One window's validated topic terms. If its input does not fit, it
    /// fails closed with `.contextBudgetExceeded`.
    private func generateWindowTopicTerms(windowNotes: [LectureNoteItem]) async throws -> [String] {
        let prompt = Self.encodeWindowTopicPrompt(windowBodies: windowNotes.map(\.body))
        try await requirePreparedInputFits(instructions: Self.windowTopicInstructions, prompt: prompt, stage: .windowTopics)
        try Task.checkCancellation()
        return try await withGeneratedOutputRetry { attempt in
            let outcome = try await dispatch(
                instructions: Self.windowTopicInstructions,
                prompt: attempt == 1 ? prompt : prompt + "\n\n" + Self.windowTopicRetryNote,
                jsonSchema: Self.windowTopicJSONSchema,
                maxOutputTokens: responseReserves.reserve(for: .windowTopics),
                sampling: nil
            )
            return try Self.validatedWindowTopicTerms(fromJSON: outcome.jsonText)
        }
    }

    /// Validates a single-window response: exactly one `topicTerms` field
    /// holding 1 to 3 strings, each non-empty after trimming, free of line
    /// breaks and tabs, and free of Han ideographs; ordinary internal spaces
    /// and technical punctuation are accepted. Fails closed — never
    /// splitting, truncating, rewriting, transliterating, dropping, or
    /// inventing a term — otherwise.
    static func validatedWindowTopicTerms(fromJSON jsonText: String) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
              Set(object.keys) == ["topicTerms"], let rawTerms = object["topicTerms"] as? [String]
        else {
            throw MLXLectureNotesBackendError.malformedResponse("window topic response was not exactly one topicTerms list")
        }
        guard Self.windowTopicTermCount.contains(rawTerms.count) else {
            throw MLXLectureNotesBackendError.malformedResponse(
                "window topic had \(rawTerms.count) terms; expected \(Self.windowTopicTermCount.lowerBound)...\(Self.windowTopicTermCount.upperBound)"
            )
        }
        return try rawTerms.map { rawTerm in
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else {
                throw MLXLectureNotesBackendError.malformedResponse("window topic term was empty")
            }
            guard !term.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0 == "\t" }) else {
                throw MLXLectureNotesBackendError.malformedResponse("window topic term contained a line break or tab")
            }
            guard !containsHanIdeograph(term) else {
                throw MLXLectureNotesBackendError.malformedResponse("window topic term contained Han characters")
            }
            return term
        }
    }

    /// Whether `text` contains a Han (CJK) ideograph — the observed failure
    /// where the model switches script to compress an English label. Uses
    /// the Unicode `Ideographic` property rather than rejecting non-ASCII,
    /// so apostrophes, superscripts such as "²", and math symbols pass.
    static func containsHanIdeograph(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    /// Each fixed section's topics: its windows' terms, in window and term
    /// order, flattened (`orderedTopics`).
    static func sectionTopics(windowTopicTerms: [[String]]) throws -> [[String]] {
        try balancedSectionWindowRanges(windowCount: windowTopicTerms.count).map { range in
            orderedTopics(windowTopicTerms[range].flatMap { $0 })
        }
    }

    /// `terms` in order, trimmed, collapsing only a term that exactly repeats
    /// the one before it (ignoring case) — never reordering, rewriting,
    /// truncating, or fuzzily merging terms.
    static func orderedTopics(_ terms: [String]) -> [String] {
        var kept: [String] = []
        for term in terms.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if let previous = kept.last, previous.caseInsensitiveCompare(term) == .orderedSame { continue }
            kept.append(term)
        }
        return kept
    }

    // MARK: - Section titles (from validated section summaries)

    /// One concise title per fixed section, in section order, each from its
    /// own request that sees only that section's validated summary — so
    /// title `i` can only describe section `i`. Calls run sequentially; any
    /// section's failure aborts synthesis.
    private func generateSectionTitles(sectionSummaries: [String]) async throws -> [String] {
        var titles: [String] = []
        for summary in sectionSummaries {
            try Task.checkCancellation()
            titles.append(try await generateSectionTitle(sectionSummary: summary))
        }
        return titles
    }

    /// One section's title. If its input does not fit, it fails closed with
    /// `.contextBudgetExceeded`.
    private func generateSectionTitle(sectionSummary: String) async throws -> String {
        let prompt = Self.encodeSectionTitlePrompt(sectionSummary: sectionSummary)
        try await requirePreparedInputFits(instructions: Self.sectionTitleInstructions, prompt: prompt, stage: .sectionTitles)
        try Task.checkCancellation()
        return try await withGeneratedOutputRetry {
            let outcome = try await dispatch(
                instructions: Self.sectionTitleInstructions,
                prompt: prompt,
                jsonSchema: Self.sectionTitleJSONSchema,
                maxOutputTokens: responseReserves.reserve(for: .sectionTitles),
                sampling: nil
            )
            return try Self.validatedSectionTitle(fromJSON: outcome.jsonText)
        }
    }

    /// Validates a section-title response: exactly one `title` string that
    /// did not fill the grammar ceiling (a grammar cut), non-empty after
    /// trimming, free of line breaks and tabs, free of Han ideographs, and at
    /// most `maximumSectionTitleLength` characters. Fails closed — never
    /// truncating or rewriting.
    static func validatedSectionTitle(fromJSON jsonText: String) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
              Set(object.keys) == ["title"], let rawTitle = object["title"] as? String
        else {
            throw MLXLectureNotesBackendError.malformedResponse("section title response was not exactly one title")
        }
        guard !sectionTitleFilledGrammarCeiling(rawTitle, ceiling: sectionTitleGrammarCeiling) else {
            throw MLXLectureNotesBackendError.malformedResponse("section title reached the \(sectionTitleGrammarCeiling)-character grammar ceiling and was cut")
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MLXLectureNotesBackendError.malformedResponse("section title was empty")
        }
        guard !title.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0 == "\t" }) else {
            throw MLXLectureNotesBackendError.malformedResponse("section title contained a line break or tab")
        }
        guard !containsHanIdeograph(title) else {
            throw MLXLectureNotesBackendError.malformedResponse("section title contained Han characters")
        }
        guard title.count <= maximumSectionTitleLength else {
            throw MLXLectureNotesBackendError.malformedResponse("section title exceeded \(maximumSectionTitleLength) characters")
        }
        return title
    }

    /// Whether a raw, untrimmed title string filled a grammar `maxLength` of
    /// `ceiling`. Guided decoding permits only the closing quote once a
    /// string reaches its `maxLength`, so such a title was cut by the
    /// grammar, not ended by the model. Counted in Unicode scalars, the
    /// grammar's unit.
    static func sectionTitleFilledGrammarCeiling(_ rawTitle: String, ceiling: Int) -> Bool {
        rawTitle.unicodeScalars.count >= ceiling
    }

    // MARK: - Section summaries → overview (per-section reduction if needed)

    /// One summary of one or two sentences per fixed section, in order —
    /// each from its own request that sees only that section's notes, so a
    /// summary can only describe its own section. Calls run sequentially;
    /// any section's failure aborts synthesis (no placeholder or borrowed
    /// summary).
    private func generateSectionSummaries(sectionItems: [[LectureNoteItem]]) async throws -> [String] {
        var summaries: [String] = []
        for items in sectionItems {
            try Task.checkCancellation()
            summaries.append(try await generateSectionSummary(items: items))
        }
        return summaries
    }

    /// One section's summary. If its plain bodies do not fit, only this
    /// section's notes are condensed (hierarchical reduction, bounded by
    /// `maxReductionLevels`).
    private func generateSectionSummary(items: [LectureNoteItem]) async throws -> String {
        var currentItems = items
        var prompt = Self.encodeSectionSummaryPrompt(sectionBodies: currentItems.map(\.body))
        var level = 0
        while true {
            do {
                try await requirePreparedInputFits(instructions: Self.sectionSummaryInstructions, prompt: prompt, stage: .sectionSummaries)
                break
            } catch let error as MLXLectureNotesBackendError {
                guard case .contextBudgetExceeded = error else { throw error }
                guard level < maxReductionLevels else { throw error }
            }
            try Task.checkCancellation()
            let batches = try await makeContextSafeReductionBatches(currentItems, depth: 0)
            currentItems = try await reduceChunks(batches)
            prompt = Self.encodeSectionSummaryPrompt(sectionBodies: currentItems.map(\.body))
            level += 1
        }

        try Task.checkCancellation()
        // The retry resends this identical greedy request (it exists for
        // the shared malformed-output policy); it adds no model diversity.
        return try await withGeneratedOutputRetry {
            let outcome = try await dispatch(
                instructions: Self.sectionSummaryInstructions,
                prompt: prompt,
                jsonSchema: Self.sectionSummaryJSONSchema,
                maxOutputTokens: responseReserves.reserve(for: .sectionSummaries),
                sampling: nil
            )
            let dto = try Self.decode(MLXSectionSummariesDTO.self, from: outcome.jsonText)
            return try Self.validatedSectionSummary(dto)
        }
    }

    /// Validates one section's summary. Fails closed — never truncating,
    /// appending punctuation, splitting, dropping, combining, or inventing
    /// text — when the response does not hold exactly one summary, or the
    /// summary is empty, contains a line break, tab, or Han character, is
    /// longer than `maximumSectionSummaryLength`, does not end with `.`,
    /// `?`, or `!`, or is not one or two sentences.
    static func validatedSectionSummary(_ dto: MLXSectionSummariesDTO) throws -> String {
        guard dto.sectionSummaries.count == 1, let rawSummary = dto.sectionSummaries.first else {
            throw MLXLectureNotesBackendError.malformedResponse(
                "section summary count was \(dto.sectionSummaries.count); expected 1"
            )
        }
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw MLXLectureNotesBackendError.malformedResponse("section summary was empty")
        }
        guard !summary.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0 == "\t" }) else {
            throw MLXLectureNotesBackendError.malformedResponse("section summary contained a line break or tab")
        }
        guard !containsHanIdeograph(summary) else {
            throw MLXLectureNotesBackendError.malformedResponse("section summary contained Han characters")
        }
        guard summary.count <= Self.maximumSectionSummaryLength else {
            throw MLXLectureNotesBackendError.malformedResponse("section summary exceeded \(Self.maximumSectionSummaryLength) characters")
        }
        guard let last = summary.last, ".?!".contains(last) else {
            throw MLXLectureNotesBackendError.malformedResponse("section summary was not a complete sentence")
        }
        let sentences = sectionSummarySentenceCount(summary)
        guard (1...Self.maximumSectionSummarySentences).contains(sentences) else {
            throw MLXLectureNotesBackendError.malformedResponse("section summary had \(sentences) sentences; expected 1 or 2")
        }
        return summary
    }

    /// Counts sentences deterministically: each maximal run of `.`, `?`,
    /// `!`, or `…` ends a sentence when it closes the text, or when
    /// whitespace and then an uppercase letter follow it — except a run of
    /// periods after a known abbreviation (`sectionSummaryAbbreviations`) or
    /// a single uppercase initial. So "3.14", "V = IR." inside a clause,
    /// "e.g. friction", and "Is it? yes" do not split; an unrecognized
    /// abbreviation before a capitalized word counts as a boundary.
    static func sectionSummarySentenceCount(_ text: String) -> Int {
        let characters = Array(text)
        let terminators: Set<Character> = [".", "?", "!", "…"]
        var count = 0
        var index = 0
        while index < characters.count {
            guard terminators.contains(characters[index]) else {
                index += 1
                continue
            }
            let runStart = index
            while index < characters.count, terminators.contains(characters[index]) { index += 1 }
            let run = characters[runStart..<index]
            if index == characters.count {
                count += 1
                break
            }
            var next = index
            while next < characters.count, characters[next].isWhitespace { next += 1 }
            guard next > index, next < characters.count, characters[next].isUppercase else { continue }
            if run.allSatisfy({ $0 == "." }) {
                var wordStart = runStart
                while wordStart > 0, !characters[wordStart - 1].isWhitespace { wordStart -= 1 }
                let word = String(characters[wordStart..<runStart])
                let isInitial = word.count == 1 && word.first?.isUppercase == true
                if isInitial || Self.sectionSummaryAbbreviations.contains(word.lowercased()) { continue }
            }
            count += 1
        }
        return count
    }

    /// Splits `items` into context-safe reduction batches, bisecting and
    /// recursing whenever a candidate batch does not fit the `.reduction`
    /// stage's reserve.
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
                    maxOutputTokens: responseReserves.reserve(for: .reduction),
                    sampling: nil
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

    private func validateProvenanceCompatibility(_ generation: LectureNotesGenerationRecord) throws {
        guard
            generation.provenance.backendIdentifier == MLXNotesConfiguration.backendIdentifier,
            generation.provenance.generatorIdentifier == modelDescriptor.modelIdentifier,
            generation.provenance.generatorVersion == modelDescriptor.modelRevision,
            generation.provenance.recipeVersion == MLXNotesConfiguration.recipeVersion
        else {
            throw MLXLectureNotesBackendError.incompatibleProvenance
        }
    }

    // MARK: - Retry

    private func withGeneratedOutputRetry<Output>(
        _ operation: () async throws -> Output
    ) async throws -> Output {
        try await withGeneratedOutputRetry { _ in try await operation() }
    }

    /// As above, passing the 1-based attempt number so a caller can adjust
    /// its retry request.
    private func withGeneratedOutputRetry<Output>(
        _ operation: (Int) async throws -> Output
    ) async throws -> Output {
        for attempt in 1...Self.maximumGeneratedOutputAttempts {
            try Task.checkCancellation()
            do {
                return try await operation(attempt)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MLXLectureNotesBackendError {
                let isRetryable: Bool
                switch error {
                case .malformedResponse:
                    isRetryable = true
                case .invalidSourceReference, .incompleteOutput,
                     .incompatibleProvenance, .contextBudgetExceeded,
                     .contextPreflightUnavailable, .configurationFailure, .runtimeFailure:
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
        instructions: String, prompt: String, jsonSchema: String, maxOutputTokens: Int,
        sampling: MLXGuidedSampling?
    ) async throws -> MLXGuidedGenerationOutcome {
        do {
            return try await sessionDriver.respond(
                instructions: instructions, prompt: prompt, jsonSchema: jsonSchema, maxOutputTokens: maxOutputTokens,
                sampling: sampling
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MLXGuidedGenerationRuntimeError {
            switch error {
            case .incompleteOutput(let detail):
                throw MLXLectureNotesBackendError.incompleteOutput(detail)
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

    /// One section's summary input: only that section's notes, as plain
    /// bodies — no other section's notes, section number, source ranges,
    /// item kinds, fidelity labels, or reconstruction notes, and no numeric
    /// length target.
    static func encodeSectionSummaryPrompt(sectionBodies: [String]) -> String {
        let header = "Summarize this lecture section in one or two concise sentences."
        return ([header, ""] + ["Notes in this lecture section:"] + sectionBodies.map { "- \($0)" }).joined(separator: "\n")
    }

    /// One window's topic-label input: only that window's notes, as plain
    /// bodies — no other window's notes, window number, source ranges, item
    /// kinds, fidelity labels, or reconstruction notes.
    static func encodeWindowTopicPrompt(windowBodies: [String]) -> String {
        (["Notes in this lecture segment:"] + windowBodies.map { "- \($0)" }).joined(separator: "\n")
    }

    /// One section's title input: only that section's validated summary.
    static func encodeSectionTitlePrompt(sectionSummary: String) -> String {
        "Summary of this lecture section:\n\(sectionSummary)"
    }

    /// Labels each line with its source sequence range — used only for
    /// reduction, whose response items must reuse source `sequenceRange`s.
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
        } catch let error as DecodingError {
            throw MLXLectureNotesBackendError.malformedResponse(
                "could not decode JSON: \(Self.safeDecodingErrorDescription(error, rawText: jsonText))"
            )
        } catch {
            throw MLXLectureNotesBackendError.malformedResponse("could not decode JSON: \(error.localizedDescription)")
        }
    }

    /// A privacy-safe description of a `DecodingError` — category, coding
    /// path (key names/indexes only), expected type, and the framework's
    /// own structural debug description, plus (for a malformed top-level
    /// payload) size/shape metadata that never includes the actual
    /// generated text. Never includes the raw JSON, transcript content, or
    /// generated Notes bodies — only structural facts about the payload.
    private static func safeDecodingErrorDescription(_ error: DecodingError, rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValidJSONSyntax = (try? JSONSerialization.jsonObject(with: Data(rawText.utf8))) != nil
        let shape = "utf8Bytes=\(rawText.utf8.count) empty=\(trimmed.isEmpty) startsWithBrace=\(trimmed.first == "{") endsWithBrace=\(trimmed.last == "}") validJSONSyntax=\(isValidJSONSyntax)"

        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.isEmpty ? "<root>" : codingPath.map(\.stringValue).joined(separator: ".")
        }

        switch error {
        case .dataCorrupted(let context):
            return "dataCorrupted at \(path(context.codingPath)): \(context.debugDescription) [\(shape)]"
        case .keyNotFound(let key, let context):
            return "keyNotFound '\(key.stringValue)' at \(path(context.codingPath)) [\(shape)]"
        case .typeMismatch(let type, let context):
            return "typeMismatch expected \(type) at \(path(context.codingPath)) [\(shape)]"
        case .valueNotFound(let type, let context):
            return "valueNotFound expected \(type) at \(path(context.codingPath)) [\(shape)]"
        @unknown default:
            return "unknownDecodingError [\(shape)]"
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
        let validatedReferences = try dto.sourceReferences.map { reference -> NotesSourceReference in
            guard Self.range(reference.firstSequenceNumber, reference.lastSequenceNumber, isContainedIn: allowedSequences) else {
                throw MLXLectureNotesBackendError.invalidSourceReference(
                    firstSequenceNumber: reference.firstSequenceNumber,
                    lastSequenceNumber: reference.lastSequenceNumber,
                    allowedSequenceNumbers: allowedSequences.sorted()
                )
            }
            return NotesSourceReference(
                sessionID: sessionID,
                firstSequenceNumber: reference.firstSequenceNumber,
                lastSequenceNumber: reference.lastSequenceNumber
            )
        }
        var references: [NotesSourceReference] = []
        for reference in validatedReferences {
            let isExactDuplicate = references.contains {
                $0.firstSequenceNumber == reference.firstSequenceNumber
                    && $0.lastSequenceNumber == reference.lastSequenceNumber
            }
            guard !isExactDuplicate else { continue }
            references.append(reference)
        }
        guard
            MLXNoteVocabulary.itemKinds.contains(dto.kind),
            let kind = LectureNoteItemKind(rawValue: dto.kind)
        else {
            throw MLXLectureNotesBackendError.malformedResponse("unrecognized item kind \(dto.kind)")
        }
        guard
            MLXNoteVocabulary.generatedNoteFidelities.contains(dto.fidelity),
            let fidelity = LectureNoteContentFidelity(rawValue: dto.fidelity)
        else {
            throw MLXLectureNotesBackendError.malformedResponse("unrecognized fidelity \(dto.fidelity)")
        }
        let rawNote = dto.uncertaintyNote ?? ""
        let trimmedUncertaintyNote = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let uncertaintyNote: String?
        if fidelity == .transcriptSupported {
            uncertaintyNote = trimmedUncertaintyNote.isEmpty ? nil : rawNote
        } else {
            guard !trimmedUncertaintyNote.isEmpty else {
                throw MLXLectureNotesBackendError.malformedResponse("reconstructed item omitted uncertainty context")
            }
            uncertaintyNote = rawNote
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

    /// Maps one new window-analysis item through the same validation as
    /// every MLX item (non-empty body, recognized kind, references inside
    /// this window, exact duplicate references collapsed in first-occurrence
    /// order). New MLX Notes are always transcriptSupported: the model never
    /// chooses fidelity, and new generation never claims a reconstruction.
    static func mapAnalysisItem(
        _ dto: MLXAnalysisNoteItemDTO, sessionID: UUID, allowedSequences: Set<Int>
    ) throws -> LectureNoteItem {
        try mapItem(
            MLXNoteItemDTO(
                kind: dto.kind,
                body: dto.body,
                fidelity: LectureNoteContentFidelity.transcriptSupported.rawValue,
                sourceReferences: dto.sourceReferences,
                uncertaintyNote: nil
            ),
            sessionID: sessionID,
            allowedSequences: allowedSequences
        )
    }

    private static func range(_ first: Int, _ last: Int, isContainedIn allowed: Set<Int>) -> Bool {
        guard first <= last else { return false }
        for sequence in first...last where !allowed.contains(sequence) {
            return false
        }
        return true
    }

    /// Balanced contiguous section window ranges for `windowCount` ordered
    /// windows — computed from the count alone, never from lecture text.
    /// Aims for `preferredWindowsPerSection` windows per section
    /// (round(windowCount / 2.5) sections), raised so no section exceeds
    /// `maximumWindowsPerSection` windows and capped at
    /// `maximumSectionsPerDocument`; sizes differ by at most one window, the
    /// larger sections first. A window count that would need more than
    /// eight 3-window sections (over 24 windows, about 96 minutes — beyond
    /// the 60–90 minute target) fails closed rather than creating an
    /// oversized section.
    static func balancedSectionWindowRanges(windowCount: Int) throws -> [ClosedRange<Int>] {
        guard windowCount > 0 else {
            throw MLXLectureNotesBackendError.malformedResponse("section partition had no windows")
        }
        let fewestSections = (windowCount + Self.maximumWindowsPerSection - 1) / Self.maximumWindowsPerSection
        guard fewestSections <= Self.maximumSectionsPerDocument else {
            throw MLXLectureNotesBackendError.contextBudgetExceeded(
                "detailed sections (\(windowCount) note windows exceed the supported \(Self.maximumSectionsPerDocument * Self.maximumWindowsPerSection))"
            )
        }
        let preferred = Int((Double(windowCount) / Self.preferredWindowsPerSection).rounded())
        let sectionCount = min(Self.maximumSectionsPerDocument, max(fewestSections, preferred, 1))
        let baseSize = windowCount / sectionCount
        let largerSections = windowCount % sectionCount
        var ranges: [ClosedRange<Int>] = []
        var start = 0
        for index in 0..<sectionCount {
            let size = baseSize + (index < largerSections ? 1 : 0)
            ranges.append(start...(start + size - 1))
            start += size
        }
        return ranges
    }

    /// The notes of each balanced section: every item of every window in a
    /// section's window range, in order — always the already-committed items
    /// themselves. Defensively checks that every window and every item
    /// appears exactly once, in order.
    static func sectionItemGroups(windowItems: [[LectureNoteItem]]) throws -> [[LectureNoteItem]] {
        let ranges = try balancedSectionWindowRanges(windowCount: windowItems.count)
        guard ranges.first?.lowerBound == 0, ranges.last?.upperBound == windowItems.count - 1,
              zip(ranges, ranges.dropFirst()).allSatisfy({ $0.upperBound + 1 == $1.lowerBound }),
              ranges.allSatisfy({ (1...Self.maximumWindowsPerSection).contains($0.count) })
        else {
            throw MLXLectureNotesBackendError.malformedResponse("section partition did not cover every window exactly once")
        }
        let groups = ranges.map { windowItems[$0].flatMap { $0 } }
        guard groups.allSatisfy({ !$0.isEmpty }),
              groups.flatMap({ $0 }).map(\.id) == windowItems.flatMap({ $0 }).map(\.id)
        else {
            throw MLXLectureNotesBackendError.malformedResponse("section partition did not cover every item exactly once")
        }
        return groups
    }

    // MARK: - JSON Schemas

    /// Window analysis: each item names its kind, body, and 1 to
    /// `maximumWindowAnalysisSourceReferences` source references, each a
    /// contiguous range of this window's own units. No fidelity — every
    /// accepted new item is transcriptSupported (see `mapAnalysisItem`).
    static func windowAnalysisJSONSchema(allowedSequenceNumbers: [Int]) -> String {
        let validRanges = Self.validContiguousSourceRanges(allowedSequenceNumbers: allowedSequenceNumbers)
        precondition(!validRanges.isEmpty, "window analysis requires at least one source unit")
        let alternatives = validRanges.map { range in
            """
            {
              "type": "object",
              "properties": {
                "firstSequenceNumber": { "type": "integer", "const": \(range.first) },
                "lastSequenceNumber": { "type": "integer", "const": \(range.last) }
              },
              "required": ["firstSequenceNumber", "lastSequenceNumber"]
            }
            """
        }.joined(separator: ",\n")
        return """
        {
          "type": "object",
          "properties": {
            "items": {
              "type": "array",
              "maxItems": \(Self.maximumWindowAnalysisItems),
              "items": {
                "type": "object",
                "properties": {
                  "kind": { "type": "string", "enum": \(Self.jsonArray(MLXNoteVocabulary.itemKinds)) },
                  "body": { "type": "string", "maxLength": \(Self.maximumWindowAnalysisBodyLength) },
                  "sourceReferences": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": \(Self.maximumWindowAnalysisSourceReferences),
                    "items": { "anyOf": [
        \(alternatives)
                    ] }
                  }
                },
                "required": ["kind", "body", "sourceReferences"],
                "additionalProperties": false
              }
            }
          },
          "required": ["items"]
        }
        """
    }

    static let noteItemsJSONSchema = Self.makeNoteItemsJSONSchema(
        sourceReferenceItemSchema: """
        {
          "type": "object",
          "properties": {
            "firstSequenceNumber": { "type": "integer" },
            "lastSequenceNumber": { "type": "integer" }
          },
          "required": ["firstSequenceNumber", "lastSequenceNumber"]
        }
        """
    )

    /// One title of 1 to `sectionTitleGrammarCeiling` characters (an
    /// emergency grammar ceiling, not a product limit) and nothing else.
    static let sectionTitleJSONSchema = """
    {
      "type": "object",
      "properties": {
        "title": { "type": "string", "minLength": 1, "maxLength": \(Self.sectionTitleGrammarCeiling) }
      },
      "required": ["title"],
      "additionalProperties": false
    }
    """

    /// 1 to 3 topic terms of 1 to `windowTopicTermSchemaMaxLength`
    /// characters (a grammar safety ceiling, not a product limit) and
    /// nothing else: no window number, boundary, or range.
    static let windowTopicJSONSchema = """
    {
      "type": "object",
      "properties": {
        "topicTerms": {
          "type": "array",
          "minItems": \(Self.windowTopicTermCount.lowerBound),
          "maxItems": \(Self.windowTopicTermCount.upperBound),
          "items": { "type": "string", "minLength": 1, "maxLength": \(Self.windowTopicTermSchemaMaxLength) }
        }
      },
      "required": ["topicTerms"],
      "additionalProperties": false
    }
    """

    /// Exactly one summary string of 1 to `sectionSummaryGrammarCeiling`
    /// characters — nothing else. The ceiling sits above the accepted length
    /// only to stop a runaway reply; `validatedSectionSummary` enforces the
    /// accepted length.
    static let sectionSummaryJSONSchema = """
    {
      "type": "object",
      "properties": {
        "sectionSummaries": {
          "type": "array",
          "minItems": 1,
          "maxItems": 1,
          "items": { "type": "string", "minLength": 1, "maxLength": \(sectionSummaryGrammarCeiling) }
        }
      },
      "required": ["sectionSummaries"],
      "additionalProperties": false
    }
    """

    private static func validContiguousSourceRanges(
        allowedSequenceNumbers: [Int]
    ) -> [(first: Int, last: Int)] {
        let sortedSequenceNumbers = Array(Set(allowedSequenceNumbers)).sorted()
        var ranges: [(first: Int, last: Int)] = []
        for startIndex in sortedSequenceNumbers.indices {
            var previous = sortedSequenceNumbers[startIndex]
            for endIndex in startIndex..<sortedSequenceNumbers.endIndex {
                let end = sortedSequenceNumbers[endIndex]
                if endIndex > startIndex {
                    let (expected, overflow) = previous.addingReportingOverflow(1)
                    guard !overflow, end == expected else { break }
                }
                ranges.append((first: sortedSequenceNumbers[startIndex], last: end))
                previous = end
            }
        }
        return ranges
    }

    /// Reduction's item schema. One `anyOf` variant per generated fidelity
    /// moves `mapItem`'s rules into the grammar: `uncertain` has no variant,
    /// and every item carries an `uncertaintyNote`, non-empty for
    /// reconstructed items. `mapItem` still validates as defense in depth.
    private static func makeNoteItemsJSONSchema(sourceReferenceItemSchema: String) -> String {
        let variants = MLXNoteVocabulary.generatedNoteFidelities.map { fidelity in
            let isReconstructed = fidelity == LectureNoteContentFidelity.reconstructed.rawValue
            return """
            {
              "type": "object",
              "properties": {
                "kind": { "type": "string", "enum": \(Self.jsonArray(MLXNoteVocabulary.itemKinds)) },
                "body": {
                  "type": "string",
                  "maxLength": \(Self.maximumWindowAnalysisBodyLength)
                },
                "fidelity": { "type": "string", "enum": \(Self.jsonArray([fidelity])) },
                "sourceReferences": {
                  "type": "array",
                  "minItems": 1,
                  "maxItems": \(Self.maximumWindowAnalysisSourceReferences),
                  "items": \(sourceReferenceItemSchema)
                },
                "uncertaintyNote": {
                  "type": "string",
                  \(isReconstructed ? "\"minLength\": 1,\n" : "")"maxLength": \(Self.maximumWindowAnalysisUncertaintyNoteLength)
                }
              },
              "required": ["kind", "body", "fidelity", "sourceReferences", "uncertaintyNote"]
            }
            """
        }.joined(separator: ",\n")
        return """
        {
          "type": "object",
          "properties": {
            "items": {
              "type": "array",
              "maxItems": \(Self.maximumWindowAnalysisItems),
              "items": {
                "anyOf": [
        \(variants)
                ]
              }
            }
          },
          "required": ["items"]
        }
        """
    }

    private static func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }
}
