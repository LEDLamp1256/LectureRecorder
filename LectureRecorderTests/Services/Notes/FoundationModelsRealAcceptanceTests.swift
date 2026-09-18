import XCTest
@testable import LectureRecorder

/// Thread-safe, in-memory sink for `FoundationModelsSummaryDiagnosticEvent`s
/// recorded during the real-acceptance run below. `print` output is not
/// reliably captured by this Xcode/xctestrun environment's `.xcresult`, so
/// this collector — not `print` — is what makes diagnostics reach the
/// XCTest failure message itself.
private final class RealAcceptanceDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [FoundationModelsSummaryDiagnosticEvent] = []

    var events: [FoundationModelsSummaryDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: FoundationModelsSummaryDiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        storedEvents.append(event)
    }

    var chronologicalDescription: String {
        let events = events
        guard !events.isEmpty else { return "no generated-output diagnostic events were recorded" }
        return events.enumerated().map { index, event in
            "[\(index + 1)] stage=\(event.stage.rawValue) attempt=\(event.attempt) error=\(event.error) generatedFidelity=\(event.generatedFidelity?.rawValue ?? "n/a") requiredFloorFidelity=\(event.requiredFloorFidelity?.rawValue ?? "n/a") supportIndices=\(event.supportIndices.map(String.init(describing:)) ?? "n/a")"
        }.joined(separator: ", ")
    }
}

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

    /// Narrow T5-F2 acceptance using the same opt-in local-model mechanism:
    /// real token preflight, one small batch, final synthesis, local support
    /// mapping, and the production Summary integrity validator.
    func testRealLocalSummaryGenerationProducesIntegrityValidatedGroundedSummary() async throws {
        try XCTSkipUnless(Self.isEnabled, "Opt-in only — set LECTURE_RECORDER_RUN_LOCAL_NOTES_ACCEPTANCE=1 to run against the real on-device model.")

        let driver = RealFoundationModelsSessionDriver()
        let availability = driver.availability()
        guard case .available = availability else {
            throw XCTSkip("Apple's on-device model is unavailable in this environment: \(availability)")
        }

        let source = try SummaryTestSupport.source()
        let diagnostics = RealAcceptanceDiagnosticCollector()
        let backend = FoundationModelsLectureSummaryGenerator(sessionDriver: driver) { event in
            diagnostics.record(event)
            // Secondary convenience only — the XCTFail below is what makes
            // diagnostics reach the recorded .xcresult on failure.
            print("T5-F2 Summary diagnostic: stage=\(event.stage.rawValue) attempt=\(event.attempt) error=\(event.error) generatedFidelity=\(event.generatedFidelity?.rawValue ?? "n/a") requiredFloorFidelity=\(event.requiredFloorFidelity?.rawValue ?? "n/a") supportIndices=\(event.supportIndices.map(String.init(describing:)) ?? "n/a")")
        }

        do {
            let plan = try await backend.makePlan(for: source)
            let generation = LectureSummaryGenerationRecord.newGeneration(
                sessionID: source.sessionID,
                sourceNotesGenerationID: source.sourceNotesGenerationID,
                transcriptFingerprint: source.transcriptFingerprint,
                sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
                batchPlan: plan,
                provenance: backend.provenance
            )

            var analyses: [LectureSummaryAnalysis] = []
            for batch in plan.batches.sorted(by: { $0.batchIndex < $1.batchIndex }) {
                analyses.append(try await backend.generateAnalysis(
                    for: batch, generation: generation, source: source
                ))
            }
            let document = try await backend.generateDocument(
                from: analyses, generation: generation, source: source
            )
            XCTAssertFalse(analyses.flatMap(\.passages).isEmpty)
            XCTAssertFalse(document.sections.isEmpty)
            XCTAssertNoThrow(try LectureSummaryIntegrityValidator.validate(
                document: document, generation: generation, source: source
            ))

            let firstBatch = plan.batches[0]
            let batchIDs = Set(firstBatch.sourceItemIDs)
            let firstBatchItems = source.sourceItems.filter { batchIDs.contains($0.item.id) }
            let batchPrompt = FoundationModelsLectureSummaryGenerator.encodeSourceItems(firstBatchItems)
            let batchSchema = try FoundationModelsLectureSummaryGenerator.passagesSchema(
                inputCount: firstBatchItems.count
            )
            let batchTokens = await driver.estimatedTokenCount(
                instructions: FoundationModelsLectureSummaryGenerator.batchInstructions,
                prompt: batchPrompt,
                schema: batchSchema
            )
            let carriers = analyses.sorted(by: { $0.batchIndex < $1.batchIndex }).flatMap(\.passages).map {
                FoundationModelsSummaryCarrier(
                    text: $0.text,
                    supportingNoteItemIDs: $0.supportingNoteItemIDs,
                    sourceReferences: $0.sourceReferences,
                    fidelity: $0.fidelity,
                    uncertaintyNote: $0.uncertaintyNote
                )
            }
            let structureSchema = try FoundationModelsLectureSummaryGenerator.structureSchema(
                inputCount: carriers.count
            )
            let structureTokens = await driver.estimatedTokenCount(
                instructions: FoundationModelsLectureSummaryGenerator.finalStructureInstructions,
                prompt: FoundationModelsLectureSummaryGenerator.encodeCarriers(carriers),
                schema: structureSchema
            )
            let measuredBatchTokens = batchTokens.map(String.init) ?? "unavailable"
            let measuredStructureTokens = structureTokens.map(String.init) ?? "unavailable"
            print("T5-F2 Foundation Models measurements: contextSize=\(driver.contextTokenBudget), batchInputTokens=\(measuredBatchTokens), finalStructureInputTokens=\(measuredStructureTokens)")
        } catch {
            XCTFail("Summary generation failed: \(error). Diagnostics (chronological): \(diagnostics.chronologicalDescription)")
        }
    }
}
