import XCTest
@testable import LectureRecorder

/// Dedicated sandbox/signing/embedding evidence for the T2 embedded
/// helper. Distinct from `FoundationProcessRunnerTests`/
/// `TranscriptionWorkerClientTests`: those prove protocol and lifecycle
/// correctness; this file specifically proves *placement*, *signing*, and
/// *inherited-sandbox file access*.
///
/// Ordering matters here: `testHostedProcessExhibitsActiveAppSandboxContainerRedirection`
/// must be read as the load-bearing proof that this test process is
/// actually running under App Sandbox — without it, a positive read
/// result from `testInheritedSandboxPermitsReadingAControlledSourceFileWithoutModifyingIt`
/// alone would pass identically whether or not the hosted process were
/// sandboxed at all (reading a temp file requires no sandbox-specific
/// permission either way), so it cannot by itself distinguish "sandboxed
/// and correctly inheriting" from "not sandboxed." This deliberately does
/// NOT attempt a write outside the sandbox to prove denial — that would be
/// brittle and unnecessary; instead it uses a positive, non-brittle
/// signature of active sandbox enforcement already documented elsewhere in
/// this repository (`FileSystemLocator.swift`'s own doc comment): a
/// sandboxed process's `.applicationSupportDirectory` is silently
/// redirected by the OS into `~/Library/Containers/<bundle-id>/...`,
/// something that never happens for an unsandboxed process.
final class EmbeddedWorkerSmokeTests: XCTestCase {

    // MARK: - Sandbox positive control (must run/be read before the inheritance test below)

    func testHostedProcessExhibitsActiveAppSandboxContainerRedirection() throws {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return XCTFail("Could not resolve this process's Application Support directory")
        }
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return XCTFail("Could not resolve the hosting app's bundle identifier")
        }

        let expectedContainerFragment = "Library/Containers/\(bundleID)/Data/Library/Application Support"
        XCTAssertTrue(
            appSupportURL.path.contains(expectedContainerFragment),
            """
            Expected the hosted test process's Application Support directory to be \
            sandbox-redirected to contain "\(expectedContainerFragment)", but got \
            "\(appSupportURL.path)". This process does not appear to be running under \
            active App Sandbox enforcement — if so, the read-only inherited-access test \
            below is NOT valid evidence of sandbox inheritance and must not be treated \
            as such.
            """
        )
    }

    // MARK: - Placement

    func testHelperResolvesToARealExecutableFileInsideAppBundleMacOSDirectory() throws {
        let url = try WorkerFixtureTestSupport.resolveFixtureURLOrFail()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        XCTAssertTrue(url.path.contains("Contents/MacOS"), "Expected the helper inside Contents/MacOS, got \(url.path)")
        XCTAssertEqual(url.lastPathComponent, "LectureRecorderWorkerFixture")
        try MachOHeaderValidator.validateThinArm64Executable(
            Data(contentsOf: url, options: .mappedIfSafe)
        )
    }

    // MARK: - Signing: exact entitlement set

    func testHelperCodeSignatureCarriesExactlyTheApprovedEntitlements() throws {
        let helperURL = try WorkerFixtureTestSupport.resolveFixtureURLOrFail()
        try WorkerEntitlementTestSupport.requireLaunchableSignature(at: helperURL)
    }

    // MARK: - Signing: identifier and team

    func testHelperCodeSignatureIdentifierAndTeamAreExact() throws {
        let helperURL = try WorkerFixtureTestSupport.resolveFixtureURLOrFail()
        let helperInfo = try readCodesignInfo(at: helperURL)

        XCTAssertEqual(helperInfo.identifier, "LectureRecorderWorkerFixture")
        XCTAssertFalse(helperInfo.teamIdentifier.isEmpty)

        guard let appExecutableURL = Bundle.main.executableURL else {
            return XCTFail("Could not resolve the hosting app's own executable URL")
        }
        let appBundleURL = appExecutableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appInfo = try readCodesignInfo(at: appBundleURL)

        XCTAssertEqual(helperInfo.teamIdentifier, appInfo.teamIdentifier)
    }

    // MARK: - Launch and inherited access (valid only given the positive control above)

    func testHostedProcessCanLaunchEmbeddedHelperAndReceiveAValidResponse() async throws {
        try WorkerEntitlementTestSupport.requireLaunchableSignature(
            at: WorkerFixtureTestSupport.resolveFixtureURLOrFail()
        )
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
        try WorkerEntitlementTestSupport.requireLaunchableSignature(at: fixtureURL)
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

    private struct CodesignInfo {
        var identifier: String
        var teamIdentifier: String
    }

    /// Runs `codesign -dvvv`, checks its exit status, and parses out both
    /// `Identifier=` and `TeamIdentifier=` from its diagnostic (stderr)
    /// output.
    private func readCodesignInfo(at url: URL) throws -> CodesignInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", url.path]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe() // codesign -dvvv writes its report to stderr
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let diagnostics = String(data: errorData, encoding: .utf8) ?? "<no diagnostics>"
            XCTFail("codesign -dvvv exited \(process.terminationStatus) for \(url.path): \(diagnostics)")
            return CodesignInfo(identifier: "", teamIdentifier: "")
        }

        let text = String(data: errorData, encoding: .utf8) ?? ""
        var identifier = ""
        var teamIdentifier = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Identifier=") {
                identifier = String(line.dropFirst("Identifier=".count))
            } else if line.hasPrefix("TeamIdentifier=") {
                teamIdentifier = String(line.dropFirst("TeamIdentifier=".count))
            }
        }

        if identifier.isEmpty || teamIdentifier.isEmpty {
            XCTFail("Could not parse Identifier/TeamIdentifier from codesign -dvvv output for \(url.path): \(text)\n\(String(data: outputData, encoding: .utf8) ?? "")")
        }

        return CodesignInfo(identifier: identifier, teamIdentifier: teamIdentifier)
    }
}
