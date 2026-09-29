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

    private func generationRecord(
        sessionID: UUID = UUID(),
        plannedWindow: NotesInputWindow? = nil,
        provenance: LectureNotesGenerationProvenance = MLXNotesConfiguration.generationProvenance
    ) -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: []),
            windowPlan: NotesWindowPlan(windows: [plannedWindow ?? window()]),
            provenance: provenance
        )
    }

    private func makeGenerator(driver: FakeMLXSessionDriver) -> MLXLectureNotesGenerator {
        MLXLectureNotesGenerator(sessionDriver: driver)
    }

    /// One v8 window-analysis item.
    private func candidate(_ body: String, kind: String = "explanation", references: [(Int, Int)]) -> [String: Any] {
        [
            "kind": kind, "body": body,
            "sourceReferences": references.map { ["firstSequenceNumber": $0.0, "lastSequenceNumber": $0.1] },
        ]
    }

    private func itemsJSON(_ candidates: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["items": candidates]), as: UTF8.self)
    }

    private func noteJSON(sequenceNumber: Int) -> String {
        itemsJSON([candidate("A grounded point.", references: [(sequenceNumber, sequenceNumber)])])
    }

    private func sourceReferenceRangeAlternatives(allowedSequenceNumbers: [Int]) throws -> Set<String> {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            MLXLectureNotesGenerator.windowAnalysisJSONSchema(allowedSequenceNumbers: allowedSequenceNumbers).utf8
        )) as? [String: Any])
        let item = try XCTUnwrap((((schema["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"]) as? [String: Any])
        let references = try XCTUnwrap((item["properties"] as? [String: Any])?["sourceReferences"] as? [String: Any])
        let alternatives = try XCTUnwrap((references["items"] as? [String: Any])?["anyOf"] as? [[String: Any]])
        return Set(try alternatives.map { alternative in
            let properties = try XCTUnwrap(alternative["properties"] as? [String: Any])
            let first = try XCTUnwrap((properties["firstSequenceNumber"] as? [String: Any])?["const"] as? Int)
            let last = try XCTUnwrap((properties["lastSequenceNumber"] as? [String: Any])?["const"] as? Int)
            return "\(first)-\(last)"
        })
    }

    /// The Notes item schema's `anyOf` variants, keyed by their single
    /// allowed fidelity value.
    private func noteItemSchemaVariants(_ schemaData: Data) throws -> [String: [String: Any]] {
        let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        let rootProperties = schema?["properties"] as? [String: Any]
        let items = rootProperties?["items"] as? [String: Any]
        let item = items?["items"] as? [String: Any]
        let variants = try XCTUnwrap(item?["anyOf"] as? [[String: Any]])
        var byFidelity: [String: [String: Any]] = [:]
        for variant in variants {
            let properties = variant["properties"] as? [String: Any]
            let fidelity = properties?["fidelity"] as? [String: Any]
            let allowed = try XCTUnwrap(fidelity?["enum"] as? [String])
            XCTAssertEqual(allowed.count, 1, "each variant allows exactly one fidelity")
            XCTAssertNil(byFidelity[allowed[0]], "one variant per fidelity")
            byFidelity[allowed[0]] = variant
        }
        return byFidelity
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

    // MARK: - Model-specific provenance

    func testDefaultGeneratorRejects14BProvenanceWithoutDispatch() async {
        let driver = FakeMLXSessionDriver()
        let generator = MLXLectureNotesGenerator(sessionDriver: driver)
        await assertIncompatibleProvenance(
            generator: generator,
            generation: generationRecord(provenance: MLXNotesConfiguration.generationProvenance(for: .qwen3_14b_4bit))
        )
        XCTAssertEqual(driver.respondCallCount, 0)
    }

    func test14BGeneratorRejects8BProvenanceWithoutDispatch() async {
        let driver = FakeMLXSessionDriver()
        let generator = MLXLectureNotesGenerator(
            sessionDriver: driver, modelDescriptor: .qwen3_14b_4bit
        )
        await assertIncompatibleProvenance(generator: generator, generation: generationRecord())
        XCTAssertEqual(driver.respondCallCount, 0)
    }

    func test14BGeneratorAccepts14BProvenance() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: noteJSON(sequenceNumber: 0))))
        let generator = MLXLectureNotesGenerator(
            sessionDriver: driver, modelDescriptor: .qwen3_14b_4bit
        )

        let analysis = try await generator.analyzeWindow(
            units: [unit(0, "source")],
            window: window(first: 0, last: 0),
            generation: generationRecord(provenance: MLXNotesConfiguration.generationProvenance(for: .qwen3_14b_4bit))
        )

        XCTAssertEqual(analysis.items.count, 1)
    }

    private func assertIncompatibleProvenance(
        generator: MLXLectureNotesGenerator,
        generation: LectureNotesGenerationRecord
    ) async {
        do {
            _ = try await generator.analyzeWindow(
                units: [unit(0, "source")], window: window(first: 0, last: 0), generation: generation
            )
            XCTFail("expected incompatibleProvenance")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .incompatibleProvenance)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Window analysis is one generation call

    func testAnalyzeWindowSendsCompleteOriginalWindowInOneGenerationCall() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: noteJSON(sequenceNumber: 16))))
        let generator = MLXLectureNotesGenerator(sessionDriver: driver)
        let plannedWindow = window(first: 16, last: 18)
        let units = [unit(16, "first original"), unit(17, "second original"), unit(18, "third original")]

        let analysis = try await generator.analyzeWindow(
            units: units,
            window: plannedWindow,
            generation: generationRecord(plannedWindow: plannedWindow)
        )

        XCTAssertEqual(analysis.items.map(\.body), ["A grounded point."])
        XCTAssertEqual(driver.respondCallCount, 1, "window analysis must not dispatch any downstream LLM judgment")
        let request = try XCTUnwrap(driver.respondArguments.first)
        XCTAssertEqual(request.instructions, MLXLectureNotesGenerator.analysisInstructions)
        XCTAssertEqual(request.prompt, "[16] first original\n[17] second original\n[18] third original")
        XCTAssertEqual(
            request.jsonSchema,
            MLXLectureNotesGenerator.windowAnalysisJSONSchema(allowedSequenceNumbers: [16, 17, 18])
        )
    }

    func testZeroGeneratedItemsReturnsValidEmptyAnalysis() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: "{\"items\":[]}")))
        let generator = MLXLectureNotesGenerator(sessionDriver: driver)
        let sessionID = UUID()
        let units = [unit(0, "first"), unit(1, "second")]
        let fingerprint = TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        let snapshot = NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: fingerprint
        )
        let plannedWindow = window()
        let generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            windowPlan: NotesWindowPlan(windows: [plannedWindow]),
            provenance: MLXNotesConfiguration.generationProvenance
        )

        let analysis = try await generator.analyzeWindow(
            units: units, window: plannedWindow, generation: generation
        )

        XCTAssertTrue(analysis.items.isEmpty)
        XCTAssertNoThrow(try NotesIntegrityValidator.validate(
            analysis: analysis,
            generation: generation,
            plannedWindow: plannedWindow,
            sourceSnapshot: snapshot
        ))
        XCTAssertEqual(driver.respondCallCount, 1, "an empty analysis is accepted without retry")
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

    /// v10: window analysis — and only window analysis — is sampled, with
    /// exactly the recipe's fixed configuration.
    func testWindowAnalysisSendsTheV10SamplingOnEveryAttempt() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: "not json")))
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([candidate("A key idea.", references: [(0, 1)])]))))
        _ = try await makeGenerator(driver: driver).analyzeWindow(
            units: [unit(0, "line zero"), unit(1, "line one")], window: window(), generation: generationRecord()
        )
        XCTAssertEqual(driver.respondSamplings, [MLXNotesConfiguration.windowAnalysisSampling, MLXNotesConfiguration.windowAnalysisSampling],
                       "each attempt carries the same fixed configuration; the driver builds a fresh sampler per call")
        XCTAssertEqual(MLXNotesConfiguration.windowAnalysisSampling.seed, 20_260_928)
    }

    /// Resume determinism: a window's request is identical whether it runs
    /// first, after other windows, or after a restart — it depends only on
    /// its own units, never on earlier calls.
    func testAWindowRequestDoesNotDependOnEarlierWindows() async throws {
        let later = [unit(8, "line eight"), unit(9, "line nine")]
        let fresh = FakeMLXSessionDriver()
        fresh.enqueueRespond(.success(.stub(jsonText: #"{"items":[]}"#)))
        _ = try await makeGenerator(driver: fresh).analyzeWindow(units: later, window: window(first: 8, last: 9), generation: generationRecord())

        let continuing = FakeMLXSessionDriver()
        continuing.enqueueRespond(.success(.stub(jsonText: itemsJSON([candidate("Earlier idea.", references: [(0, 1)])]))))
        continuing.enqueueRespond(.success(.stub(jsonText: #"{"items":[]}"#)))
        let generator = makeGenerator(driver: continuing)
        _ = try await generator.analyzeWindow(units: [unit(0, "line zero"), unit(1, "line one")], window: window(), generation: generationRecord())
        _ = try await generator.analyzeWindow(units: later, window: window(first: 8, last: 9), generation: generationRecord())

        let a = try XCTUnwrap(fresh.respondArguments.last)
        let b = try XCTUnwrap(continuing.respondArguments.last)
        XCTAssertEqual([a.instructions, a.prompt, a.jsonSchema], [b.instructions, b.prompt, b.jsonSchema])
        XCTAssertEqual(a.maxOutputTokens, b.maxOutputTokens)
        XCTAssertEqual(fresh.respondSamplings.last, continuing.respondSamplings.last)
    }

    func testAnalyzeWindowSucceedsWithValidJSON() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([candidate("A key idea.", references: [(0, 1)])]))))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()
        XCTAssertEqual(generation.provenance.recipeVersion, "mlx1-notes-v15")

        let analysis = try await generator.analyzeWindow(
            units: [unit(0, "line zero"), unit(1, "line one")], window: window(), generation: generation
        )
        XCTAssertEqual(analysis.items.count, 1)
        XCTAssertEqual(analysis.items[0].body, "A key idea.")
        XCTAssertEqual(analysis.items[0].fidelity, .transcriptSupported)
        XCTAssertNil(analysis.items[0].uncertaintyNote)
        XCTAssertEqual(analysis.items[0].sourceReferences.map { "\($0.firstSequenceNumber)-\($0.lastSequenceNumber)" }, ["0-1"])
        XCTAssertEqual(driver.respondCallCount, 1)
    }

    func testAnalyzeWindowDispatchesDensityControlledRequestWithoutChangingPromptFormat() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([candidate("A key idea.", references: [(0, 1)])]))))
        let generator = makeGenerator(driver: driver)

        _ = try await generator.analyzeWindow(
            units: [unit(0, "line zero"), unit(1, "line one")], window: window(), generation: generationRecord()
        )

        let request = try XCTUnwrap(driver.respondArguments.first)
        XCTAssertTrue(request.instructions.contains("worth retaining for study"))
        XCTAssertTrue(request.instructions.contains("Consolidate overlapping or repeated material"))
        XCTAssertTrue(request.instructions.contains("Keep each body concise"))
        XCTAssertTrue(request.instructions.contains("Output no more than 12 items"))
        XCTAssertEqual(request.prompt, "[0] line zero\n[1] line one")
        XCTAssertEqual(request.maxOutputTokens, 4_096)
    }

    func testAnalyzeWindowCanonicalizesExactDuplicateSourceReferencesInFirstOccurrenceOrder() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([
            candidate("A grounded point.", references: [(4, 4), (4, 4), (5, 5), (4, 4)]),
        ]))))
        let analysis = try await makeGenerator(driver: driver).analyzeWindow(
            units: [unit(4, "line four"), unit(5, "line five")], window: window(first: 4, last: 5), generation: generationRecord()
        )
        XCTAssertEqual(
            analysis.items[0].sourceReferences.map { "\($0.firstSequenceNumber)-\($0.lastSequenceNumber)" },
            ["4-4", "5-5"]
        )
        XCTAssertEqual(driver.respondCallCount, 1, "exact duplicate references should be canonicalized without regeneration")
    }

    func testAnalyzeWindowFailsClosedOnOutOfRangeSourceReference() async {
        let driver = FakeMLXSessionDriver()
        // sequenceNumber 5 was never given to this window (only 0 and 1) —
        // the typed failure propagates without repeating the same
        // deterministic generation request.
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([candidate("Claims an unseen line.", references: [(5, 5)])]))))
        do {
            _ = try await makeGenerator(driver: driver).analyzeWindow(
                units: [unit(0, "a"), unit(1, "b")], window: window(), generation: generationRecord()
            )
            XCTFail("expected invalidSourceReference to fail closed")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .invalidSourceReference(firstSequenceNumber: 5, lastSequenceNumber: 5, allowedSequenceNumbers: [0, 1]))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 1, "invalidSourceReference must not repeat an identical generation request")
    }

    func testAnalysisInstructionsDescribeTheV8GroundedNotesContract() {
        let instructions = MLXLectureNotesGenerator.analysisInstructions
        for phrase in [
            "Create note items for what the lecture actually teaches that is worth retaining for study",
            "paraphrasing, grammatical cleanup, shortening, removing filler, restructuring spoken language, and writing clearly spoken mathematics in standard notation are all fine",
            "Every item's sourceReferences must cite the lines that support it, using only sequenceNumber values that appear in the given lines",
        ] {
            XCTAssertTrue(instructions.contains(phrase), phrase)
        }
        // No fidelity choice, reconstruction workflow, quotes, or verifier.
        for obsolete in ["transcriptSupported", "reconstructed", "fidelity", "repair", "heardAs", "quote", "evidence",
                         "uncertaintyNote", "verif", "\"uncertain\""] {
            XCTAssertFalse(instructions.contains(obsolete), obsolete)
        }
    }

    func testAnalysisInstructionsForbidDomainCompletion() {
        let instructions = MLXLectureNotesGenerator.analysisInstructions
        XCTAssertTrue(instructions.contains("State only what the lecturer provides: do not add definitions, formulas, consequences, or domain knowledge the lecturer did not give"))
        XCTAssertTrue(instructions.contains("a question or passing mention of a topic is not a reason to explain it"))
        // No domain-specific worked example that could prime a subject.
        for primed in ["center of mass", "curl", "Gauss", "Maxwell", "resistance", "Newton"] {
            XCTAssertFalse(instructions.contains(primed), primed)
        }
    }

    func testAnalysisInstructionsOmitGarbledMaterialItemByItem() {
        let instructions = MLXLectureNotesGenerator.analysisInstructions
        XCTAssertTrue(instructions.contains("If a passage is too garbled or ambiguous to understand confidently, leave out that note and keep using the other clear material in the window"))
        XCTAssertTrue(instructions.contains("Not every line or window needs a note; an empty items array is a valid answer"))
        XCTAssertTrue(instructions.contains("A change of subject is not by itself a reason to omit material"))
        XCTAssertFalse(instructions.contains("at least"), "no minimum item count")
    }

    /// Item-local omission is structural too: a window may return only its
    /// clear items after omitting a doubtful one, and that is accepted as is.
    func testWindowWithOneOmittedDamagedItemKeepsItsClearNeighbors() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([
            candidate("A stable sort keeps equal keys in their original relative order.", kind: "definition", references: [(0, 0)]),
            candidate("Merging two sorted halves takes linear time.", references: [(2, 2)]),
        ]))))
        let analysis = try await makeGenerator(driver: driver).analyzeWindow(
            units: [unit(0, "a stable sort keeps equal keys in their original relative order"),
                    unit(1, "and the the flerb of the zamp is either quartic or cubic I think"),
                    unit(2, "merging two sorted halves is just linear")],
            window: window(first: 0, last: 2), generation: generationRecord()
        )
        XCTAssertEqual(analysis.items.map(\.body), [
            "A stable sort keeps equal keys in their original relative order.", "Merging two sorted halves takes linear time.",
        ])
        XCTAssertEqual(analysis.items.flatMap(\.sourceReferences).map(\.firstSequenceNumber), [0, 2])
        XCTAssertEqual(driver.respondCallCount, 1)
    }

    /// New v8 Notes never carry a model-chosen fidelity or repair: the schema
    /// has no field for either, and stray values are ignored — every
    /// accepted new item is transcriptSupported with no reconstruction note.
    func testNewItemsAreAlwaysTranscriptSupportedAndTheModelCannotChooseFidelity() async throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MLXLectureNotesGenerator.windowAnalysisJSONSchema(allowedSequenceNumbers: [0]).utf8)) as? [String: Any])
        let item = try XCTUnwrap((((schema["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"]) as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(item["properties"] as? [String: Any]).keys), ["kind", "body", "sourceReferences"])
        XCTAssertEqual(item["required"] as? [String], ["kind", "body", "sourceReferences"])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)

        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"items":[{"kind":"formula","body":"v = dx/dt","fidelity":"reconstructed","uncertaintyNote":"Repaired notation.","repair":{"heardAs":"dee ex","recoveredAs":"dx"},"sourceReferences":[{"firstSequenceNumber":0,"lastSequenceNumber":0}]}]}
        """)))
        let analysis = try await makeGenerator(driver: driver).analyzeWindow(
            units: [unit(0, "velocity is dee ex over dee tee")], window: window(first: 0, last: 0), generation: generationRecord()
        )
        XCTAssertEqual(analysis.items.map(\.fidelity), [.transcriptSupported])
        XCTAssertEqual(analysis.items.map(\.uncertaintyNote), [nil])
    }

    /// Ordinary paraphrase and cleanup are simply grounded notes.
    func testParaphrasedCleanedUpItemIsTranscriptSupported() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([
            candidate("Merging two sorted halves takes linear time because each element is visited once.", references: [(0, 0)]),
        ]))))
        let analysis = try await makeGenerator(driver: driver).analyzeWindow(
            units: [unit(0, "um so when you, when you merge them, the two halves, it's linear right, 'cause you only look at each thing once")],
            window: window(first: 0, last: 0), generation: generationRecord()
        )
        XCTAssertEqual(analysis.items.map(\.fidelity), [.transcriptSupported])
    }

    func testWindowAnalysisSchemaAllowsEveryContiguousRange() throws {
        XCTAssertEqual(try sourceReferenceRangeAlternatives(allowedSequenceNumbers: [18, 19, 20]),
                       Set(["18-18", "18-19", "18-20", "19-19", "19-20", "20-20"]))
    }

    func testWindowAnalysisSchemaDoesNotBridgeMissingSequence() throws {
        let alternatives = try sourceReferenceRangeAlternatives(allowedSequenceNumbers: [16, 18, 19])
        XCTAssertEqual(alternatives, Set(["16-16", "18-18", "18-19", "19-19"]))
        XCTAssertFalse(alternatives.contains("16-18"))
    }

    func testWindowAnalysisSchemaUsesAnotherNoncontiguousSourceSet() throws {
        XCTAssertEqual(try sourceReferenceRangeAlternatives(allowedSequenceNumbers: [3, 7, 8, 12]),
                       Set(["3-3", "7-7", "7-8", "8-8", "12-12"]))
    }

    // MARK: - v8 recipe and resume compatibility

    func testRecipeIsV15AndPinsTheProductionModelRevision() {
        XCTAssertEqual(MLXNotesConfiguration.recipeVersion, "mlx1-notes-v15")
        XCTAssertEqual(MLXNotesConfiguration.generationProvenance, LectureNotesGenerationProvenance(
            recipeVersion: "mlx1-notes-v15", generatorIdentifier: "mlx-community/Qwen3-8B-4bit",
            generatorVersion: "545dc4251c05440727734bcd94334791f6ab0192", backendIdentifier: "mlx"
        ))
    }

    /// A v7, v8, v10, v11, v12, v13, or v14 generation (or one made with
    /// another revision of the same model) is never resumed as v15: both window analysis and
    /// synthesis fail closed before any model call, so a document's
    /// provenance always names the pipeline that produced it.
    func testIncompatibleRecipeOrRevisionIsNeverResumed() async throws {
        let current = MLXNotesConfiguration.generationProvenance
        var v7 = current
        v7.recipeVersion = "mlx1-notes-v7"
        var v8 = current
        v8.recipeVersion = "mlx1-notes-v8"
        var v10 = current
        v10.recipeVersion = "mlx1-notes-v10"
        var v11 = current
        v11.recipeVersion = "mlx1-notes-v11"
        var v12 = current
        v12.recipeVersion = "mlx1-notes-v12"
        var v13 = current
        v13.recipeVersion = "mlx1-notes-v13"
        var v14 = current
        v14.recipeVersion = "mlx1-notes-v14"
        var otherRevision = current
        otherRevision.generatorVersion = "0000000000000000000000000000000000000000"
        for provenance in [v7, v8, v10, v11, v12, v13, v14, otherRevision] {
            let driver = FakeMLXSessionDriver()
            let generation = generationRecord(provenance: provenance)
            do {
                _ = try await makeGenerator(driver: driver).analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
                XCTFail("expected incompatibleProvenance for \(provenance)")
            } catch let error as MLXLectureNotesBackendError {
                XCTAssertEqual(error, .incompatibleProvenance)
            }
            let analysis = self.analysis(generation: generation, windowIndex: 0, items: [item(sessionID: generation.sessionID, sequence: 0)])
            do {
                _ = try await makeGenerator(driver: driver).synthesize(analyses: [analysis], generation: generation)
                XCTFail("expected synthesis to reject \(provenance)")
            } catch let error as MLXLectureNotesBackendError {
                XCTAssertEqual(error, .incompatibleProvenance)
            }
            XCTAssertEqual(driver.respondCallCount, 0)
            XCTAssertEqual(driver.tokenCountCallCount, 0)
        }
        // The matching model + revision + recipe resumes normally.
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([candidate("A point.", references: [(0, 0)])]))))
        let resumed = try await makeGenerator(driver: driver).analyzeWindow(
            units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generationRecord(provenance: current)
        )
        XCTAssertEqual(resumed.items.count, 1)
    }

    func testAnalyzeWindowRetriesOnceAfterMalformedResponseThenSucceeds() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: "not valid json")))
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([candidate("recovered", references: [(0, 0)])]))))
        let analysis = try await makeGenerator(driver: driver).analyzeWindow(
            units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generationRecord()
        )
        XCTAssertEqual(analysis.items.first?.body, "recovered")
        XCTAssertEqual(driver.respondCallCount, 2)
        XCTAssertEqual(driver.respondArguments[1].prompt, driver.respondArguments[0].prompt, "window analysis keeps the plain single retry")
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

    /// Regression: a guided-generation call that reports success (no
    /// thrown MLXGuidedGenerationRuntimeError) but yields a genuinely
    /// empty jsonText must still classify as a retryable malformedResponse
    /// -- never crash, hang, or silently produce an empty note-item list.
    func testAnalyzeWindowFailsClosedOnEmptyGuidedGenerationOutput() async {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.success(.stub(jsonText: "")))
        driver.enqueueRespond(.success(.stub(jsonText: "")))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
            XCTFail("expected malformedResponse for empty guided-generation output")
        } catch let error as MLXLectureNotesBackendError {
            guard case .malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 2, "empty output is retryable -- both attempts should run")
    }

    /// A bounded guided-generation call that exhausts its output budget is
    /// not helped by repeating the same greedy request, so it must retain a
    /// typed distinction from malformed response text and fail immediately.
    func testAnalyzeWindowDoesNotRetryIncompleteOutput() async {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.failure(MLXGuidedGenerationRuntimeError.incompleteOutput("truncated")))
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()

        do {
            _ = try await generator.analyzeWindow(
                units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation
            )
            XCTFail("expected incompleteOutput")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .incompleteOutput("truncated"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 1, "incomplete output must not repeat an identical generation request")
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

    func testSynthesizeReturnsEmptyDocumentWithoutModelCallsWhenEveryWindowAbstained() async throws {
        let driver = FakeMLXSessionDriver()
        let generator = makeGenerator(driver: driver)
        let sessionID = UUID()
        let units = [unit(0, "first"), unit(1, "second")]
        let fingerprint = TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        let snapshot = NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: fingerprint
        )
        let generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            windowPlan: NotesWindowPlan(windows: [
                window(first: 0, last: 0),
                NotesInputWindow(windowIndex: 1, firstSequenceNumber: 1, lastSequenceNumber: 1, unitCount: 1, isOversizedSingleUnit: false),
            ]),
            provenance: MLXNotesConfiguration.generationProvenance
        )
        let abstained = [
            analysis(generation: generation, windowIndex: 0, items: []),
            analysis(generation: generation, windowIndex: 1, items: []),
        ]

        let document = try await generator.synthesize(analyses: abstained, generation: generation)

        XCTAssertTrue(document.sections.isEmpty)
        XCTAssertEqual(document.overview, "", "no placeholder content is presented as notes")
        XCTAssertEqual(document.provenance, generation.provenance)
        XCTAssertEqual(driver.respondCallCount, 0)
        XCTAssertEqual(driver.tokenCountCallCount, 0)
        XCTAssertNoThrow(try NotesIntegrityValidator.validate(
            document: document, generation: generation, sourceSnapshot: snapshot
        ))
    }

    /// Analyses for consecutive windows holding `itemCounts[w]` items each,
    /// with bodies "w<window>-<item>", and all their items in order.
    private func windowAnalyses(
        generation: LectureNotesGenerationRecord, itemCounts: [Int]
    ) -> (analyses: [LectureNotesWindowAnalysis], items: [LectureNoteItem]) {
        let analyses = itemCounts.enumerated().map { windowIndex, count in
            analysis(generation: generation, windowIndex: windowIndex, items: (0..<count).map {
                item(sessionID: generation.sessionID, sequence: windowIndex, body: "w\(windowIndex)-\($0)")
            })
        }
        return (analyses, analyses.flatMap(\.items))
    }

    /// A topic-terms response whose terms, joined with " / ", are `label`.
    private func topicJSON(_ label: String) -> String {
        termsJSON(label.components(separatedBy: " / "))
    }

    private func termsJSON(_ terms: [String]) -> String {
        let encoded = try! JSONEncoder().encode(["topicTerms": terms])
        return String(decoding: encoded, as: UTF8.self)
    }

    /// One section's summary response: exactly one sentence.
    private func summaryJSON(_ summary: String) -> String {
        let encoded = try! JSONEncoder().encode(["sectionSummaries": [summary]])
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Queues one single-sentence response per section, in section order.
    private func enqueueSummaries(_ summaries: [String], on driver: FakeMLXSessionDriver) {
        for summary in summaries {
            driver.enqueueRespond(.success(.stub(jsonText: summaryJSON(summary))))
        }
    }

    // MARK: Balanced partition

    private func sizes(_ windowCount: Int) throws -> [Int] {
        try MLXLectureNotesGenerator.balancedSectionWindowRanges(windowCount: windowCount).map(\.count)
    }

    func testBalancedPartitionOfSmallWindowCounts() throws {
        XCTAssertEqual(try sizes(1), [1])
        XCTAssertEqual(try sizes(2), [2])
        XCTAssertEqual(try sizes(3), [3])
        XCTAssertEqual(try sizes(4), [2, 2])
        XCTAssertEqual(try sizes(5), [3, 2])
        XCTAssertEqual(try sizes(7), [3, 2, 2])
        XCTAssertEqual(try sizes(10), [3, 3, 2, 2])
    }

    func testFifteenWindowsPartitionIntoSixSectionsOfTwoOrThreeWindows() throws {
        let ranges = try MLXLectureNotesGenerator.balancedSectionWindowRanges(windowCount: 15)
        XCTAssertEqual(ranges, [0...2, 3...5, 6...8, 9...10, 11...12, 13...14])
    }

    func testEveryPartitionIsContiguousBalancedAndBounded() throws {
        for windowCount in 1...24 {
            let ranges = try MLXLectureNotesGenerator.balancedSectionWindowRanges(windowCount: windowCount)
            XCTAssertEqual(ranges.first?.lowerBound, 0, "\(windowCount)")
            XCTAssertEqual(ranges.last?.upperBound, windowCount - 1, "\(windowCount)")
            XCTAssertEqual(ranges.flatMap { Array($0) }, Array(0..<windowCount), "\(windowCount): every window once, in order, no gap or overlap")
            XCTAssertTrue(ranges.allSatisfy { (1...3).contains($0.count) }, "\(windowCount)")
            XCTAssertLessThanOrEqual(ranges.count, 8, "\(windowCount)")
            let counts = ranges.map(\.count)
            XCTAssertLessThanOrEqual(counts.max()! - counts.min()!, 1, "\(windowCount): sizes differ by at most one")
            XCTAssertEqual(try MLXLectureNotesGenerator.balancedSectionWindowRanges(windowCount: windowCount), ranges, "deterministic")
        }
        XCTAssertEqual(try sizes(22), [3, 3, 3, 3, 3, 3, 2, 2], "rounding to 9 is capped at 8 sections")
        XCTAssertEqual(try sizes(24), Array(repeating: 3, count: 8))
    }

    func testOversizedInputFailsClearlyInsteadOfCreatingLargerSections() {
        for windowCount in [25, 40] {
            XCTAssertThrowsError(try MLXLectureNotesGenerator.balancedSectionWindowRanges(windowCount: windowCount)) {
                XCTAssertEqual($0 as? MLXLectureNotesBackendError,
                               .contextBudgetExceeded("detailed sections (\(windowCount) note windows exceed the supported 24)"))
            }
        }
        XCTAssertThrowsError(try MLXLectureNotesGenerator.balancedSectionWindowRanges(windowCount: 0))
    }

    // MARK: Item mapping

    func testSectionItemGroupsCoverEveryItemOnceInOrderUnchanged() throws {
        let generation = generationRecord()
        let (analyses, items) = windowAnalyses(generation: generation, itemCounts: [10, 6, 5, 11, 11, 7, 8, 6, 11, 10, 9, 8, 8, 7, 6])
        let groups = try MLXLectureNotesGenerator.sectionItemGroups(windowItems: analyses.map(\.items))

        XCTAssertEqual(items.count, 123)
        XCTAssertEqual(groups.map(\.count), [21, 29, 25, 19, 16, 13])
        XCTAssertEqual(groups.flatMap { $0 }, items, "every item exactly once, in order, with every field unchanged")
        XCTAssertEqual(groups.first?.first, items.first)
        XCTAssertEqual(groups.last?.last, items.last)
    }

    private func enqueueTopics(_ topics: [String], on driver: FakeMLXSessionDriver) {
        for topic in topics { driver.enqueueRespond(.success(.stub(jsonText: topicJSON(topic)))) }
    }

    private func titleJSON(_ title: String) -> String {
        String(decoding: try! JSONEncoder().encode(["title": title]), as: UTF8.self)
    }

    private func enqueueTitles(_ titles: [String], on driver: FakeMLXSessionDriver) {
        for title in titles { driver.enqueueRespond(.success(.stub(jsonText: titleJSON(title)))) }
    }

    func testSynthesisSummarizesSectionsThenLabelsEachWindowSeparately() async throws {
        let driver = FakeMLXSessionDriver()
        // Windows 0–5 hold 2, 1, 0 (abstained), 3, 1, 2 items: five non-empty
        // windows, partitioned 3 + 2.
        enqueueSummaries(["First part covers A.", "Second part covers B?"], on: driver)
        enqueueTopics(["Alpha", "Beta", "Gamma", "Delta", "Epsilon"], on: driver)
        enqueueTitles(["First title", "Second title"], on: driver)
        let generation = generationRecord()
        let (analyses, items) = windowAnalyses(generation: generation, itemCounts: [2, 1, 0, 3, 1, 2])

        let document = try await makeGenerator(driver: driver).synthesize(analyses: analyses.reversed(), generation: generation)

        XCTAssertEqual(document.overview, "First part covers A. Second part covers B?", "summaries joined in section order with single spaces")
        XCTAssertEqual(document.sections.map(\.heading), ["First title", "Second title"])
        XCTAssertEqual(document.sections.map(\.topics), [["Alpha", "Beta", "Gamma"], ["Delta", "Epsilon"]], "every window contributes its terms, in order")
        XCTAssertEqual(document.sections.map { $0.items.map(\.body) }, [
            ["w0-0", "w0-1", "w1-0", "w3-0", "w3-1", "w3-2"], ["w4-0", "w5-0", "w5-1"],
        ])
        XCTAssertEqual(document.sections.flatMap(\.items), items, "every item exactly once, in order, unchanged")
        XCTAssertEqual(driver.respondArguments.map(\.instructions),
                       Array(repeating: MLXLectureNotesGenerator.sectionSummaryInstructions, count: 2)
                           + Array(repeating: MLXLectureNotesGenerator.windowTopicInstructions, count: 5)
                           + Array(repeating: MLXLectureNotesGenerator.sectionTitleInstructions, count: 2),
                       "one summary call per section, then one topic call per non-empty window, then one title call per section")
        XCTAssertEqual(driver.respondSamplings, Array(repeating: nil, count: 9), "synthesis stays greedy")
        XCTAssertEqual(driver.respondArguments[0...1].map(\.prompt), [
            "Summarize this lecture section in one or two concise sentences.\n\nNotes in this lecture section:\n- w0-0\n- w0-1\n- w1-0\n- w3-0\n- w3-1\n- w3-2",
            "Summarize this lecture section in one or two concise sentences.\n\nNotes in this lecture section:\n- w4-0\n- w5-0\n- w5-1",
        ], "each summary request carries only its own section's notes, in section order")
        XCTAssertEqual(driver.respondArguments[2...6].map(\.prompt), [
            "Notes in this lecture segment:\n- w0-0\n- w0-1",
            "Notes in this lecture segment:\n- w1-0",
            "Notes in this lecture segment:\n- w3-0\n- w3-1\n- w3-2",
            "Notes in this lecture segment:\n- w4-0",
            "Notes in this lecture segment:\n- w5-0\n- w5-1",
        ], "each topic request carries only its own window's notes, in window order")
        XCTAssertEqual(driver.respondArguments[7...8].map(\.prompt), [
            "Summary of this lecture section:\nFirst part covers A.",
            "Summary of this lecture section:\nSecond part covers B?",
        ], "each title request carries only its own section's sentence")
    }

    /// Regression for the v10 acceptance: with distinct sentinel notes per
    /// section, summary request `i` sees only section `i`, and response `i`
    /// becomes section `i`'s sentence and title input — a model that
    /// describes the first section's notes can no longer fill another
    /// section's slot. Under the old single batched request, one request
    /// held every section and six slots came back from it.
    func testEachSectionSummaryRequestSeesOnlyItsOwnSection() async throws {
        let driver = FakeMLXSessionDriver()
        let windowCount = 15
        let summaries = (0..<6).map { "Covers section \($0)." }
        enqueueSummaries(summaries, on: driver)
        enqueueTopics((0..<windowCount).map { "Label \($0)" }, on: driver)
        enqueueTitles((0..<6).map { "Title \($0)" }, on: driver)
        let generation = generationRecord()
        let (analyses, items) = windowAnalyses(generation: generation, itemCounts: Array(repeating: 2, count: windowCount))
        let sectionWindows = try MLXLectureNotesGenerator.balancedSectionWindowRanges(windowCount: windowCount)
        XCTAssertEqual(sectionWindows.map(\.count), [3, 3, 3, 2, 2, 2])

        let document = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)

        let summaryRequests = driver.respondArguments.filter { $0.instructions == MLXLectureNotesGenerator.sectionSummaryInstructions }
        XCTAssertEqual(summaryRequests.count, 6, "exactly one summary request per section")
        for (section, request) in summaryRequests.enumerated() {
            XCTAssertTrue(request.prompt.hasPrefix("Summarize this lecture section in one or two concise sentences."))
            for window in 0..<windowCount {
                let isOwn = sectionWindows[section].contains(window)
                XCTAssertEqual(request.prompt.contains("- w\(window)-0"), isOwn,
                               "summary request \(section) must contain window \(window)'s notes only if they are its own")
            }
            XCTAssertEqual(request.jsonSchema, MLXLectureNotesGenerator.sectionSummaryJSONSchema)
        }
        XCTAssertEqual(document.overview, summaries.joined(separator: " "))
        let titleRequests = driver.respondArguments.filter { $0.instructions == MLXLectureNotesGenerator.sectionTitleInstructions }
        XCTAssertEqual(titleRequests.map(\.prompt), summaries.map { "Summary of this lecture section:\n\($0)" })
        XCTAssertEqual(document.sections.map(\.heading), (0..<6).map { "Title \($0)" })
        XCTAssertEqual(document.sections.flatMap(\.items), items, "all items exactly once, in order")
    }

    /// Alignment is structural: with distinct sentinel notes per window,
    /// request `i` contains only window `i`'s notes, and response `i`
    /// becomes label `i`, whatever the labels say.
    func testEachTopicRequestSeesOnlyItsOwnWindowAndItsResponseBecomesThatWindowsLabel() async throws {
        let driver = FakeMLXSessionDriver()
        let windowCount = 15
        enqueueSummaries((0..<6).map { "Summary \($0)." }, on: driver)
        enqueueTopics((0..<windowCount).map { "Label \($0)" }, on: driver)
        enqueueTitles((0..<6).map { "Title \($0)" }, on: driver)
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: [10, 6, 5, 11, 11, 7, 8, 6, 11, 10, 9, 8, 8, 7, 6])

        let document = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)

        let topicPrompts = driver.respondArguments.filter { $0.instructions == MLXLectureNotesGenerator.windowTopicInstructions }.map(\.prompt)
        XCTAssertEqual(topicPrompts.count, windowCount, "exactly one topic request per window")
        for (index, prompt) in topicPrompts.enumerated() {
            let ownBodies = analyses[index].items.map(\.body)
            XCTAssertEqual(prompt, (["Notes in this lecture segment:"] + ownBodies.map { "- \($0)" }).joined(separator: "\n"))
            for other in analyses.indices where other != index {
                XCTAssertFalse(prompt.contains("- w\(other)-"), "request \(index) must not contain window \(other)'s notes")
            }
        }
        XCTAssertEqual(document.sections.map(\.topics), [
            ["Label 0", "Label 1", "Label 2"], ["Label 3", "Label 4", "Label 5"], ["Label 6", "Label 7", "Label 8"],
            ["Label 9", "Label 10"], ["Label 11", "Label 12"], ["Label 13", "Label 14"],
        ], "call i's response is window i's terms")
    }

    func testTopicFailureOnAMiddleWindowAbortsSynthesisWithoutSubstitution() async throws {
        let driver = FakeMLXSessionDriver()
        enqueueSummaries(["One.", "Two."], on: driver)
        enqueueTopics(["First", "Second"], on: driver)
        driver.enqueueRespond(.failure(MLXGuidedGenerationRuntimeError.incompleteOutput("truncated")))
        enqueueTopics(["Fourth"], on: driver)
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: [1, 1, 1, 1])
        do {
            _ = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)
            XCTFail("a failed window label must fail synthesis")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .incompleteOutput("truncated"))
        }
        XCTAssertEqual(driver.respondCallCount, 5, "two section summaries, windows 0–1, then the failing window 2; window 3 is never labeled")
        XCTAssertEqual(driver.tokenCountCallCount, 5, "one preflight per section summary and one per window reached (0, 1, 2)")
    }

    func testSynthesizeAssemblesOneSectionWithoutSplitting() async throws {
        let driver = FakeMLXSessionDriver()
        enqueueSummaries(["A short overview."], on: driver)
        enqueueTopics(["Part one"], on: driver)
        enqueueTitles(["Part one title"], on: driver)
        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()
        let analysis = analysis(generation: generation, windowIndex: 0, items: [item(sessionID: generation.sessionID, sequence: 0)])

        let document = try await generator.synthesize(analyses: [analysis], generation: generation)
        XCTAssertEqual(document.overview, "A short overview.")
        XCTAssertEqual(document.sections.map(\.heading), ["Part one title"])
        XCTAssertEqual(document.sections.map(\.topics), [["Part one"]])
        XCTAssertEqual(document.sections[0].items, analysis.items)
        XCTAssertEqual(driver.respondCallCount, 3)
    }

    func testSummaryAndWindowTopicPromptsCarryNoMetadata() async throws {
        let driver = FakeMLXSessionDriver()
        enqueueSummaries(["Potential and resistors are introduced."], on: driver)
        enqueueTopics(["Potential", "Resistors"], on: driver)
        enqueueTitles(["Potential and Resistance"], on: driver)
        let generation = generationRecord()
        let sessionID = generation.sessionID
        let analyses = [
            analysis(generation: generation, windowIndex: 0, items: [
                LectureNoteItem(kind: .definition, body: "Potential is energy per charge.", fidelity: .reconstructed,
                                sourceReferences: [NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 3, lastSequenceNumber: 7)],
                                uncertaintyNote: "garbled unit"),
            ]),
            analysis(generation: generation, windowIndex: 1, items: [item(sessionID: sessionID, sequence: 9, body: "Resistors limit current.")]),
        ]

        let document = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)

        XCTAssertEqual(document.sections.flatMap(\.items), analyses.flatMap(\.items), "source references, kinds, fidelity, and notes unchanged")
        XCTAssertEqual(document.sections.map(\.heading), ["Potential and Resistance"])
        XCTAssertEqual(document.sections.map(\.topics), [["Potential", "Resistors"]])
        let prompts = driver.respondArguments.map(\.prompt)
        XCTAssertEqual(prompts[0], "Summarize this lecture section in one or two concise sentences.\n\nNotes in this lecture section:\n- Potential is energy per charge.\n- Resistors limit current.")
        XCTAssertEqual(Array(prompts[1...3]), [
            "Notes in this lecture segment:\n- Potential is energy per charge.",
            "Notes in this lecture segment:\n- Resistors limit current.",
            "Summary of this lecture section:\nPotential and resistors are introduced.",
        ])
        for prompt in prompts {
            for metadata in ["[", "]", "(", ")", "{", "}", "definition", "explanation", "reconstructed", "transcriptSupported",
                             "garbled", "uncertainty", "3-7", "Window", "window", "MLXSection", "MLXWindow",
                             "sectionSummaries", "topicTerms", sessionID.uuidString] {
                XCTAssertFalse(prompt.contains(metadata), "\(metadata) leaked into: \(prompt)")
            }
        }
    }

    /// When the sections' notes do not fit one summary request, each section
    /// is condensed separately (never merged across sections) until they fit.
    /// Reduction is per section: only a section whose own summary request
    /// does not fit is condensed, and its sentence still comes from its own
    /// request; a section that fits keeps its original notes.
    func testOnlyTheSectionWhoseSummaryDoesNotFitIsReduced() async throws {
        let driver = FakeMLXSessionDriver()
        // Preflight order: [section 0 summary (fits), section 1 summary (too
        // big), section 1 reduction batch (fits), section 1 summary after
        // reduction (fits)], then one default-sized preflight per later call.
        driver.enqueueTokenCount(.success(100))
        driver.enqueueTokenCount(.success(999_999))
        driver.enqueueTokenCount(.success(100))
        driver.enqueueTokenCount(.success(100))
        // Dispatch order: section 0 summary, section 1 reduction, section 1
        // summary, 4 window topics, 2 titles.
        enqueueSummaries(["Original one."], on: driver)
        driver.enqueueRespond(.success(.stub(jsonText: """
        {"items":[{"kind":"explanation","body":"condensed-2","fidelity":"transcriptSupported","sourceReferences":[{"firstSequenceNumber":2,"lastSequenceNumber":2}],"uncertaintyNote":""}]}
        """)))
        enqueueSummaries(["Reduced two."], on: driver)
        enqueueTopics(["One", "Two", "Three", "Four"], on: driver)
        enqueueTitles(["First", "Second"], on: driver)

        let generator = makeGenerator(driver: driver)
        let generation = generationRecord()
        let (analyses, items) = windowAnalyses(generation: generation, itemCounts: [1, 1, 1, 1])

        let document = try await generator.synthesize(analyses: analyses, generation: generation)
        XCTAssertEqual(document.overview, "Original one. Reduced two.")
        XCTAssertEqual(document.sections.map(\.heading), ["First", "Second"])
        XCTAssertEqual(document.sections.map(\.topics), [["One", "Two"], ["Three", "Four"]])
        XCTAssertEqual(document.sections.flatMap(\.items), items, "detailed sections are never affected by summary-input reduction")
        XCTAssertEqual(driver.respondCallCount, 9)
        XCTAssertEqual(driver.respondArguments.map(\.instructions)[0...2], [
            MLXLectureNotesGenerator.sectionSummaryInstructions,
            MLXLectureNotesGenerator.reductionInstructions,
            MLXLectureNotesGenerator.sectionSummaryInstructions,
        ])
        XCTAssertTrue(driver.respondArguments[0].prompt.hasSuffix("Notes in this lecture section:\n- w0-0\n- w1-0"),
                      "the section that fits keeps its original notes")
        XCTAssertFalse(driver.respondArguments[1].prompt.contains("w0-0") || driver.respondArguments[1].prompt.contains("w1-0"),
                       "only the oversized section is condensed")
        XCTAssertTrue(driver.respondArguments[2].prompt.hasSuffix("Notes in this lecture section:\n- condensed-2"))
        XCTAssertEqual(driver.respondArguments[5].prompt, "Notes in this lecture segment:\n- w2-0",
                       "window topics always see the original, unreduced window notes")
        XCTAssertTrue(driver.respondSamplings.allSatisfy { $0 == nil }, "reduction, summaries, topics, and titles stay greedy")
    }

    /// A window-topic request that cannot fit fails closed rather than being
    /// split, batched, or dispatched.
    func testSynthesizeFailsClosedWhenAWindowTopicRequestCannotFit() async {
        let driver = FakeMLXSessionDriver()
        driver.enqueueTokenCount(.success(100))
        driver.enqueueTokenCount(.success(100))
        driver.enqueueTokenCount(.success(999_999))
        enqueueSummaries(["One."], on: driver)
        enqueueTopics(["First"], on: driver)
        let generator = MLXLectureNotesGenerator(sessionDriver: driver, maxReductionLevels: 2)
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: [3, 2])

        do {
            _ = try await generator.synthesize(analyses: analyses, generation: generation)
            XCTFail("expected contextBudgetExceeded")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .contextBudgetExceeded("window topic labeling"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.respondCallCount, 2, "summaries and window 0; window 1's oversized request is never dispatched")
    }

    func testUnsupportedWindowCountFailsBeforeAnyModelCall() async {
        let driver = FakeMLXSessionDriver()
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: Array(repeating: 1, count: 25))
        do {
            _ = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)
            XCTFail("expected the unsupported window count to fail")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .contextBudgetExceeded("detailed sections (25 note windows exceed the supported 24)"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(driver.tokenCountCallCount, 0)
        XCTAssertEqual(driver.respondCallCount, 0)
    }

    // MARK: - Bounded synthesis output

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testWindowTopicSchemaIsOneToThreeTermsWithAGenerousSafetyCeiling() throws {
        let schema = try jsonObject(MLXLectureNotesGenerator.windowTopicJSONSchema)
        XCTAssertEqual(schema["required"] as? [String], ["topicTerms"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["topicTerms"], "no topicWords, topic phrase, window number, boundary, or range")
        let terms = try XCTUnwrap(properties["topicTerms"] as? [String: Any])
        XCTAssertEqual(terms["type"] as? String, "array")
        XCTAssertEqual(terms["minItems"] as? Int, 1)
        XCTAssertEqual(terms["maxItems"] as? Int, 3)
        let term = try XCTUnwrap(terms["items"] as? [String: Any])
        XCTAssertEqual(term["type"] as? String, "string")
        XCTAssertEqual(term["minLength"] as? Int, 1)
        XCTAssertEqual(term["maxLength"] as? Int, 48)
        // A 48-character, many-word term is accepted: no smaller Swift character or word limit.
        let long = "a b c d e f g h i j k l m n o p q r s t u v w x"
        XCTAssertEqual(long.count, 47)
        XCTAssertEqual(try MLXLectureNotesGenerator.validatedWindowTopicTerms(fromJSON: termsJSON([long + "y"])), [long + "y"])
    }

    func testWindowTopicTermsAreValidatedWithoutRepair() throws {
        let valid: [[String]] = [
            ["Voltage"], ["Potential energy"], ["Power rule for polynomial derivatives"],
            ["Topic one", "Topic two"], ["Alpha term", "Beta", "Gamma delta epsilon"],
            [" Trimmed term "], ["Gauss's law"], ["Gauss\u{2019}s law"], ["Lumped-circuit abstraction"], ["Signals & systems"],
            ["x² derivative"], ["∇·E"], ["Ampère's law"], ["Course logistics"],
        ]
        for terms in valid {
            XCTAssertEqual(try MLXLectureNotesGenerator.validatedWindowTopicTerms(fromJSON: termsJSON(terms)),
                           terms.map { $0.trimmingCharacters(in: .whitespaces) }, "\(terms)")
        }
        let cases: [(String, String)] = [
            (termsJSON([]), "window topic had 0 terms; expected 1...3"),
            (termsJSON(["A", "B", "C", "D"]), "window topic had 4 terms; expected 1...3"),
            (termsJSON(["Voltage", ""]), "window topic term was empty"),
            (termsJSON(["   "]), "window topic term was empty"),
            (termsJSON(["Electric\nfield"]), "window topic term contained a line break or tab"),
            (termsJSON(["Electric\rfield"]), "window topic term contained a line break or tab"),
            (termsJSON(["Electric\tfield"]), "window topic term contained a line break or tab"),
            (termsJSON(["电 field"]), "window topic term contained Han characters"),
            (termsJSON(["Electric force力"]), "window topic term contained Han characters"),
            (#"{"topicTerms":["A"],"window":3}"#, "window topic response was not exactly one topicTerms list"),
            (#"{"topicWords":["A"]}"#, "window topic response was not exactly one topicTerms list"),
            (#"{"topic":"A"}"#, "window topic response was not exactly one topicTerms list"),
            (#"{"topicTerms":"A"}"#, "window topic response was not exactly one topicTerms list"),
            ("not json", "window topic response was not exactly one topicTerms list"),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try MLXLectureNotesGenerator.validatedWindowTopicTerms(fromJSON: json), json) {
                XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse(expected))
            }
        }
    }

    func testHanDetectionIsNarrowerThanNonASCII() {
        XCTAssertTrue(MLXLectureNotesGenerator.containsHanIdeograph("电"))
        XCTAssertTrue(MLXLectureNotesGenerator.containsHanIdeograph("Force 力"))
        for text in ["x²", "Gauss\u{2019}s law", "∇ · E", "Ω and µ", "café", "π/2", "—"] {
            XCTAssertFalse(MLXLectureNotesGenerator.containsHanIdeograph(text), text)
        }
    }

    func testInvalidWindowTopicGetsOnlyOneRetryThatStatesTheContractWithoutEchoingTheResponse() async throws {
        for bad in [termsJSON([]), termsJSON(["Electric\nfield"]), termsJSON(["Force力"]), #"{"topicTerms":["A"],"extra":1}"#] {
            let driver = FakeMLXSessionDriver()
            enqueueSummaries(["One.", "Two."], on: driver)
            enqueueTopics(["First"], on: driver)
            for _ in 0..<2 { driver.enqueueRespond(.success(.stub(jsonText: bad))) }
            let generation = generationRecord()
            let (analyses, _) = windowAnalyses(generation: generation, itemCounts: [1, 1, 1, 1])
            do {
                _ = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)
                XCTFail("an invalid window topic must fail synthesis after its single retry: \(bad)")
            } catch let error as MLXLectureNotesBackendError {
                guard case .malformedResponse = error else { return XCTFail("expected malformedResponse, got \(error)") }
            }
            XCTAssertEqual(driver.respondCallCount, 5, "two section summaries, window 0, then window 1 and its single retry: \(bad)")
            let firstAttempt = driver.respondArguments[3].prompt
            let retry = driver.respondArguments[4].prompt
            XCTAssertEqual(firstAttempt, "Notes in this lecture segment:\n- w1-0")
            XCTAssertEqual(retry, firstAttempt + "\n\n" + MLXLectureNotesGenerator.windowTopicRetryNote, "the retry differs from the greedy first request")
            XCTAssertEqual(driver.respondArguments[4].instructions, MLXLectureNotesGenerator.windowTopicInstructions)
            XCTAssertEqual(driver.respondSamplings, [nil, nil, nil, nil, nil], "the topic retry stays greedy too")
            XCTAssertFalse(retry.contains("Electric") || retry.contains("力") || retry.contains("extra"), "the rejected response is never echoed")
        }
        let note = MLXLectureNotesGenerator.windowTopicRetryNote
        XCTAssertEqual(note, "The previous response violated the topic-term format. Return 1 to 3 concise English topic terms, with one topic term per array entry.")
        XCTAssertFalse(note.contains("character") || note.contains("word"), "no character or word counts")
    }

    func testAValidRetryAfterAnInvalidWindowTopicIsUsed() async throws {
        let driver = FakeMLXSessionDriver()
        enqueueSummaries(["One."], on: driver)
        driver.enqueueRespond(.success(.stub(jsonText: termsJSON(["Gravitational force", "电"]))))
        enqueueTopics(["Gravity Electrostatics Isotropy"], on: driver)
        enqueueTitles(["Forces and Isotropy"], on: driver)
        let generation = generationRecord()
        let analysis = analysis(generation: generation, windowIndex: 0, items: [item(sessionID: generation.sessionID, sequence: 0)])

        let document = try await makeGenerator(driver: driver).synthesize(analyses: [analysis], generation: generation)

        XCTAssertEqual(document.sections.map(\.topics), [["Gravity Electrostatics Isotropy"]])
        XCTAssertEqual(driver.respondCallCount, 4)
    }

    // MARK: Section topics and titles

    func testSectionTopicsFlattenWindowTermsInOrderCollapsingOnlyAdjacentExactRepeats() {
        XCTAssertEqual(MLXLectureNotesGenerator.orderedTopics(["A"]), ["A"])
        XCTAssertEqual(MLXLectureNotesGenerator.orderedTopics(["C", "A", "B"]), ["C", "A", "B"], "order preserved, never sorted")
        XCTAssertEqual(MLXLectureNotesGenerator.orderedTopics(["Voltage", " voltage ", "Circuits"]), ["Voltage", "Circuits"],
                       "an adjacent case-insensitive exact repeat collapses")
        XCTAssertEqual(MLXLectureNotesGenerator.orderedTopics(["A", "B", "A"]), ["A", "B", "A"], "non-adjacent duplicates remain")
        XCTAssertEqual(MLXLectureNotesGenerator.orderedTopics(["Voltage", "Voltage basics", "Voltages"]),
                       ["Voltage", "Voltage basics", "Voltages"], "similar but textually different terms are kept")
        let long = String(repeating: "q", count: 48)
        XCTAssertEqual(MLXLectureNotesGenerator.orderedTopics([long, "Potential energy and work"]), [long, "Potential energy and work"],
                       "never truncated or rewritten")
    }

    func testEveryWindowOfTheRepresentativePartitionContributesItsTermsToItsSectionTopics() throws {
        let terms = (0..<15).map { ["T\($0)a", "T\($0)b"] }
        let topics = try MLXLectureNotesGenerator.sectionTopics(windowTopicTerms: terms)
        XCTAssertEqual(topics.count, 6)
        XCTAssertEqual(topics[0], ["T0a", "T0b", "T1a", "T1b", "T2a", "T2b"])
        XCTAssertEqual(topics[5], ["T13a", "T13b", "T14a", "T14b"])
        XCTAssertEqual(topics.flatMap { $0 }, terms.flatMap { $0 }, "every window's terms appear once, in order")
    }

    func testTitleBoundsSeparateTheAcceptedMaximumFromTheGrammarCeiling() {
        XCTAssertEqual(MLXLectureNotesGenerator.maximumSectionTitleLength, 80)
        XCTAssertEqual(MLXLectureNotesGenerator.sectionTitleGrammarCeiling, 112)
        XCTAssertLessThan(MLXLectureNotesGenerator.maximumSectionTitleLength, MLXLectureNotesGenerator.sectionTitleGrammarCeiling,
                          "the grammar ceiling is an emergency bound, never the product limit")
    }

    func testSectionTitleSchemaIsOneTitleWithAGenerousSafetyCeiling() throws {
        let schema = try jsonObject(MLXLectureNotesGenerator.sectionTitleJSONSchema)
        XCTAssertEqual(schema["required"] as? [String], ["title"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["title"])
        let title = try XCTUnwrap(properties["title"] as? [String: Any])
        XCTAssertEqual(title["type"] as? String, "string")
        XCTAssertEqual(title["minLength"] as? Int, 1)
        XCTAssertEqual(title["maxLength"] as? Int, MLXLectureNotesGenerator.sectionTitleGrammarCeiling)
        XCTAssertEqual(title["maxLength"] as? Int, 112)
    }

    func testSectionTitlesAreValidatedWithoutRepair() throws {
        let atMaximum = String(repeating: "t", count: 80)
        let v14Length = "Synthesis of Information through Symbolic and Mathematical Descriptions"
        for title in [
            "Electric Fields and Potential", " Course Overview ", "Gauss's Law", "Derivatives of x²", "Ohm's Law",
            "Maxwell's Equations and ∇·E = ρ/ε₀", "Limits and Derivatives", v14Length, atMaximum,
        ] {
            XCTAssertEqual(try MLXLectureNotesGenerator.validatedSectionTitle(fromJSON: titleJSON(title)),
                           title.trimmingCharacters(in: .whitespaces), "accepted unchanged: \(title)")
        }
        let cases: [(String, String)] = [
            (titleJSON(String(repeating: "t", count: 81)), "section title exceeded 80 characters"),
            (titleJSON(String(repeating: "t", count: 111)), "section title exceeded 80 characters"),
            (titleJSON(String(repeating: "t", count: 112)), "section title reached the 112-character grammar ceiling and was cut"),
            (titleJSON(String(repeating: "t", count: 110) + "  "), "section title reached the 112-character grammar ceiling and was cut"),
            (titleJSON(""), "section title was empty"),
            (titleJSON("   "), "section title was empty"),
            (titleJSON("Electric\nFields"), "section title contained a line break or tab"),
            (titleJSON("Electric 电场"), "section title contained Han characters"),
            (#"{"title":"A","topics":["B"]}"#, "section title response was not exactly one title"),
            (#"{"headings":["A"]}"#, "section title response was not exactly one title"),
            ("not json", "section title response was not exactly one title"),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try MLXLectureNotesGenerator.validatedSectionTitle(fromJSON: json), json) {
                XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse(expected))
            }
        }
    }

    /// The v14 run persisted this title: guided decoding closed the string
    /// at the old 64-character `maxLength`, mid-word. A title that fills the
    /// ceiling it was generated under is a grammar cut and never valid —
    /// the check that now guards the 112-character ceiling rejects it
    /// under its own ceiling, and nothing is truncated or repaired.
    func testTheV14GrammarCutTitleIsRejectedUnderItsOwnCeiling() {
        let cut = "Synthesis of Information through Symbolic and Mathematical Desri"
        XCTAssertEqual(cut.unicodeScalars.count, 64)
        XCTAssertTrue(MLXLectureNotesGenerator.sectionTitleFilledGrammarCeiling(cut, ceiling: 64), "the v14 ceiling cut it")
        XCTAssertTrue(MLXLectureNotesGenerator.sectionTitleFilledGrammarCeiling(String(repeating: "t", count: 112),
                                                                              ceiling: MLXLectureNotesGenerator.sectionTitleGrammarCeiling))
        XCTAssertFalse(MLXLectureNotesGenerator.sectionTitleFilledGrammarCeiling(String(repeating: "t", count: 111),
                                                                               ceiling: MLXLectureNotesGenerator.sectionTitleGrammarCeiling))
        XCTAssertFalse(MLXLectureNotesGenerator.sectionTitleFilledGrammarCeiling("Limits and Derivatives", ceiling: 64))
        // Grapheme clusters can undercount the grammar's scalar units.
        let combining = String(repeating: "e\u{301}", count: 56)
        XCTAssertEqual(combining.count, 56)
        XCTAssertTrue(MLXLectureNotesGenerator.sectionTitleFilledGrammarCeiling(combining, ceiling: 112))
    }

    /// A title over the accepted maximum fails synthesis after its single
    /// retry; it is never shortened into a valid one.
    func testOverlongTitleAbortsSynthesisWithoutTruncation() async throws {
        let driver = FakeMLXSessionDriver()
        enqueueSummaries(["One.", "Two."], on: driver)
        enqueueTopics(["A", "B", "C", "D"], on: driver)
        enqueueTitles(["First title"], on: driver)
        let overlong = String(repeating: "Long ", count: 18)
        for _ in 0..<2 { driver.enqueueRespond(.success(.stub(jsonText: titleJSON(overlong)))) }
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: [1, 1, 1, 1])
        do {
            _ = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)
            XCTFail("an overlong title must fail synthesis")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .malformedResponse("section title exceeded 80 characters"))
        }
        XCTAssertEqual(driver.respondCallCount, 9)
    }

    /// Alignment is structural: title request `i` contains only section
    /// `i`'s validated summary, and response `i` becomes section `i`'s
    /// title; the title is never assembled from the topic list.
    func testEachTitleRequestSeesOnlyItsOwnSectionSummaryAndTopicsStaySeparate() async throws {
        let driver = FakeMLXSessionDriver()
        let summaries = (0..<6).map { "Summary sentinel \($0)." }
        enqueueSummaries(summaries, on: driver)
        enqueueTopics((0..<15).map { "Term \($0) / Extra \($0)" }, on: driver)
        enqueueTitles((0..<6).map { "Title \($0)" }, on: driver)
        let generation = generationRecord()
        let (analyses, items) = windowAnalyses(generation: generation, itemCounts: [10, 6, 5, 11, 11, 7, 8, 6, 11, 10, 9, 8, 8, 7, 6])

        let document = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)

        let titleCalls = driver.respondArguments.filter { $0.instructions == MLXLectureNotesGenerator.sectionTitleInstructions }
        XCTAssertEqual(titleCalls.map(\.prompt), summaries.map { "Summary of this lecture section:\n\($0)" },
                       "exactly one title request per section, each with only its own summary")
        XCTAssertEqual(titleCalls.map(\.jsonSchema), Array(repeating: MLXLectureNotesGenerator.sectionTitleJSONSchema, count: 6))
        XCTAssertEqual(document.sections.map(\.heading), (0..<6).map { "Title \($0)" }, "call i's response is section i's title")
        XCTAssertEqual(document.sections[0].topics, ["Term 0", "Extra 0", "Term 1", "Extra 1", "Term 2", "Extra 2"])
        XCTAssertEqual(document.sections[3].topics, ["Term 9", "Extra 9", "Term 10", "Extra 10"])
        XCTAssertFalse(document.sections.contains { $0.heading.contains("Term") }, "the topic list is never concatenated into the title")
        XCTAssertEqual(document.overview, summaries.joined(separator: " "), "the overview is unchanged")
        XCTAssertEqual(document.sections.flatMap(\.items), items)
    }

    func testTitleFailureAbortsSynthesisWithoutSubstitution() async throws {
        let driver = FakeMLXSessionDriver()
        enqueueSummaries(["One.", "Two."], on: driver)
        enqueueTopics(["A", "B", "C", "D"], on: driver)
        enqueueTitles(["First title"], on: driver)
        for _ in 0..<2 { driver.enqueueRespond(.success(.stub(jsonText: titleJSON("电")))) }
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: [1, 1, 1, 1])
        do {
            _ = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)
            XCTFail("an invalid title must fail synthesis after its single retry")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .malformedResponse("section title contained Han characters"))
        }
        XCTAssertEqual(driver.respondCallCount, 9, "two section summaries, 4 window topics, title 0, then title 1 and its single retry")
    }

    func testSectionTitleInstructionsNameTheDominantThemeOnly() {
        let instructions = MLXLectureNotesGenerator.sectionTitleInstructions
        for phrase in [
            "Write one concise English navigation title for a single section of a lecture, from the short summary given for that section only",
            "describe the section's dominant academic theme as a normal short noun phrase",
            "it does not need to name every topic in the section, and must not enumerate them",
            "Use English only, and never switch to another language or script",
            "Do not mention kinds, fidelity, ranges, source references, indices, or any other metadata",
        ] {
            XCTAssertTrue(instructions.contains(phrase), phrase)
        }
        for obsolete in ["character", "64", "80", "112", "e.g.", "for example"] {
            XCTAssertFalse(instructions.contains(obsolete), obsolete)
        }
    }

    func testWindowTopicInstructionsAskForSemanticTermSlotsWithoutCounts() {
        let instructions = MLXLectureNotesGenerator.windowTopicInstructions
        for phrase in [
            "Give 1 to 3 concise English topic terms for a single segment of a lecture, from the study notes given for that segment only",
            "Each array entry is one topic term: a concise noun phrase or technical term, which may be several words long, naming a substantial academic topic of the segment",
            "When the segment genuinely covers more than one substantial topic, use a separate entry for each",
            "never drop a substantial topic because it comes late in the notes",
            "a segment that is mainly course logistics or administration may be named by an administrative term",
            "Do not write sentences",
            "Use English only, and never switch to another language or script to compress meaning",
            "Do not mention kinds, fidelity, ranges, source references, indices, or any other metadata",
        ] {
            XCTAssertTrue(instructions.contains(phrase), phrase)
        }
        for obsolete in ["character", "48", "30", "18", "one word", "single word", "topic words", "heading", "section", "Window:",
                         "startWindowIndex", "boundar", "e.g.", "for example"] {
            XCTAssertFalse(instructions.contains(obsolete), obsolete)
        }
    }

    func testSectionSummarySchemaAllowsOneStringUpToTheGrammarCeiling() throws {
        let schema = try jsonObject(MLXLectureNotesGenerator.sectionSummaryJSONSchema)
        XCTAssertEqual(schema["required"] as? [String], ["sectionSummaries"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false, "extra properties are rejected")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["sectionSummaries"], "no free-form overview and no boundaries")
        let summaries = try XCTUnwrap(properties["sectionSummaries"] as? [String: Any])
        XCTAssertEqual(summaries["minItems"] as? Int, 1, "one request, one summary string")
        XCTAssertEqual(summaries["maxItems"] as? Int, 1)
        let summary = try XCTUnwrap(summaries["items"] as? [String: Any])
        XCTAssertEqual(summary["type"] as? String, "string")
        XCTAssertEqual(summary["minLength"] as? Int, 1)
        XCTAssertEqual(summary["maxLength"] as? Int, 768, "the grammar ceiling, above the accepted length")
    }

    /// v14: a loose accepted safety bound (600) below a runaway grammar
    /// ceiling (768); no numeric target and no aggregate overview limit.
    func testSectionSummaryAcceptedLengthSitsBelowTheGrammarCeiling() {
        XCTAssertEqual(MLXLectureNotesGenerator.maximumSectionSummaryLength, 600)
        XCTAssertEqual(MLXLectureNotesGenerator.sectionSummaryGrammarCeiling, 768)
        XCTAssertEqual(MLXLectureNotesGenerator.maximumSectionSummarySentences, 2)
        XCTAssertLessThan(MLXLectureNotesGenerator.maximumSectionSummaryLength, MLXLectureNotesGenerator.sectionSummaryGrammarCeiling)
    }

    private func validateSummary(_ text: String) throws -> String {
        try MLXLectureNotesGenerator.validatedSectionSummary(MLXSectionSummariesDTO(sectionSummaries: [text]))
    }

    /// The v12 failure shape (a reply cut mid-clause at the grammar ceiling,
    /// drifting into another script) and every overlong or incomplete reply
    /// fail closed: nothing is truncated, trimmed into validity, or given
    /// punctuation.
    func testSummariesAboveTheAcceptedLengthOrIncompleteAreNeverAcceptedOrRepaired() throws {
        let atLimit = String(repeating: "a", count: 599) + "."
        XCTAssertEqual(try validateSummary(atLimit), atLimit, "exactly 600 is accepted exactly as generated")
        for length in [601, 650, 768] {
            let completeButLong = String(repeating: "a", count: length - 1) + "."
            XCTAssertThrowsError(try validateSummary(completeButLong), "\(length)") {
                XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse("section summary exceeded 600 characters"))
            }
        }
        let cutAtCeiling = "The lecture emphasizes synthesizing information by connecting symbolic representations in circuits to measurable quantities like voltage and current, while highlighting the importance of understanding limits and"
        XCTAssertThrowsError(try validateSummary(cutAtCeiling)) {
            XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse("section summary was not a complete sentence"))
        }
        XCTAssertThrowsError(try validateSummary(cutAtCeiling + "物理方")) {
            XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse("section summary contained Han characters"))
        }
        XCTAssertThrowsError(try validateSummary("Ends with an ellipsis…")) {
            XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse("section summary was not a complete sentence"))
        }
        for broken in ["One line.\nSecond line.", "Tabbed\tsummary."] {
            XCTAssertThrowsError(try validateSummary(broken)) {
                XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse("section summary contained a line break or tab"))
            }
        }
    }

    /// The complete, grounded two-sentence section-3 summary that v13
    /// replay 1E8341E1 rejected at 400 characters is accepted under v14,
    /// exactly as generated.
    func testTheRealTwoSentence499CharacterSummaryIsAcceptedUnchanged() throws {
        let summary = "This section explores the fundamental principles of electromagnetism, emphasizing the relationship between electric and magnetic fields through Maxwell's equations, the concept of curl and divergence in vector fields, and the conservation of charge as described by the continuity equation. These concepts illustrate how electromagnetic phenomena can be analyzed through both differential and integral formulations, highlighting the interplay between field circulation, flux, and charge conservation."
        XCTAssertEqual(summary.count, 499)
        XCTAssertEqual(MLXLectureNotesGenerator.sectionSummarySentenceCount(summary), 2)
        XCTAssertEqual(try validateSummary(summary), summary)
    }

    func testSectionSummarySentenceCountAcceptsOneOrTwoSentencesOnly() throws {
        let accepted: [(String, Int)] = [
            ("Ohm's law relates voltage and current through resistance.", 1),
            ("Voltage is potential energy per unit charge. Current is the rate of charge flow.", 2),
            ("Pi is about 3.14 here, and the ratio stays fixed.", 1),
            ("It uses V = IR. Then power follows from P = VI.", 2),
            ("Dissipative forces, e.g. friction, oppose motion.", 1),
            ("Newton vs. Einstein differ on gravity. Both remain useful approximations.", 2),
            ("Dr. Smith explains entropy as a measure of disorder.", 1),
            ("Why is charge conserved? The continuity equation guarantees it!", 2),
            ("Is the field conservative? yes, when its curl is zero.", 1),
            ("Waves interfere... Then they can cancel completely.", 2),
            ("J. C. Maxwell unified electricity and magnetism.", 1),
        ]
        for (text, sentences) in accepted {
            XCTAssertEqual(MLXLectureNotesGenerator.sectionSummarySentenceCount(text), sentences, text)
            XCTAssertEqual(try validateSummary(text), text, "accepted unchanged: \(text)")
        }
        let threeSentences = "The derivative is a limit. It measures slope. It uses the difference quotient."
        XCTAssertEqual(MLXLectureNotesGenerator.sectionSummarySentenceCount(threeSentences), 3)
        XCTAssertThrowsError(try validateSummary(threeSentences)) {
            XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse("section summary had 3 sentences; expected 1 or 2"))
        }
        XCTAssertThrowsError(try validateSummary("   ")) {
            XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse("section summary was empty"))
        }
        XCTAssertThrowsError(try validateSummary("A complete sentence. And an incomplete trailing one")) {
            XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse("section summary was not a complete sentence"))
        }
    }

    /// End to end with a fake driver: the request carries no numeric target,
    /// dispatches the 768 grammar ceiling, and a complete 650-character
    /// reply — allowed by the grammar — fails validation rather than
    /// entering the overview.
    func testSynthesisRequestsNoNumericTargetAndRejectsAnOverlongReply() async throws {
        let driver = FakeMLXSessionDriver()
        let overlong = String(repeating: "a", count: 649) + "."
        for _ in 0..<2 { driver.enqueueRespond(.success(.stub(jsonText: summaryJSON(overlong)))) }
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: Array(repeating: 1, count: 15))
        do {
            _ = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)
            XCTFail("an overlong summary must not be accepted")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .malformedResponse("section summary exceeded 600 characters"))
        }
        let request = try XCTUnwrap(driver.respondArguments.first)
        XCTAssertTrue(request.prompt.hasPrefix("Summarize this lecture section in one or two concise sentences.\n\nNotes in this lecture section:\n"))
        XCTAssertNil(request.prompt.components(separatedBy: "\n").first?.range(of: #"\d"#, options: .regularExpression), "the header states no number")
        XCTAssertEqual(request.jsonSchema, MLXLectureNotesGenerator.sectionSummaryJSONSchema)
        XCTAssertEqual(driver.respondCallCount, 2, "the existing retry resends the identical greedy request once")
        XCTAssertEqual(driver.respondArguments[0].prompt, driver.respondArguments[1].prompt)
    }

    /// With no aggregate cap, six full-length two-sentence summaries form an
    /// overview far longer than the old 1,100 characters and are accepted.
    func testOverviewIsTheJoinedSummariesWithoutAnAggregateCap() async throws {
        let driver = FakeMLXSessionDriver()
        let summaries = (0..<6).map { index in
            "Section \(index) develops its main idea in detail across the notes it gathers. " + String(repeating: "x", count: 300) + " closes it."
        }
        XCTAssertTrue(summaries.allSatisfy { $0.count <= 600 })
        enqueueSummaries(summaries, on: driver)
        enqueueTopics((0..<15).map { "Label \($0)" }, on: driver)
        enqueueTitles((0..<6).map { "Title \($0)" }, on: driver)
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: Array(repeating: 1, count: 15))

        let document = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)

        XCTAssertEqual(document.overview, summaries.joined(separator: " "))
        XCTAssertGreaterThan(document.overview.count, 1_100)
        XCTAssertLessThanOrEqual(document.overview.count, MLXLectureNotesGenerator.maximumSectionsPerDocument * 600 + 7)
    }

    func testSectionSummaryIsTrimmedAndAcceptsTerminalPunctuation() throws {
        for (raw, expected) in [("  First.", "First."), ("Second?  ", "Second?"), ("Third!", "Third!")] {
            XCTAssertEqual(try validateSummary(raw), expected)
        }
    }

    func testMalformedSectionSummaryIsRejectedNotRepaired() {
        let tooLong = String(repeating: "a", count: 600) + "."
        let cases: [([String], String)] = [
            ([], "section summary count was 0; expected 1"),
            (["One.", "Two."], "section summary count was 2; expected 1"),
            (["   "], "section summary was empty"),
            (["Two"], "section summary was not a complete sentence"),
            (["Two,"], "section summary was not a complete sentence"),
            ([tooLong], "section summary exceeded 600 characters"),
        ]
        for (summaries, expected) in cases {
            XCTAssertThrowsError(try MLXLectureNotesGenerator.validatedSectionSummary(
                MLXSectionSummariesDTO(sectionSummaries: summaries)
            ), "\(summaries)") {
                XCTAssertEqual($0 as? MLXLectureNotesBackendError, .malformedResponse(expected))
            }
        }
    }

    func testMalformedSectionSummaryGetsOnlyTheBoundedRetryAndStopsSynthesis() async throws {
        let driver = FakeMLXSessionDriver()
        enqueueSummaries(["Complete."], on: driver)
        for _ in 0..<2 { driver.enqueueRespond(.success(.stub(jsonText: summaryJSON("Unfinished")))) }
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: [1, 1, 1, 1])
        do {
            _ = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)
            XCTFail("an incomplete sentence must fail the section summary")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .malformedResponse("section summary was not a complete sentence"))
        }
        XCTAssertEqual(driver.respondCallCount, 3, "section 0, then section 1 and its single retry; no topic or title call")
        XCTAssertTrue(driver.respondArguments.allSatisfy { $0.instructions == MLXLectureNotesGenerator.sectionSummaryInstructions })
    }

    func testSynthesisReservesCoverTheLargestBoundedOutput() {
        // Worst case: text at one token per character, plus each array
        // element's quotes and comma (about 4 tokens) and the object wrapper.
        let perElementStructureTokens = 4
        let wrapperTokens = 15
        let reserves = MLXNotesResponseReserves.conservativeDefault
        // One window-topic call returns a single label.
        let largestTopic = MLXLectureNotesGenerator.windowTopicTermCount.upperBound
            * (MLXLectureNotesGenerator.windowTopicTermSchemaMaxLength + perElementStructureTokens) + wrapperTokens
        XCTAssertLessThanOrEqual(largestTopic, reserves.reserve(for: .windowTopics))
        // One section-summary call returns one sentence.
        let largestSummary = MLXLectureNotesGenerator.sectionSummaryGrammarCeiling + perElementStructureTokens + wrapperTokens
        XCTAssertLessThanOrEqual(largestSummary, reserves.reserve(for: .sectionSummaries))
        let largestTitle = MLXLectureNotesGenerator.sectionTitleGrammarCeiling + perElementStructureTokens + wrapperTokens
        XCTAssertLessThanOrEqual(largestTitle, reserves.reserve(for: .sectionTitles))
        XCTAssertEqual(reserves.reserve(for: .windowTopics), 2_048)
        XCTAssertEqual(reserves.reserve(for: .sectionTitles), 2_048)
        XCTAssertEqual(reserves.reserve(for: .sectionSummaries), 2_048)
    }

    func testSynthesisDispatchesTheBoundedSchemasAndReserves() async throws {
        let driver = FakeMLXSessionDriver()
        enqueueSummaries(["About potential.", "About resistors."], on: driver)
        enqueueTopics(["Potential", "Charge", "Resistors", "Ohm"], on: driver)
        enqueueTitles(["Potential", "Resistors"], on: driver)
        let generation = generationRecord()
        let (analyses, _) = windowAnalyses(generation: generation, itemCounts: [1, 1, 1, 1])

        let document = try await makeGenerator(driver: driver).synthesize(analyses: analyses, generation: generation)

        XCTAssertEqual(document.sections.map(\.heading), ["Potential", "Resistors"])
        XCTAssertEqual(document.sections.map(\.topics), [["Potential", "Charge"], ["Resistors", "Ohm"]])
        XCTAssertEqual(document.sections.map { $0.items.map(\.body) }, [["w0-0", "w1-0"], ["w2-0", "w3-0"]])
        XCTAssertEqual(driver.respondArguments.count, 8)
        for summaryCall in driver.respondArguments[0...1] {
            XCTAssertEqual(summaryCall.instructions, MLXLectureNotesGenerator.sectionSummaryInstructions)
            XCTAssertEqual(summaryCall.jsonSchema, MLXLectureNotesGenerator.sectionSummaryJSONSchema)
            XCTAssertEqual(summaryCall.maxOutputTokens, 2_048)
        }
        for topicCall in driver.respondArguments[2...5] {
            XCTAssertEqual(topicCall.instructions, MLXLectureNotesGenerator.windowTopicInstructions)
            XCTAssertEqual(topicCall.jsonSchema, MLXLectureNotesGenerator.windowTopicJSONSchema)
            XCTAssertEqual(topicCall.maxOutputTokens, 2_048)
        }
        for titleCall in driver.respondArguments[6...7] {
            XCTAssertEqual(titleCall.instructions, MLXLectureNotesGenerator.sectionTitleInstructions)
            XCTAssertEqual(titleCall.jsonSchema, MLXLectureNotesGenerator.sectionTitleJSONSchema)
            XCTAssertEqual(titleCall.maxOutputTokens, 2_048)
        }
    }

    func testSectionSummaryIncompleteOutputIsTypedAndNotRetried() async throws {
        let driver = FakeMLXSessionDriver()
        driver.enqueueRespond(.failure(MLXGuidedGenerationRuntimeError.incompleteOutput("truncated")))
        let generation = generationRecord()
        let analysis = analysis(generation: generation, windowIndex: 0, items: [item(sessionID: generation.sessionID, sequence: 0)])
        do {
            _ = try await makeGenerator(driver: driver).synthesize(analyses: [analysis], generation: generation)
            XCTFail("expected incompleteOutput")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .incompleteOutput("truncated"))
        }
        XCTAssertEqual(driver.respondCallCount, 1, "a truncated response is not repeated")
    }

    /// v13: one or two concise sentences on the section's throughline —
    /// semantic brevity, never a numeric length target.
    func testSectionSummaryInstructionsAskForOneOrTwoConciseSentencesWithoutANumericTarget() {
        let instructions = MLXLectureNotesGenerator.sectionSummaryInstructions
        for phrase in [
            "Summarize one section of a lecture's study notes, using only the notes given for that section",
            "Write one or two concise, complete prose sentences that capture the section's main throughline: its dominant academic concepts and, where useful, the important relationships between them",
            "Do not enumerate the individual notes or try to mention every detail; secondary details are covered separately by the section's topics",
            "Give academic content priority over course logistics and administration, and summarize a section that is genuinely administrative compactly",
            "Write natural English prose, and finish the final sentence with a period, question mark, or exclamation mark",
            "do not mention kinds, fidelity, ranges, source references, indices, labels, or any other metadata",
        ] {
            XCTAssertTrue(instructions.contains(phrase), phrase)
        }
        XCTAssertNil(instructions.range(of: #"\d"#, options: .regularExpression), "no numeric target of any kind")
        for obsolete in ["character", "target length", "comfortably within", "exactly one complete prose sentence",
                         "represents every", "every substantial academic topic", "longest sentence allowed",
                         "per section", "in the same order", "how many sections", "another section", "e.g.", "for example"] {
            XCTAssertFalse(instructions.contains(obsolete), obsolete)
        }
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
        driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([candidate("content", references: [(0, 0)])]))))
        var recordedEvents: [MLXNotesDiagnosticEvent] = []
        let generator = MLXLectureNotesGenerator(
            sessionDriver: driver,
            diagnosticRecorder: { recordedEvents.append($0) }
        )
        let generation = generationRecord()

        let analysis = try await generator.analyzeWindow(units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generation)
        XCTAssertEqual(analysis.items.first?.body, "content")
        XCTAssertFalse(recordedEvents.isEmpty, "diagnostics should have observed the preflight, purely additively")
    }

    // MARK: - Schema

    func testNoteItemsJSONSchemaBoundsWindowAnalysisOutput() throws {
        try assertBoundedNoteItemsSchema(Data(MLXLectureNotesGenerator.noteItemsJSONSchema.utf8))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MLXLectureNotesGenerator.windowAnalysisJSONSchema(allowedSequenceNumbers: [0, 1, 2]).utf8)) as? [String: Any])
        let items = try XCTUnwrap((schema["properties"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(items["maxItems"] as? Int, 12)
        let properties = try XCTUnwrap((items["items"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual((properties["body"] as? [String: Any])?["maxLength"] as? Int, 600)
        XCTAssertEqual((properties["kind"] as? [String: Any])?["enum"] as? [String], MLXNoteVocabulary.itemKinds)
    }

    private func assertBoundedNoteItemsSchema(_ schemaData: Data) throws {
        let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        let items = schema?["properties"] as? [String: Any]
        let itemsArray = items?["items"] as? [String: Any]
        XCTAssertEqual(itemsArray?["maxItems"] as? Int, 12)

        for (fidelity, variant) in try noteItemSchemaVariants(schemaData) {
            let properties = variant["properties"] as? [String: Any]
            let body = properties?["body"] as? [String: Any]
            let sourceReferences = properties?["sourceReferences"] as? [String: Any]
            let uncertaintyNote = properties?["uncertaintyNote"] as? [String: Any]
            let kind = properties?["kind"] as? [String: Any]
            XCTAssertEqual(body?["maxLength"] as? Int, 600, fidelity)
            XCTAssertEqual(sourceReferences?["minItems"] as? Int, 1, fidelity)
            XCTAssertEqual(sourceReferences?["maxItems"] as? Int, 3, fidelity)
            if let uncertaintyNote {
                XCTAssertEqual(uncertaintyNote["maxLength"] as? Int, 200, fidelity)
            }
            XCTAssertEqual(kind?["enum"] as? [String], MLXNoteVocabulary.itemKinds, fidelity)
        }
    }

    // MARK: - Fidelity-conditional uncertainty note

    func testReductionNoteItemSchemaHasOneVariantPerFidelity() throws {
        let reduction = try noteItemSchemaVariants(Data(MLXLectureNotesGenerator.noteItemsJSONSchema.utf8))
        XCTAssertEqual(Set(reduction.keys), ["transcriptSupported", "reconstructed"])
        XCTAssertNil(reduction["uncertain"], "new Notes cannot be generated as uncertain")
        for (fidelity, variant) in reduction {
            XCTAssertEqual(variant["required"] as? [String], ["kind", "body", "fidelity", "sourceReferences", "uncertaintyNote"], fidelity)
        }
    }

    func testTranscriptSupportedVariantAllowsEmptyUncertaintyNote() throws {
        let variant = try XCTUnwrap(
            noteItemSchemaVariants(Data(MLXLectureNotesGenerator.noteItemsJSONSchema.utf8))["transcriptSupported"]
        )
        let note = (variant["properties"] as? [String: Any])?["uncertaintyNote"] as? [String: Any]
        XCTAssertNil(note?["minLength"], "transcriptSupported keeps an empty note meaning none")
    }

    func testReductionReconstructedVariantRequiresNonEmptyUncertaintyNote() throws {
        let variant = try XCTUnwrap(noteItemSchemaVariants(Data(MLXLectureNotesGenerator.noteItemsJSONSchema.utf8))["reconstructed"])
        let note = (variant["properties"] as? [String: Any])?["uncertaintyNote"] as? [String: Any]
        XCTAssertEqual(note?["minLength"] as? Int, 1)
        XCTAssertEqual(note?["maxLength"] as? Int, 200)
    }

    func testNewNotesCannotSelectTheUncertaintyKind() async throws {
        for (fidelity, variant) in try noteItemSchemaVariants(Data(MLXLectureNotesGenerator.noteItemsJSONSchema.utf8)) {
            let kind = (variant["properties"] as? [String: Any])?["kind"] as? [String: Any]
            XCTAssertFalse(try XCTUnwrap(kind?["enum"] as? [String], fidelity).contains("uncertainty"), fidelity)
        }
        let windowSchema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MLXLectureNotesGenerator.windowAnalysisJSONSchema(allowedSequenceNumbers: [0]).utf8)) as? [String: Any])
        let windowKinds = ((((windowSchema["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])?["kind"] as? [String: Any]
        XCTAssertFalse(try XCTUnwrap(windowKinds?["enum"] as? [String]).contains("uncertainty"))
        // Persisted data keeps the case.
        XCTAssertEqual(LectureNoteItemKind(rawValue: "uncertainty"), .uncertainty)

        // Defense in depth behind the grammar.
        let driver = FakeMLXSessionDriver()
        for _ in 0..<2 {
            driver.enqueueRespond(.success(.stub(jsonText: itemsJSON([candidate("Unclear.", kind: "uncertainty", references: [(0, 0)])]))))
        }
        do {
            _ = try await makeGenerator(driver: driver).analyzeWindow(
                units: [unit(0, "a")], window: window(first: 0, last: 0), generation: generationRecord()
            )
            XCTFail("expected the uncertainty kind to be rejected")
        } catch let error as MLXLectureNotesBackendError {
            XCTAssertEqual(error, .malformedResponse("unrecognized item kind uncertainty"))
        }
    }

    func testPersistedFidelityStillDecodesUncertain() throws {
        // Storage compatibility: only new generation stopped offering it.
        XCTAssertEqual(LectureNoteContentFidelity(rawValue: "uncertain"), .uncertain)
        XCTAssertEqual(MLXNoteVocabulary.fidelities, ["transcriptSupported", "reconstructed", "uncertain"])
        XCTAssertEqual(MLXNoteVocabulary.generatedNoteFidelities, ["transcriptSupported", "reconstructed"])
    }
}
