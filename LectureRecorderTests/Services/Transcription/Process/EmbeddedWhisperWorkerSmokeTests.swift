import Foundation
import XCTest
@testable import LectureRecorder

final class EmbeddedWhisperWorkerSmokeTests: XCTestCase {
    private struct CodesignInfo {
        let identifier: String
        let teamIdentifier: String
    }

    private func resolveWhisperWorker() throws -> URL {
        switch EmbeddedWorkerLocator.resolve(descriptor: .whisper) {
        case .success(let url):
            return url
        case .failure(let error):
            XCTFail("Production Whisper helper did not resolve: \(error)")
            throw error
        }
    }

    func testProductionHelperIsEmbeddedAsARegularArm64Executable() throws {
        let helper = try resolveWhisperWorker()
        let executableDirectory = try XCTUnwrap(Bundle.main.executableURL?.deletingLastPathComponent())
        XCTAssertEqual(helper.deletingLastPathComponent().standardizedFileURL, executableDirectory.standardizedFileURL)
        XCTAssertEqual(helper.lastPathComponent, "LectureRecorderWhisperWorker")

        let values = try helper.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertNotEqual(values.isSymbolicLink, true)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))

        try assertThinArm64MachO(at: helper)
    }

    func testProductionHelperCarriesExactlyInheritedSandboxEntitlements() throws {
        let helper = try resolveWhisperWorker()
        try WorkerEntitlementTestSupport.requireLaunchableSignature(at: helper)
    }

    func testProductionHelperIdentifierAndTeamMatchApprovedHostBoundary() throws {
        let helperInfo = try readCodesignInfo(at: resolveWhisperWorker())
        XCTAssertEqual(helperInfo.identifier, WhisperCapabilityProbeConstants.workerIdentifier)
        XCTAssertFalse(helperInfo.teamIdentifier.isEmpty)

        let hostExecutable = try XCTUnwrap(Bundle.main.executableURL)
        let hostBundle = hostExecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let hostInfo = try readCodesignInfo(at: hostBundle)
        XCTAssertEqual(helperInfo.teamIdentifier, hostInfo.teamIdentifier)
    }

    func testHostedClientLaunchesProductionHelperAndReceivesNativeWhisperVersion() async throws {
        try WorkerEntitlementTestSupport.requireLaunchableSignature(at: resolveWhisperWorker())
        let client = TranscriptionWorkerClient(
            processRunner: FoundationProcessRunner(pollInterval: 0.01),
            workerDescriptor: .whisper
        )
        let outcome: WorkerInvocationOutcome<WhisperCapabilityProbeOutput> = await client.submit(
            payload: WhisperCapabilityProbePayload(),
            identity: WorkerFixtureTestSupport.makeIdentity(sourceIdentity: "t3a-capability-probe"),
            outputType: WhisperCapabilityProbeOutput.self,
            limits: WorkerInvocationLimits(overallTimeout: 5.0)
        )
        guard case .success(let output) = outcome else {
            return XCTFail("Expected native capability-probe success, got \(outcome)")
        }
        XCTAssertEqual(output.schemaVersion, WhisperCapabilityProbeConstants.currentSchemaVersion)
        XCTAssertEqual(output.upstreamVersion, "1.9.2")
    }

    func testRawProductionResponseDeclaresStableImplementationVersion() async throws {
        try WorkerEntitlementTestSupport.requireLaunchableSignature(at: resolveWhisperWorker())
        let identity = WorkerFixtureTestSupport.makeIdentity(sourceIdentity: "t3a-version-proof")
        let request = WorkerRequestEnvelope(
            schemaVersion: WorkerProtocolConstants.currentSchemaVersion,
            requestID: identity.requestID,
            attemptID: identity.attemptID,
            sessionID: identity.sessionID,
            chunkSequenceNumber: identity.chunkSequenceNumber,
            sourceIdentity: identity.sourceIdentity,
            payload: WhisperCapabilityProbePayload()
        )
        let invocation = ProcessInvocationRequest(
            executableURL: try resolveWhisperWorker(),
            stdin: try JSONEncoder().encode(request),
            environmentPolicy: .empty,
            maximumStdinBytes: 1 * 1024 * 1024,
            maximumStdoutBytes: 1 * 1024 * 1024,
            maximumStderrBytes: 64 * 1024,
            overallTimeout: 5.0,
            gracePeriod: 0.5
        )
        let result = await FoundationProcessRunner(pollInterval: 0.01).run(invocation)
        guard case .success(let processResult) = result else {
            return XCTFail("Expected raw helper launch success, got \(result)")
        }
        XCTAssertEqual(processResult.terminationReason, .exited(status: 0))
        let response = try JSONDecoder().decode(WorkerResponseEnvelope<WhisperCapabilityProbeOutput>.self, from: processResult.stdout)
        XCTAssertEqual(response.workerIdentifier, WhisperCapabilityProbeConstants.workerIdentifier)
        XCTAssertEqual(response.workerVersion, WhisperCapabilityProbeConstants.workerImplementationVersion)
        XCTAssertEqual(response.output?.upstreamVersion, "1.9.2")
    }

    private func readCodesignInfo(at url: URL) throws -> CodesignInfo {
        let report = try runTool("/usr/bin/codesign", arguments: ["-dvvv", url.path], captureStandardError: true)
        var identifier = ""
        var teamIdentifier = ""
        for line in report.split(separator: "\n") {
            if line.hasPrefix("Identifier=") {
                identifier = String(line.dropFirst("Identifier=".count))
            } else if line.hasPrefix("TeamIdentifier=") {
                teamIdentifier = String(line.dropFirst("TeamIdentifier=".count))
            }
        }
        XCTAssertFalse(identifier.isEmpty, "Missing codesign identifier in: \(report)")
        XCTAssertFalse(teamIdentifier.isEmpty, "Missing codesign team identifier in: \(report)")
        return CodesignInfo(identifier: identifier, teamIdentifier: teamIdentifier)
    }

    private func assertThinArm64MachO(at url: URL) throws {
        try MachOHeaderValidator.validateThinArm64Executable(
            Data(contentsOf: url, options: .mappedIfSafe)
        )
    }

    private func runTool(
        _ executablePath: String,
        arguments: [String],
        captureStandardError: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let diagnostic = String(decoding: stderrData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "\(executablePath) failed: \(diagnostic)")
        return String(decoding: captureStandardError ? stderrData : stdoutData, as: UTF8.self)
    }
}
