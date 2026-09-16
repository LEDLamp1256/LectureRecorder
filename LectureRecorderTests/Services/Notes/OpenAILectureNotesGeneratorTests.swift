import XCTest
@testable import LectureRecorder

final class OpenAILectureNotesGeneratorTests: XCTestCase {
    private let apiKey = "test-secret-key"

    private func configurationSource(apiKey: String? = "test-secret-key") -> OpenAINotesConfigurationSource {
        OpenAINotesConfigurationSource { key in key == "OPENAI_API_KEY" ? apiKey : nil }
    }

    private func unit(_ sequence: Int, text: String = "The professor derives E equals m c squared.") -> NotesTranscriptSourceUnit {
        NotesTranscriptSourceUnit(
            sequenceNumber: sequence,
            chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequence),
            text: text,
            startOffsetSeconds: Double(sequence) * 30,
            durationSeconds: 30
        )
    }

    private func generation(units: [NotesTranscriptSourceUnit]) throws -> LectureNotesGenerationRecord {
        let sessionID = UUID()
        let fingerprint = TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        let window = NotesInputWindow(
            windowIndex: 0,
            firstSequenceNumber: units.first!.sequenceNumber,
            lastSequenceNumber: units.last!.sequenceNumber,
            unitCount: units.count,
            isOversizedSingleUnit: false
        )
        return LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            windowPlan: NotesWindowPlan(windows: [window]),
            provenance: configurationSource().generationProvenance
        )
    }

    private func response(status: Int = 200, headers: [String: String] = [:], payload: Any) throws -> NotesHTTPResponse {
        let body: Any
        if status == 200 {
            let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let payloadText = String(decoding: payloadData, as: UTF8.self)
            body = [
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [["type": "output_text", "text": payloadText]]
                ]]
            ]
        } else {
            body = payload
        }
        return NotesHTTPResponse(
            statusCode: status,
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private func rawResponse(_ body: Any) throws -> NotesHTTPResponse {
        NotesHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private func item(
        kind: String = "explanation",
        fidelity: String = "transcriptSupported",
        first: Int = 0,
        last: Int = 0,
        uncertaintyNote: Any = NSNull()
    ) -> [String: Any] {
        [
            "kind": kind,
            "title": "Relativity",
            "body": "Mass and energy are related.",
            "fidelity": fidelity,
            "sourceReferences": [["firstSequenceNumber": first, "lastSequenceNumber": last]],
            "uncertaintyNote": uncertaintyNote
        ]
    }

    private func makeGenerator(transport: FakeNotesHTTPTransport, apiKey: String? = "test-secret-key") -> OpenAILectureNotesGenerator {
        OpenAILectureNotesGenerator(configurationSource: configurationSource(apiKey: apiKey), transport: transport)
    }

    private func analyze(using generator: OpenAILectureNotesGenerator, units: [NotesTranscriptSourceUnit]) async throws -> LectureNotesWindowAnalysis {
        let generation = try generation(units: units)
        return try await generator.analyzeWindow(
            units: units,
            window: generation.windowPlan.windows[0],
            generation: generation
        )
    }

    func testMissingAndEmptyAPIKeyFailWithStableConfigurationError() async throws {
        for key in [nil, "", "   "] as [String?] {
            let transport = FakeNotesHTTPTransport(behaviors: [])
            do {
                _ = try await analyze(using: makeGenerator(transport: transport, apiKey: key), units: [unit(0)])
                XCTFail("expected configuration failure")
            } catch {
                XCTAssertEqual(error as? OpenAINotesBackendError, .configuration(.missingAPIKey))
            }
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testAnalysisRequestUsesResponsesModelStrictSchemaAndTechnicalGroundingInstructions() async throws {
        let transport = FakeNotesHTTPTransport(behaviors: [
            .response(try response(payload: ["items": [item()]]))
        ])
        let units = [unit(0)]
        let analysis = try await analyze(using: makeGenerator(transport: transport), units: units)
        let capturedRequests = await transport.requests
        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(body["store"] as? Bool, false)
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        for phrase in ["derivations", "formulas", "algorithms", "code", "instructor emphasis", "Do not supplement", "Do not invent chunk indices", "transcriptSupported", "reconstructed", "uncertain"] {
            XCTAssertTrue(instructions.contains(phrase), "missing instruction: \(phrase)")
        }
        let input = try XCTUnwrap(body["input"] as? String)
        XCTAssertTrue(input.contains("sequenceNumber"))
        XCTAssertTrue(input.contains("startOffsetSeconds"))
        XCTAssertTrue(input.contains(units[0].text))
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertNotNil(format["schema"] as? [String: Any])
        XCTAssertEqual(analysis.items.count, 1)
        XCTAssertFalse(String(describing: analysis).contains(apiKey))
        XCTAssertFalse(String(describing: analysis.generationID).contains(apiKey))
    }

    func testAnalysisMapsEveryFidelityAndSourceReferences() async throws {
        let payload: [String: Any] = ["items": [
            item(kind: "definition", fidelity: "transcriptSupported", first: 0),
            item(kind: "formula", fidelity: "reconstructed", first: 1, last: 1, uncertaintyNote: "Notation normalized from speech."),
            item(kind: "algorithmOrCode", fidelity: "uncertain", first: 2, last: 2, uncertaintyNote: "Operator was ambiguous.")
        ]]
        let transport = FakeNotesHTTPTransport(behaviors: [.response(try response(payload: payload))])
        let analysis = try await analyze(using: makeGenerator(transport: transport), units: [unit(0), unit(1), unit(2)])
        XCTAssertEqual(analysis.items.map(\.fidelity), [.transcriptSupported, .reconstructed, .uncertain])
        XCTAssertEqual(analysis.items.map { $0.sourceReferences[0].firstSequenceNumber }, [0, 1, 2])
        XCTAssertEqual(analysis.items[1].uncertaintyNote, "Notation normalized from speech.")
    }

    func testExistingGenerationUsesRecordedModelWhenCurrentConfigurationChanges() async throws {
        let units = [unit(0)]
        let generation = try generation(units: units)
        let key = apiKey
        let changedSource = OpenAINotesConfigurationSource(model: "newly-configured-model") { _ in key }
        let transport = FakeNotesHTTPTransport(behaviors: [.response(try response(payload: ["items": [item()]]))])
        let generator = OpenAILectureNotesGenerator(configurationSource: changedSource, transport: transport)

        _ = try await generator.analyzeWindow(
            units: units,
            window: generation.windowPlan.windows[0],
            generation: generation
        )

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-sol")
        XCTAssertNotEqual(body["model"] as? String, changedSource.model)
    }

    func testIncompatibleGenerationProvenanceIsRejectedBeforeTransport() async throws {
        let units = [unit(0)]
        var generation = try generation(units: units)
        generation.provenance.backendIdentifier = "different-backend"
        let transport = FakeNotesHTTPTransport(behaviors: [])
        do {
            _ = try await makeGenerator(transport: transport).analyzeWindow(
                units: units,
                window: generation.windowPlan.windows[0],
                generation: generation
            )
            XCTFail("expected provenance rejection")
        } catch {
            guard case .unsupportedProviderResponse = error as? OpenAINotesBackendError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testIncompatibleRecipeVersionIsRejectedBeforeTransport() async throws {
        let units = [unit(0)]
        var generation = try generation(units: units)
        generation.provenance.recipeVersion = "stale-openai-notes-recipe"
        let transport = FakeNotesHTTPTransport(behaviors: [])

        do {
            _ = try await makeGenerator(transport: transport).analyzeWindow(
                units: units,
                window: generation.windowPlan.windows[0],
                generation: generation
            )
            XCTFail("expected recipe-version rejection")
        } catch {
            guard case .unsupportedProviderResponse = error as? OpenAINotesBackendError else {
                return XCTFail("unexpected error \(error)")
            }
        }

        XCTAssertEqual(generation.provenance.generatorIdentifier, OpenAINotesConfiguration.generatorIdentifier)
        XCTAssertEqual(generation.provenance.backendIdentifier, OpenAINotesConfiguration.backendIdentifier)
        XCTAssertEqual(generation.provenance.generatorVersion, "gpt-5.6-sol")
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMalformedMissingInvalidEnumAndExtraFieldResponsesFailStrictly() async throws {
        let malformedEnvelope = try rawResponse(["status": "completed", "output": []])
        var invalidEnumItem = item()
        invalidEnumItem["fidelity"] = "probably"
        var extraItem = item()
        extraItem["invented"] = true
        let nonJSONPayloadEnvelope: [String: Any] = [
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": "not-json"]]
            ]]
        ]
        let responses = [
            try rawResponse(nonJSONPayloadEnvelope),
            malformedEnvelope,
            try response(payload: ["items": [invalidEnumItem]]),
            try response(payload: ["items": [extraItem]])
        ]
        let expected: [OpenAINotesBackendError] = [
            .malformedStructuredResponse,
            .missingExpectedPayload,
            .malformedStructuredResponse,
            .malformedStructuredResponse
        ]
        for (providerResponse, expectedError) in zip(responses, expected) {
            let transport = FakeNotesHTTPTransport(behaviors: [.response(providerResponse)])
            do {
                _ = try await analyze(using: makeGenerator(transport: transport), units: [unit(0)])
                XCTFail("expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? OpenAINotesBackendError, expectedError)
            }
        }
    }

    func testInventedReferenceAndMissingUncertaintyContextAreRejectedWithoutRepair() async throws {
        for invalidItem in [
            item(first: 9),
            item(kind: "formula", fidelity: "reconstructed", uncertaintyNote: NSNull())
        ] {
            let transport = FakeNotesHTTPTransport(behaviors: [.response(try response(payload: ["items": [invalidItem]]))])
            do {
                _ = try await analyze(using: makeGenerator(transport: transport), units: [unit(0)])
                XCTFail("expected unsupported response")
            } catch {
                guard case .unsupportedProviderResponse = error as? OpenAINotesBackendError else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testSynthesisRepresentsAllAnalysesInOrderAndMapsDocument() async throws {
        let units = [unit(0), unit(1)]
        let generation = try generation(units: units)
        let analyses = [0, 1].map { index in
            LectureNotesWindowAnalysis(
                generationID: generation.generationID,
                sessionID: generation.sessionID,
                transcriptFingerprint: generation.transcriptFingerprint,
                windowIndex: index,
                ownedRange: NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: index),
                items: [LectureNoteItem(
                    kind: .explanation,
                    body: "analysis \(index)",
                    fidelity: .transcriptSupported,
                    sourceReferences: [NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: index)]
                )]
            )
        }
        let payload: [String: Any] = [
            "overview": "Two useful takeaways.",
            "sections": [["heading": "Core ideas", "items": [item(first: 0, last: 1)]]]
        ]
        let transport = FakeNotesHTTPTransport(behaviors: [.response(try response(payload: payload))])
        let document = try await makeGenerator(transport: transport).synthesize(analyses: analyses, generation: generation)
        let capturedRequests = await transport.requests
        let request = try XCTUnwrap(capturedRequests.first)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        let input = try XCTUnwrap(body["input"] as? String)
        XCTAssertLessThan(try XCTUnwrap(input.range(of: "analysis 0")?.lowerBound), try XCTUnwrap(input.range(of: "analysis 1")?.lowerBound))
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains("committed window analyses"))
        XCTAssertTrue(instructions.contains("lecture order"))
        XCTAssertTrue(instructions.contains("5–10"))
        XCTAssertTrue(instructions.contains("Do not reload"))
        let format = ((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format?["strict"] as? Bool, true)
        XCTAssertEqual(document.overview, "Two useful takeaways.")
        XCTAssertEqual(document.sections.first?.items.first?.sourceReferences.first?.lastSequenceNumber, 1)
        XCTAssertEqual(document.provenance, generation.provenance)
    }

    func testMalformedSynthesisResponseFailsCleanly() async throws {
        let units = [unit(0)]
        let generation = try generation(units: units)
        let analysis = LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: 0,
            ownedRange: NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: 0),
            items: [LectureNoteItem(kind: .explanation, body: "x", fidelity: .transcriptSupported, sourceReferences: [NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: 0)])]
        )
        let transport = FakeNotesHTTPTransport(behaviors: [.response(try response(payload: ["overview": "x", "sections": [], "extra": true]))])
        do {
            _ = try await makeGenerator(transport: transport).synthesize(analyses: [analysis], generation: generation)
            XCTFail("expected malformed response")
        } catch {
            XCTAssertEqual(error as? OpenAINotesBackendError, .malformedStructuredResponse)
        }
    }

    func testHTTPAndTransportFailuresAreDifferentiated() async throws {
        let cases: [(FakeNotesHTTPTransport.Behavior, OpenAINotesBackendError)] = [
            (.response(try response(status: 401, payload: ["error": ["code": "invalid_api_key"]])), .authenticationFailure),
            (.response(try response(status: 429, headers: ["Retry-After": "7"], payload: ["error": ["code": "rate_limit_exceeded"]])), .rateLimited(retryAfterSeconds: 7)),
            (.response(try response(status: 400, payload: ["error": ["code": "invalid_request_error"]])), .apiRejection(statusCode: 400, code: "invalid_request_error")),
            (.failure(.offline), .transportFailure("offline"))
        ]
        for (behavior, expected) in cases {
            let transport = FakeNotesHTTPTransport(behaviors: [behavior])
            do {
                _ = try await analyze(using: makeGenerator(transport: transport), units: [unit(0)])
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? OpenAINotesBackendError, expected)
                XCTAssertFalse(error.localizedDescription.contains(apiKey))
            }
        }
    }

    func testCancellationPropagatesAsCancellation() async throws {
        let transport = FakeNotesHTTPTransport(behaviors: [.waitForCancellation])
        let generator = makeGenerator(transport: transport)
        let task = Task { try await self.analyze(using: generator, units: [self.unit(0)]) }
        while await transport.requests.isEmpty { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
