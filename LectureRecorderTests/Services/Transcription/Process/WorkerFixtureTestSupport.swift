import Foundation
import XCTest
@testable import LectureRecorder

/// A trivial, empty request payload for tests that only care about the
/// stable envelope identity fields, not any fixture-specific content.
struct EmptyTestPayload: Codable, Sendable {}

/// A trivial output type matching the fixture's `FixtureOutput` shape
/// field-for-field (independently declared here, exactly as the fixture's
/// own mirror is independently declared from the app's — see
/// `WorkerProtocol.swift`'s header comment).
struct TestFixtureOutput: Codable, Sendable, Equatable {
    var text: String
}

enum WorkerFixtureTestSupport {
    /// Resolves the real, embedded, signed helper via the same trusted
    /// locator production code uses. Every test that calls this exercises
    /// genuine embedded-helper launch from the hosted XCTest environment
    /// (`LectureRecorderTests` is injected into `LectureRecorder.app` via
    /// `TEST_HOST`, so `Bundle.main` here resolves to the real app bundle).
    static func resolveFixtureURLOrFail(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        switch EmbeddedWorkerLocator.resolve() {
        case .success(let url):
            return url
        case .failure(let error):
            XCTFail("Embedded worker fixture did not resolve: \(error)", file: file, line: line)
            throw error
        }
    }

    static func makeIdentity(
        requestID: UUID = UUID(),
        attemptID: UUID = UUID(),
        sessionID: UUID = UUID(),
        chunkSequenceNumber: Int = 0,
        sourceIdentity: String = "test-source"
    ) -> WorkerRequestIdentity {
        WorkerRequestIdentity(
            requestID: requestID,
            attemptID: attemptID,
            sessionID: sessionID,
            chunkSequenceNumber: chunkSequenceNumber,
            sourceIdentity: sourceIdentity
        )
    }

    static func encodeRequest(identity: WorkerRequestIdentity) throws -> Data {
        let envelope = WorkerRequestEnvelope(
            schemaVersion: WorkerProtocolConstants.currentSchemaVersion,
            requestID: identity.requestID,
            attemptID: identity.attemptID,
            sessionID: identity.sessionID,
            chunkSequenceNumber: identity.chunkSequenceNumber,
            sourceIdentity: identity.sourceIdentity,
            payload: EmptyTestPayload()
        )
        return try JSONEncoder().encode(envelope)
    }

    static func makeRequest(
        executableURL: URL,
        arguments: [String],
        stdin: Data,
        maximumStdinBytes: Int = 1 * 1024 * 1024,
        maximumStdoutBytes: Int = 8 * 1024 * 1024,
        maximumStderrBytes: Int = 1 * 1024 * 1024,
        overallTimeout: TimeInterval = 5.0,
        gracePeriod: TimeInterval = 0.5
    ) -> ProcessInvocationRequest {
        ProcessInvocationRequest(
            executableURL: executableURL,
            arguments: arguments,
            stdin: stdin,
            environmentPolicy: .empty,
            workingDirectoryURL: nil,
            maximumStdinBytes: maximumStdinBytes,
            maximumStdoutBytes: maximumStdoutBytes,
            maximumStderrBytes: maximumStderrBytes,
            overallTimeout: overallTimeout,
            gracePeriod: gracePeriod
        )
    }
}
