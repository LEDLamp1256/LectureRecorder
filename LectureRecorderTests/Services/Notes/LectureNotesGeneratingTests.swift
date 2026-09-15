import XCTest
@testable import LectureRecorder

final class LectureNotesGeneratingTests: XCTestCase {
    private func makeUnits(count: Int) -> [NotesTranscriptSourceUnit] {
        (0..<count).map { seq in
            NotesTranscriptSourceUnit(
                sequenceNumber: seq,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                text: "text \(seq)",
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30
            )
        }
    }

    private func makeSnapshot(sessionID: UUID, units: [NotesTranscriptSourceUnit]) -> NotesTranscriptSourceSnapshot {
        NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        )
    }

    func testFakeWindowAnalysisSatisfiesGeneratorContractAndValidation() async throws {
        let sessionID = UUID()
        let units = makeUnits(count: 4)
        let snapshot = makeSnapshot(sessionID: sessionID, units: units)
        let windows = NotesWindowPlanner.plan(units: units, budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 12))
        let generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowPlan: NotesWindowPlan(windows: windows),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "fake-recipe-v1")
        )
        let generator = FakeLectureNotesGenerator()

        var analyses: [LectureNotesWindowAnalysis] = []
        for window in windows {
            let analysis = try await generator.analyzeWindow(units: units, window: window, generation: generation)
            XCTAssertNoThrow(
                try NotesIntegrityValidator.validate(
                    analysis: analysis, generation: generation, plannedWindow: window, sourceSnapshot: snapshot
                )
            )
            analyses.append(analysis)
        }
        XCTAssertNoThrow(
            try NotesIntegrityValidator.validateCoverage(analyses: analyses, generation: generation, sourceSnapshot: snapshot)
        )
    }

    func testFakeSynthesisSatisfiesGeneratorContractAndValidation() async throws {
        let sessionID = UUID()
        let units = makeUnits(count: 3)
        let snapshot = makeSnapshot(sessionID: sessionID, units: units)
        let windows = NotesWindowPlanner.plan(units: units, budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 1_000))
        let generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowPlan: NotesWindowPlan(windows: windows),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "fake-recipe-v1")
        )
        let generator = FakeLectureNotesGenerator()

        var analyses: [LectureNotesWindowAnalysis] = []
        for window in windows {
            analyses.append(try await generator.analyzeWindow(units: units, window: window, generation: generation))
        }

        let document = try await generator.synthesize(analyses: analyses, generation: generation)
        XCTAssertNoThrow(
            try NotesIntegrityValidator.validate(document: document, generation: generation, sourceSnapshot: snapshot)
        )
        XCTAssertEqual(document.sections.flatMap(\.items).count, units.count)
    }

    func testMalformedFakeOutputIsRejectedAtValidationBoundary() async throws {
        let sessionID = UUID()
        let units = makeUnits(count: 3)
        let snapshot = makeSnapshot(sessionID: sessionID, units: units)
        let windows = NotesWindowPlanner.plan(units: units, budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 1_000))
        let generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            windowPlan: NotesWindowPlan(windows: windows),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "fake-recipe-v1")
        )
        let malformedGenerator = FakeLectureNotesGenerator(claimsOutOfRangeSourceReference: true)

        guard let window = windows.first else {
            return XCTFail("expected at least one window")
        }
        let analysis = try await malformedGenerator.analyzeWindow(units: units, window: window, generation: generation)

        XCTAssertThrowsError(
            try NotesIntegrityValidator.validate(
                analysis: analysis, generation: generation, plannedWindow: window, sourceSnapshot: snapshot
            )
        ) { error in
            XCTAssertTrue(error is NotesIntegrityError)
        }
    }
}
