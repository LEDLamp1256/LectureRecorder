import XCTest
@testable import LectureRecorder

final class OpenAINotesConfigurationTests: XCTestCase {
    func testInvalidModelAndEndpointAreRejected() {
        XCTAssertThrowsError(try OpenAINotesConfiguration(apiKey: "key", model: "")) { error in
            XCTAssertEqual(error as? OpenAINotesConfigurationError, .invalidModel)
        }
        XCTAssertThrowsError(
            try OpenAINotesConfiguration(apiKey: "key", endpoint: URL(string: "http://api.openai.com/v1/responses")!)
        ) { error in
            XCTAssertEqual(error as? OpenAINotesConfigurationError, .invalidEndpoint)
        }
    }

    func testProvenanceContainsProviderAndModelButNeverCredential() throws {
        let secret = "a-secret-that-must-not-be-persisted"
        let source = OpenAINotesConfigurationSource { _ in secret }
        let configuration = try source.resolve()
        XCTAssertEqual(configuration.apiKey, secret)
        XCTAssertEqual(source.generationProvenance.generatorIdentifier, "openai-responses-api")
        XCTAssertEqual(source.generationProvenance.generatorVersion, "gpt-5.6-sol")
        XCTAssertEqual(source.generationProvenance.backendIdentifier, "openai")
        let encoded = try JSONEncoder().encode(source.generationProvenance)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))
    }
}
