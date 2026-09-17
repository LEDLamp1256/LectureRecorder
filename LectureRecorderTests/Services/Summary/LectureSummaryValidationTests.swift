import XCTest
@testable import LectureRecorder

final class LectureSummaryValidationTests: XCTestCase {
    private func analysis(
        generation: LectureSummaryGenerationRecord,
        passages: [LectureSummaryPassage],
        batchIndex: Int = 0
    ) -> LectureSummaryAnalysis {
        let batch = generation.batchPlan.batches[batchIndex]
        return LectureSummaryAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            batchID: batch.batchID,
            batchIndex: batch.batchIndex,
            passages: passages,
            provenance: generation.provenance
        )
    }

    private func document(
        generation: LectureSummaryGenerationRecord,
        passages: [LectureSummaryPassage]
    ) -> LectureSummaryDocument {
        LectureSummaryDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.sourceNotesGenerationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: generation.sourceNotesDocumentFingerprint,
            provenance: generation.provenance,
            createdDate: Date(timeIntervalSince1970: 1_700_000_020),
            sections: [LectureSummarySection(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
                heading: "Core ideas",
                passages: passages
            )]
        )
    }

    func testValidGenerationAnalysisAndLossyDocumentPass() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let passage = try SummaryTestSupport.passage(source: source)
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(generation: generation, source: source))
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(
            analysis: analysis(generation: generation, passages: [passage]), generation: generation, source: source
        ))
        // Only item 0 is retained; items 1 and 2 need not appear in the final Summary.
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        ))
    }

    func testSchemaVersionAndFrozenPlanTamperingAreRejected() throws {
        let source = try SummaryTestSupport.source()
        var generation = try SummaryTestSupport.generation(source: source)
        generation.schemaVersion = 999
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(generation: generation, source: source)) {
            XCTAssertEqual($0 as? LectureSummaryIntegrityError, .unsupportedSchemaVersion(999))
        }
        generation = try SummaryTestSupport.generation(source: source)
        generation.batchPlan.batches[0].sourceItemIDs.removeLast()
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(generation: generation, source: source)) {
            guard case LectureSummaryIntegrityError.invalidPlan(.lastSourceItemIndexMismatch) = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
    }

    func testGenerationSourceIdentityAndProvenancePresenceAreEnforced() throws {
        let source = try SummaryTestSupport.source()
        var generation = try SummaryTestSupport.generation(source: source)
        generation.sourceNotesGenerationID = UUID()
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(generation: generation, source: source)) {
            XCTAssertEqual($0 as? LectureSummaryIntegrityError, .sourceNotesGenerationIdentityMismatch)
        }
        generation = try SummaryTestSupport.generation(source: source)
        generation.provenance.recipeVersion = " "
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(generation: generation, source: source)) {
            XCTAssertEqual($0 as? LectureSummaryIntegrityError, .provenanceMissing)
        }
    }

    func testAnalysisIdentityAndProvenanceMismatchAreRejected() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let passage = try SummaryTestSupport.passage(source: source)
        var value = analysis(generation: generation, passages: [passage])
        value.generationID = UUID()
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(analysis: value, generation: generation, source: source)) {
            XCTAssertEqual($0 as? LectureSummaryIntegrityError, .generationIdentityMismatch)
        }
        value = analysis(generation: generation, passages: [passage])
        value.provenance.generatorVersion = "other"
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(analysis: value, generation: generation, source: source)) {
            XCTAssertEqual($0 as? LectureSummaryIntegrityError, .provenanceMismatch)
        }
    }

    func testAnalysisAndDocumentSchemaBatchAndProvenanceMismatchesAreRejected() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let passage = try SummaryTestSupport.passage(source: source)
        var batchAnalysis = analysis(generation: generation, passages: [passage])
        batchAnalysis.schemaVersion = 999
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            analysis: batchAnalysis, generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .unsupportedSchemaVersion(999)) }
        batchAnalysis = analysis(generation: generation, passages: [passage])
        batchAnalysis.batchID = "invented"
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            analysis: batchAnalysis, generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .batchIdentityMismatch(0)) }
        batchAnalysis = analysis(generation: generation, passages: [])
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            analysis: batchAnalysis, generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .emptyAnalysis(0)) }

        var finalDocument = document(generation: generation, passages: [passage])
        finalDocument.schemaVersion = 999
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            document: finalDocument, generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .unsupportedSchemaVersion(999)) }
        finalDocument = document(generation: generation, passages: [passage])
        finalDocument.provenance.backendIdentifier = "other"
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            document: finalDocument, generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .provenanceMismatch) }
    }

    func testAnalysisCannotSupportItemOutsideAssignedBatch() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let outside = try SummaryTestSupport.passage(
            support: [SummaryTestSupport.itemIDs[2]], fidelity: .uncertain,
            uncertaintyNote: "Preserves uncertainty.", source: source
        )
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            analysis: analysis(generation: generation, passages: [outside]), generation: generation, source: source
        )) {
            XCTAssertEqual($0 as? LectureSummaryIntegrityError, .supportingItemOutsideBatch(SummaryTestSupport.itemIDs[2]))
        }
    }

    func testEmptyAndInventedSupportAreRejected() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        var passage = try SummaryTestSupport.passage(source: source)
        passage.supportingNoteItemIDs = []
        passage.sourceReferences = []
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .emptySupport) }

        let invented = UUID()
        passage.supportingNoteItemIDs = [invented]
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .supportingItemOutsideSource(invented)) }
    }

    func testExactOrderedDeduplicatedReferenceUnionIsRequired() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let support = [SummaryTestSupport.itemIDs[1], SummaryTestSupport.itemIDs[2]]
        let expected = try LectureSummaryIntegrityValidator.derivedSourceReferences(
            supportingItemIDs: support, source: source
        )
        XCTAssertEqual(expected, [
            NotesSourceReference(sessionID: SummaryTestSupport.sessionID, sequenceNumber: 1),
            NotesSourceReference(sessionID: SummaryTestSupport.sessionID, sequenceNumber: 0),
            NotesSourceReference(sessionID: SummaryTestSupport.sessionID, sequenceNumber: 2)
        ])
        var passage = try SummaryTestSupport.passage(
            support: support, fidelity: .uncertain, uncertaintyNote: "Conservative synthesis.", source: source
        )
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        ))
        passage.sourceReferences.removeLast()
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .sourceReferencesMismatch) }
        passage.sourceReferences = expected + [NotesSourceReference(sessionID: SummaryTestSupport.sessionID, sequenceNumber: 2)]
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .sourceReferencesMismatch) }
    }

    func testFidelityLowerBoundAndUncertaintyExplanationAreEnforced() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        var passage = try SummaryTestSupport.passage(
            support: [SummaryTestSupport.itemIDs[1]], fidelity: .transcriptSupported, source: source
        )
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .fidelityTooStrong) }

        passage.fidelity = .reconstructed
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .uncertaintyExplanationRequired) }
        passage.uncertaintyNote = "Normalized from source Notes."
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        ))
    }

    func testUncertainSupportCannotBeUpgradedButMayRemainUncertain() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        var passage = try SummaryTestSupport.passage(
            support: [SummaryTestSupport.itemIDs[2]], fidelity: .reconstructed,
            uncertaintyNote: "Still cautious.", source: source
        )
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        )) { XCTAssertEqual($0 as? LectureSummaryIntegrityError, .fidelityTooStrong) }
        passage.fidelity = .uncertain
        XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(
            document: document(generation: generation, passages: [passage]), generation: generation, source: source
        ))
    }

    func testDuplicateIDsAndEmptyHeadingsTextAndSectionsAreRejected() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let passage = try SummaryTestSupport.passage(source: source)
        var value = document(generation: generation, passages: [passage, passage])
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(document: value, generation: generation, source: source))
        value = document(generation: generation, passages: [passage])
        value.sections[0].heading = " "
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(document: value, generation: generation, source: source))
        value = document(generation: generation, passages: [passage])
        value.sections[0].passages[0].text = "\n"
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(document: value, generation: generation, source: source))
        value = document(generation: generation, passages: [])
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(document: value, generation: generation, source: source))
        value = document(generation: generation, passages: [passage])
        value.sections.append(value.sections[0])
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(document: value, generation: generation, source: source))
    }

    func testDocumentIdentityAndFingerprintMismatchAreRejected() throws {
        let source = try SummaryTestSupport.source()
        let generation = try SummaryTestSupport.generation(source: source)
        let passage = try SummaryTestSupport.passage(source: source)
        var value = document(generation: generation, passages: [passage])
        value.sourceNotesGenerationID = UUID()
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(document: value, generation: generation, source: source))
        value = document(generation: generation, passages: [passage])
        value.sourceNotesDocumentFingerprint.digestHex = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(document: value, generation: generation, source: source))
        value = document(generation: generation, passages: [passage])
        value.transcriptFingerprint.digestHex = String(repeating: "e", count: 64)
        XCTAssertThrowsError(try LectureSummaryIntegrityValidator.validate(document: value, generation: generation, source: source))
    }
}
