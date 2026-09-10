import XCTest
@testable import LectureRecorder

/// Dedicated sandbox/signing/embedding evidence for the T2 embedded
/// helper. Distinct from `FoundationProcessRunnerTests`/
/// `TranscriptionWorkerClientTests`: those prove protocol and lifecycle
/// correctness; this file specifically proves *placement*, *signing*, and
/// *inherited-sandbox file access* — the properties the second
/// architecture review flagged as needing direct confirmation rather than
/// inference from build settings alone.
final class EmbeddedWorkerSmokeTests: XCTestCase {

    func testHelperResolvesToARealExecutableFileInsideAppBundleMacOSDirectory() throws {
        let url = try WorkerFixtureTestSupport.resolveFixtureURLOrFail()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        XCTAssertTrue(url.path.contains("Contents/MacOS"), "Expected the helper inside Contents/MacOS, got \(url.path)")
        XCTAssertEqual(url.lastPathComponent, "LectureRecorderWorkerFixture")
    }

    func testHelperCodeSignatureCarriesExactlyTheApprovedEntitlements() throws {
        let helperURL = try WorkerFixtureTestSupport.resolveFixtureURLOrFail()
        let entitlementsXML = try runCodesignEntitlements(at: helperURL)

        XCTAssertTrue(entitlementsXML.contains("com.apple.security.app-sandbox"))
        XCTAssertTrue(entitlementsXML.contains("com.apple.security.inherit"))
        // No other entitlement keys should be present.
        let disallowedKeys = [
            "com.apple.security.network",
            "com.apple.security.device.audio-input",
            "com.apple.security.files.user-selected",
            "com.apple.security.get-task-allow",
        ]
        for key in disallowedKeys {
            XCTAssertFalse(entitlementsXML.contains(key), "Helper entitlements unexpectedly contain \(key)")
        }
    }

    func testHelperCodeSignatureTeamMatchesApp() throws {
        let helperURL = try WorkerFixtureTestSupport.resolveFixtureURLOrFail()
        let helperTeam = try runCodesignTeamIdentifier(at: helperURL)

        guard let appExecutableURL = Bundle.main.executableURL else {
            return XCTFail("Could not resolve the hosting app's own executable URL")
        }
        let appBundleURL = appExecutableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appTeam = try runCodesignTeamIdentifier(at: appBundleURL)

        XCTAssertEqual(helperTeam, appTeam)
        XCTAssertFalse(helperTeam.isEmpty)
    }

    func testHostedProcessCanLaunchEmbeddedHelperAndReceiveAValidResponse() async throws {
        let client = TranscriptionWorkerClient(processRunner: FoundationProcessRunner())
        let outcome = await client.submit(
            payload: EmptyTestPayload(),
            identity: WorkerFixtureTestSupport.makeIdentity(),
            outputType: TestFixtureOutput.self,
            arguments: ["--mode=success"],
            limits: WorkerInvocationLimits(overallTimeout: 5.0)
        )
        guard case .success = outcome else {
            return XCTFail("Expected the embedded, signed helper to launch and respond successfully from the hosted test environment; got \(outcome)")
        }
    }

    func testInheritedSandboxPermitsReadingAControlledSourceFileWithoutModifyingIt() async throws {
        let fixtureURL = try WorkerFixtureTestSupport.resolveFixtureURLOrFail()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("t2-smoke-source-\(UUID().uuidString).txt")
        let originalContent = "controlled source content, must remain unmodified"
        try Data(originalContent.utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let attributesBefore = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let modificationDateBefore = attributesBefore[.modificationDate] as? Date

        let identity = WorkerFixtureTestSupport.makeIdentity()
        let requestData = try WorkerFixtureTestSupport.encodeRequest(identity: identity)
        let request = WorkerFixtureTestSupport.makeRequest(
            executableURL: fixtureURL,
            arguments: ["--mode=read-source-file", "--source-path=\(sourceURL.path)"],
            stdin: requestData,
            overallTimeout: 5.0
        )

        let runner = FoundationProcessRunner()
        let outcome = await runner.run(request)
        guard case .success(let result) = outcome else {
            return XCTFail("Expected the helper to read the controlled source file successfully; got \(outcome)")
        }
        XCTAssertTrue(String(data: result.stdout, encoding: .utf8)?.contains("\"outcome\":\"success\"") ?? false)

        let contentAfter = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertEqual(contentAfter, originalContent, "The source file must not be modified by the worker")

        let attributesAfter = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let modificationDateAfter = attributesAfter[.modificationDate] as? Date
        XCTAssertEqual(modificationDateBefore, modificationDateAfter, "The source file's modification date must not change")
    }

    // MARK: - Helpers

    private func runCodesignEntitlements(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", "-", "--xml", url.path]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func runCodesignTeamIdentifier(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", url.path]
        let stderrPipe = Pipe() // codesign -dvvv writes its report to stderr
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        try process.run()
        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            return String(line.dropFirst("TeamIdentifier=".count))
        }
        return ""
    }
}
