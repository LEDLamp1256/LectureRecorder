import XCTest
@testable import LectureRecorder

final class MLXLectureNotesGeneratorTests: XCTestCase {

    private func unit(_ sequence: Int, _ text: String) -> NotesTranscriptSourceUnit {
        NotesTranscriptSourceUnit(
            sequenceNumber: sequence,
            chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequence),
            text: text,
            startOffsetSeconds: Double(sequence) * 30,
            durationSeconds: 30
        )
    }

    private func window(first: Int = 0, last: Int = 1) -> NotesInputWindow {
        NotesInputWindow(
            windowIndex: 0, firstSequenceNumber: first, lastSequenceNumber: last,
            unitCount: last - first + 1, isOversizedSingleUnit: false
        )
    }

    private func generationRecord(sessionID: UUID = UUID()) -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: []),
            windowPlan: NotesWindowPlan(windows: [window()]),
            provenance: MLXNotesConfiguration.generationProvenance
        )
    }

    private func makeGenerator(driver: FakeMLXSessionDriver) -> MLXLectureNotesGenerator {
        MLXLectureNotesGenerator(sessionDriver: driver)
    }

    private func item(sessionID: UUID, sequence: Int, body: String = "content") -> LectureNoteItem {
        LectureNoteItem(
            kind: .explanation, body: body, fidelity: .transcriptSupported,
            sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: sequence)]
        )
    }

    private func analysis(generation: LectureNotesGenerationRecord, windowIndex: Int, items: [LectureNoteItem]) -> LectureNotesWindowAnalysis {
        LectureNotesWindowAnalysis(
            generationID: generation.generationID, sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint, windowIndex: windowIndex,
            ownedRange: NotesSourceReference(sessionID: generation.sessionID, firstSequenceNumber: 0, lastSequenceNumber: 0),
            items: items
        )
    }

    // MARK: - Availability

    func testAvailabilityDelegatesToDriver() {
        let driver = FakeMLXSessionDriver()
        driver.setAvailability(.unavailable(description: "model not provisioned"))
        let generator = makeGenerator(driver: driver)
        XCTAssertEqual(generator.availabilityForNewGeneration(), .unavailable(description: "model not provisioned"))
    }

    // MARK: - Context-budget preflight

    func testAnalyzeWindowFailsClosedWhenPreflightExceedsOperationalCeiling() async {
        let driver = FakeMLXSessionDriver(operationalContextCeiling: 1_000)
        driver.setDefaultTokenCount(.success(999_999))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(units: [unit(0, "hello")], window: window(), generation: generation)
            XCTFail("expected contextBudgetExceeded")
        } catch let error as MLXLectureNotesBackendError {
            guard case .contextBudgetExceeded = error else {
                return XCTFail("expected contextBudgetExceeded, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 0, "must never dispatch a request known to exceed budget")
    }

    /// Correction 2: token-count failure must never authorize dispatch —
    /// it fails closed through its own typed error, never a byte estimate.
    func testAnalyzeWindowFailsClosedWhenTokenCountingFails() async {
        struct SomeDriverFailure: Error {}
        let driver = FakeMLXSessionDriver()
        driver.setDefaultTokenCount(.failure(SomeDriverFailure()))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(units: [unit(0, "hello")], window: window(), generation: generation)
            XCTFail("expected contextPreflightUnavailable")
        } catch let error as MLXLectureNotesBackendError {
            guard case .contextPreflightUnavailable = error else {
                return XCTFail("expected contextPreflightUnavailable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 0, "token-count failure must never authorize dispatch")
    }

    /// Correction 2: a genuine cancellation during token counting must
    /// remain a `CancellationError`, never be reported as an ordinary
    /// token-count-unavailable failure.
    func testTokenCountingCancellationIsNotMisreportedAsPreflightUnavailable() async {
        let driver = FakeMLXSessionDriver()
        driver.setDefaultTokenCount(.failure(CancellationError()))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(units: [unit(0, "hello")], window: window(), generation: generation)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: - Guided-output decoding + support-index validation

    func testAnalyzeWindowSucceedsWithValidJSON() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"items":[{"kind":"explanation","body":"A key idea.","fidelity":"transcriptSupported","sourceReferences":[{"firstSequenceNumber":0,"lastSequenceNumber":1}],"uncertaintyNote":""}]}
        """)))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        let analysis = try await generator.analyzeWindow(
            units: [unit(0, "line zero"), unit(1, "line one")], window: window(), generation: generation
        )
        XCTAssertEqual(analysis.items.count, 1)
        XCTAssertEqual(analysis.items[0].body, "A key idea.")
        XCTAssertEqual(analysis.items[0].fidelity, .transcriptSupported)
        XCTAssertEqual(driver.respondCallCount, 1)
    }

    func testAnalyzeWindowFailsClosedOnOutOfRangeSourceReference() async {
        let driver = FakeMLXSessionDriver()
        // sequenceNumber 5 was never given to this window (only 0 and 1) —
        // must fail closed on both retry attempts.
        for _ in 0..<2 {
            driver.enqueueRespond(.success(.stub(jsonText: """
            {"items":[{"kind":"explanation","body":"claims an unseen line","fidelity":"transcriptSupported","sourceReferences":[{"firstSequenceNumber":5,"lastSequenceNumber":5}],"uncertaintyNote":""}]}
            """)))
        }
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(
                units: [unit(0, "a"), unit(1, "b")], window: window(), generation: generation
            )
            XCTFail("expected invalidSourceReference to fail closed")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .invalidSourceReference)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 2, "invalidSourceReference is retryable — both attempts should run")
    }

    func testUncertainFidelityWithoutUncertaintyNoteFailsClosed() async {
        let driver = FakeMLXSessionDriver()
        for _ in 0..<2 {
            driver.enqueueRespond(.success(.stub(jsonText: """
            {"items":[{"kind":"explanation","body":"ambiguous","fidelity":"uncertain","sourceReferences":[{"firstSequenceNumber":0,"lastSequenceNumber":0}],"uncertaintyNote":""}]}
            """)))
        }
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
            XCTFail("expected malformedResponse for missing uncertainty context")
        } catch let error as MLXLectureNotesBackendError {
            guard case .malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Retry behavior

    func testAnalyzeWindowRetriesOnceAfterMalformedResponseThenSucceeds() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: "not valid json")))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"items":[{"kind":"explanation","body":"recovered","fidelity":"transcriptSupported","sourceReferences":[{"firstSequenceNumber":0,"lastSequenceNumber":0}],"uncertaintyNote":""}]}
        """)))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        let analysis = try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
        XCTAssertEqual(analysis.items.first?.body, "recovered")
        XCTAssertEqual(driver.respondCallCount, 2)
    }

    func testAnalyzeWindowFailsAfterExhaustingRetries() async {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: "not valid json")))
        driver.enqueueRespond(.success(.stub(jsonText: "still not valid json")))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
            XCTFail("expected malformedResponse after exhausting retries")
        } catch let error as MLXLectureNotesBackendError {
            guard case .malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 2)
    }

    /// Correction 3: an incomplete/truncated guided-generation output from
    /// the MLX runtime must receive the same bounded retry as a malformed
    /// response, never escape unclassified.
    func testAnalyzeWindowRetriesOnIncompleteOutputThenSucceeds() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.failure(MLXGuidedGenerationRuntimeError.incompleteOutput("truncated")))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"items":[{"kind":"explanation","body":"recovered","fidelity":"transcriptSupported","sourceReferences":[{"firstSequenceNumber":0,"lastSequenceNumber":0}],"uncertaintyNote":""}]}
        """)))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        let analysis = try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
        XCTAssertEqual(analysis.items.first?.body, "recovered")
        XCTAssertEqual(driver.respondCallCount, 2)
    }

    /// Correction 3: a configuration-shaped MLX failure (bad schema/grammar/
    /// tokenizer template) must be treated as non-retryable — retrying the
    /// identical request cannot fix it.
    func testAnalyzeWindowDoesNotRetryConfigurationFailure() async {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.failure(MLXGuidedGenerationRuntimeError.configurationFailure("bad schema")))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
            XCTFail("expected configurationFailure")
        } catch let error as MLXLectureNotesBackendError {
            guard case .configurationFailure = error else {
                return XCTFail("expected configurationFailure, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 1, "configuration failures must not be retried")
    }

    /// An unclassified MLX runtime failure must also not be retried —
    /// "do not turn every runtime failure into a retry."
    func testAnalyzeWindowDoesNotRetryUnclassifiedRuntimeFailure() async {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.failure(MLXGuidedGenerationRuntimeError.unclassified("mystery failure")))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
            XCTFail("expected runtimeFailure")
        } catch let error as MLXLectureNotesBackendError {
            guard case .runtimeFailure = error else {
                return XCTFail("expected runtimeFailure, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 1, "unclassified runtime failures must not be retried")
    }

    // MARK: - Synthesis

    func testSynthesizeAssemblesSectionsAndOverviewWithoutSplitting() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"sections":[{"heading":"Part one","firstItemIndex":0,"lastItemIndex":0}]}
        """)))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"overview":"A short overview."}
        """)))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()
        let analysis = analysis(generation: generation, windowIndex: 0, items: [item(sessionID: generation.sessionID, sequence: 0)])

        let document = try await generator.synthesize(analyses: [analysis], generation: generation)
        XCTAssertEqual(document.overview, "A short overview.")
        XCTAssertEqual(document.sections.count, 1)
        XCTAssertEqual(document.sections[0].heading, "Part one")
        XCTAssertEqual(document.sections[0].items.count, 1)
        XCTAssertEqual(document.sections[0].items[0].body, "content")
        XCTAssertEqual(driver.respondCallCount, 2)
    }

    /// Correction 1: when the full item set does not fit one section-plan
    /// request, the generator must bisect and recurse — never fail
    /// immediately, and never drop any item.
    func testSynthesizeSplitsSectionPlanWhenFullSetDoesNotFitThenPreservesAllItems() async throws {
        let driver = FakeMLXSessionDriver()
        // Preflight order: [full-set section-plan (too big), piece A, piece B, overview (fits)].
        driver.enqueueTokenCount(.success(999_999))
        driver.enqueueTokenCount(.success(100))
        driver.enqueueTokenCount(.success(100))
        driver.enqueueTokenCount(.success(100))
        // Dispatch order: piece A section-plan, piece B section-plan, overview.
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"sections":[{"heading":"Part A","firstItemIndex":0,"lastItemIndex":1}]}
        """)))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"sections":[{"heading":"Part B","firstItemIndex":0,"lastItemIndex":1}]}
        """)))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"overview":"Combined overview."}
        """)))

        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()
        let items = (0..<4).map { item(sessionID: generation.sessionID, sequence: $0, body: "item-\($0)") }
        let analysis = analysis(generation: generation, windowIndex: 0, items: items)

        let document = try await generator.synthesize(analyses: [analysis], generation: generation)
        XCTAssertEqual(document.overview, "Combined overview.")
        XCTAssertEqual(document.sections.map(\.heading), ["Part A", "Part B"])
        let allSectionedBodies = document.sections.flatMap { $0.items.map(\.body) }
        XCTAssertEqual(allSectionedBodies, ["item-0", "item-1", "item-2", "item-3"], "every original item must survive, in order, with none dropped")
        XCTAssertEqual(driver.respondCallCount, 3)
    }

    /// Correction 1: when the overview's full input does not fit, the
    /// generator must hierarchically reduce (never concatenate everything
    /// into one unchecked final request) until a reduced set fits.
    func testSynthesizeReducesOverviewInputWhenFullSetDoesNotFit() async throws {
        let driver = FakeMLXSessionDriver()
        // Preflight order: [section-plan (fits), overview-1st-check (too big),
        // reduction-batch (fits), overview-2nd-check-after-reduction (fits)].
        driver.enqueueTokenCount(.success(100))
        driver.enqueueTokenCount(.success(999_999))
        driver.enqueueTokenCount(.success(100))
        driver.enqueueTokenCount(.success(100))
        // Dispatch order: section-plan, reduction, overview.
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"sections":[{"heading":"Everything","firstItemIndex":0,"lastItemIndex":1}]}
        """)))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"items":[{"kind":"explanation","body":"condensed","fidelity":"transcriptSupported","sourceReferences":[{"firstSequenceNumber":0,"lastSequenceNumber":1}],"uncertaintyNote":""}]}
        """)))
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"overview":"Reduced overview."}
        """)))

        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()
        let items = [
            item(sessionID: generation.sessionID, sequence: 0, body: "item-0"),
            item(sessionID: generation.sessionID, sequence: 1, body: "item-1"),
        ]
        let analysis = analysis(generation: generation, windowIndex: 0, items: items)

        let document = try await generator.synthesize(analyses: [analysis], generation: generation)
        XCTAssertEqual(document.overview, "Reduced overview.")
        // Detailed sections are never affected by overview reduction --
        // both original items still appear there.
        XCTAssertEqual(document.sections.flatMap { $0.items.map(\.body) }, ["item-0", "item-1"])
        XCTAssertEqual(driver.respondCallCount, 3)
    }

    /// An irreducible single item that still cannot fit must fail closed,
    /// not loop or crash.
    func testSynthesizeFailsClosedWhenSingleItemCannotFitEvenAfterMaxBisection() async {
        let driver = FakeMLXSessionDriver()
        driver.setDefaultTokenCount(.success(999_999))
        let generator = MLXLectureNotesGenerator(sessionDriver: driver, maxReductionLevels: 2)
        let generation = generationRecord()
        let analysis = analysis(generation: generation, windowIndex: 0, items: [item(sessionID: generation.sessionID, sequence: 0)])

        do {
            _ = try await generator.synthesize(analyses: [analysis], generation: generation)
            XCTFail("expected contextBudgetExceeded")
        } catch let error as MLXLectureNotesBackendError {
            guard case .contextBudgetExceeded = error else {
                return XCTFail("expected contextBudgetExceeded, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 0, "must never dispatch a request known to exceed budget")
    }

    // MARK: - Cancellation

    func testAnalyzeWindowPropagatesCancellation() async {
        let driver = FakeMLXSessionDriver()
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        let task = Task {
            try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation to propagate")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: - Diagnostics never affect the outcome

    func testDiagnosticRecorderDoesNotAffectResult() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"items":[{"kind":"explanation","body":"content","fidelity":"transcriptSupported","sourceReferences":[{"firstSequenceNumber":0,"lastSequenceNumber":0}],"uncertaintyNote":""}]}
        """)))
        var recordedEvents: [MLXNotesDiagnosticEvent] = []
        let generator = MLXLectureNotesGenerator(sessionDriver: driver, diagnosticRecorder: { recordedEvents.append($0) })
        let generation = generationRecord()

        let analysis = try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
        XCTAssertEqual(analysis.items.first?.body, "content")
        XCTAssertFalse(recordedEvents.isEmpty, "diagnostics should have observed the preflight, purely additively")
    }
}
