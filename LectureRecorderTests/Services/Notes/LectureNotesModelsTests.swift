import XCTest
@testable import LectureRecorder

final class LectureNotesModelsTests: XCTestCase {
    private let encoder = AtomicFileWriter.defaultEncoder
    private let decoder = AtomicFileWriter.defaultDecoder

    // `AtomicFileWriter`'s ISO8601-with-fractional-seconds date strategy only
    // preserves millisecond precision, while an in-memory `Date()` carries
    // full `Double` precision (see `TranscriptionModelsTests` for the same
    // note) — these round-trip tests therefore compare a *second* decode
    // against the first, not against the pre-encoding original.

    func testGenerationRecordRoundTrips() throws {
        let windowPlan = NotesWindowPlan(windows: [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 2, isOversizedSingleUnit: false)
        ])
        let record = LectureNotesGenerationRecord.newGeneration(
            sessionID: UUID(),
            transcriptFingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "a", count: 64)),
            windowPlan: windowPlan,
            provenance: LectureNotesGenerationProvenance(recipeVersion: "fake-recipe-v1")
        )
        let decoded = try decoder.decode(LectureNotesGenerationRecord.self, from: encoder.encode(record))
        let redecoded = try decoder.decode(LectureNotesGenerationRecord.self, from: encoder.encode(decoded))
        XCTAssertEqual(decoded, redecoded)
        XCTAssertEqual(decoded.generationID, record.generationID)
        XCTAssertEqual(decoded.sessionID, record.sessionID)
        XCTAssertEqual(decoded.transcriptFingerprint, record.transcriptFingerprint)
        XCTAssertEqual(decoded.windowPlan, record.windowPlan)
        XCTAssertEqual(decoded.provenance, record.provenance)
        XCTAssertEqual(decoded.schemaVersion, record.schemaVersion)
    }

    func testWindowPlanCurrentSchemaVersionIsOne() {
        XCTAssertEqual(NotesWindowPlan.currentSchemaVersion, 1)
    }

    func testWindowAnalysisRoundTrips() throws {
        let sessionID = UUID()
        let fingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "b", count: 64))
        let analysis = LectureNotesWindowAnalysis(
            generationID: UUID(),
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: [
                LectureNoteItem(
                    kind: .keyConcept,
                    body: "A concept",
                    fidelity: .transcriptSupported,
                    sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)]
                )
            ]
        )
        let decoded = try decoder.decode(LectureNotesWindowAnalysis.self, from: encoder.encode(analysis))
        XCTAssertEqual(analysis, decoded)
    }

    func testDocumentRoundTrips() throws {
        let sessionID = UUID()
        let fingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "c", count: 64))
        let document = LectureNotesDocument(
            generationID: UUID(),
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            provenance: LectureNotesGenerationProvenance(recipeVersion: "fake-recipe-v1"),
            overview: "Overview text",
            sections: [
                LectureNoteSection(heading: "Section 1", items: [
                    LectureNoteItem(
                        kind: .definition,
                        body: "Definition body",
                        fidelity: .transcriptSupported,
                        sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)]
                    )
                ])
            ]
        )
        let decoded = try decoder.decode(LectureNotesDocument.self, from: encoder.encode(document))
        let redecoded = try decoder.decode(LectureNotesDocument.self, from: encoder.encode(decoded))
        XCTAssertEqual(decoded, redecoded)
        XCTAssertEqual(decoded.generationID, document.generationID)
        XCTAssertEqual(decoded.sessionID, document.sessionID)
        XCTAssertEqual(decoded.transcriptFingerprint, document.transcriptFingerprint)
        XCTAssertEqual(decoded.provenance, document.provenance)
        XCTAssertEqual(decoded.overview, document.overview)
        XCTAssertEqual(decoded.sections, document.sections)
    }

    func testSectionTopicsRoundTripInOrder() throws {
        let section = LectureNoteSection(heading: "Electric Fields", items: [], topics: ["Electric field", "Work", "Lumped circuit abstraction"])
        let decoded = try decoder.decode(LectureNoteSection.self, from: encoder.encode(section))
        XCTAssertEqual(decoded, section)
        XCTAssertEqual(decoded.topics, ["Electric field", "Work", "Lumped circuit abstraction"])
    }

    func testSectionSavedBeforeTopicsExistedDecodesWithNoTopics() throws {
        let id = UUID()
        let legacy = #"{"id":"\#(id.uuidString)","heading":"Section 1","items":[]}"#
        let decoded = try decoder.decode(LectureNoteSection.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.heading, "Section 1")
        XCTAssertEqual(decoded.topics, [])
    }

    /// Empty topics are left out of the encoded section, exactly as sections
    /// were encoded before `topics` existed; non-empty topics are written.
    func testEmptyTopicsAreOmittedAndNonEmptyTopicsAreEncoded() throws {
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(LectureNoteSection(heading: "Section 1", items: []))
        ) as? [String: Any])
        XCTAssertEqual(Set(empty.keys), ["id", "heading", "items"], "no \"topics\": [] is introduced")

        let withTopics = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(LectureNoteSection(heading: "Section 1", items: [], topics: ["Work"]))
        ) as? [String: Any])
        XCTAssertEqual(Set(withTopics.keys), ["id", "heading", "items", "topics"])
        XCTAssertEqual(withTopics["topics"] as? [String], ["Work"])
    }

    /// A document persisted before `topics` existed decodes and re-encodes
    /// to exactly its original JSON — no key added, removed, or changed —
    /// so fingerprints computed from the re-encoding stay historical.
    func testLegacyDocumentReEncodesToItsOriginalJSON() throws {
        let legacy = """
        {"createdDate":"2026-05-01T12:00:00.000Z","generationID":"00000000-0000-0000-0000-0000000000A2",\
        "overview":"Legacy overview.","provenance":{"recipeVersion":"t5e-apple-local-notes-v3"},"schemaVersion":1,\
        "sections":[{"heading":"Voltage","id":"00000000-0000-0000-0000-0000000000B1","items":[\
        {"body":"Voltage is energy per unit charge.","fidelity":"transcriptSupported","id":"00000000-0000-0000-0000-0000000000C1",\
        "kind":"definition","sourceReferences":[{"firstSequenceNumber":0,"lastSequenceNumber":0,"sessionID":"00000000-0000-0000-0000-0000000000A1"}]}]}],\
        "sessionID":"00000000-0000-0000-0000-0000000000A1",\
        "transcriptFingerprint":{"algorithmVersion":1,"digestHex":"\(String(repeating: "d", count: 64))"}}
        """
        let decoded = try decoder.decode(LectureNotesDocument.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.sections.map(\.topics), [[]])
        let reEncoded = try encoder.encode(decoded)
        XCTAssertFalse(String(decoding: reEncoded, as: UTF8.self).contains("topics"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? NSDictionary)
        let roundTripped = try XCTUnwrap(JSONSerialization.jsonObject(with: reEncoded) as? NSDictionary)
        XCTAssertEqual(roundTripped, original)
    }

    func testDocumentSavedBeforeTopicsExistedStillDecodes() throws {
        let sessionID = UUID()
        let document = LectureNotesDocument(
            generationID: UUID(),
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "d", count: 64)),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "fake-recipe-v1"),
            overview: "Overview text",
            sections: [LectureNoteSection(heading: "Section 1", items: [
                LectureNoteItem(kind: .definition, body: "Definition body", fidelity: .transcriptSupported,
                                sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)])
            ], topics: ["Topic"])]
        )
        // Strip `topics` to reproduce a document persisted by an earlier build.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        var sections = try XCTUnwrap(object["sections"] as? [[String: Any]])
        sections = sections.map { var section = $0; section.removeValue(forKey: "topics"); return section }
        object["sections"] = sections
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(String(decoding: legacyData, as: UTF8.self).contains("topics"))

        let decoded = try decoder.decode(LectureNotesDocument.self, from: legacyData)
        XCTAssertEqual(decoded.schemaVersion, LectureNotesDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.sections.map(\.topics), [[]])
        XCTAssertEqual(decoded.sections.map(\.heading), ["Section 1"])
        XCTAssertEqual(decoded.sections[0].items.count, 1)
    }

    /// New MLX v8 generation never creates reconstructed items, but Notes
    /// persisted by earlier recipes or other backends keep decoding with
    /// their fidelity and reconstruction or uncertainty notes intact.
    func testHistoricalReconstructedAndUncertainItemsStillDecodeWithTheirNotes() throws {
        let sessionID = UUID()
        let legacy = """
        {"id":"\(UUID().uuidString)","heading":"Legacy","items":[
          {"id":"\(UUID().uuidString)","kind":"formula","body":"v = dx/dt","fidelity":"reconstructed",
           "sourceReferences":[{"sessionID":"\(sessionID.uuidString)","firstSequenceNumber":0,"lastSequenceNumber":0}],
           "uncertaintyNote":"Transcript wording \\"dee ex\\" was repaired as \\"dx\\"."},
          {"id":"\(UUID().uuidString)","kind":"explanation","body":"Possibly a boundary condition.","fidelity":"uncertain",
           "sourceReferences":[{"sessionID":"\(sessionID.uuidString)","firstSequenceNumber":1,"lastSequenceNumber":1}],
           "uncertaintyNote":"Garbled wording."}
        ]}
        """
        let section = try decoder.decode(LectureNoteSection.self, from: Data(legacy.utf8))
        XCTAssertEqual(section.items.map(\.fidelity), [.reconstructed, .uncertain])
        XCTAssertEqual(section.items.map(\.uncertaintyNote), ["Transcript wording \"dee ex\" was repaired as \"dx\".", "Garbled wording."])
        XCTAssertEqual(section.topics, [])
        let roundTripped = try decoder.decode(LectureNoteSection.self, from: encoder.encode(section))
        XCTAssertEqual(roundTripped, section)
    }

    func testCurrentSchemaVersionsAreOne() {
        XCTAssertEqual(LectureNotesGenerationRecord.currentSchemaVersion, 1)
        XCTAssertEqual(LectureNotesWindowAnalysis.currentSchemaVersion, 1)
        XCTAssertEqual(LectureNotesDocument.currentSchemaVersion, 1)
        XCTAssertEqual(NotesTranscriptSourceSnapshot.currentSchemaVersion, 1)
    }

    func testReconstructedFidelityIsDistinctFromTranscriptSupported() {
        let sessionID = UUID()
        let reconstructed = LectureNoteItem(
            kind: .formula,
            body: "E = mc^2",
            fidelity: .reconstructed,
            sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)],
            uncertaintyNote: "Normalized from spoken description; not verbatim."
        )
        XCTAssertEqual(reconstructed.fidelity, .reconstructed)
        XCTAssertNotEqual(reconstructed.fidelity, .transcriptSupported)
    }

    // MARK: - NotesWindowPlan validation

    private func makeSnapshotForPlanTests(sessionID: UUID = UUID(), unitCount: Int) -> NotesTranscriptSourceSnapshot {
        let units = (0..<unitCount).map { seq in
            NotesTranscriptSourceUnit(
                sequenceNumber: seq,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                text: "unit \(seq)",
                startOffsetSeconds: Double(seq) * 30,
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

    func testWindowPlanUnsupportedSchemaVersionRejected() {
        let plan = NotesWindowPlan(schemaVersion: 999, windows: [])
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .unsupportedSchemaVersion(999))
        }
    }

    func testWindowPlanDuplicateWindowIndexRejected() {
        let window = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 0, unitCount: 1, isOversizedSingleUnit: false)
        let plan = NotesWindowPlan(windows: [window, window])
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .duplicateWindowIndex(0))
        }
    }

    func testWindowPlanNonSequentialIndicesRejected() {
        let windows = [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 0, unitCount: 1, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 2, firstSequenceNumber: 1, lastSequenceNumber: 1, unitCount: 1, isOversizedSingleUnit: false)
        ]
        let plan = NotesWindowPlan(windows: windows)
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .nonSequentialWindowIndices(indices: [0, 2]))
        }
    }

    func testWindowPlanInvertedRangeRejected() {
        let window = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 3, lastSequenceNumber: 1, unitCount: 1, isOversizedSingleUnit: false)
        let plan = NotesWindowPlan(windows: [window])
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .invertedWindowRange(windowIndex: 0, firstSequenceNumber: 3, lastSequenceNumber: 1))
        }
    }

    func testWindowPlanNonPositiveUnitCountRejected() {
        let window = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 0, isOversizedSingleUnit: false)
        let plan = NotesWindowPlan(windows: [window])
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .nonPositiveUnitCount(windowIndex: 0, unitCount: 0))
        }
    }

    func testWindowPlanUnitCountMismatchRejected() {
        let window = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 5, isOversizedSingleUnit: false)
        let plan = NotesWindowPlan(windows: [window])
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .unitCountMismatch(windowIndex: 0, expected: 2, actual: 5))
        }
    }

    func testWindowPlanOversizedFlagInconsistentWithUnitCountRejected() {
        let window = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 2, isOversizedSingleUnit: true)
        let plan = NotesWindowPlan(windows: [window])
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .oversizedFlagInconsistentWithUnitCount(windowIndex: 0, unitCount: 2))
        }
    }

    func testWindowPlanOverlappingWindowsRejected() {
        let windows = [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 2, unitCount: 3, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 1, firstSequenceNumber: 1, lastSequenceNumber: 3, unitCount: 3, isOversizedSingleUnit: false)
        ]
        let plan = NotesWindowPlan(windows: windows)
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .overlappingWindows(firstWindowIndex: 0, secondWindowIndex: 1))
        }
    }

    func testWindowPlanGapBetweenWindowsRejected() {
        let windows = [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 0, unitCount: 1, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 1, firstSequenceNumber: 2, lastSequenceNumber: 2, unitCount: 1, isOversizedSingleUnit: false)
        ]
        let plan = NotesWindowPlan(windows: windows)
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(
                error as? NotesWindowPlanValidationError,
                .gapBetweenWindows(afterWindowIndex: 0, expectedNextSequenceNumber: 1, actualNextSequenceNumber: 2)
            )
        }
    }

    func testWindowPlanValidStructurePasses() {
        let windows = [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 2, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 1, firstSequenceNumber: 2, lastSequenceNumber: 2, unitCount: 1, isOversizedSingleUnit: true)
        ]
        XCTAssertNoThrow(try NotesWindowPlan(windows: windows).validateStructure())
    }

    func testWindowPlanEmptyForNonemptySourceRejected() {
        let snapshot = makeSnapshotForPlanTests(unitCount: 2)
        let plan = NotesWindowPlan(windows: [])
        XCTAssertThrowsError(try plan.validateCoversExactly(snapshot)) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .emptyPlanForNonemptySource)
        }
    }

    func testWindowPlanCoverageDoesNotMatchSourceRejected() {
        let snapshot = makeSnapshotForPlanTests(unitCount: 4)
        // Structurally valid on its own, but only covers half the source.
        let plan = NotesWindowPlan(windows: [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 2, isOversizedSingleUnit: false)
        ])
        XCTAssertThrowsError(try plan.validateCoversExactly(snapshot)) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .coverageDoesNotMatchSource)
        }
    }

    func testWindowPlanCoversExactlyValidSnapshotPasses() {
        let snapshot = makeSnapshotForPlanTests(unitCount: 3)
        let plan = NotesWindowPlan(windows: [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 2, unitCount: 3, isOversizedSingleUnit: false)
        ])
        XCTAssertNoThrow(try plan.validateCoversExactly(snapshot))
    }

    // MARK: - Overflow-safe arithmetic (malformed persisted extreme values)

    func testWindowPlanUnitCountArithmeticOverflowRejectedWithoutTrapping() {
        // `lastSequenceNumber - firstSequenceNumber` itself fits, but
        // adding 1 to get the implied unitCount overflows `Int`.
        let window = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: Int.max, unitCount: Int.max, isOversizedSingleUnit: false)
        let plan = NotesWindowPlan(windows: [window])
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .arithmeticOverflow(windowIndex: 0))
        }
    }

    func testWindowPlanNextSequenceNumberArithmeticOverflowRejectedWithoutTrapping() {
        // Window 0 (Int.max - 1 ... Int.max) is itself perfectly valid;
        // only computing "one past its end" (Int.max + 1), needed to
        // check window 1 for a gap/overlap, overflows.
        let windows = [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: Int.max - 1, lastSequenceNumber: Int.max, unitCount: 2, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 1, firstSequenceNumber: Int.max, lastSequenceNumber: Int.max, unitCount: 1, isOversizedSingleUnit: true)
        ]
        let plan = NotesWindowPlan(windows: windows)
        XCTAssertThrowsError(try plan.validateStructure()) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .arithmeticOverflow(windowIndex: 0))
        }
    }

    func testWindowPlanCoverageAggregateRangeOverflowRejectedWithoutTrapping() {
        // Every individual window below is perfectly valid on its own (no
        // per-window overflow) — only the *aggregate* first-window-to-
        // last-window span, computed in `validateCoversExactly`, overflows
        // `Int` (planMin = -1, planMax = Int.max).
        let half = Int.max / 2
        let windows = [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: -1, lastSequenceNumber: -1, unitCount: 1, isOversizedSingleUnit: true),
            NotesInputWindow(windowIndex: 1, firstSequenceNumber: 0, lastSequenceNumber: half, unitCount: half + 1, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 2, firstSequenceNumber: half + 1, lastSequenceNumber: Int.max, unitCount: Int.max - half, isOversizedSingleUnit: false)
        ]
        let plan = NotesWindowPlan(windows: windows)
        XCTAssertNoThrow(try plan.validateStructure())

        // A hand-constructed snapshot whose own min/max sequence numbers
        // exactly match the plan's (-1 and Int.max) — needed so the
        // min/max agreement check passes and execution actually reaches
        // the aggregate span computation this test means to exercise.
        let snapshot = NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: UUID(),
            units: [
                NotesTranscriptSourceUnit(sequenceNumber: -1, chunkFileName: "a.caf", text: "a", startOffsetSeconds: 0, durationSeconds: 30),
                NotesTranscriptSourceUnit(sequenceNumber: Int.max, chunkFileName: "b.caf", text: "b", startOffsetSeconds: 30, durationSeconds: 30)
            ],
            fingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "0", count: 64))
        )
        XCTAssertThrowsError(try plan.validateCoversExactly(snapshot)) { error in
            XCTAssertEqual(error as? NotesWindowPlanValidationError, .coverageRangeOverflow)
        }
    }
}
