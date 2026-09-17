import Foundation

nonisolated enum LectureSummaryIntegrityError: LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case sessionIdentityMismatch
    case generationIdentityMismatch
    case sourceNotesGenerationIdentityMismatch
    case transcriptFingerprintMismatch
    case notesDocumentFingerprintMismatch
    case provenanceMissing
    case provenanceMismatch
    case invalidSourceSnapshot
    case invalidPlan(LectureSummaryPlanValidationError)
    case planDoesNotMatchSource
    case batchNotInPlan(Int)
    case batchIdentityMismatch(Int)
    case emptyAnalysis(Int)
    case supportingItemOutsideBatch(UUID)
    case supportingItemOutsideSource(UUID)
    case emptyPassageText
    case emptySupport
    case duplicateSupportingItem(UUID)
    case supportingItemsOutOfOrder
    case sourceReferencesMismatch
    case fidelityTooStrong
    case uncertaintyExplanationRequired
    case duplicatePassageID(UUID)
    case duplicateSectionID(UUID)
    case emptyDocument
    case emptySectionHeading
    case emptySection(UUID)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let value): return "Summary artifact schema version \(value) is unsupported."
        case .sessionIdentityMismatch: return "Summary session identity does not match."
        case .generationIdentityMismatch: return "Summary generation identity does not match."
        case .sourceNotesGenerationIdentityMismatch: return "Summary source Notes generation identity does not match."
        case .transcriptFingerprintMismatch: return "Summary transcript fingerprint does not match."
        case .notesDocumentFingerprintMismatch: return "Summary source Notes document fingerprint does not match."
        case .provenanceMissing: return "Summary generator provenance is missing a recipe version."
        case .provenanceMismatch: return "Summary generator provenance does not match its generation."
        case .invalidSourceSnapshot: return "The frozen Summary source snapshot is structurally invalid."
        case .invalidPlan(let underlying): return underlying.errorDescription
        case .planDoesNotMatchSource: return "Summary batch plan is not the deterministic plan for its source and limits."
        case .batchNotInPlan(let index): return "Summary batch #\(index) is not in the frozen plan."
        case .batchIdentityMismatch(let index): return "Summary batch #\(index) identity does not match the frozen plan."
        case .emptyAnalysis(let index): return "Summary batch #\(index) contains no grounded passages."
        case .supportingItemOutsideBatch(let id): return "Supporting Note item \(id.uuidString) is outside the assigned batch."
        case .supportingItemOutsideSource(let id): return "Supporting Note item \(id.uuidString) is outside the frozen source."
        case .emptyPassageText: return "A Summary passage has empty explanatory text."
        case .emptySupport: return "A Summary passage has no supporting Note items."
        case .duplicateSupportingItem(let id): return "A Summary passage repeats supporting Note item \(id.uuidString)."
        case .supportingItemsOutOfOrder: return "Summary passage support IDs are not in canonical source order."
        case .sourceReferencesMismatch: return "Summary passage transcript references are not the exact ordered union derived from its supporting Note items."
        case .fidelityTooStrong: return "Summary passage fidelity is stronger than its supporting Notes permit."
        case .uncertaintyExplanationRequired: return "A reconstructed or uncertain Summary passage requires a nonempty explanation."
        case .duplicatePassageID(let id): return "Summary passage ID \(id.uuidString) is duplicated."
        case .duplicateSectionID(let id): return "Summary section ID \(id.uuidString) is duplicated."
        case .emptyDocument: return "A completed Summary document must contain at least one section."
        case .emptySectionHeading: return "A Summary section heading is empty."
        case .emptySection(let id): return "Summary section \(id.uuidString) contains no passages."
        }
    }
}

nonisolated enum LectureSummaryIntegrityValidator {
    static func validate(
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) throws {
        try validateSourceSnapshotStructure(source)
        guard generation.schemaVersion == LectureSummaryGenerationRecord.currentSchemaVersion else {
            throw LectureSummaryIntegrityError.unsupportedSchemaVersion(generation.schemaVersion)
        }
        do {
            try generation.batchPlan.validateStructure()
        } catch let error as LectureSummaryPlanValidationError {
            throw LectureSummaryIntegrityError.invalidPlan(error)
        }
        try validateSourceIdentity(generation: generation, source: source)
        try validateProvenance(generation.provenance)
        guard let budget = try? LectureSummaryBatchBudget(
            maxSerializedBytesPerBatch: generation.batchPlan.maxSerializedBytesPerBatch,
            maxItemsPerBatch: generation.batchPlan.maxItemsPerBatch
        ), let expected = try? LectureSummaryPlanner.plan(source: source, budget: budget),
              expected == generation.batchPlan else {
            throw LectureSummaryIntegrityError.planDoesNotMatchSource
        }
    }

    static func validate(
        analysis: LectureSummaryAnalysis,
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) throws {
        guard analysis.schemaVersion == LectureSummaryAnalysis.currentSchemaVersion else {
            throw LectureSummaryIntegrityError.unsupportedSchemaVersion(analysis.schemaVersion)
        }
        try validate(generation: generation, source: source)
        try validateArtifactIdentity(
            generationID: analysis.generationID,
            sessionID: analysis.sessionID,
            sourceNotesGenerationID: analysis.sourceNotesGenerationID,
            transcriptFingerprint: analysis.transcriptFingerprint,
            notesDocumentFingerprint: analysis.sourceNotesDocumentFingerprint,
            provenance: analysis.provenance,
            generation: generation
        )
        guard let batch = generation.batchPlan.batches.first(where: { $0.batchIndex == analysis.batchIndex }) else {
            throw LectureSummaryIntegrityError.batchNotInPlan(analysis.batchIndex)
        }
        guard analysis.batchID == batch.batchID else {
            throw LectureSummaryIntegrityError.batchIdentityMismatch(analysis.batchIndex)
        }
        guard !analysis.passages.isEmpty else {
            throw LectureSummaryIntegrityError.emptyAnalysis(analysis.batchIndex)
        }
        var passageIDs: Set<UUID> = []
        for passage in analysis.passages {
            guard passageIDs.insert(passage.id).inserted else {
                throw LectureSummaryIntegrityError.duplicatePassageID(passage.id)
            }
            for id in passage.supportingNoteItemIDs where !batch.sourceItemIDs.contains(id) {
                throw LectureSummaryIntegrityError.supportingItemOutsideBatch(id)
            }
            try validate(passage: passage, source: source)
        }
    }

    static func validate(
        document: LectureSummaryDocument,
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) throws {
        guard document.schemaVersion == LectureSummaryDocument.currentSchemaVersion else {
            throw LectureSummaryIntegrityError.unsupportedSchemaVersion(document.schemaVersion)
        }
        try validate(generation: generation, source: source)
        try validateArtifactIdentity(
            generationID: document.generationID,
            sessionID: document.sessionID,
            sourceNotesGenerationID: document.sourceNotesGenerationID,
            transcriptFingerprint: document.transcriptFingerprint,
            notesDocumentFingerprint: document.sourceNotesDocumentFingerprint,
            provenance: document.provenance,
            generation: generation
        )
        guard !document.sections.isEmpty else { throw LectureSummaryIntegrityError.emptyDocument }
        var sectionIDs: Set<UUID> = []
        var passageIDs: Set<UUID> = []
        for section in document.sections {
            guard sectionIDs.insert(section.id).inserted else {
                throw LectureSummaryIntegrityError.duplicateSectionID(section.id)
            }
            guard !section.heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LectureSummaryIntegrityError.emptySectionHeading
            }
            guard !section.passages.isEmpty else { throw LectureSummaryIntegrityError.emptySection(section.id) }
            for passage in section.passages {
                guard passageIDs.insert(passage.id).inserted else {
                    throw LectureSummaryIntegrityError.duplicatePassageID(passage.id)
                }
                try validate(passage: passage, source: source)
            }
        }
    }

    static func derivedSourceReferences(
        supportingItemIDs: [UUID],
        source: LectureSummarySourceSnapshot
    ) throws -> [NotesSourceReference] {
        var seen: Set<ReferenceKey> = []
        var result: [NotesSourceReference] = []
        for id in supportingItemIDs {
            let matches = source.sourceItems.filter { $0.item.id == id }
            guard matches.count == 1, let item = matches.first?.item else {
                throw LectureSummaryIntegrityError.supportingItemOutsideSource(id)
            }
            for reference in item.sourceReferences {
                let key = ReferenceKey(reference)
                if seen.insert(key).inserted { result.append(reference) }
            }
        }
        return result
    }

    private static func validate(passage: LectureSummaryPassage, source: LectureSummarySourceSnapshot) throws {
        guard !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LectureSummaryIntegrityError.emptyPassageText
        }
        guard !passage.supportingNoteItemIDs.isEmpty else { throw LectureSummaryIntegrityError.emptySupport }
        var seen: Set<UUID> = []
        for id in passage.supportingNoteItemIDs {
            guard seen.insert(id).inserted else { throw LectureSummaryIntegrityError.duplicateSupportingItem(id) }
        }
        let indices = try passage.supportingNoteItemIDs.map { id -> Int in
            let matches = source.sourceItems.filter { $0.item.id == id }
            guard matches.count == 1, let index = matches.first?.sourceIndex else {
                throw LectureSummaryIntegrityError.supportingItemOutsideSource(id)
            }
            return index
        }
        guard indices == indices.sorted() else { throw LectureSummaryIntegrityError.supportingItemsOutOfOrder }
        guard passage.sourceReferences == (try derivedSourceReferences(
            supportingItemIDs: passage.supportingNoteItemIDs,
            source: source
        )) else { throw LectureSummaryIntegrityError.sourceReferencesMismatch }

        let items = passage.supportingNoteItemIDs.compactMap { id in
            source.sourceItems.first(where: { $0.item.id == id })?.item
        }
        let requiredRank = items.map { fidelityRank($0.fidelity) }.max() ?? 0
        guard fidelityRank(passage.fidelity) >= requiredRank else {
            throw LectureSummaryIntegrityError.fidelityTooStrong
        }
        if passage.fidelity != .transcriptSupported {
            guard let explanation = passage.uncertaintyNote,
                  !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LectureSummaryIntegrityError.uncertaintyExplanationRequired
            }
        }
    }

    private static func validateSourceIdentity(
        generation: LectureSummaryGenerationRecord,
        source: LectureSummarySourceSnapshot
    ) throws {
        guard generation.sessionID == source.sessionID else { throw LectureSummaryIntegrityError.sessionIdentityMismatch }
        guard generation.sourceNotesGenerationID == source.sourceNotesGenerationID else {
            throw LectureSummaryIntegrityError.sourceNotesGenerationIdentityMismatch
        }
        guard generation.transcriptFingerprint == source.transcriptFingerprint else {
            throw LectureSummaryIntegrityError.transcriptFingerprintMismatch
        }
        guard generation.sourceNotesDocumentFingerprint == source.sourceNotesDocumentFingerprint else {
            throw LectureSummaryIntegrityError.notesDocumentFingerprintMismatch
        }
    }

    private static func validateSourceSnapshotStructure(_ source: LectureSummarySourceSnapshot) throws {
        guard source.schemaVersion == LectureSummarySourceSnapshot.currentSchemaVersion,
              !source.sourceItems.isEmpty,
              source.sourceItems.map(\.sourceIndex) == Array(0..<source.sourceItems.count),
              Set(source.sourceItems.map(\.item.id)).count == source.sourceItems.count,
              source.transcriptFingerprint.algorithmVersion == TranscriptSourceFingerprint.currentAlgorithmVersion,
              source.sourceNotesDocumentFingerprint.algorithmVersion == NotesDocumentFingerprint.currentAlgorithmVersion,
              source.transcriptFingerprint.digestHex.count == 64,
              source.sourceNotesDocumentFingerprint.digestHex.count == 64 else {
            throw LectureSummaryIntegrityError.invalidSourceSnapshot
        }
    }

    private static func validateArtifactIdentity(
        generationID: UUID,
        sessionID: UUID,
        sourceNotesGenerationID: UUID,
        transcriptFingerprint: TranscriptSourceFingerprint,
        notesDocumentFingerprint: NotesDocumentFingerprint,
        provenance: LectureNotesGenerationProvenance,
        generation: LectureSummaryGenerationRecord
    ) throws {
        guard sessionID == generation.sessionID else { throw LectureSummaryIntegrityError.sessionIdentityMismatch }
        guard generationID == generation.generationID else { throw LectureSummaryIntegrityError.generationIdentityMismatch }
        guard sourceNotesGenerationID == generation.sourceNotesGenerationID else {
            throw LectureSummaryIntegrityError.sourceNotesGenerationIdentityMismatch
        }
        guard transcriptFingerprint == generation.transcriptFingerprint else {
            throw LectureSummaryIntegrityError.transcriptFingerprintMismatch
        }
        guard notesDocumentFingerprint == generation.sourceNotesDocumentFingerprint else {
            throw LectureSummaryIntegrityError.notesDocumentFingerprintMismatch
        }
        guard provenance == generation.provenance else { throw LectureSummaryIntegrityError.provenanceMismatch }
    }

    private static func validateProvenance(_ provenance: LectureNotesGenerationProvenance) throws {
        guard !provenance.recipeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LectureSummaryIntegrityError.provenanceMissing
        }
    }

    private static func fidelityRank(_ fidelity: LectureNoteContentFidelity) -> Int {
        switch fidelity {
        case .transcriptSupported: return 0
        case .reconstructed: return 1
        case .uncertain: return 2
        }
    }

    private struct ReferenceKey: Hashable {
        let sessionID: UUID
        let first: Int
        let last: Int

        init(_ reference: NotesSourceReference) {
            sessionID = reference.sessionID
            first = reference.firstSequenceNumber
            last = reference.lastSequenceNumber
        }
    }
}
