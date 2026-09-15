import XCTest
@testable import LectureRecorder

final class NotesValidationTests: XCTestCase {
    private func makeSnapshot(sessionID: UUID, unitCount: Int) -> NotesTranscriptSourceSnapshot {
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

    private func makeGeneration(
        sessionID: UUID,
        fingerprint: TranscriptSourceFingerprint,
        windows: [NotesInputWindow] = []
    ) -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            windowPlan: NotesWindowPlan(windows: windows),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "fake-recipe-v1")
        )
    }

    // A single window that exactly covers a 2-unit source (0...1). Every
    // `validate`/`validateCoverage` entry point now independently checks
    // that `generation.windowPlan` exactly covers whatever source snapshot
    // is supplied (see `validateSourceMatchesGeneration`), so any test that
    // reaches past that check must give its generation a plan that fully
    // (not just partially) covers its snapshot — even when the specific
    // failure mode under test lies elsewhere entirely.
    private let twoUnitWindow = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 2, isOversizedSingleUnit: false)

    /// A two-window plan that fully covers a 5-unit snapshot (0...4),
    /// split as [0...1, 2...4] — used by tests that need a *valid,
    /// complete* plan while still isolating a window-0-specific failure
    /// mode (e.g. an owned-range or source-reference check) against a
    /// snapshot larger than window 0 alone.
    private func fiveUnitWindows() -> [NotesInputWindow] {
        [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 2, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 1, firstSequenceNumber: 2, lastSequenceNumber: 4, unitCount: 3, isOversizedSingleUnit: false)
        ]
    }

    func testWindowAnalysisWithWrongFingerprintRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])
        let wrongFingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "f", count: 64))

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: wrongFingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .transcriptFingerprintMismatch)
        }
    }

    func testWindowAnalysisWithWrongGenerationIdentityRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let analysis = LectureNotesWindowAnalysis(
            generationID: UUID(),
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .generationIdentityMismatch)
        }
    }

    func testWindowAnalysisWithSessionIdentityMismatchRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: UUID(),
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .sessionIdentityMismatch)
        }
    }

    // MARK: - Anchoring to the persisted plan (not a caller-supplied window)

    func testWindowAnalysisReferencingWindowNotInPersistedPlanRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        // Plan fully and validly covers the snapshot (so the central
        // generation/source check passes) — the analysis below simply
        // references a windowIndex that plan doesn't contain.
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 5,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .windowNotInPlan(windowIndex: 5))
        }
    }

    func testSuppliedPlannedWindowDisagreeingWithPersistedPlanRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 1)
        // Persisted plan's own (only, fully-covering) entry for window 0
        // covers exactly the 1-unit snapshot.
        let persistedWindow = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 0, unitCount: 1, isOversizedSingleUnit: true)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [persistedWindow])
        // Caller supplies a *different*-looking window (same index, wider
        // range) — must never be accepted merely because it "looks" plausible.
        let suppliedWindow = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 2, unitCount: 3, isOversizedSingleUnit: false)

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 2),
            items: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: suppliedWindow, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .plannedWindowDisagreesWithPersistedPlan(windowIndex: 0))
        }
    }

    // MARK: - Central generation/source integrity check

    func testAnalysisValidationRejectsSnapshotWithChangedFingerprintForSameSession() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        // A retranscription of the same session changed its content —
        // same session, ranges still nominally line up, but the fingerprint
        // no longer matches the generation this snapshot is validated against.
        var changedUnits = snapshot.units
        changedUnits[0].text = "a different transcript now"
        let changedSnapshot = NotesTranscriptSourceSnapshot(
            schemaVersion: snapshot.schemaVersion,
            sessionID: sessionID,
            units: changedUnits,
            fingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: changedUnits)
        )

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(
                analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: changedSnapshot
            )
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .transcriptFingerprintMismatch)
        }
    }

    func testDocumentValidationRejectsSnapshotFromADifferentSession() {
        let sessionID = UUID()
        let otherSessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])
        let otherSessionSnapshot = makeSnapshot(sessionID: otherSessionID, unitCount: 2)

        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: "overview",
            sections: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(document: document, generation: generation, sourceSnapshot: otherSessionSnapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .sessionIdentityMismatch)
        }
    }

    func testAnalysisValidationRejectsStructurallyValidButIncompletePlan() {
        let sessionID = UUID()
        // Snapshot has 5 units, but the persisted plan only covers 0...1 —
        // structurally valid on its own (a single, internally-consistent
        // window), yet incomplete against the full source. Must be
        // rejected even for a *single*-window-analysis validation, not
        // only when the full `validateCoverage` path happens to run.
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 5)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        ) { error in
            guard case NotesIntegrityError.invalidWindowPlan(.coverageDoesNotMatchSource) = error else {
                return XCTFail("expected invalidWindowPlan(.coverageDoesNotMatchSource), got \(error)")
            }
        }
    }

    func testDocumentValidationRejectsStructurallyValidButIncompletePlan() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 5)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: "overview",
            sections: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(document: document, generation: generation, sourceSnapshot: snapshot)
        ) { error in
            guard case NotesIntegrityError.invalidWindowPlan(.coverageDoesNotMatchSource) = error else {
                return XCTFail("expected invalidWindowPlan(.coverageDoesNotMatchSource), got \(error)")
            }
        }
    }

    func testWindowAnalysisWithSourceReferenceOutsideOwnedRangeRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 5)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: fiveUnitWindows())

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: [
                LectureNoteItem(
                    kind: .keyConcept,
                    body: "claims outside range",
                    fidelity: .transcriptSupported,
                    sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 4)]
                )
            ]
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        ) { error in
            guard case NotesIntegrityError.sourceReferenceOutsideOwnedWindow = error else {
                return XCTFail("expected sourceReferenceOutsideOwnedWindow, got \(error)")
            }
        }
    }

    func testWindowAnalysisItemWithNoSourceReferencesRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: [
                LectureNoteItem(kind: .keyConcept, body: "ungrounded", fidelity: .transcriptSupported, sourceReferences: [])
            ]
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .itemMissingSourceReferences)
        }
    }

    func testWindowAnalysisWithOwnedRangeNotMatchingPlannedWindowRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 5)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: fiveUnitWindows())

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 2),
            items: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        ) { error in
            guard case NotesIntegrityError.windowOwnedRangeDoesNotMatchPlannedWindow = error else {
                return XCTFail("expected windowOwnedRangeDoesNotMatchPlannedWindow, got \(error)")
            }
        }
    }

    func testUnsupportedSchemaVersionRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        var analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: []
        )
        analysis.schemaVersion = 999

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .unsupportedSchemaVersion(999))
        }
    }

    func testDuplicateWindowIndexRejected() {
        let sessionID = UUID()
        let fingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "d", count: 64))
        let generationID = UUID()
        func makeAnalysis(_ windowIndex: Int) -> LectureNotesWindowAnalysis {
            LectureNotesWindowAnalysis(
                generationID: generationID,
                sessionID: sessionID,
                transcriptFingerprint: fingerprint,
                windowIndex: windowIndex,
                ownedRange: NotesSourceReference(sessionID: sessionID, sequenceNumber: 0),
                items: []
            )
        }
        let analyses = [makeAnalysis(0), makeAnalysis(1), makeAnalysis(0)]

        XCTAssertThrowsError(try NotesIntegrityValidator.validateNoDuplicateWindowIndices(analyses)) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .duplicateWindowIndex(0))
        }
    }

    func testDocumentWithGenerationIdentityMismatchRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let document = LectureNotesDocument(
            generationID: UUID(),
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            provenance: generation.provenance,
            overview: "overview",
            sections: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(document: document, generation: generation, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .generationIdentityMismatch)
        }
    }

    func testDocumentWithProvenanceValueMismatchRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            provenance: LectureNotesGenerationProvenance(recipeVersion: "a-different-recipe"),
            overview: "overview",
            sections: []
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(document: document, generation: generation, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .provenanceMismatch)
        }
    }

    func testDocumentWithInvalidSourceReferenceRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            provenance: generation.provenance,
            overview: "overview",
            sections: [
                LectureNoteSection(heading: "Section", items: [
                    LectureNoteItem(
                        kind: .keyConcept,
                        body: "body",
                        fidelity: .transcriptSupported,
                        sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 99)]
                    )
                ])
            ]
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(document: document, generation: generation, sourceSnapshot: snapshot)
        ) { error in
            guard case NotesIntegrityError.invalidSourceReference = error else {
                return XCTFail("expected invalidSourceReference, got \(error)")
            }
        }
    }

    func testDocumentItemWithNoSourceReferencesRejected() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            provenance: generation.provenance,
            overview: "overview",
            sections: [
                LectureNoteSection(heading: "Section", items: [
                    LectureNoteItem(kind: .keyConcept, body: "ungrounded", fidelity: .transcriptSupported, sourceReferences: [])
                ])
            ]
        )

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(document: document, generation: generation, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .itemMissingSourceReferences)
        }
    }

    func testValidWindowAnalysisAndDocumentPassValidation() throws {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow])

        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            items: [
                LectureNoteItem(
                    kind: .keyConcept,
                    body: "valid",
                    fidelity: .transcriptSupported,
                    sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)]
                )
            ]
        )
        XCTAssertNoThrow(
            try NotesIntegrityValidator.validate(analysis: analysis, generation: generation, plannedWindow: twoUnitWindow, sourceSnapshot: snapshot)
        )

        let document = LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            provenance: generation.provenance,
            overview: "overview",
            sections: [LectureNoteSection(heading: "S", items: analysis.items)]
        )
        XCTAssertNoThrow(
            try NotesIntegrityValidator.validate(document: document, generation: generation, sourceSnapshot: snapshot)
        )
    }

    // MARK: - Coverage validator

    private func makeAnalysis(
        sessionID: UUID,
        generation: LectureNotesGenerationRecord,
        window: NotesInputWindow
    ) -> LectureNotesWindowAnalysis {
        LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: window.windowIndex,
            ownedRange: NotesSourceReference(
                sessionID: sessionID, firstSequenceNumber: window.firstSequenceNumber, lastSequenceNumber: window.lastSequenceNumber
            ),
            items: [
                LectureNoteItem(
                    kind: .keyConcept,
                    body: "item",
                    fidelity: .transcriptSupported,
                    sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: window.firstSequenceNumber)]
                )
            ]
        )
    }

    func testCoverageValidatorAcceptsExactCompleteCoverage() throws {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 4)
        let windows = [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 2, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 1, firstSequenceNumber: 2, lastSequenceNumber: 3, unitCount: 2, isOversizedSingleUnit: false)
        ]
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: windows)
        let analyses = windows.map { makeAnalysis(sessionID: sessionID, generation: generation, window: $0) }

        XCTAssertNoThrow(
            try NotesIntegrityValidator.validateCoverage(analyses: analyses, generation: generation, sourceSnapshot: snapshot)
        )
    }

    func testCoverageValidatorRejectsMissingWindow() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 4)
        let windows = [
            NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 2, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 1, firstSequenceNumber: 2, lastSequenceNumber: 3, unitCount: 2, isOversizedSingleUnit: false)
        ]
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: windows)
        let analyses = [makeAnalysis(sessionID: sessionID, generation: generation, window: windows[0])]

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validateCoverage(analyses: analyses, generation: generation, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .missingWindowAnalysis(windowIndices: [1]))
        }
    }

    func testCoverageValidatorRejectsExtraWindow() {
        let sessionID = UUID()
        // Plan fully (and only) covers this 2-unit snapshot; the "extra"
        // analysis below references a window index outside that plan —
        // distinct from a plan that fails to cover its own snapshot.
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let windows = [twoUnitWindow]
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: windows)
        let extraWindow = NotesInputWindow(windowIndex: 1, firstSequenceNumber: 2, lastSequenceNumber: 2, unitCount: 1, isOversizedSingleUnit: true)
        let analyses = [
            makeAnalysis(sessionID: sessionID, generation: generation, window: windows[0]),
            makeAnalysis(sessionID: sessionID, generation: generation, window: extraWindow)
        ]

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validateCoverage(analyses: analyses, generation: generation, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .unexpectedWindowAnalysis(windowIndices: [1]))
        }
    }

    func testCoverageValidatorRejectsDuplicateWindow() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        let windows = [twoUnitWindow]
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: windows)
        let analysis = makeAnalysis(sessionID: sessionID, generation: generation, window: windows[0])

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validateCoverage(analyses: [analysis, analysis], generation: generation, sourceSnapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? NotesIntegrityError, .duplicateWindowIndex(0))
        }
    }

    func testCoverageValidatorRejectsGenerationWithInvalidWindowPlan() {
        let sessionID = UUID()
        let snapshot = makeSnapshot(sessionID: sessionID, unitCount: 2)
        // Duplicate window indices — an invalid plan.
        let generation = makeGeneration(sessionID: sessionID, fingerprint: snapshot.fingerprint, windows: [twoUnitWindow, twoUnitWindow])
        let analysis = makeAnalysis(sessionID: sessionID, generation: generation, window: twoUnitWindow)

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validateCoverage(analyses: [analysis], generation: generation, sourceSnapshot: snapshot)
        ) { error in
            guard case NotesIntegrityError.invalidWindowPlan = error else {
                return XCTFail("expected invalidWindowPlan, got \(error)")
            }
        }
    }
}
