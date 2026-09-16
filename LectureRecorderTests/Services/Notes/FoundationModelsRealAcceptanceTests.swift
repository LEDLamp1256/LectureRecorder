import XCTest
@testable import LectureRecorder

/// Opt-in real on-device Foundation Models acceptance path — disabled by
/// default and never part of normal deterministic-suite success. Enable
/// with:
///
///     LECTURE_RECORDER_RUN_LOCAL_NOTES_ACCEPTANCE=1
///
/// Uses no `OPENAI_API_KEY` and makes no network request. Reports
/// "unavailable" (via `XCTSkip`, distinct from a failure) when Apple
/// Intelligence/the on-device model is not ready in this environment,
/// rather than failing the run.
final class FoundationModelsRealAcceptanceTests: XCTestCase {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LECTURE_RECORDER_RUN_LOCAL_NOTES_ACCEPTANCE"] == "1"
    }

    private func unit(_ sequence: Int, _ text: String) -> NotesTranscriptSourceUnit {
        NotesTranscriptSourceUnit(
            sequenceNumber: sequence,
            chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequence),
            text: text,
            startOffsetSeconds: Double(sequence) * 30,
            durationSeconds: 30
        )
    }

    /// Exercises two windows (so real hierarchical hand-off between window
    /// analysis and synthesis is exercised, not just a single call), then
    /// validates the result through the same `NotesIntegrityValidator` real
    /// generations are held to — never a separate, looser acceptance-only
    /// check.
    func testRealLocalNotesGenerationProducesIntegrityValidatedStructuredNotes() async throws {
        try XCTSkipUnless(Self.isEnabled, "Opt-in only — set LECTURE_RECORDER_RUN_LOCAL_NOTES_ACCEPTANCE=1 to run against the real on-device model.")

        let driver = RealFoundationModelsSessionDriver()
        let availability = driver.availability()
        guard case .available = availability else {
            throw XCTSkip("Apple's on-device model is unavailable in this environment: \(availability)")
        }

        let sessionID = UUID()
        let unitsWindow0 = [
            unit(0, "Today we cover Newton's second law: force equals mass times acceleration, written F equals m a."),
            unit(1, "We derive the impulse-momentum theorem by integrating force over time.")
        ]
        let unitsWindow1 = [
            unit(2, "Next, we discuss conservation of momentum in an isolated two-body collision."),
            unit(3, "Finally, a worked example: a 2 kilogram cart moving at 3 meters per second collides with a stationary 1 kilogram cart.")
        ]
        let allUnits = unitsWindow0 + unitsWindow1
        let window0 = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 1, unitCount: 2, isOversizedSingleUnit: false)
        let window1 = NotesInputWindow(windowIndex: 1, firstSequenceNumber: 2, lastSequenceNumber: 3, unitCount: 2, isOversizedSingleUnit: false)
        let fingerprint = TranscriptSourceFingerprint.compute(sessionID: sessionID, units: allUnits)
        let generationRecord = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            windowPlan: NotesWindowPlan(windows: [window0, window1]),
            provenance: FoundationModelsNotesConfiguration.generationProvenance
        )
        let snapshot = NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: allUnits,
            fingerprint: fingerprint
        )

        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let analysis0 = try await generator.analyzeWindow(units: unitsWindow0, window: window0, generation: generationRecord)
        let analysis1 = try await generator.analyzeWindow(units: unitsWindow1, window: window1, generation: generationRecord)
        XCTAssertFalse(analysis0.items.isEmpty, "expected the real on-device model to produce at least one grounded note item for window 0")
        XCTAssertFalse(analysis1.items.isEmpty, "expected the real on-device model to produce at least one grounded note item for window 1")

        XCTAssertNoThrow(try NotesIntegrityValidator.validate(analysis: analysis0, generation: generationRecord, plannedWindow: window0, sourceSnapshot: snapshot))
        XCTAssertNoThrow(try NotesIntegrityValidator.validate(analysis: analysis1, generation: generationRecord, plannedWindow: window1, sourceSnapshot: snapshot))

        let document = try await generator.synthesize(analyses: [analysis0, analysis1], generation: generationRecord)
        XCTAssertFalse(document.overview.isEmpty)
        XCTAssertFalse(document.sections.isEmpty)

        XCTAssertNoThrow(try NotesIntegrityValidator.validateCoverage(analyses: [analysis0, analysis1], generation: generationRecord, sourceSnapshot: snapshot))
        XCTAssertNoThrow(try NotesIntegrityValidator.validate(document: document, generation: generationRecord, sourceSnapshot: snapshot))
    }
}
