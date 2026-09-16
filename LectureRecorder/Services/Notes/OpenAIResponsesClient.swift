import Foundation

nonisolated enum OpenAINotesBackendError: LocalizedError, Sendable, Equatable {
    case configuration(OpenAINotesConfigurationError)
    case authenticationFailure
    case rateLimited(retryAfterSeconds: Int?)
    case transportFailure(String)
    case apiRejection(statusCode: Int, code: String?)
    case malformedProviderResponse
    case malformedStructuredResponse
    case missingExpectedPayload
    case unsupportedProviderResponse(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .configuration(let error):
            return error.localizedDescription
        case .authenticationFailure:
            return "OpenAI rejected the Notes API credential."
        case .rateLimited(let seconds):
            if let seconds { return "OpenAI rate-limited Notes generation; retry after approximately \(seconds) seconds." }
            return "OpenAI rate-limited Notes generation."
        case .transportFailure(let detail):
            return "The OpenAI Notes request failed in transport: \(detail)"
        case .apiRejection(let statusCode, let code):
            if let code { return "OpenAI rejected the Notes request (HTTP \(statusCode), code \(code))." }
            return "OpenAI rejected the Notes request (HTTP \(statusCode))."
        case .malformedProviderResponse:
            return "OpenAI returned a malformed Responses API envelope."
        case .malformedStructuredResponse:
            return "OpenAI returned Notes structured output that could not be decoded exactly."
        case .missingExpectedPayload:
            return "OpenAI returned no expected structured Notes payload."
        case .unsupportedProviderResponse(let reason):
            return "OpenAI returned an unsupported Notes response: \(reason)"
        case .refused:
            return "OpenAI refused the Notes generation request."
        }
    }
}

/// Minimal non-streaming OpenAI Responses API client. It intentionally knows
/// nothing about Notes domain models; callers provide the prompt, input JSON,
/// and strict response schema and receive only the structured response bytes.
nonisolated struct OpenAIResponsesClient: Sendable {
    private let configurationSource: OpenAINotesConfigurationSource
    private let transport: any NotesHTTPTransport

    init(configurationSource: OpenAINotesConfigurationSource, transport: any NotesHTTPTransport) {
        self.configurationSource = configurationSource
        self.transport = transport
    }

    func createStructuredResponse(
        instructions: String,
        input: String,
        schemaName: String,
        schema: [String: Any],
        generationModel: String
    ) async throws -> Data {
        let configuration: OpenAINotesConfiguration
        do {
            configuration = try configurationSource.resolve()
        } catch let error as OpenAINotesConfigurationError {
            throw OpenAINotesBackendError.configuration(error)
        }

        let body: [String: Any] = [
            // The immutable generation record, not current app defaults,
            // selects the model for Generate/Continue/Retry alike.
            "model": generationModel,
            "instructions": instructions,
            "input": input,
            "store": false,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": schemaName,
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
        let encodedBody: Data
        do {
            encodedBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            throw OpenAINotesBackendError.unsupportedProviderResponse("request schema could not be encoded")
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = encodedBody

        let response: NotesHTTPResponse
        do {
            try Task.checkCancellation()
            response = try await transport.send(request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OpenAINotesBackendError.transportFailure(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPError(response)
        }
        return try extractStructuredPayload(from: response.body)
    }

    private func mapHTTPError(_ response: NotesHTTPResponse) -> OpenAINotesBackendError {
        if response.statusCode == 401 { return .authenticationFailure }
        if response.statusCode == 429 {
            let seconds = response.headerValue(named: "Retry-After").flatMap(Int.init)
            return .rateLimited(retryAfterSeconds: seconds)
        }
        let code = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: response.body))?.error?.code
        return .apiRejection(statusCode: response.statusCode, code: code)
    }

    private func extractStructuredPayload(from data: Data) throws -> Data {
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw OpenAINotesBackendError.malformedProviderResponse
        }

        if let error = envelope.error {
            throw OpenAINotesBackendError.apiRejection(statusCode: 200, code: error.code)
        }
        guard envelope.status == "completed" else {
            if envelope.status == "incomplete" {
                throw OpenAINotesBackendError.unsupportedProviderResponse(
                    "response was incomplete\(envelope.incompleteDetails?.reason.map { " (\($0))" } ?? "")"
                )
            }
            throw OpenAINotesBackendError.unsupportedProviderResponse("response status was \(envelope.status ?? "missing")")
        }

        let content = envelope.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
        if content.contains(where: { $0.type == "refusal" }) {
            throw OpenAINotesBackendError.refused
        }
        let outputTexts = content.compactMap { item -> String? in
            guard item.type == "output_text" else { return nil }
            return item.text
        }
        guard outputTexts.count == 1, let text = outputTexts.first, !text.isEmpty else {
            throw OpenAINotesBackendError.missingExpectedPayload
        }
        guard let payload = text.data(using: .utf8) else {
            throw OpenAINotesBackendError.malformedStructuredResponse
        }
        return payload
    }
}

private nonisolated struct APIErrorEnvelope: Decodable {
    var error: APIError?
}

private nonisolated struct APIError: Decodable {
    var code: String?
}

private nonisolated struct ResponseEnvelope: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status, error, output
        case incompleteDetails = "incomplete_details"
    }

    var status: String?
    var error: APIError?
    var incompleteDetails: IncompleteDetails?
    var output: [OutputItem]
}

private nonisolated struct IncompleteDetails: Decodable {
    var reason: String?
}

private nonisolated struct OutputItem: Decodable {
    var type: String
    var content: [OutputContent]?
}

private nonisolated struct OutputContent: Decodable {
    var type: String
    var text: String?
}
