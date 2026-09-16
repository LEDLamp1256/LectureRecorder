import Foundation

nonisolated enum OpenAINotesConfigurationError: LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidModel
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI Notes configuration is unavailable because OPENAI_API_KEY is missing or empty."
        case .invalidModel:
            return "OpenAI Notes configuration contains an invalid model identifier."
        case .invalidEndpoint:
            return "OpenAI Notes configuration contains an invalid HTTPS endpoint."
        }
    }
}

/// Resolved request configuration. The API key exists only in memory and is
/// never copied into generation provenance or Notes artifacts.
nonisolated struct OpenAINotesConfiguration: Sendable, Equatable {
    static let productionModel = "gpt-5.6-sol"
    static let responsesEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let recipeVersion = "t5c-openai-notes-v1"
    static let generatorIdentifier = "openai-responses-api"
    static let backendIdentifier = "openai"

    let apiKey: String
    let model: String
    let endpoint: URL

    init(apiKey: String, model: String = Self.productionModel, endpoint: URL = Self.responsesEndpoint) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAINotesConfigurationError.missingAPIKey }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAINotesConfigurationError.invalidModel
        }
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw OpenAINotesConfigurationError.invalidEndpoint
        }
        self.apiKey = trimmedKey
        self.model = model
        self.endpoint = endpoint
    }
}

/// Lazily resolves the development credential for each explicitly admitted
/// operation. Constructing the app never reads, stores, or validates a key.
nonisolated struct OpenAINotesConfigurationSource: Sendable {
    private let valueForEnvironmentKey: @Sendable (String) -> String?
    let model: String
    let endpoint: URL

    init(
        model: String = OpenAINotesConfiguration.productionModel,
        endpoint: URL = OpenAINotesConfiguration.responsesEndpoint,
        valueForEnvironmentKey: @escaping @Sendable (String) -> String?
    ) {
        self.model = model
        self.endpoint = endpoint
        self.valueForEnvironmentKey = valueForEnvironmentKey
    }

    static func processEnvironment(
        model: String = OpenAINotesConfiguration.productionModel,
        endpoint: URL = OpenAINotesConfiguration.responsesEndpoint
    ) -> OpenAINotesConfigurationSource {
        OpenAINotesConfigurationSource(model: model, endpoint: endpoint) { key in
            ProcessInfo.processInfo.environment[key]
        }
    }

    func resolve() throws -> OpenAINotesConfiguration {
        guard let apiKey = valueForEnvironmentKey("OPENAI_API_KEY") else {
            throw OpenAINotesConfigurationError.missingAPIKey
        }
        return try OpenAINotesConfiguration(apiKey: apiKey, model: model, endpoint: endpoint)
    }

    var generationProvenance: LectureNotesGenerationProvenance {
        LectureNotesGenerationProvenance(
            recipeVersion: OpenAINotesConfiguration.recipeVersion,
            generatorIdentifier: OpenAINotesConfiguration.generatorIdentifier,
            generatorVersion: model,
            backendIdentifier: OpenAINotesConfiguration.backendIdentifier
        )
    }
}
