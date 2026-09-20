import XCTest
@testable import LectureRecorder

/// MLX-3: opt-in, test-only measurement harness for the current MLX Notes
/// and Summary generators against one real, representative completed
/// lecture session's full transcript — never the small synthetic fixtures
/// `MLXRealAcceptanceTests`/`MLXSummaryRealAcceptanceTests` use. Disabled by
/// default and never part of the deterministic suite. Enable with:
///
///     LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE=1
///     LECTURE_RECORDER_ACCEPTANCE_SESSION_ID=<completed session UUID>
///     LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY=<absolute local path>
///
/// Optionally also set `LECTURE_RECORDER_ACCEPTANCE_DIAGNOSTICS=1` (the
/// existing `AcceptanceDiagnosticLogger` gate) for the ordinary structural
/// diagnostics trace, unrelated to this harness's own local artifacts.
///
/// Bypasses `LectureNotesGenerationService`/`LectureSummaryGenerationService`
/// entirely and drives `MLXLectureNotesGenerator`/`MLXLectureSummaryGenerator`
/// directly — exactly as `MLXRealAcceptanceTests`/`MLXSummaryRealAcceptanceTests`
/// already do. This measures generator quality/performance only: because it
/// bypasses both generation services and `AppEnvironment` entirely, it
/// proves nothing about either service's durable-recovery behavior, and
/// nothing about `AppEnvironment`'s production provider routing — that
/// routing is covered separately by `AppEnvironmentTests`.
///
/// Never downloads or reprovisions the pinned model:
/// `RealMLXSessionDriver.availability()` must already report `.available`,
/// exactly like the two existing acceptance tests.
///
/// Once the master gate is `1`, every other configuration/session/model
/// problem is reported as an explicit `XCTFail`, never a silent `XCTSkip` —
/// an intentionally requested acceptance run must never appear to have
/// "passed" by silently skipping.
final class MLXRealLectureAcceptanceTests: XCTestCase {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE"] == "1"
    }

    private enum HarnessConfigurationError: LocalizedError {
        case missingSessionID
        case malformedSessionID(String)
        case missingOutputDirectory
        case outputDirectoryUnavailable(String, String)
        case runDirectoryCollision(String)

        var errorDescription: String? {
            switch self {
            case .missingSessionID:
                return "LECTURE_RECORDER_ACCEPTANCE_SESSION_ID is required when LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE=1."
            case .malformedSessionID(let value):
                return "LECTURE_RECORDER_ACCEPTANCE_SESSION_ID '\(value)' is not a valid UUID."
            case .missingOutputDirectory:
                return "LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY is required when LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE=1."
            case .outputDirectoryUnavailable(let path, let reason):
                return "LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY '\(path)' is unusable: \(reason)"
            case .runDirectoryCollision(let path):
                return "Acceptance run directory already exists (unexpected UUID collision): \(path)"
            }
        }
    }

    /// One real MLX call's structural/timing-only diagnostics — never
    /// `instructions`/`prompt`/`jsonSchema`/`jsonText`. `kind` distinguishes
    /// a token-count preflight call from a real guided-generation call;
    /// only the latter has generation/memory fields.
    private struct CallRecord: Encodable {
        var callIndex: Int
        var kind: String
        var wallClockSeconds: Double
        var promptTokenCount: Int?
        var generatedTokenCount: Int?
        var generationSeconds: Double?
        var activeMemoryBytes: Int?
        var peakMemoryBytes: Int?
    }

    /// Wraps exactly one real `MLXSessionDriving` conformer, recording
    /// per-call structural/timing diagnostics (see `CallRecord`) without
    /// ever touching call content. An `actor` so its own bookkeeping is
    /// safely isolated; this harness only ever awaits one call at a time.
    /// Shared, unmodified, by both the Notes and Summary generators below —
    /// satisfying "exactly one `RealMLXSessionDriver`" while adding
    /// zero-content-exposure diagnostics.
    private actor TimingSessionDriver: MLXSessionDriving {
        private let wrapped: any MLXSessionDriving
        private(set) var records: [CallRecord] = []

        nonisolated var nativeContextLength: Int { wrapped.nativeContextLength }
        nonisolated var operationalContextCeiling: Int { wrapped.operationalContextCeiling }
        nonisolated func availability() -> LectureNotesGenerationAvailability { wrapped.availability() }

        init(wrapped: any MLXSessionDriving) {
            self.wrapped = wrapped
        }

        func preparedInputTokenCount(instructions: String, prompt: String) async throws -> Int {
            let start = AcceptanceDiagnosticLogger.startInstant()
            let count = try await wrapped.preparedInputTokenCount(instructions: instructions, prompt: prompt)
            records.append(CallRecord(
                callIndex: records.count,
                kind: "tokenCount",
                wallClockSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start),
                promptTokenCount: count,
                generatedTokenCount: nil,
                generationSeconds: nil,
                activeMemoryBytes: nil,
                peakMemoryBytes: nil
            ))
            return count
        }

        func respond(
            instructions: String, prompt: String, jsonSchema: String, maxOutputTokens: Int
        ) async throws -> MLXGuidedGenerationOutcome {
            let start = AcceptanceDiagnosticLogger.startInstant()
            let outcome = try await wrapped.respond(
                instructions: instructions, prompt: prompt, jsonSchema: jsonSchema, maxOutputTokens: maxOutputTokens
            )
            records.append(CallRecord(
                callIndex: records.count,
                kind: "respond",
                wallClockSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start),
                promptTokenCount: outcome.promptTokenCount,
                generatedTokenCount: outcome.generatedTokenCount,
                generationSeconds: outcome.generationSeconds,
                activeMemoryBytes: outcome.memory?.activeMemoryBytes,
                peakMemoryBytes: outcome.memory?.peakMemoryBytes
            ))
            return outcome
        }
    }

    private struct TimedWindow: Encodable {
        var windowIndex: Int
        var seconds: Double
    }

    private struct TimedBatch: Encodable {
        var batchIndex: Int
        var seconds: Double
    }

    /// Non-sensitive run result: identifiers, counts, and timings only —
    /// never transcript, prompt, Notes, or Summary text.
    private struct RunResult: Encodable {
        var runID: String
        var startedAt: Date
        var finishedAt: Date
        var sessionID: String
        var transcriptFingerprintDigestHex: String
        var transcriptUnitCount: Int
        var modelIdentifier: String
        var modelRevision: String
        var backendIdentifier: String
        var nativeContextLength: Int
        var operationalContextCeiling: Int

        var notesPlannedWindowCount: Int
        var notesPerWindowSeconds: [TimedWindow]
        var notesSynthesisSeconds: Double
        var notesTotalSeconds: Double
        var notesSectionCount: Int
        var notesItemCount: Int
        var notesRealCallRecords: [CallRecord]

        var summaryPlannedBatchCount: Int
        var summaryPlanningSeconds: Double
        var summaryPerBatchSeconds: [TimedBatch]
        var summarySynthesisSeconds: Double
        var summaryTotalSeconds: Double
        var summarySectionCount: Int
        var summaryPassageCount: Int
        var summaryRealCallRecords: [CallRecord]
        var summaryIntegrityValidation: String

        var totalEndToEndSeconds: Double
        var persistenceWarnings: [String]
        var retryMeasurementNote: String
        var memoryMeasurementNote: String
    }

    func testRealMLXNotesAndSummaryOnRepresentativeLecture() async throws {
        try XCTSkipUnless(
            Self.isEnabled,
            "Set LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE=1 to run this opt-in MLX-3 real-lecture acceptance test."
        )

        let environment = ProcessInfo.processInfo.environment

        guard let sessionIDString = environment["LECTURE_RECORDER_ACCEPTANCE_SESSION_ID"], !sessionIDString.isEmpty else {
            XCTFail(HarnessConfigurationError.missingSessionID.localizedDescription)
            return
        }
        guard let sessionID = UUID(uuidString: sessionIDString) else {
            XCTFail(HarnessConfigurationError.malformedSessionID(sessionIDString).localizedDescription)
            return
        }
        guard let outputDirectoryPath = environment["LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY"], !outputDirectoryPath.isEmpty else {
            XCTFail(HarnessConfigurationError.missingOutputDirectory.localizedDescription)
            return
        }
        let outputRootURL = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputRootURL, withIntermediateDirectories: true)
        } catch {
            XCTFail(HarnessConfigurationError.outputDirectoryUnavailable(outputDirectoryPath, error.localizedDescription).localizedDescription)
            return
        }

        // Exactly one real MLX session driver, never downloaded/reprovisioned
        // here — must already be verified in place.
        let realDriver = RealMLXSessionDriver()
        switch realDriver.availability() {
        case .available:
            break
        case .unavailable(let description):
            XCTFail("Pinned MLX model assets are not provisioned/verified: \(description)")
            return
        }
        let timingDriver = TimingSessionDriver(wrapped: realDriver)

        // A unique, non-overwriting run subdirectory. Never write into the
        // selected lecture's real session directory.
        let runID = UUID()
        let runStartDate = Date()
        let runDirectory = outputRootURL.appendingPathComponent(
            "mlx3-\(sessionID.uuidString)-\(runID.uuidString)", isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: runDirectory.path) else {
            XCTFail(HarnessConfigurationError.runDirectoryCollision(runDirectory.path).localizedDescription)
            return
        }
        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        } catch {
            XCTFail("Unable to create acceptance run directory: \(error.localizedDescription)")
            return
        }
        let notesWindowAnalysesDirectory = runDirectory.appendingPathComponent("notes-window-analyses", isDirectory: true)
        let summaryBatchAnalysesDirectory = runDirectory.appendingPathComponent("summary-batch-analyses", isDirectory: true)

        var persistenceWarnings: [String] = []
        func persist<T: Encodable>(_ value: T, to url: URL) {
            do {
                try AtomicFileWriter.writeJSON(value, to: url)
            } catch {
                persistenceWarnings.append("Unable to write \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let overallStart = AcceptanceDiagnosticLogger.startInstant()

        // 1/2: load the real transcript through the exact production
        // source-loading path — never a parallel ad hoc loader.
        let transcriptLoader = NotesTranscriptSourceLoader(transcriptionStore: TranscriptionStore())
        let transcriptSnapshot: NotesTranscriptSourceSnapshot
        do {
            transcriptSnapshot = try await transcriptLoader.loadCurrentSnapshot(sessionID: sessionID)
        } catch {
            XCTFail("Unable to load session \(sessionID)'s transcript through the production path: \(error.localizedDescription)")
            return
        }
        guard !transcriptSnapshot.units.isEmpty else {
            XCTFail("Session \(sessionID) has an empty transcript; nothing to measure.")
            return
        }

        // 3: the same planner and MLX budget production uses.
        let windowPlan = NotesWindowPlan(
            windows: NotesWindowPlanner.plan(units: transcriptSnapshot.units, budget: MLXNotesConfiguration.windowBudget)
        )
        do {
            try windowPlan.validateCoversExactly(transcriptSnapshot)
        } catch {
            XCTFail("Computed window plan does not exactly cover the loaded transcript: \(error.localizedDescription)")
            return
        }

        // 4/5: one shared driver, real Notes generator.
        let notesGenerator = MLXLectureNotesGenerator(sessionDriver: timingDriver)
        let notesGeneration = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: transcriptSnapshot.fingerprint,
            windowPlan: windowPlan,
            provenance: MLXNotesConfiguration.generationProvenance
        )

        // 6: analyze every planned window in deterministic source order,
        // persisting each successful result as it completes.
        var windowAnalyses: [LectureNotesWindowAnalysis] = []
        var notesPerWindowSeconds: [TimedWindow] = []
        let orderedWindows = windowPlan.windows.sorted { $0.windowIndex < $1.windowIndex }
        for window in orderedWindows {
            let unitsInWindow = transcriptSnapshot.units.filter {
                $0.sequenceNumber >= window.firstSequenceNumber && $0.sequenceNumber <= window.lastSequenceNumber
            }
            let windowStart = AcceptanceDiagnosticLogger.startInstant()
            let analysis: LectureNotesWindowAnalysis
            do {
                analysis = try await notesGenerator.analyzeWindow(units: unitsInWindow, window: window, generation: notesGeneration)
            } catch {
                XCTFail("Notes window #\(window.windowIndex) analysis failed after \(windowAnalyses.count) prior windows succeeded: \(error.localizedDescription)")
                return
            }
            let seconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: windowStart)
            windowAnalyses.append(analysis)
            notesPerWindowSeconds.append(TimedWindow(windowIndex: window.windowIndex, seconds: seconds))
            persist(
                analysis,
                to: notesWindowAnalysesDirectory.appendingPathComponent("window_\(String(format: "%04d", window.windowIndex)).json")
            )
        }

        // 7: synthesize the complete Notes document through the existing
        // MLX path — no weakened validation.
        let notesSynthesisStart = AcceptanceDiagnosticLogger.startInstant()
        let notesDocument: LectureNotesDocument
        do {
            notesDocument = try await notesGenerator.synthesize(analyses: windowAnalyses, generation: notesGeneration)
        } catch {
            XCTFail("Notes synthesis failed: \(error.localizedDescription)")
            return
        }
        let notesSynthesisSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: notesSynthesisStart)
        persist(notesDocument, to: runDirectory.appendingPathComponent("notes-document.json"))

        let notesTotalSeconds = notesPerWindowSeconds.reduce(0) { $0 + $1.seconds } + notesSynthesisSeconds
        let notesRealCallCount = await timingDriver.records.count

        // 8/9: build the in-memory Summary source through the existing
        // Summary contract (the same pure builder `LectureSummarySourceLoader`
        // uses), then generate the dedicated Summary with the same shared
        // driver.
        let sourceSnapshot: LectureSummarySourceSnapshot
        do {
            sourceSnapshot = try LectureSummarySourceBuilder.build(
                generation: notesGeneration, analyses: windowAnalyses, document: notesDocument, transcriptSnapshot: transcriptSnapshot
            )
        } catch {
            XCTFail("Unable to build the in-memory Summary source snapshot from the generated Notes document: \(error.localizedDescription)")
            return
        }

        let summaryGenerator = MLXLectureSummaryGenerator(sessionDriver: timingDriver)
        let summaryPlanStart = AcceptanceDiagnosticLogger.startInstant()
        let summaryPlan: LectureSummaryPlan
        do {
            summaryPlan = try await summaryGenerator.makePlan(for: sourceSnapshot)
        } catch {
            XCTFail("Summary planning failed: \(error.localizedDescription)")
            return
        }
        let summaryPlanningSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: summaryPlanStart)

        let summaryGeneration = LectureSummaryGenerationRecord.newGeneration(
            sessionID: sessionID,
            sourceNotesGenerationID: notesGeneration.generationID,
            transcriptFingerprint: transcriptSnapshot.fingerprint,
            sourceNotesDocumentFingerprint: sourceSnapshot.sourceNotesDocumentFingerprint,
            batchPlan: summaryPlan,
            provenance: MLXSummaryConfiguration.generationProvenance
        )

        var summaryAnalyses: [LectureSummaryAnalysis] = []
        var summaryPerBatchSeconds: [TimedBatch] = []
        let orderedBatches = summaryPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        for batch in orderedBatches {
            let batchStart = AcceptanceDiagnosticLogger.startInstant()
            let analysis: LectureSummaryAnalysis
            do {
                analysis = try await summaryGenerator.generateAnalysis(for: batch, generation: summaryGeneration, source: sourceSnapshot)
            } catch {
                XCTFail("Summary batch #\(batch.batchIndex) analysis failed after \(summaryAnalyses.count) prior batches succeeded: \(error.localizedDescription)")
                return
            }
            let seconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: batchStart)
            do {
                try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: summaryGeneration, source: sourceSnapshot)
            } catch {
                XCTFail("Summary batch #\(batch.batchIndex) analysis failed independent integrity validation: \(error.localizedDescription)")
                return
            }
            summaryAnalyses.append(analysis)
            summaryPerBatchSeconds.append(TimedBatch(batchIndex: batch.batchIndex, seconds: seconds))
            persist(
                analysis,
                to: summaryBatchAnalysesDirectory.appendingPathComponent("batch_\(String(format: "%04d", batch.batchIndex)).json")
            )
        }

        let summarySynthesisStart = AcceptanceDiagnosticLogger.startInstant()
        let summaryDocument: LectureSummaryDocument
        do {
            summaryDocument = try await summaryGenerator.generateDocument(from: summaryAnalyses, generation: summaryGeneration, source: sourceSnapshot)
        } catch {
            XCTFail("Summary synthesis failed: \(error.localizedDescription)")
            return
        }
        let summarySynthesisSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: summarySynthesisStart)
        do {
            try LectureSummaryIntegrityValidator.validate(document: summaryDocument, generation: summaryGeneration, source: sourceSnapshot)
        } catch {
            XCTFail("Summary document failed independent integrity validation: \(error.localizedDescription)")
            return
        }
        persist(summaryDocument, to: runDirectory.appendingPathComponent("summary-document.json"))

        let summaryTotalSeconds = summaryPlanningSeconds + summaryPerBatchSeconds.reduce(0) { $0 + $1.seconds } + summarySynthesisSeconds
        let totalElapsedSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: overallStart)

        // 10: shared-driver reuse evidence — every call, Notes and Summary
        // alike, went through the one `timingDriver`/`realDriver` pair. The
        // call-index boundary below splits its accumulated records into a
        // Notes-phase prefix and a Summary-phase suffix for reporting; a
        // single outlying-duration call at index 0 (model load) followed by
        // much shorter calls throughout both phases is the evidence that
        // exactly one model load served the entire run.
        let allCallRecords = await timingDriver.records
        let notesCallRecords = Array(allCallRecords.prefix(notesRealCallCount))
        let summaryCallRecords = Array(allCallRecords.suffix(from: notesRealCallCount))

        let result = RunResult(
            runID: runID.uuidString,
            startedAt: runStartDate,
            finishedAt: Date(),
            sessionID: sessionID.uuidString,
            transcriptFingerprintDigestHex: transcriptSnapshot.fingerprint.digestHex,
            transcriptUnitCount: transcriptSnapshot.units.count,
            modelIdentifier: MLXNotesConfiguration.generatorIdentifier,
            modelRevision: MLXNotesConfiguration.generatorVersion,
            backendIdentifier: MLXNotesConfiguration.backendIdentifier,
            nativeContextLength: timingDriver.nativeContextLength,
            operationalContextCeiling: timingDriver.operationalContextCeiling,
            notesPlannedWindowCount: windowPlan.windows.count,
            notesPerWindowSeconds: notesPerWindowSeconds,
            notesSynthesisSeconds: notesSynthesisSeconds,
            notesTotalSeconds: notesTotalSeconds,
            notesSectionCount: notesDocument.sections.count,
            notesItemCount: notesDocument.sections.reduce(0) { $0 + $1.items.count },
            notesRealCallRecords: notesCallRecords,
            summaryPlannedBatchCount: summaryPlan.batches.count,
            summaryPlanningSeconds: summaryPlanningSeconds,
            summaryPerBatchSeconds: summaryPerBatchSeconds,
            summarySynthesisSeconds: summarySynthesisSeconds,
            summaryTotalSeconds: summaryTotalSeconds,
            summarySectionCount: summaryDocument.sections.count,
            summaryPassageCount: summaryDocument.sections.reduce(0) { $0 + $1.passages.count },
            summaryRealCallRecords: summaryCallRecords,
            summaryIntegrityValidation: "validated (document + every analysis) via LectureSummaryIntegrityValidator; a failure there would have already failed this run before reaching this point",
            totalEndToEndSeconds: totalElapsedSeconds,
            persistenceWarnings: persistenceWarnings,
            retryMeasurementNote: "withGeneratedOutputRetry is private to each MLX generator and the existing diagnosticRecorder hook only fires for preflight-fit events, never retry attempts — no per-window/per-batch retry count is observable from this generator's public surface. notesRealCallRecords/summaryRealCallRecords (total respond()+tokenCount call counts per phase) are the closest available proxy; they are not a precise retry counter.",
            memoryMeasurementNote: "activeMemoryBytes/peakMemoryBytes above are exactly what RealMLXSessionDriver.respond already reports per call (MLXRuntimeMLX's Memory.activeMemory/Memory.peakMemory) — no separate in-process memory subsystem was added for this harness. No OS-level (RSS/wired) measurement is captured in-process; that would require an external measurement (e.g. wrapping the test invocation) and is out of this patch's scope."
        )
        persist(result, to: runDirectory.appendingPathComponent("result.json"))

        XCTAssertFalse(notesDocument.sections.isEmpty, "expected at least one Notes section from the real local model")
        XCTAssertFalse(summaryDocument.sections.isEmpty, "expected at least one Summary section from the real local model")
        XCTAssertTrue(persistenceWarnings.isEmpty, "acceptance artifact persistence warnings: \(persistenceWarnings.joined(separator: "; "))")
    }
}
