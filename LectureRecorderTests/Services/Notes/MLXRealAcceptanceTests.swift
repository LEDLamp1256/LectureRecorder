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

        let driver = RealMLXSessionDriver()
        switch driver.availability() {
        case .available:
            break
        case .unavailable(let description):
            throw XCTSkip("Pinned MLX model assets are not provisioned/verified: \(description)")
        }

        let generator = MLXLectureNotesGenerator(sessionDriver: driver)
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
