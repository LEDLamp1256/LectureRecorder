import XCTest
@testable import LectureRecorder

/// Opt-in real local-MLX Summary acceptance path — disabled by default and
/// never part of normal deterministic-suite success. Enable with:
///
///     LECTURE_RECORDER_RUN_MLX_SUMMARY_ACCEPTANCE=1
///
/// Never downloads the model: it must already be verified in place (see
/// `MLXModelVerifier`) before this test is enabled. Mirrors
/// `MLXRealAcceptanceTests`'s (Notes) established convention exactly,
/// including its `XCTSkip`-not-fail behavior for the opt-in variable and
/// for an unprovisioned model.
///
/// The Summary source snapshot is a small, deterministic in-memory fixture
/// (`SummaryTestSupport.source()`) — this test never runs real MLX Notes
/// generation to produce it, keeping this acceptance path narrowly scoped
/// to the Summary backend alone.
final class MLXSummaryRealAcceptanceTests: XCTestCase {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LECTURE_RECORDER_RUN_MLX_SUMMARY_ACCEPTANCE"] == "1"
    }

    /// Purely additive: when acceptance diagnostics are enabled, prints
    /// privacy-safe `MLXSummaryDiagnosticEvent` fields — never transcript,
    /// prompt, or generated Summary text.
    private func diagnosticRecorderIfEnabled() -> (@Sendable (MLXSummaryDiagnosticEvent) -> Void)? {
        guard AcceptanceDiagnosticLogger.isEnabled else { return nil }
        return { event in
            print("[MLX Summary acceptance] stage=\(event.stage) estimatedInputTokens=\(String(describing: event.estimatedInputTokens)) responseReserve=\(event.responseReserve) contextLimit=\(event.contextLimit) fitDirectly=\(event.fitDirectly)")
        }
    }

    /// Small test-only decorator forwarding every call to a real
    /// `MLXSessionDriving` conformer, additionally printing privacy-safe
    /// `MLXGuidedGenerationOutcome` metadata (token counts, timing, memory —
    /// never `jsonText`) when acceptance diagnostics are enabled. Mirrors
    /// `MLXRealAcceptanceTests.RecordingSessionDriver` exactly.
    private struct RecordingSessionDriver: MLXSessionDriving {
        let wrapped: any MLXSessionDriving
        var nativeContextLength: Int { wrapped.nativeContextLength }
        var operationalContextCeiling: Int { wrapped.operationalContextCeiling }

        func availability() -> LectureNotesGenerationAvailability { wrapped.availability() }

        func preparedInputTokenCount(instructions: String, prompt: String) async throws -> Int {
            try await wrapped.preparedInputTokenCount(instructions: instructions, prompt: prompt)
        }

        func respond(
            instructions: String, prompt: String, jsonSchema: String, maxOutputTokens: Int
        ) async throws -> MLXGuidedGenerationOutcome {
            let outcome = try await wrapped.respond(
                instructions: instructions, prompt: prompt, jsonSchema: jsonSchema, maxOutputTokens: maxOutputTokens
            )
            if AcceptanceDiagnosticLogger.isEnabled {
                print("[MLX Summary acceptance] promptTokenCount=\(outcome.promptTokenCount) generatedTokenCount=\(outcome.generatedTokenCount) generationSeconds=\(String(describing: outcome.generationSeconds)) memory=\(String(describing: outcome.memory))")
            }
            return outcome
        }
    }

    func testRealMLXSummaryAnalysisAndDocumentProduceGroundedOutput() async throws {
        try XCTSkipUnless(Self.isEnabled, "Set LECTURE_RECORDER_RUN_MLX_SUMMARY_ACCEPTANCE=1 to run this opt-in real-MLX acceptance test.")

        let realDriver = RealMLXSessionDriver()
        switch realDriver.availability() {
        case .available:
            break
        case .unavailable(let description):
            throw XCTSkip("Pinned MLX model assets are not provisioned/verified: \(description)")
        }
        let driver = RecordingSessionDriver(wrapped: realDriver)
        if AcceptanceDiagnosticLogger.isEnabled {
            print("[MLX Summary acceptance] modelIdentifier=\(MLXSummaryConfiguration.generatorIdentifier) modelRevision=\(MLXSummaryConfiguration.generatorVersion) nativeContextLength=\(driver.nativeContextLength) operationalContextCeiling=\(driver.operationalContextCeiling)")
        }

        // A modest, deterministic, in-memory source — a small fixed Notes
        // document flattened into 3 source items (see `SummaryTestSupport`).
        // Never a representative 60-90 minute lecture; that scale belongs to
        // MLX-3.
        let source = try SummaryTestSupport.source()
        // A single batch covering all 3 source items keeps this run to
        // exactly one analysis call plus one final-structure call plus one
        // final-section call — the minimum real MLX round trips needed to
        // exercise both `generateAnalysis` and `generateDocument`.
        let plan = try LectureSummaryPlanner.plan(
            source: source,
            budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 60_000, maxItemsPerBatch: 3)
        )
        XCTAssertEqual(plan.batches.count, 1, "expected the small fixture source to fit in a single batch")
        let generation = LectureSummaryGenerationRecord.newGeneration(
            sessionID: source.sessionID,
            sourceNotesGenerationID: source.sourceNotesGenerationID,
            transcriptFingerprint: source.transcriptFingerprint,
            sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
            batchPlan: plan,
            provenance: MLXSummaryConfiguration.generationProvenance
        )

        let generator = MLXLectureSummaryGenerator(sessionDriver: driver, diagnosticRecorder: diagnosticRecorderIfEnabled())

        let batch = plan.batches[0]
        let analysis = try await generator.generateAnalysis(for: batch, generation: generation, source: source)
        XCTAssertFalse(analysis.passages.isEmpty, "expected at least one grounded Summary passage from the real local model")
        for passage in analysis.passages {
            XCTAssertFalse(passage.text.isEmpty)
            XCTAssertFalse(passage.supportingNoteItemIDs.isEmpty)
            XCTAssertFalse(passage.sourceReferences.isEmpty)
        }

        let document = try await generator.generateDocument(from: [analysis], generation: generation, source: source)
        XCTAssertFalse(document.sections.isEmpty, "expected at least one Summary section from the real local model")
        var totalPassages = 0
        for section in document.sections {
            XCTAssertFalse(section.heading.isEmpty)
            XCTAssertFalse(section.passages.isEmpty)
            for passage in section.passages {
                XCTAssertFalse(passage.text.isEmpty)
                XCTAssertFalse(passage.supportingNoteItemIDs.isEmpty)
                XCTAssertFalse(passage.sourceReferences.isEmpty)
                totalPassages += 1
            }
        }
        print("[MLX Summary acceptance] sections=\(document.sections.count) totalPassages=\(totalPassages)")

        // Integrity/grounding validation: `generateAnalysis`/`generateDocument`
        // already run this internally and would have thrown otherwise, but
        // re-running it here on the returned artifacts is an explicit,
        // independent proof the acceptance criteria actually require.
        try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: generation, source: source)
        try LectureSummaryIntegrityValidator.validate(document: document, generation: generation, source: source)

        XCTAssertEqual(document.provenance.backendIdentifier, MLXSummaryConfiguration.backendIdentifier)
        XCTAssertEqual(document.provenance.generatorIdentifier, MLXSummaryConfiguration.generatorIdentifier)
    }
}
