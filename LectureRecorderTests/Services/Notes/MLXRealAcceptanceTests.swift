import XCTest
@testable import LectureRecorder

/// Opt-in real local-MLX acceptance path — disabled by default and never
/// part of normal deterministic-suite success. Enable with:
///
///     LECTURE_RECORDER_RUN_MLX_NOTES_ACCEPTANCE=1
///
/// Never downloads the model: it must already be verified in place (see
/// `MLXModelVerifier`) before this test is enabled. Reports a clear
/// `XCTSkip` when the opt-in variable is absent, or when the pinned model
/// assets are not provisioned, rather than failing the run — mirroring
/// `FoundationModelsRealAcceptanceTests`'s established convention.
final class MLXRealAcceptanceTests: XCTestCase {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LECTURE_RECORDER_RUN_MLX_NOTES_ACCEPTANCE"] == "1"
    }

    /// Purely additive: when acceptance diagnostics are enabled, prints
    /// privacy-safe `MLXNotesDiagnosticEvent` fields (stage/token counts/
    /// reserve/limit/fit result) -- never transcript, prompt, or generated
    /// Notes text.
    private func diagnosticRecorderIfEnabled() -> (@Sendable (MLXNotesDiagnosticEvent) -> Void)? {
        guard AcceptanceDiagnosticLogger.isEnabled else { return nil }
        return { event in
            print("[MLX acceptance] stage=\(event.stage) estimatedInputTokens=\(String(describing: event.estimatedInputTokens)) responseReserve=\(event.responseReserve) contextLimit=\(event.contextLimit) fitDirectly=\(event.fitDirectly)")
        }
    }

    /// Small test-only decorator that forwards every call to a real
    /// `MLXSessionDriving` conformer, additionally printing privacy-safe
    /// `MLXGuidedGenerationOutcome` metadata (token counts, timing, memory
    /// -- never `jsonText`) when acceptance diagnostics are enabled. Not
    /// production code; exists only so this opt-in acceptance test can
    /// surface real generation diagnostics without a larger diagnostics
    /// framework.
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
                print("[MLX acceptance] promptTokenCount=\(outcome.promptTokenCount) generatedTokenCount=\(outcome.generatedTokenCount) generationSeconds=\(String(describing: outcome.generationSeconds)) memory=\(String(describing: outcome.memory))")
            }
            return outcome
        }
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

    func testRealMLXNotesWindowAnalysisProducesStructuredOutput() async throws {
        try XCTSkipUnless(Self.isEnabled, "Set LECTURE_RECORDER_RUN_MLX_NOTES_ACCEPTANCE=1 to run this opt-in real-MLX acceptance test.")

        let realDriver = RealMLXSessionDriver()
        switch realDriver.availability() {
        case .available:
            break
        case .unavailable(let description):
            throw XCTSkip("Pinned MLX model assets are not provisioned/verified: \(description)")
        }
        let driver = RecordingSessionDriver(wrapped: realDriver)
        if AcceptanceDiagnosticLogger.isEnabled {
            print("[MLX acceptance] modelIdentifier=\(MLXNotesConfiguration.generatorIdentifier) modelRevision=\(MLXNotesConfiguration.generatorVersion) nativeContextLength=\(driver.nativeContextLength) operationalContextCeiling=\(driver.operationalContextCeiling)")
        }

        let generator = MLXLectureNotesGenerator(sessionDriver: driver, diagnosticRecorder: diagnosticRecorderIfEnabled())
        let sessionID = UUID()
        let units = [
            unit(0, "Today we cover binary search trees."),
            unit(1, "A binary search tree keeps left children smaller than their parent."),
            unit(2, "Insertion and lookup both run in O(log n) time on a balanced tree."),
        ]
        let window = NotesInputWindow(
            windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 2, unitCount: units.count, isOversizedSingleUnit: false
        )
        let generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units),
            windowPlan: NotesWindowPlan(windows: [window]),
            provenance: MLXNotesConfiguration.generationProvenance
        )

        let analysis = try await generator.analyzeWindow(units: units, window: window, generation: generation)
        XCTAssertFalse(analysis.items.isEmpty, "expected at least one grounded note item from the real local model")
        for item in analysis.items {
            XCTAssertFalse(item.body.isEmpty)
            XCTAssertFalse(item.sourceReferences.isEmpty)
        }
    }
}
