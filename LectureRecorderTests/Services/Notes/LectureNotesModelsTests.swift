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
