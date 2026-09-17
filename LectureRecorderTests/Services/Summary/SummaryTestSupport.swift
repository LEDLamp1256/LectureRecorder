import Foundation
@testable import LectureRecorder

enum SummaryTestSupport {
    static let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let notesGenerationID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let summaryGenerationID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let itemIDs = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    ]
    static let provenance = LectureNotesGenerationProvenance(
        recipeVersion: "summary-recipe-v1",
        generatorIdentifier: "test-generator",
        generatorVersion: "1",
        backendIdentifier: "test-backend"
    )

    static func transcript() -> NotesTranscriptSourceSnapshot {
        let units = (0..<3).map {
            NotesTranscriptSourceUnit(
                sequenceNumber: $0,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: $0),
                text: "transcript \($0)",
                startOffsetSeconds: Double($0) * 30,
                durationSeconds: 30
            )
        }
        return NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        )
    }

    static func notesEvidence() -> (LectureNotesGenerationRecord, LectureNotesDocument, NotesTranscriptSourceSnapshot, [LectureNotesWindowAnalysis]) {
        let transcript = transcript()
        let generation = LectureNotesGenerationRecord.newGeneration(
            generationID: notesGenerationID,
            sessionID: sessionID,
            transcriptFingerprint: transcript.fingerprint,
            windowPlan: NotesWindowPlan(windows: [
                NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 2, unitCount: 3, isOversizedSingleUnit: false)
            ]),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "notes-recipe-v1"),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let document = LectureNotesDocument(
            generationID: notesGenerationID,
            sessionID: sessionID,
            transcriptFingerprint: transcript.fingerprint,
            provenance: generation.provenance,
            createdDate: Date(timeIntervalSince1970: 1_700_000_001),
            overview: "At a Glance is not used as the dedicated Summary source.",
            sections: [
                LectureNoteSection(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                    heading: "Concepts",
                    items: [
                        LectureNoteItem(
                            id: itemIDs[0], kind: .keyConcept, body: "First detailed concept",
                            fidelity: .transcriptSupported,
                            sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)]
                        ),
                        LectureNoteItem(
                            id: itemIDs[1], kind: .formula, body: "Reconstructed formula",
                            fidelity: .reconstructed,
                            sourceReferences: [
                                NotesSourceReference(sessionID: sessionID, sequenceNumber: 1),
                                NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)
                            ],
                            uncertaintyNote: "Normalized from spoken notation."
                        )
                    ]
                ),
                LectureNoteSection(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
                    heading: "Conclusion",
                    items: [
                        LectureNoteItem(
                            id: itemIDs[2], kind: .uncertainty, body: "Tentative conclusion",
                            fidelity: .uncertain,
                            sourceReferences: [
                                NotesSourceReference(sessionID: sessionID, sequenceNumber: 2),
                                NotesSourceReference(sessionID: sessionID, sequenceNumber: 1)
                            ],
                            uncertaintyNote: "The lecturer qualified this conclusion."
                        )
                    ]
                )
            ]
        )
        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: transcript.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 2),
            items: document.sections.flatMap(\.items)
        )
        return (generation, document, transcript, [analysis])
    }

    static func source() throws -> LectureSummarySourceSnapshot {
        let evidence = notesEvidence()
        return try LectureSummarySourceBuilder.build(
            generation: evidence.0,
            analyses: evidence.3,
            document: evidence.1,
            transcriptSnapshot: evidence.2
        )
    }

    static func generation(source: LectureSummarySourceSnapshot? = nil) throws -> LectureSummaryGenerationRecord {
        let source = try source ?? self.source()
        let plan = try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 10_000, maxItemsPerBatch: 2)
        )
        return LectureSummaryGenerationRecord.newGeneration(
            generationID: summaryGenerationID,
            sessionID: sessionID,
            sourceNotesGenerationID: notesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint,
            sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchPlan: plan,
            provenance: provenance,
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )
    }

    static func passage(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
        support: [UUID] = [itemIDs[0]],
        fidelity: LectureNoteContentFidelity = .transcriptSupported,
        uncertaintyNote: String? = nil,
        source: LectureSummarySourceSnapshot? = nil
    ) throws -> LectureSummaryPassage {
        let source = try source ?? self.source()
        return LectureSummaryPassage(
            id: id,
            text: "Grounded explanatory prose.",
            supportingNoteItemIDs: support,
            sourceReferences: try LectureSummaryIntegrityValidator.derivedSourceReferences(
                supportingItemIDs: support, source: source
            ),
            fidelity: fidelity,
            uncertaintyNote: uncertaintyNote
        )
    }
}
