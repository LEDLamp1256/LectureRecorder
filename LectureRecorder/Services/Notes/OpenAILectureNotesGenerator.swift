import Foundation

/// OpenAI-specific adapter for the provider-neutral Notes generation
/// protocol. It performs no planning, persistence, recovery, transcript
/// loading, generation identity creation, or cancellation bookkeeping.
nonisolated struct OpenAILectureNotesGenerator: LectureNotesGenerating {
    static let analysisInstructions = """
    Produce substantive technical college-lecture notes from only the supplied transcript window. Preserve concepts, definitions, explanations, derivations and reasoning, formulas and mathematical relationships, algorithms, code or pseudocode, examples, warnings, caveats, instructor emphasis, and genuine uncertainty. Do not reduce the material to a generic short summary.

    Every note item must cite one or more source ranges using only supplied sequenceNumber values. Do not invent chunk indices, timestamps, quotations, facts, notation, constants, operators, equations, code, or derivation steps. Do not supplement the lecture with external knowledge.

    Use fidelity "transcriptSupported" only when the technical meaning and stated precision are directly supported. Use "reconstructed" when notation, code, equations, formatting, or structure is normalized from sufficiently supported spoken material. Use "uncertain" when reconstruction is genuinely ambiguous. For reconstructed or uncertain items, provide a useful uncertaintyNote explaining the normalization or ambiguity. Preserve uncertainty instead of fabricating precision.
    """

    static let synthesisInstructions = """
    Synthesize substantive study notes from only the supplied committed window analyses, in their supplied lecture order. Do not reload or imagine the transcript, re-plan windows, introduce external knowledge, or invent source references. Preserve useful technical depth, examples, reasoning, formulas, code, warnings, caveats, instructor emphasis, and all fidelity/uncertainty distinctions while removing unnecessary repetition.

    Write an overview of roughly 5–10 useful takeaways or topics when the evidence supports that many; do not pad it. Detailed sections must follow lecture order. Every meaningful note item must retain one or more source ranges composed only of sequence numbers already cited by the supplied analyses. Reconstructed and uncertain items must retain useful uncertainty context. The result must be study notes, not merely an abstract.
    """

    private let client: OpenAIResponsesClient

    init(configurationSource: OpenAINotesConfigurationSource, transport: any NotesHTTPTransport) {
        self.client = OpenAIResponsesClient(configurationSource: configurationSource, transport: transport)
    }

    func analyzeWindow(
        units: [NotesTranscriptSourceUnit],
        window: NotesInputWindow,
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesWindowAnalysis {
        let generationModel = try model(for: generation)
        let input = AnalysisInput(window: window, units: units)
        let response = try await client.createStructuredResponse(
            instructions: Self.analysisInstructions,
            input: try encodeInput(input),
            schemaName: "lecture_notes_window_analysis",
            schema: Self.analysisSchema,
            generationModel: generationModel
        )
        try StrictNotesProviderJSON.validateAnalysis(response)
        let dto: ProviderAnalysisDTO
        do {
            dto = try JSONDecoder().decode(ProviderAnalysisDTO.self, from: response)
        } catch {
            throw OpenAINotesBackendError.malformedStructuredResponse
        }
        let allowedSequences = Set(units.map(\.sequenceNumber))
        let items = try dto.items.map {
            try mapItem($0, sessionID: generation.sessionID, allowedSequences: allowedSequences)
        }
        guard !items.isEmpty else {
            throw OpenAINotesBackendError.unsupportedProviderResponse("window analysis contained no note items")
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

    func synthesize(
        analyses: [LectureNotesWindowAnalysis],
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesDocument {
        let generationModel = try model(for: generation)
        let input = SynthesisInput(analyses: analyses)
        let response = try await client.createStructuredResponse(
            instructions: Self.synthesisInstructions,
            input: try encodeInput(input),
            schemaName: "lecture_notes_document",
            schema: Self.documentSchema,
            generationModel: generationModel
        )
        try StrictNotesProviderJSON.validateDocument(response)
        let dto: ProviderDocumentDTO
        do {
            dto = try JSONDecoder().decode(ProviderDocumentDTO.self, from: response)
        } catch {
            throw OpenAINotesBackendError.malformedStructuredResponse
        }
        let allowedSequences = try Self.allowedSequences(in: analyses)
        let sections = try dto.sections.map { section -> LectureNoteSection in
            guard !section.heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenAINotesBackendError.unsupportedProviderResponse("document contained an empty section heading")
            }
            let items = try section.items.map {
                try mapItem($0, sessionID: generation.sessionID, allowedSequences: allowedSequences)
            }
            guard !items.isEmpty else {
                throw OpenAINotesBackendError.unsupportedProviderResponse("document contained an empty section")
            }
            return LectureNoteSection(heading: section.heading, items: items)
        }
        guard !dto.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sections.isEmpty else {
            throw OpenAINotesBackendError.unsupportedProviderResponse("document was empty")
        }
        return LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: dto.overview,
            sections: sections
        )
    }

    private func encodeInput<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw OpenAINotesBackendError.unsupportedProviderResponse("request input could not be encoded")
        }
        return string
    }

    private func model(for generation: LectureNotesGenerationRecord) throws -> String {
        guard
            generation.provenance.recipeVersion == OpenAINotesConfiguration.recipeVersion,
            generation.provenance.generatorIdentifier == OpenAINotesConfiguration.generatorIdentifier,
            generation.provenance.backendIdentifier == OpenAINotesConfiguration.backendIdentifier,
            let model = generation.provenance.generatorVersion,
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OpenAINotesBackendError.unsupportedProviderResponse(
                "generation provenance is not compatible with the OpenAI Responses backend"
            )
        }
        return model
    }

    private func mapItem(
        _ dto: ProviderNoteItemDTO,
        sessionID: UUID,
        allowedSequences: Set<Int>
    ) throws -> LectureNoteItem {
        guard !dto.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAINotesBackendError.unsupportedProviderResponse("note item body was empty")
        }
        guard !dto.sourceReferences.isEmpty else {
            throw OpenAINotesBackendError.unsupportedProviderResponse("note item omitted source references")
        }
        let references = try dto.sourceReferences.map { reference -> NotesSourceReference in
            guard try Self.range(reference.firstSequenceNumber, reference.lastSequenceNumber, isContainedIn: allowedSequences) else {
                throw OpenAINotesBackendError.unsupportedProviderResponse("note item invented a source reference")
            }
            return NotesSourceReference(
                sessionID: sessionID,
                firstSequenceNumber: reference.firstSequenceNumber,
                lastSequenceNumber: reference.lastSequenceNumber
            )
        }
        if dto.fidelity != .transcriptSupported {
            guard let note = dto.uncertaintyNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenAINotesBackendError.unsupportedProviderResponse("reconstructed or uncertain item omitted uncertainty context")
            }
        }
        return LectureNoteItem(
            kind: dto.kind.domainValue,
            title: dto.title,
            body: dto.body,
            fidelity: dto.fidelity.domainValue,
            sourceReferences: references,
            uncertaintyNote: dto.uncertaintyNote
        )
    }

    private static func allowedSequences(in analyses: [LectureNotesWindowAnalysis]) throws -> Set<Int> {
        var result: Set<Int> = []
        for reference in analyses.flatMap(\.items).flatMap(\.sourceReferences) {
            guard reference.firstSequenceNumber <= reference.lastSequenceNumber else {
                throw OpenAINotesBackendError.unsupportedProviderResponse("input analysis contained an invalid source reference")
            }
            var value = reference.firstSequenceNumber
            while true {
                result.insert(value)
                if value == reference.lastSequenceNumber { break }
                let (next, overflowed) = value.addingReportingOverflow(1)
                guard !overflowed else {
                    throw OpenAINotesBackendError.unsupportedProviderResponse("input source reference overflowed")
                }
                value = next
            }
        }
        return result
    }

    private static func range(_ first: Int, _ last: Int, isContainedIn allowed: Set<Int>) throws -> Bool {
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

// MARK: - Provider request DTOs

private nonisolated struct AnalysisInput: Encodable {
    var window: NotesInputWindow
    var units: [NotesTranscriptSourceUnit]
}

private nonisolated struct SynthesisInput: Encodable {
    var analyses: [SynthesisAnalysisInput]

    init(analyses: [LectureNotesWindowAnalysis]) {
        self.analyses = analyses.map(SynthesisAnalysisInput.init)
    }
}

private nonisolated struct SynthesisAnalysisInput: Encodable {
    var windowIndex: Int
    var items: [SynthesisItemInput]

    init(_ analysis: LectureNotesWindowAnalysis) {
        windowIndex = analysis.windowIndex
        items = analysis.items.map(SynthesisItemInput.init)
    }
}

private nonisolated struct SynthesisItemInput: Encodable {
    var kind: String
    var title: String?
    var body: String
    var fidelity: String
    var sourceReferences: [ProviderSourceReferenceDTO]
    var uncertaintyNote: String?

    init(_ item: LectureNoteItem) {
        kind = item.kind.rawValue
        title = item.title
        body = item.body
        fidelity = item.fidelity.rawValue
        sourceReferences = item.sourceReferences.map {
            ProviderSourceReferenceDTO(
                firstSequenceNumber: $0.firstSequenceNumber,
                lastSequenceNumber: $0.lastSequenceNumber
            )
        }
        uncertaintyNote = item.uncertaintyNote
    }
}

// MARK: - Provider response DTOs

private nonisolated struct ProviderAnalysisDTO: Decodable {
    var items: [ProviderNoteItemDTO]
}

private nonisolated struct ProviderDocumentDTO: Decodable {
    var overview: String
    var sections: [ProviderSectionDTO]
}

private nonisolated struct ProviderSectionDTO: Decodable {
    var heading: String
    var items: [ProviderNoteItemDTO]
}

private nonisolated struct ProviderNoteItemDTO: Decodable {
    var kind: ProviderItemKind
    var title: String?
    var body: String
    var fidelity: ProviderFidelity
    var sourceReferences: [ProviderSourceReferenceDTO]
    var uncertaintyNote: String?
}

private nonisolated struct ProviderSourceReferenceDTO: Codable {
    var firstSequenceNumber: Int
    var lastSequenceNumber: Int
}

private nonisolated enum ProviderItemKind: String, Decodable {
    case keyConcept, definition, explanation, example, formula, algorithmOrCode, warning, uncertainty, other

    var domainValue: LectureNoteItemKind { LectureNoteItemKind(rawValue: rawValue)! }
}

private nonisolated enum ProviderFidelity: String, Decodable {
    case transcriptSupported, reconstructed, uncertain

    var domainValue: LectureNoteContentFidelity { LectureNoteContentFidelity(rawValue: rawValue)! }
}

// MARK: - Strict schemas and pre-decoding shape validation

extension OpenAILectureNotesGenerator {
    private static let sourceReferenceSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "firstSequenceNumber": ["type": "integer"],
            "lastSequenceNumber": ["type": "integer"]
        ],
        "required": ["firstSequenceNumber", "lastSequenceNumber"],
        "additionalProperties": false
    ]

    private static var noteItemSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": LectureNoteItemKind.allProviderValues],
                "title": ["type": ["string", "null"]],
                "body": ["type": "string"],
                "fidelity": ["type": "string", "enum": LectureNoteContentFidelity.allProviderValues],
                "sourceReferences": ["type": "array", "items": sourceReferenceSchema],
                "uncertaintyNote": ["type": ["string", "null"]]
            ],
            "required": ["kind", "title", "body", "fidelity", "sourceReferences", "uncertaintyNote"],
            "additionalProperties": false
        ]
    }

    static var analysisSchema: [String: Any] {
        [
            "type": "object",
            "properties": ["items": ["type": "array", "items": noteItemSchema]],
            "required": ["items"],
            "additionalProperties": false
        ]
    }

    static var documentSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "overview": ["type": "string"],
                "sections": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "heading": ["type": "string"],
                            "items": ["type": "array", "items": noteItemSchema]
                        ],
                        "required": ["heading", "items"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["overview", "sections"],
            "additionalProperties": false
        ]
    }
}

private extension LectureNoteItemKind {
    nonisolated static let allProviderValues = [
        keyConcept, definition, explanation, example, formula,
        algorithmOrCode, warning, uncertainty, other
    ].map(\.rawValue)
}

private extension LectureNoteContentFidelity {
    nonisolated static let allProviderValues = [transcriptSupported, reconstructed, uncertain].map(\.rawValue)
}

private nonisolated enum StrictNotesProviderJSON {
    static func validateAnalysis(_ data: Data) throws {
        let root = try object(from: data)
        try exactKeys(root, ["items"])
        try items(root["items"])
    }

    static func validateDocument(_ data: Data) throws {
        let root = try object(from: data)
        try exactKeys(root, ["overview", "sections"])
        guard root["overview"] is String, let sections = root["sections"] as? [Any] else { throw malformed }
        for value in sections {
            guard let section = value as? [String: Any] else { throw malformed }
            try exactKeys(section, ["heading", "items"])
            guard section["heading"] is String else { throw malformed }
            try items(section["items"])
        }
    }

    private static var malformed: OpenAINotesBackendError { .malformedStructuredResponse }

    private static func object(from data: Data) throws -> [String: Any] {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw malformed }
        guard let object = value as? [String: Any] else { throw malformed }
        return object
    }

    private static func exactKeys(_ object: [String: Any], _ expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw malformed }
    }

    private static func items(_ value: Any?) throws {
        guard let values = value as? [Any] else { throw malformed }
        for value in values {
            guard let item = value as? [String: Any] else { throw malformed }
            try exactKeys(item, ["kind", "title", "body", "fidelity", "sourceReferences", "uncertaintyNote"])
            guard item["kind"] is String, item["body"] is String, item["fidelity"] is String else { throw malformed }
            guard item["title"] is String || item["title"] is NSNull else { throw malformed }
            guard item["uncertaintyNote"] is String || item["uncertaintyNote"] is NSNull else { throw malformed }
            guard let references = item["sourceReferences"] as? [Any] else { throw malformed }
            for value in references {
                guard let reference = value as? [String: Any] else { throw malformed }
                try exactKeys(reference, ["firstSequenceNumber", "lastSequenceNumber"])
                guard reference["firstSequenceNumber"] is NSNumber, reference["lastSequenceNumber"] is NSNumber else { throw malformed }
            }
        }
    }
}
