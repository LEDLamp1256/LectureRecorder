import XCTest
@testable import LectureRecorder

final class FoundationModelsLectureNotesGeneratorTests: XCTestCase {

    // MARK: - Fixtures

    private func unit(_ sequence: Int, text: String? = nil) -> NotesTranscriptSourceUnit {
        NotesTranscriptSourceUnit(
            sequenceNumber: sequence,
            chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequence),
            text: text ?? "The professor explains a concept at sequence \(sequence).",
            startOffsetSeconds: Double(sequence) * 30,
            durationSeconds: 30
        )
    }

    private func makeGenerationRecord(sessionID: UUID = UUID(), windows: [NotesInputWindow]) -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: []),
            windowPlan: NotesWindowPlan(windows: windows),
            provenance: FoundationModelsNotesConfiguration.generationProvenance
        )
    }

    private func makeAnalysis(
        windowIndex: Int,
        sessionID: UUID,
        generationID: UUID,
        fingerprint: TranscriptSourceFingerprint,
        sequenceNumber: Int,
        body: String? = nil,
        fidelity: LectureNoteContentFidelity = .transcriptSupported,
        uncertaintyNote: String? = nil
    ) -> LectureNotesWindowAnalysis {
        LectureNotesWindowAnalysis(
            generationID: generationID,
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            windowIndex: windowIndex,
            ownedRange: NotesSourceReference(sessionID: sessionID, sequenceNumber: sequenceNumber),
            items: [LectureNoteItem(
                kind: .explanation,
                body: body ?? "window \(windowIndex) content",
                fidelity: fidelity,
                sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: sequenceNumber)],
                uncertaintyNote: uncertaintyNote
            )]
        )
    }

    private func makeItemDTO(
        kind: String = "explanation",
        title: String? = nil,
        body: String = "Some grounded content.",
        fidelity: String = "transcriptSupported",
        first: Int,
        last: Int? = nil,
        uncertaintyNote: String = ""
    ) -> AppleNoteItemDTO {
        AppleNoteItemDTO(
            kind: kind,
            title: title,
            body: body,
            fidelity: fidelity,
            sourceReferences: [AppleSourceReferenceDTO(firstSequenceNumber: first, lastSequenceNumber: last ?? first)],
            uncertaintyNote: uncertaintyNote
        )
    }

    private func sectionRange(_ heading: String, _ first: Int, _ last: Int) -> AppleSectionRangeDTO {
        AppleSectionRangeDTO(heading: heading, firstItemIndex: first, lastItemIndex: last)
    }

    private func assertSectionPlanIndexBounds(
        _ request: FakeFoundationModelsSchemaRequest,
        inputCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.schemaDescription.utf8)) as? [String: Any],
            file: file,
            line: line
        )
        let properties = try XCTUnwrap(object["properties"] as? [String: Any], file: file, line: line)
        let sections = try XCTUnwrap(properties["sections"] as? [String: Any], file: file, line: line)
        XCTAssertEqual((sections["minItems"] as? NSNumber)?.intValue, 1, file: file, line: line)
        XCTAssertEqual((sections["maxItems"] as? NSNumber)?.intValue, inputCount, file: file, line: line)
        let itemReference = try XCTUnwrap(sections["items"] as? [String: Any], file: file, line: line)
        let section: [String: Any]
        if let reference = itemReference["$ref"] as? String {
            let name = String(reference.split(separator: "/").last ?? "")
            let definitions = try XCTUnwrap(object["$defs"] as? [String: Any], file: file, line: line)
            section = try XCTUnwrap(definitions[name] as? [String: Any], file: file, line: line)
        } else {
            section = itemReference
        }
        let sectionProperties = try XCTUnwrap(
            section["properties"] as? [String: Any],
            file: file,
            line: line
        )
        for key in ["firstItemIndex", "lastItemIndex"] {
            let index = try XCTUnwrap(sectionProperties[key] as? [String: Any], file: file, line: line)
            XCTAssertEqual((index["minimum"] as? NSNumber)?.intValue, 0, file: file, line: line)
            XCTAssertEqual(
                (index["maximum"] as? NSNumber)?.intValue,
                inputCount - 1,
                file: file,
                line: line
            )
        }
    }

    private func singleUnitWindow(_ sequence: Int) -> NotesInputWindow {
        NotesInputWindow(windowIndex: sequence, firstSequenceNumber: sequence, lastSequenceNumber: sequence, unitCount: 1, isOversizedSingleUnit: false)
    }

    // MARK: - analyzeWindow

    func testAnalyzeWindowMapsValidStructuredResponse() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.enqueue(AppleNoteItemsDTO(items: [
            makeItemDTO(kind: "definition", title: "Energy", body: "E equals m c squared.", fidelity: "transcriptSupported", first: 0)
        ]))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(windows: [window])

        let analysis = try await generator.analyzeWindow(units: [unit(0)], window: window, generation: generationRecord)

        XCTAssertEqual(analysis.items.count, 1)
        XCTAssertEqual(analysis.items[0].kind, .definition)
        XCTAssertEqual(analysis.items[0].title, "Energy")
        XCTAssertEqual(analysis.items[0].fidelity, .transcriptSupported)
        XCTAssertEqual(analysis.items[0].sourceReferences, [NotesSourceReference(sessionID: generationRecord.sessionID, sequenceNumber: 0)])
        XCTAssertEqual(analysis.windowIndex, 0)
        XCTAssertEqual(driver.capturedPrompts.first?.instructions, FoundationModelsLectureNotesGenerator.analysisInstructions)
        XCTAssertTrue(driver.capturedPrompts.first?.prompt.contains("[0]") ?? false)
    }

    func testAnalyzeWindowRejectsOutOfRangeSourceReference() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(first: 99)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(first: 99)]))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(windows: [window])

        do {
            _ = try await generator.analyzeWindow(units: [unit(0)], window: window, generation: generationRecord)
            XCTFail("expected a rejection for an invented source reference")
        } catch {
            XCTAssertEqual(error as? FoundationModelsNotesBackendError, .invalidSourceReference)
        }
    }

    func testAnalyzeWindowRequiresUncertaintyNoteForNonTranscriptSupportedFidelity() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(fidelity: "reconstructed", first: 0, uncertaintyNote: "")]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(fidelity: "reconstructed", first: 0, uncertaintyNote: "")]))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(windows: [window])

        do {
            _ = try await generator.analyzeWindow(units: [unit(0)], window: window, generation: generationRecord)
            XCTFail("expected a rejection for a missing uncertainty note")
        } catch let error as FoundationModelsNotesBackendError {
            guard case .malformedResponse = error else {
                XCTFail("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    func testAnalyzeWindowRetriesMissingUncertaintyWithExactRequestAndUsesOnlyValidAttempt() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.enqueue(AppleNoteItemsDTO(items: [
            makeItemDTO(
                body: "Discarded malformed content.",
                fidelity: "reconstructed",
                first: 0,
                uncertaintyNote: " "
            )
        ]))
        driver.enqueue(AppleNoteItemsDTO(items: [
            makeItemDTO(
                body: "Valid grounded content.",
                fidelity: "reconstructed",
                first: 0,
                uncertaintyNote: "Equation notation was normalized from speech."
            )
        ]))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(windows: [window])

        let analysis = try await generator.analyzeWindow(
            units: [unit(0)], window: window, generation: generationRecord
        )

        XCTAssertEqual(driver.callCount, 2)
        XCTAssertEqual(driver.tokenCountCallCount, 1)
        XCTAssertEqual(driver.capturedPrompts[0].instructions, driver.capturedPrompts[1].instructions)
        XCTAssertEqual(driver.capturedPrompts[0].prompt, driver.capturedPrompts[1].prompt)
        XCTAssertEqual(driver.capturedResponseTypes[0], driver.capturedResponseTypes[1])
        XCTAssertEqual(analysis.items.map(\.body), ["Valid grounded content."])
        XCTAssertEqual(
            analysis.items[0].uncertaintyNote,
            "Equation notation was normalized from speech."
        )
        XCTAssertEqual(
            analysis.items[0].sourceReferences,
            [NotesSourceReference(sessionID: generationRecord.sessionID, sequenceNumber: 0)]
        )
    }

    func testAnalyzeWindowRetriesInvalidGeneratedSourceReferenceAndUsesOnlyValidEvidence() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: "Invented evidence.", first: 99)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: "Valid evidence.", first: 0)]))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(windows: [window])

        let analysis = try await generator.analyzeWindow(
            units: [unit(0)], window: window, generation: generationRecord
        )

        XCTAssertEqual(driver.callCount, 2)
        XCTAssertEqual(analysis.items.map(\.body), ["Valid evidence."])
        XCTAssertEqual(
            analysis.items[0].sourceReferences,
            [NotesSourceReference(sessionID: generationRecord.sessionID, sequenceNumber: 0)]
        )
    }

    func testAnalyzeWindowRetryExhaustionReturnsFinalTypedError() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(first: 99)]))
        driver.enqueue(AppleNoteItemsDTO(items: [
            makeItemDTO(fidelity: "uncertain", first: 0, uncertaintyNote: " ")
        ]))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(windows: [window])

        do {
            _ = try await generator.analyzeWindow(
                units: [unit(0)], window: window, generation: generationRecord
            )
            XCTFail("expected retry exhaustion")
        } catch {
            XCTAssertEqual(
                error as? FoundationModelsNotesBackendError,
                .malformedResponse("reconstructed or uncertain item omitted uncertainty context")
            )
        }
        XCTAssertEqual(driver.callCount, 2)
    }

    func testFidelityAndUncertaintyNoteSurviveMapping() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.enqueue(AppleNoteItemsDTO(items: [
            makeItemDTO(fidelity: "uncertain", first: 0, uncertaintyNote: "Notation was normalized from spoken description.")
        ]))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(windows: [window])

        let analysis = try await generator.analyzeWindow(units: [unit(0)], window: window, generation: generationRecord)

        XCTAssertEqual(analysis.items[0].fidelity, .uncertain)
        XCTAssertEqual(analysis.items[0].uncertaintyNote, "Notation was normalized from spoken description.")
    }

    // MARK: - Required uncertaintyNote semantics (schema field is a
    // required, non-optional String — never an escape hatch to omit it)

    private func mapSingleItem(_ dto: AppleNoteItemDTO) async throws -> LectureNoteItem {
        let driver = FakeFoundationModelsSessionDriver()
        driver.enqueue(AppleNoteItemsDTO(items: [dto]))
        driver.enqueue(AppleNoteItemsDTO(items: [dto]))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(windows: [window])
        let analysis = try await generator.analyzeWindow(units: [unit(0)], window: window, generation: generationRecord)
        return analysis.items[0]
    }

    func testReconstructedWithNonEmptyUncertaintyNoteIsAccepted() async throws {
        let item = try await mapSingleItem(makeItemDTO(fidelity: "reconstructed", first: 0, uncertaintyNote: "equation was reformatted from spoken description"))
        XCTAssertEqual(item.fidelity, .reconstructed)
        XCTAssertEqual(item.uncertaintyNote, "equation was reformatted from spoken description")
    }

    func testUncertainWithNonEmptyUncertaintyNoteIsAccepted() async throws {
        let item = try await mapSingleItem(makeItemDTO(fidelity: "uncertain", first: 0, uncertaintyNote: "instructor's wording was ambiguous"))
        XCTAssertEqual(item.fidelity, .uncertain)
        XCTAssertEqual(item.uncertaintyNote, "instructor's wording was ambiguous")
    }

    func testReconstructedWithEmptyUncertaintyNoteIsRejected() async throws {
        do {
            _ = try await mapSingleItem(makeItemDTO(fidelity: "reconstructed", first: 0, uncertaintyNote: ""))
            XCTFail("expected rejection for reconstructed with an empty uncertainty note")
        } catch let error as FoundationModelsNotesBackendError {
            guard case .malformedResponse = error else {
                XCTFail("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    func testUncertainWithWhitespaceOnlyUncertaintyNoteIsRejected() async throws {
        do {
            _ = try await mapSingleItem(makeItemDTO(fidelity: "uncertain", first: 0, uncertaintyNote: "   "))
            XCTFail("expected rejection for uncertain with a whitespace-only uncertainty note")
        } catch let error as FoundationModelsNotesBackendError {
            guard case .malformedResponse = error else {
                XCTFail("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    func testTranscriptSupportedWithEmptyUncertaintyNoteMapsToDomainNil() async throws {
        let item = try await mapSingleItem(makeItemDTO(fidelity: "transcriptSupported", first: 0, uncertaintyNote: ""))
        XCTAssertEqual(item.fidelity, .transcriptSupported)
        XCTAssertNil(item.uncertaintyNote)
    }

    func testAnalyzeWindowCancellationCommitsNoResult() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.armGate(beforeCallNumber: 1)
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(windows: [window])

        let task = Task { try await generator.analyzeWindow(units: [unit(0)], window: window, generation: generationRecord) }
        while !driver.hasEnteredGate { await Task.yield() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(driver.callCount, 1)
    }

    /// A window whose units cannot be made to fit the local context budget
    /// (e.g. an unusual `isOversizedSingleUnit` window) must fail cleanly
    /// with `.contextBudgetExceeded` — never be sent to the model anyway.
    func testAnalyzeWindowFailsClosedWhenUnitsCannotFitContextBudget() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver, maxInputBytesPerCall: 10)
        let window = NotesInputWindow(windowIndex: 3, firstSequenceNumber: 0, lastSequenceNumber: 0, unitCount: 1, isOversizedSingleUnit: true)
        let generationRecord = makeGenerationRecord(windows: [window])

        do {
            _ = try await generator.analyzeWindow(units: [unit(0, text: "a transcript unit far longer than ten bytes")], window: window, generation: generationRecord)
            XCTFail("expected a context-budget failure")
        } catch {
            guard case .contextBudgetExceeded(let stage) = error as? FoundationModelsNotesBackendError else {
                XCTFail("expected .contextBudgetExceeded, got \(error)")
                return
            }
            XCTAssertTrue(stage.contains("window analysis"))
        }
        XCTAssertEqual(driver.callCount, 0, "an oversized analysis request must never reach the model")
    }

    // MARK: - Availability

    func testAvailabilityForNewGenerationDelegatesToDriver() {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setAvailability(.unavailable(description: "Apple Intelligence is off."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        XCTAssertEqual(generator.availabilityForNewGeneration(), .unavailable(description: "Apple Intelligence is off."))
    }

    // MARK: - Provenance compatibility

    func testAnalyzeWindowRejectsIncompatibleGeneratorIdentifierBeforeAnyModelInvocation() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let incompatibleProvenance = LectureNotesGenerationProvenance(
            recipeVersion: FoundationModelsNotesConfiguration.recipeVersion,
            generatorIdentifier: "some-other-system-language-model",
            generatorVersion: nil,
            backendIdentifier: FoundationModelsNotesConfiguration.backendIdentifier
        )
        let sessionID = UUID()
        let generationRecord = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: []),
            windowPlan: NotesWindowPlan(windows: [window]),
            provenance: incompatibleProvenance
        )

        do {
            _ = try await generator.analyzeWindow(units: [unit(0)], window: window, generation: generationRecord)
            XCTFail("expected a rejection for incompatible generatorIdentifier")
        } catch {
            XCTAssertEqual(error as? FoundationModelsNotesBackendError, .incompatibleProvenance)
        }
        XCTAssertEqual(driver.callCount, 0, "an incompatible generation must never reach the model")
    }

    func testSynthesizeRejectsIncompatibleRecipeVersionBeforeAnyModelInvocation() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let window = singleUnitWindow(0)
        let incompatibleProvenance = LectureNotesGenerationProvenance(
            recipeVersion: "t5e-apple-local-notes-v2-not-yet-supported",
            generatorIdentifier: FoundationModelsNotesConfiguration.generatorIdentifier,
            generatorVersion: nil,
            backendIdentifier: FoundationModelsNotesConfiguration.backendIdentifier
        )
        let sessionID = UUID()
        let generationRecord = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: []),
            windowPlan: NotesWindowPlan(windows: [window]),
            provenance: incompatibleProvenance
        )
        let analysis0 = makeAnalysis(
            windowIndex: 0, sessionID: sessionID, generationID: generationRecord.generationID,
            fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: 0
        )

        do {
            _ = try await generator.synthesize(analyses: [analysis0], generation: generationRecord)
            XCTFail("expected a rejection for incompatible recipeVersion")
        } catch {
            XCTAssertEqual(error as? FoundationModelsNotesBackendError, .incompatibleProvenance)
        }
        XCTAssertEqual(driver.callCount, 0, "an incompatible generation must never reach the model")
    }

    // MARK: - Detailed sections (structurally lossless) + overview

    func testSmallAnalysisCollectionProducesOneSectionPlanAndDirectOverview() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: [window])
        let analysis0 = makeAnalysis(
            windowIndex: 0, sessionID: sessionID, generationID: generationRecord.generationID,
            fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: 0
        )
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Section", 0, 0)]))
        driver.enqueue(AppleOverviewDTO(overview: "Overview."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        let document = try await generator.synthesize(analyses: [analysis0], generation: generationRecord)

        XCTAssertEqual(driver.callCount, 2)
        XCTAssertEqual(driver.capturedPrompts[0].instructions, FoundationModelsLectureNotesGenerator.detailedSectionInstructions)
        XCTAssertEqual(driver.capturedPrompts[1].instructions, FoundationModelsLectureNotesGenerator.overviewInstructions)
        XCTAssertEqual(document.overview, "Overview.")
        XCTAssertEqual(document.sections.count, 1)
        XCTAssertEqual(document.sections[0].heading, "Section")
        XCTAssertEqual(document.sections[0].items, analysis0.items, "the section's items must be exactly the original items, never reconstructed")
    }

    func testSectionPlanRuntimeSchemaBoundsMatchBatchAndExactPreflight() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<3).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        let analyses = (0..<3).map {
            makeAnalysis(
                windowIndex: $0,
                sessionID: sessionID,
                generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint,
                sequenceNumber: $0
            )
        }
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("All", 0, 2)]))
        driver.enqueue(AppleOverviewDTO(overview: "Overview."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        _ = try await generator.synthesize(analyses: analyses, generation: generationRecord)

        XCTAssertEqual(driver.capturedSchemaPreflights.count, 1)
        XCTAssertEqual(driver.capturedSchemaResponses.count, 1)
        let preflight = try XCTUnwrap(driver.capturedSchemaPreflights.first)
        let dispatch = try XCTUnwrap(driver.capturedSchemaResponses.first)
        XCTAssertEqual(dispatch, preflight)
        XCTAssertEqual(dispatch.instructions, FoundationModelsLectureNotesGenerator.detailedSectionInstructions)
        XCTAssertEqual(dispatch.prompt, driver.capturedPrompts[0].prompt)
        try assertSectionPlanIndexBounds(dispatch, inputCount: 3)
    }

    func testMalformedSectionPlanRetriesBeforeAppendingAnySections() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: [window])
        let analysis0 = makeAnalysis(
            windowIndex: 0,
            sessionID: sessionID,
            generationID: generationRecord.generationID,
            fingerprint: generationRecord.transcriptFingerprint,
            sequenceNumber: 0
        )
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange(" ", 0, 0)]))
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Valid section", 0, 0)]))
        driver.enqueue(AppleOverviewDTO(overview: "Overview."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        let document = try await generator.synthesize(
            analyses: [analysis0], generation: generationRecord
        )

        XCTAssertEqual(driver.callCount, 3)
        XCTAssertEqual(driver.capturedPrompts[0].instructions, driver.capturedPrompts[1].instructions)
        XCTAssertEqual(driver.capturedPrompts[0].prompt, driver.capturedPrompts[1].prompt)
        XCTAssertEqual(driver.capturedResponseTypes[0], driver.capturedResponseTypes[1])
        XCTAssertEqual(driver.capturedSchemaPreflights.count, 1)
        XCTAssertEqual(driver.capturedSchemaResponses.count, 2)
        XCTAssertEqual(driver.capturedSchemaResponses[0], driver.capturedSchemaResponses[1])
        XCTAssertEqual(driver.capturedSchemaResponses[0], driver.capturedSchemaPreflights[0])
        try assertSectionPlanIndexBounds(driver.capturedSchemaResponses[0], inputCount: 1)
        XCTAssertEqual(document.sections.map(\.heading), ["Valid section"])
        XCTAssertEqual(document.sections[0].items, analysis0.items)
    }

    func testMalformedGeneratedSectionContentRetriesThenDecodesValidPlan() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: [window])
        let analysis0 = makeAnalysis(
            windowIndex: 0,
            sessionID: sessionID,
            generationID: generationRecord.generationID,
            fingerprint: generationRecord.transcriptFingerprint,
            sequenceNumber: 0
        )
        driver.enqueue(AppleOverviewDTO(overview: "Wrong schema.").generatedContent)
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Valid section", 0, 0)]))
        driver.enqueue(AppleOverviewDTO(overview: "Overview."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        let document = try await generator.synthesize(
            analyses: [analysis0],
            generation: generationRecord
        )

        XCTAssertEqual(driver.capturedSchemaPreflights.count, 1)
        XCTAssertEqual(driver.capturedSchemaResponses.count, 2)
        XCTAssertEqual(driver.capturedSchemaResponses[0], driver.capturedSchemaResponses[1])
        XCTAssertEqual(document.sections.map(\.heading), ["Valid section"])
    }

    func testEmptyOverviewRetriesAndReturnsOnlyValidOverview() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: [window])
        let analysis0 = makeAnalysis(
            windowIndex: 0,
            sessionID: sessionID,
            generationID: generationRecord.generationID,
            fingerprint: generationRecord.transcriptFingerprint,
            sequenceNumber: 0
        )
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Section", 0, 0)]))
        driver.enqueue(AppleOverviewDTO(overview: " "))
        driver.enqueue(AppleOverviewDTO(overview: "Valid overview."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        let document = try await generator.synthesize(
            analyses: [analysis0], generation: generationRecord
        )

        XCTAssertEqual(driver.callCount, 3)
        XCTAssertEqual(driver.capturedPrompts[1].instructions, driver.capturedPrompts[2].instructions)
        XCTAssertEqual(driver.capturedPrompts[1].prompt, driver.capturedPrompts[2].prompt)
        XCTAssertEqual(driver.capturedResponseTypes[1], driver.capturedResponseTypes[2])
        XCTAssertEqual(document.overview, "Valid overview.")
    }

    /// 20 small window analyses exceed only the deterministic item-count
    /// safety cap (`maxItemsSafetyCapPerCall: 12` by default), never the
    /// byte budget. Detailed section planning groups them into 2
    /// contiguous, ordered batches (12 + 8); the model only returns
    /// organization (heading + index range) per batch, and Swift assembles
    /// each section directly from the original items — proven here via
    /// exact equality, not merely matching scripted content. The overview
    /// pipeline separately reduces the same items, then makes one final
    /// short-overview call.
    func testDetailedSectionBatchingIsContiguousOrderedAndLosslessAndOverviewReducesSeparately() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<20).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        let analyses = (0..<20).map {
            makeAnalysis(
                windowIndex: $0, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: $0
            )
        }

        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec A", 0, 11)]))
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec B", 0, 7)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: "reduced 0-11", first: 0, last: 1)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: "reduced 12-19", first: 12, last: 13)]))
        driver.enqueue(AppleOverviewDTO(overview: "Final overview."))

        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let document = try await generator.synthesize(analyses: analyses.reversed(), generation: generationRecord)

        XCTAssertEqual(driver.callCount, 5)
        let prompts = driver.capturedPrompts
        XCTAssertEqual(prompts[0].instructions, FoundationModelsLectureNotesGenerator.detailedSectionInstructions)
        XCTAssertTrue(prompts[0].prompt.contains("window 0 content"))
        XCTAssertTrue(prompts[0].prompt.contains("window 11 content"))
        XCTAssertFalse(prompts[0].prompt.contains("window 12 content"))
        XCTAssertEqual(prompts[1].instructions, FoundationModelsLectureNotesGenerator.detailedSectionInstructions)
        XCTAssertTrue(prompts[1].prompt.contains("window 12 content"))
        XCTAssertTrue(prompts[1].prompt.contains("window 19 content"))
        XCTAssertEqual(prompts[2].instructions, FoundationModelsLectureNotesGenerator.reductionInstructions)
        XCTAssertEqual(prompts[3].instructions, FoundationModelsLectureNotesGenerator.reductionInstructions)
        XCTAssertEqual(prompts[4].instructions, FoundationModelsLectureNotesGenerator.overviewInstructions)

        XCTAssertEqual(document.sections.count, 2)
        XCTAssertEqual(document.sections[0].heading, "Sec A")
        XCTAssertEqual(document.sections[1].heading, "Sec B")
        let orderedOriginalItems = analyses.sorted { $0.windowIndex < $1.windowIndex }.flatMap(\.items)
        XCTAssertEqual(document.sections[0].items, Array(orderedOriginalItems[0..<12]))
        XCTAssertEqual(document.sections[1].items, Array(orderedOriginalItems[12..<20]))
        XCTAssertEqual(document.overview, "Final overview.")
    }

    /// Only 2 analyses — far below any item-count threshold — but each
    /// item's body is ~5,000 bytes. Each item still fits comfortably
    /// *alone* within the default 6,000-byte call budget, so detailed
    /// section planning sends them as 2 independent batches with no forced
    /// reduction — and since the model never restates item content, the
    /// full 5,000-byte body survives structurally regardless of what the
    /// (content-free) plan response says. The overview, which must combine
    /// *both* into one short summary, cannot fit them together and
    /// correctly triggers reduction.
    func testFewVeryLargeItemsFitSectionBatchesIndividuallyButTriggerOverviewReduction() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<2).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        let hugeBody = String(repeating: "x", count: 5_000)
        let analyses = (0..<2).map {
            makeAnalysis(
                windowIndex: $0, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: $0, body: hugeBody
            )
        }
        XCTAssertLessThan(analyses.count, 12, "item count alone would never have triggered anything under any old default threshold")

        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec 0", 0, 0)]))
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec 1", 0, 0)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: "short reduced 0", first: 0)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: "short reduced 1", first: 1)]))
        driver.enqueue(AppleOverviewDTO(overview: "Overview."))

        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
        let document = try await generator.synthesize(analyses: analyses, generation: generationRecord)

        XCTAssertEqual(driver.callCount, 5)
        let prompts = driver.capturedPrompts
        XCTAssertEqual(prompts[0].instructions, FoundationModelsLectureNotesGenerator.detailedSectionInstructions)
        XCTAssertEqual(prompts[1].instructions, FoundationModelsLectureNotesGenerator.detailedSectionInstructions)
        XCTAssertEqual(prompts[2].instructions, FoundationModelsLectureNotesGenerator.reductionInstructions)
        XCTAssertEqual(prompts[3].instructions, FoundationModelsLectureNotesGenerator.reductionInstructions)
        XCTAssertEqual(prompts[4].instructions, FoundationModelsLectureNotesGenerator.overviewInstructions)
        XCTAssertEqual(document.sections.count, 2)
        XCTAssertEqual(document.sections[0].items[0].body, hugeBody, "detailed sections must never lose full item detail merely to fit the overview")
        XCTAssertEqual(document.overview, "Overview.")
    }

    // MARK: - Structurally lossless preservation

    /// Several distinct, fully-populated items (distinct IDs, titles,
    /// bodies including a formula/code-like body, mixed fidelity, distinct
    /// source references, and uncertainty notes) go through a VALID
    /// multi-section plan. The final assembled sections' items must equal
    /// the original ordered items exactly (domain `Equatable`, including
    /// `id`) — never a semantic approximation, and never reordered. The
    /// scripted plan response carries zero item content, proving equality
    /// is structural (sliced from the originals), not merely because the
    /// script happened to match.
    func testDetailedSectionsPreserveOriginalItemsExactlyAndInOrder() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let generationID = UUID()
        let fingerprint = TranscriptSourceFingerprint.compute(sessionID: sessionID, units: [])
        let window = NotesInputWindow(windowIndex: 0, firstSequenceNumber: 0, lastSequenceNumber: 3, unitCount: 4, isOversizedSingleUnit: false)
        let generationRecord = LectureNotesGenerationRecord.newGeneration(
            generationID: generationID, sessionID: sessionID, transcriptFingerprint: fingerprint,
            windowPlan: NotesWindowPlan(windows: [window]), provenance: FoundationModelsNotesConfiguration.generationProvenance
        )

        let originalItems: [LectureNoteItem] = [
            LectureNoteItem(
                kind: .formula, title: "Kinetic energy", body: "KE = 1/2 m v^2",
                fidelity: .transcriptSupported, sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 0)]
            ),
            LectureNoteItem(
                kind: .algorithmOrCode, title: nil, body: "for i in 0..<n { sum += a[i] }",
                fidelity: .reconstructed, sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 1)],
                uncertaintyNote: "code was reconstructed from a spoken description"
            ),
            LectureNoteItem(
                kind: .warning, title: "Edge case", body: "This diverges when the denominator is zero.",
                fidelity: .uncertain, sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 2)],
                uncertaintyNote: "instructor's exact wording was ambiguous"
            ),
            LectureNoteItem(
                kind: .example, title: "Worked example", body: "Plugging in v = 3 gives KE = 4.5 m.",
                fidelity: .transcriptSupported, sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: 3)]
            )
        ]
        let analysis0 = LectureNotesWindowAnalysis(
            generationID: generationID, sessionID: sessionID, transcriptFingerprint: fingerprint, windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 0, lastSequenceNumber: 3),
            items: originalItems
        )

        // Two sections splitting the 4-item batch; the response carries no
        // item content whatsoever.
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Theory", 0, 1), sectionRange("Caveats and examples", 2, 3)]))
        driver.enqueue(AppleOverviewDTO(overview: "Overview."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        let document = try await generator.synthesize(analyses: [analysis0], generation: generationRecord)

        XCTAssertEqual(document.sections.count, 2)
        XCTAssertEqual(document.sections[0].heading, "Theory")
        XCTAssertEqual(document.sections[1].heading, "Caveats and examples")
        XCTAssertEqual(document.sections.flatMap(\.items), originalItems, "assembled items must equal the originals exactly, including id, in original order")
    }

    /// Every way `assembleSections` must reject a malformed model-produced
    /// plan, before any `LectureNoteSection` is ever constructed: missing
    /// first/middle/last item, overlapping ranges, a gap, out-of-bounds
    /// indices, an inverted range, out-of-order ranges, and an empty
    /// heading.
    func testSectionPlanValidationRejectsEveryMalformedShape() async throws {
        let sessionID = UUID()
        let windows = (0..<3).map { singleUnitWindow($0) }
        let makeFixture: () -> (LectureNotesGenerationRecord, [LectureNotesWindowAnalysis]) = {
            let record = self.makeGenerationRecord(sessionID: sessionID, windows: windows)
            let analyses = (0..<3).map {
                self.makeAnalysis(
                    windowIndex: $0, sessionID: sessionID, generationID: record.generationID,
                    fingerprint: record.transcriptFingerprint, sequenceNumber: $0
                )
            }
            return (record, analyses)
        }

        let malformedPlans: [(String, [AppleSectionRangeDTO])] = [
            ("missing first item", [sectionRange("A", 1, 2)]),
            ("missing middle item", [sectionRange("A", 0, 0), sectionRange("B", 2, 2)]),
            ("missing last item", [sectionRange("A", 0, 1)]),
            ("overlapping ranges", [sectionRange("A", 0, 1), sectionRange("B", 1, 2)]),
            ("gap between sections", [sectionRange("A", 0, 0), sectionRange("B", 2, 2)]),
            ("out-of-bounds index", [sectionRange("A", 0, 5)]),
            ("inverted range", [sectionRange("A", 2, 0)]),
            ("out-of-order ranges", [sectionRange("A", 2, 2), sectionRange("B", 0, 1)]),
            ("empty section heading", [sectionRange("", 0, 2)])
        ]

        for (description, sections) in malformedPlans {
            let driver = FakeFoundationModelsSessionDriver()
            driver.enqueue(AppleSectionPlanDTO(sections: sections))
            driver.enqueue(AppleSectionPlanDTO(sections: sections))
            let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)
            let (record, analyses) = makeFixture()

            do {
                _ = try await generator.synthesize(analyses: analyses, generation: record)
                XCTFail("expected rejection for: \(description)")
            } catch let error as FoundationModelsNotesBackendError {
                guard case .malformedResponse = error else {
                    XCTFail("[\(description)] expected .malformedResponse, got \(error)")
                    continue
                }
            }
        }
    }

    // MARK: - Fail-closed context handling (never submit a request known not to fit)

    /// A single item too large to fit even alone must fail cleanly before
    /// any model request — proven here via the detailed-section pipeline
    /// (which runs first in `synthesize`), so zero requests are ever made.
    func testSingleOversizedItemFailsClosedBeforeAnyRequest() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: [window])
        let hugeBody = String(repeating: "x", count: 10_000)
        let analysis0 = makeAnalysis(
            windowIndex: 0, sessionID: sessionID, generationID: generationRecord.generationID,
            fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: 0, body: hugeBody
        )
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        do {
            _ = try await generator.synthesize(analyses: [analysis0], generation: generationRecord)
            XCTFail("expected a context-budget failure")
        } catch {
            guard case .contextBudgetExceeded(let stage) = error as? FoundationModelsNotesBackendError else {
                XCTFail("expected .contextBudgetExceeded, got \(error)")
                return
            }
            XCTAssertTrue(stage.contains("detailed section"))
        }
        XCTAssertEqual(driver.callCount, 0, "no oversized request may ever reach the model")
    }

    /// Two large-but-individually-fitting items reduce fine for the
    /// overview when reduction actually shrinks content (see the
    /// individually-fitting test above). Here the reduction responses are
    /// scripted to NOT shrink the content at all, simulating a model that
    /// fails to condense — proving the hard `maxReductionLevels` bound
    /// (not merely hoping the model helps) is what stops an infinite or
    /// oversized retry loop, and that zero oversized final requests are
    /// ever made once the bound is hit.
    func testMaxReductionLevelsReachedWhileStillOversizedFailsClosed() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<2).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        let hugeBody = String(repeating: "x", count: 5_000)
        let analyses = (0..<2).map {
            makeAnalysis(
                windowIndex: $0, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: $0, body: hugeBody
            )
        }

        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec 0", 0, 0)]))
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec 1", 0, 0)]))
        // The reduction pipeline's own "verify each chunk fits" step still
        // passes (each huge item fits alone under `reductionInstructions`
        // too), so these 2 calls happen — but the model does not actually
        // shrink the content, so the overview still will not fit after
        // level 0 with `maxReductionLevels: 1`.
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: hugeBody, first: 0)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: hugeBody, first: 1)]))

        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver, maxReductionLevels: 1)

        do {
            _ = try await generator.synthesize(analyses: analyses, generation: generationRecord)
            XCTFail("expected a context-budget failure")
        } catch {
            guard case .contextBudgetExceeded(let stage) = error as? FoundationModelsNotesBackendError else {
                XCTFail("expected .contextBudgetExceeded, got \(error)")
                return
            }
            XCTAssertEqual(stage, "overview generation")
        }
        XCTAssertEqual(driver.callCount, 4, "2 detailed-section calls + 2 reduction calls, and never a 5th (oversized) overview call")
    }

    func testMalformedReductionRetriesAndPreservesExactSourceGrounding() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<20).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        let analyses = (0..<20).map {
            makeAnalysis(
                windowIndex: $0,
                sessionID: sessionID,
                generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint,
                sequenceNumber: $0
            )
        }
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec A", 0, 11)]))
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec B", 0, 7)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(
            body: "Discarded invalid reduction.", first: 99
        )]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(
            body: "Valid reduced first chunk.", first: 0, last: 1
        )]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(
            body: "Valid reduced second chunk.", first: 12, last: 13
        )]))
        driver.enqueue(AppleOverviewDTO(overview: "Grounded overview."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        let document = try await generator.synthesize(
            analyses: analyses, generation: generationRecord
        )

        XCTAssertEqual(driver.callCount, 6)
        XCTAssertEqual(driver.capturedPrompts[2].instructions, driver.capturedPrompts[3].instructions)
        XCTAssertEqual(driver.capturedPrompts[2].prompt, driver.capturedPrompts[3].prompt)
        XCTAssertEqual(driver.capturedResponseTypes[2], driver.capturedResponseTypes[3])
        let overviewPrompt = driver.capturedPrompts[5].prompt
        XCTAssertTrue(overviewPrompt.contains("Valid reduced first chunk."))
        XCTAssertFalse(overviewPrompt.contains("Discarded invalid reduction."))
        XCTAssertEqual(document.overview, "Grounded overview.")
    }

    func testReductionCannotExpandSourceReferenceScope() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<20).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        let analyses = (0..<20).map {
            makeAnalysis(
                windowIndex: $0, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: $0
            )
        }
        // Section plans (2 calls) succeed normally; the first overview
        // reduction chunk's response claims a sequence outside its own
        // chunk's allowed set.
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec A", 0, 11)]))
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec B", 0, 7)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(first: 99)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(first: 99)]))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        do {
            _ = try await generator.synthesize(analyses: analyses, generation: generationRecord)
            XCTFail("expected a rejection for a reduction widening its source-reference scope")
        } catch {
            XCTAssertEqual(error as? FoundationModelsNotesBackendError, .invalidSourceReference)
        }
        XCTAssertEqual(driver.callCount, 4)
    }

    // MARK: - Uncertainty preservation across stages

    /// A reconstructed/uncertain item's `uncertaintyNote` must survive
    /// into the next-stage prompt (detailed-section-planning input, or
    /// reduction) — never silently dropped between model calls. It is
    /// never restated by the model in the section-plan response (there is
    /// no field for it), but it must still be present in the *input*
    /// prompt so the model can make sensible grouping decisions.
    func testUncertaintyNoteSurvivesIntoNextStagePrompt() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<20).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        var analyses = (0..<20).map {
            makeAnalysis(
                windowIndex: $0, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: $0
            )
        }
        analyses[0] = makeAnalysis(
            windowIndex: 0, sessionID: sessionID, generationID: generationRecord.generationID,
            fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: 0,
            fidelity: .uncertain, uncertaintyNote: "normalized from ambiguous spoken notation"
        )

        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec A", 0, 11)]))
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec B", 0, 7)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(first: 0, last: 1)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(first: 12, last: 13)]))
        driver.enqueue(AppleOverviewDTO(overview: "Overview."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        _ = try await generator.synthesize(analyses: analyses, generation: generationRecord)

        let sectionPlanPrompt = driver.capturedPrompts[0].prompt
        let reductionPrompt = driver.capturedPrompts[2].prompt
        XCTAssertTrue(sectionPlanPrompt.contains("normalized from ambiguous spoken notation"), "detailed-section-planning prompt dropped the uncertainty note")
        XCTAssertTrue(reductionPrompt.contains("normalized from ambiguous spoken notation"), "reduction prompt dropped the uncertainty note")
    }

    // MARK: - Exact byte packing

    /// Two items whose independently-encoded sizes sum to *exactly* the
    /// byte budget, but whose actually-joined prompt (with the "\n"
    /// separator inserted between them) is one byte over — must be packed
    /// into 2 separate batches, never incorrectly combined into one
    /// oversized candidate because the packer summed each item's
    /// independently-encoded size instead of accounting for the separator
    /// exactly. Sizes are computed programmatically (not hand-counted)
    /// from the same literal encoding format detailed-section planning
    /// actually uses (index-based), to avoid an off-by-N byte-counting
    /// mistake in the test itself.
    func testPackingAccountsExactlyForJoinSeparatorBytes() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<2).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)

        let body = String(repeating: "x", count: 30)
        // Detailed-section-plan packing sizes each item as a singleton
        // (always re-indexed to "[0]" when measured alone), so both items
        // measure identically regardless of their eventual real position.
        let singleItemSize = "[0] (explanation/transcriptSupported) \(body)".utf8.count
        let naiveIndependentSum = singleItemSize * 2
        let actualJoinedSize = singleItemSize + 1 + singleItemSize
        XCTAssertEqual(actualJoinedSize, naiveIndependentSum + 1, "test setup sanity check: the join separator must be the only difference")

        let analyses = [
            makeAnalysis(
                windowIndex: 0, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: 0, body: body
            ),
            makeAnalysis(
                windowIndex: 1, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: 1, body: body
            )
        ]

        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec 0", 0, 0)]))
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec 1", 0, 0)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: "reduced 0", first: 0)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: "reduced 1", first: 1)]))
        driver.enqueue(AppleOverviewDTO(overview: "Overview."))

        // A budget equal to the naive independent sum: the buggy packer
        // (summing parts, ignoring the separator) would think this pair
        // fits exactly; the fixed packer must still see the real joined
        // size is 1 byte over and keep them separate.
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver, maxInputBytesPerCall: naiveIndependentSum)
        let document = try await generator.synthesize(analyses: analyses, generation: generationRecord)

        // Exactly 2 detailed-section-plan batches proves the packer
        // correctly refused to combine them despite the naive
        // independently-summed size fitting exactly.
        let sectionPlanPrompts = driver.capturedPrompts.filter { $0.instructions == FoundationModelsLectureNotesGenerator.detailedSectionInstructions }
        XCTAssertEqual(sectionPlanPrompts.count, 2)
        XCTAssertEqual(document.sections.count, 2)
    }

    // MARK: - Cancellation

    func testCancellationDuringDetailedSectionPlanningCommitsNoResult() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<20).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        let analyses = (0..<20).map {
            makeAnalysis(
                windowIndex: $0, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: $0
            )
        }
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec A", 0, 11)]))
        driver.armGate(beforeCallNumber: 2)
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        let task = Task { try await generator.synthesize(analyses: analyses, generation: generationRecord) }
        while !driver.hasEnteredGate { await Task.yield() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(driver.callCount, 2)
    }

    func testCancellationDuringOverviewReductionCommitsNoResult() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        let sessionID = UUID()
        let windows = (0..<20).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        let analyses = (0..<20).map {
            makeAnalysis(
                windowIndex: $0, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: $0
            )
        }
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec A", 0, 11)]))
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Sec B", 0, 7)]))
        driver.enqueue(AppleNoteItemsDTO(items: [makeItemDTO(body: "reduced 0-11", first: 0, last: 1)]))
        driver.armGate(beforeCallNumber: 4)
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        let task = Task { try await generator.synthesize(analyses: analyses, generation: generationRecord) }
        while !driver.hasEnteredGate { await Task.yield() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(driver.callCount, 4)
    }

    // MARK: - Real-token-preflight branch

    /// A byte-tiny request that the real token preflight reports as too
    /// large must not bypass that result via the byte fallback.
    func testTokenPreflightRejectsByteSmallRequestWhenReportedTooLarge() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(100)
        driver.setTokenCountOverride(200)
        let sessionID = UUID()
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: [window])
        let analysis0 = makeAnalysis(
            windowIndex: 0, sessionID: sessionID, generationID: generationRecord.generationID,
            fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: 0, body: "tiny"
        )
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        do {
            _ = try await generator.synthesize(analyses: [analysis0], generation: generationRecord)
            XCTFail("expected a context-budget failure driven by the real token result")
        } catch {
            XCTAssertEqual(error as? FoundationModelsNotesBackendError, .contextBudgetExceeded("detailed section planning"))
        }
        XCTAssertEqual(driver.callCount, 0, "the real too-large result must never be bypassed by the byte-tiny fallback estimate")
    }

    /// 20 items would fail the deterministic item-count fallback cap
    /// (12), but a real token preflight reporting them as safe must be
    /// honored — the whole list is sent as one request, not needlessly
    /// pre-split.
    func testTokenPreflightAcceptsManyItemsWhenReportedSafeDespiteItemCountFallback() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(4_096)
        driver.setTokenCountOverride(10)
        let sessionID = UUID()
        let windows = (0..<20).map { singleUnitWindow($0) }
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: windows)
        let analyses = (0..<20).map {
            makeAnalysis(
                windowIndex: $0, sessionID: sessionID, generationID: generationRecord.generationID,
                fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: $0
            )
        }
        driver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("All", 0, 19)]))
        driver.enqueue(AppleOverviewDTO(overview: "Overview."))
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        let document = try await generator.synthesize(analyses: analyses, generation: generationRecord)

        XCTAssertEqual(driver.callCount, 2, "the real token-safe result must send the whole list as one request, never pre-split by the item-count fallback alone")
        XCTAssertEqual(document.sections.count, 1)
    }

    // MARK: - Stage-specific response-headroom policy

    /// The same real-token-preflight estimate (800) and the same
    /// `contextTokenBudget` (1,100) is rejected for a window-analysis
    /// request (reserve 1,024 by default: 800+1024 > 1100) but accepted
    /// for detailed-section-planning and overview requests (reserves 128
    /// and 256 by default: both leave the total under 1,100) — proving
    /// response headroom is genuinely stage-specific, not one shared
    /// number applied everywhere.
    func testAnalysisReserveIsLargerThanSectionPlanAndOverviewReservesForTheSameTokenEstimate() async throws {
        let analysisDriver = FakeFoundationModelsSessionDriver()
        analysisDriver.setContextTokenBudget(1_100)
        analysisDriver.setTokenCountOverride(800)
        let analysisGenerator = FoundationModelsLectureNotesGenerator(sessionDriver: analysisDriver)
        let window = singleUnitWindow(0)
        let analysisGenerationRecord = makeGenerationRecord(windows: [window])

        do {
            _ = try await analysisGenerator.analyzeWindow(units: [unit(0)], window: window, generation: analysisGenerationRecord)
            XCTFail("expected analysis to be rejected under its larger response reserve")
        } catch {
            guard case .contextBudgetExceeded = error as? FoundationModelsNotesBackendError else {
                XCTFail("expected .contextBudgetExceeded, got \(error)")
                return
            }
        }
        XCTAssertEqual(analysisDriver.callCount, 0)

        let synthesizeDriver = FakeFoundationModelsSessionDriver()
        synthesizeDriver.setContextTokenBudget(1_100)
        synthesizeDriver.setTokenCountOverride(800)
        synthesizeDriver.enqueue(AppleSectionPlanDTO(sections: [sectionRange("Section", 0, 0)]))
        synthesizeDriver.enqueue(AppleOverviewDTO(overview: "Overview."))
        let synthesizeGenerator = FoundationModelsLectureNotesGenerator(sessionDriver: synthesizeDriver)
        let sessionID = UUID()
        let synthesizeGenerationRecord = makeGenerationRecord(sessionID: sessionID, windows: [window])
        let analysis0 = makeAnalysis(
            windowIndex: 0, sessionID: sessionID, generationID: synthesizeGenerationRecord.generationID,
            fingerprint: synthesizeGenerationRecord.transcriptFingerprint, sequenceNumber: 0
        )

        let document = try await synthesizeGenerator.synthesize(analyses: [analysis0], generation: synthesizeGenerationRecord)
        XCTAssertEqual(document.sections.count, 1, "the same token estimate must fit under the smaller section-planning and overview reserves")
    }

    /// A section-plan request must still fail closed when genuinely over
    /// budget, even under its smaller reserve.
    func testSectionPlanStillFailsClosedWhenGenuinelyOverBudget() async throws {
        let driver = FakeFoundationModelsSessionDriver()
        driver.setContextTokenBudget(1_000)
        driver.setTokenCountOverride(1_000)
        let sessionID = UUID()
        let window = singleUnitWindow(0)
        let generationRecord = makeGenerationRecord(sessionID: sessionID, windows: [window])
        let analysis0 = makeAnalysis(
            windowIndex: 0, sessionID: sessionID, generationID: generationRecord.generationID,
            fingerprint: generationRecord.transcriptFingerprint, sequenceNumber: 0
        )
        let generator = FoundationModelsLectureNotesGenerator(sessionDriver: driver)

        do {
            _ = try await generator.synthesize(analyses: [analysis0], generation: generationRecord)
            XCTFail("expected a context-budget failure")
        } catch {
            XCTAssertEqual(error as? FoundationModelsNotesBackendError, .contextBudgetExceeded("detailed section planning"))
        }
        XCTAssertEqual(driver.callCount, 0)
    }
}
