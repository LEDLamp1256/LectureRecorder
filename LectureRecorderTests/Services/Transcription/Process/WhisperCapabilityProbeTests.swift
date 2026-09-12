import Foundation
import XCTest
@testable import LectureRecorder

final class WhisperCapabilityProbeTests: XCTestCase {
    private struct FixedResultRunner: LocalProcessRunning {
        let result: Result<ProcessRunResult, ProcessRunFailure>

        func run(_ request: ProcessInvocationRequest) async -> Result<ProcessRunResult, ProcessRunFailure> {
            result
        }
    }

    private struct SelectedPathRunner: LocalProcessRunning {
        func run(_ request: ProcessInvocationRequest) async -> Result<ProcessRunResult, ProcessRunFailure> {
            .failure(.launchFailed(underlying: request.executableURL.lastPathComponent))
        }
    }

    func testTrustedDescriptorsAreClosedAndOwnBothFixedIdentityValues() {
        XCTAssertEqual(TrustedWorkerDescriptor.allCases, [.fixture, .whisper])
        XCTAssertEqual(TrustedWorkerDescriptor.fixture.fileName, "LectureRecorderWorkerFixture")
        XCTAssertEqual(TrustedWorkerDescriptor.fixture.expectedWorkerIdentifier, "LectureRecorderWorkerFixture")
        XCTAssertEqual(TrustedWorkerDescriptor.whisper.fileName, "LectureRecorderWhisperWorker")
        XCTAssertEqual(TrustedWorkerDescriptor.whisper.expectedWorkerIdentifier, "LectureRecorderWhisperWorker")
        XCTAssertEqual(TrustedWorkerDescriptor.fixture.expectedWorkerVersion, "1.0")
        XCTAssertEqual(TrustedWorkerDescriptor.whisper.expectedWorkerVersion, "1.0.0")
        XCTAssertTrue(TrustedWorkerDescriptor.fixture.permitsCommandLineArguments)
        XCTAssertFalse(TrustedWorkerDescriptor.whisper.permitsCommandLineArguments)
    }

    func testWhisperDescriptorRejectsCommandLineArgumentsBeforeRunning() async {
        let client = TranscriptionWorkerClient(processRunner: SelectedPathRunner(), workerDescriptor: .whisper)
        let outcome: WorkerInvocationOutcome<WhisperCapabilityProbeOutput> = await client.submit(
            payload: WhisperCapabilityProbePayload(),
            identity: WorkerFixtureTestSupport.makeIdentity(),
            outputType: WhisperCapabilityProbeOutput.self,
            arguments: ["--model=/caller/controlled.bin"],
            limits: WorkerInvocationLimits(overallTimeout: 1.0)
        )
        guard case .infrastructureFailure(.commandLineArgumentsNotPermitted) = outcome else {
            return XCTFail("Expected command-line arguments to be rejected, got \(outcome)")
        }
    }

    func testEachDescriptorSelectsOnlyItsOwnedExecutablePath() async {
        for descriptor in TrustedWorkerDescriptor.allCases {
            let client = TranscriptionWorkerClient(processRunner: SelectedPathRunner(), workerDescriptor: descriptor)
            let outcome: WorkerInvocationOutcome<WhisperCapabilityProbeOutput> = await client.submit(
                payload: WhisperCapabilityProbePayload(),
                identity: WorkerFixtureTestSupport.makeIdentity(),
                outputType: WhisperCapabilityProbeOutput.self,
                limits: WorkerInvocationLimits(overallTimeout: 1.0)
            )
            guard case .infrastructureFailure(.process(.launchFailed(let selectedFileName))) = outcome else {
                return XCTFail("Expected selected helper path to reach the runner, got \(outcome)")
            }
            XCTAssertEqual(selectedFileName, descriptor.fileName)
        }
    }

    func testCapabilityPayloadIsClosedAndVersioned() throws {
        let encoded = try JSONEncoder().encode(WhisperCapabilityProbePayload())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "operation"])
        XCTAssertEqual(object["schemaVersion"] as? Int, WhisperCapabilityProbeConstants.currentSchemaVersion)
        XCTAssertEqual(object["operation"] as? String, "capabilityProbe")

        XCTAssertThrowsError(try JSONDecoder().decode(
            WhisperCapabilityProbePayload.self,
            from: Data(#"{"schemaVersion":2,"operation":"capabilityProbe"}"#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            WhisperCapabilityProbePayload.self,
            from: Data(#"{"schemaVersion":1,"operation":"transcribe"}"#.utf8)
        ))
    }

    func testCapabilityOutputRejectsUnsupportedVersionAndEmptyUpstreamVersion() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            WhisperCapabilityProbeOutput.self,
            from: Data(#"{"schemaVersion":2,"upstreamVersion":"1.9.2"}"#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            WhisperCapabilityProbeOutput.self,
            from: Data(#"{"schemaVersion":1,"upstreamVersion":""}"#.utf8)
        ))
    }

    func testMalformedProductionResponseIsRejectedByT2Validation() async {
        let runner = FixedResultRunner(result: .success(ProcessRunResult(
            stdout: Data("not-json".utf8),
            stderr: Data(),
            stderrTruncated: false,
            terminationReason: .exited(status: 0)
        )))
        let client = TranscriptionWorkerClient(processRunner: runner, workerDescriptor: .whisper)
        let outcome: WorkerInvocationOutcome<WhisperCapabilityProbeOutput> = await client.submit(
            payload: WhisperCapabilityProbePayload(),
            identity: WorkerFixtureTestSupport.makeIdentity(),
            outputType: WhisperCapabilityProbeOutput.self,
            limits: WorkerInvocationLimits(overallTimeout: 1.0)
        )
        guard case .infrastructureFailure(.malformedResponse) = outcome else {
            return XCTFail("Expected malformed response rejection, got \(outcome)")
        }
    }

    func testIdentityMismatchedProductionResponseIsRejectedByT2Validation() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        let response = WorkerResponseEnvelope(
            schemaVersion: WorkerProtocolConstants.currentSchemaVersion,
            requestID: UUID(),
            attemptID: identity.attemptID,
            sessionID: identity.sessionID,
            chunkSequenceNumber: identity.chunkSequenceNumber,
            sourceIdentity: identity.sourceIdentity,
            workerIdentifier: WhisperCapabilityProbeConstants.workerIdentifier,
            workerVersion: WhisperCapabilityProbeConstants.workerImplementationVersion,
            outcome: WorkerOutcome.success,
            output: WhisperCapabilityProbeOutput(upstreamVersion: "1.9.2"),
            failure: nil
        )
        let runner = FixedResultRunner(result: .success(ProcessRunResult(
            stdout: try JSONEncoder().encode(response),
            stderr: Data(),
            stderrTruncated: false,
            terminationReason: .exited(status: 0)
        )))
        let client = TranscriptionWorkerClient(processRunner: runner, workerDescriptor: .whisper)
        let outcome: WorkerInvocationOutcome<WhisperCapabilityProbeOutput> = await client.submit(
            payload: WhisperCapabilityProbePayload(),
            identity: identity,
            outputType: WhisperCapabilityProbeOutput.self,
            limits: WorkerInvocationLimits(overallTimeout: 1.0)
        )
        guard case .infrastructureFailure(.identityMismatch(let field)) = outcome else {
            return XCTFail("Expected identity mismatch rejection, got \(outcome)")
        }
        XCTAssertEqual(field, "requestID")
    }

    func testProductionWorkerVersionMismatchAndEmptyVersionAreRejected() async throws {
        let identity = WorkerFixtureTestSupport.makeIdentity()
        for version in ["", "9.9.9"] {
            let response = WorkerResponseEnvelope(
                schemaVersion: WorkerProtocolConstants.currentSchemaVersion,
                requestID: identity.requestID,
                attemptID: identity.attemptID,
                sessionID: identity.sessionID,
                chunkSequenceNumber: identity.chunkSequenceNumber,
                sourceIdentity: identity.sourceIdentity,
                workerIdentifier: WhisperCapabilityProbeConstants.workerIdentifier,
                workerVersion: version,
                outcome: WorkerOutcome.success,
                output: WhisperCapabilityProbeOutput(upstreamVersion: "1.9.2"),
                failure: nil
            )
            let runner = FixedResultRunner(result: .success(ProcessRunResult(
                stdout: try JSONEncoder().encode(response),
                stderr: Data(),
                stderrTruncated: false,
                terminationReason: .exited(status: 0)
            )))
            let outcome: WorkerInvocationOutcome<WhisperCapabilityProbeOutput> = await TranscriptionWorkerClient(
                processRunner: runner,
                workerDescriptor: .whisper
            ).submit(
                payload: WhisperCapabilityProbePayload(),
                identity: identity,
                outputType: WhisperCapabilityProbeOutput.self,
                limits: WorkerInvocationLimits(overallTimeout: 1.0)
            )
            guard case .infrastructureFailure(.unexpectedWorkerVersion(let expected, let actual)) = outcome else {
                return XCTFail("Expected worker-version rejection, got \(outcome)")
            }
            XCTAssertEqual(expected, WhisperCapabilityProbeConstants.workerImplementationVersion)
            XCTAssertEqual(actual, version)
        }
    }
}
