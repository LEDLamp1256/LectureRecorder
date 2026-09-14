import Darwin
import CryptoKit
import Foundation

private struct HarnessFixturePayload: Codable, Sendable {}

private struct HarnessFixtureOutput: Codable, Sendable, Equatable {
    let text: String
}

private enum HarnessMode: String {
    case fixture
    case fixtureRead = "fixture-read"
    case whisper
    case processSuite = "process-suite"
    case acceptanceModelPath = "acceptance-model-path"
    case realInference = "real-inference"
}

private final class HarnessTimingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WhisperInferenceTiming?
    func set(_ timing: WhisperInferenceTiming) { lock.withLock { stored = timing } }
    func get() -> WhisperInferenceTiming? { lock.withLock { stored } }
}

private struct RealInferenceReport: Codable {
    let sessionID: UUID
    let transcript: String
    let segments: [TranscriptionTimingSegment]
    let provenance: TranscriptionProvenance
    let persistedSchemaVersion: Int
    let modelInitializationMilliseconds: Int64
    let audioConversionMilliseconds: Int64
    let inferenceMilliseconds: Int64
    let totalMilliseconds: Int64
    let sourceByteCount: Int
    let sourceSHA256Before: String
    let sourceSHA256After: String
    let sourceModificationDateUnchanged: Bool
    let modelPath: String
}

private enum HarnessFailure: LocalizedError {
    case usage
    case fixtureProbe(WorkerInvocationOutcome<HarnessFixtureOutput>)
    case fixtureRead(WorkerInvocationOutcome<HarnessFixtureOutput>)
    case unexpectedFixtureRead(String)
    case sourceChanged
    case whisperProbe(WorkerInvocationOutcome<WhisperCapabilityProbeOutput>)
    case emptyWhisperVersion
    case processScenario(name: String, detail: String)
    case realInference(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: LectureRecorderWorkerLaunchHarness fixture|fixture-read|whisper|process-suite|acceptance-model-path|real-inference"
        case .fixtureProbe(let outcome):
            return "Fixture probe failed: \(outcome)"
        case .fixtureRead(let outcome):
            return "Fixture inherited-sandbox read failed: \(outcome)"
        case .unexpectedFixtureRead(let output):
            return "Fixture returned unexpected file-read output: \(output)"
        case .sourceChanged:
            return "Fixture source file changed during the inherited-sandbox read proof."
        case .whisperProbe(let outcome):
            return "Whisper capability probe failed: \(outcome)"
        case .emptyWhisperVersion:
            return "whisper_version() returned an empty upstream version."
        case .processScenario(let name, let detail):
            return "Process scenario '\(name)' failed: \(detail)"
        case .realInference(let detail):
            return "Real-inference acceptance failed: \(detail)"
        }
    }
}

@main
private enum LectureRecorderWorkerLaunchHarness {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2,
                  let mode = HarnessMode(rawValue: CommandLine.arguments[1]) else {
                throw HarnessFailure.usage
            }

            switch mode {
            case .fixture:
                try await runFixtureProbe()
            case .fixtureRead:
                try await runFixtureReadProof()
            case .whisper:
                try await runWhisperProbe()
            case .processSuite:
                try await runProcessSuite()
            case .acceptanceModelPath:
                print(try harnessModelURL().path)
            case .realInference:
                try await runRealInference()
            }
        } catch {
            let diagnostic = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            FileHandle.standardError.write(Data(diagnostic.prefix(4096).utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func identity(sourceIdentity: String) -> WorkerRequestIdentity {
        WorkerRequestIdentity(
            requestID: UUID(),
            attemptID: UUID(),
            sessionID: UUID(),
            chunkSequenceNumber: 0,
            sourceIdentity: sourceIdentity
        )
    }

    private static func runFixtureProbe() async throws {
        let outcome: WorkerInvocationOutcome<HarnessFixtureOutput> = await TranscriptionWorkerClient().submit(
            payload: HarnessFixturePayload(),
            identity: identity(sourceIdentity: "t3a-harness-fixture"),
            outputType: HarnessFixtureOutput.self,
            arguments: ["--mode=success"],
            limits: WorkerInvocationLimits(overallTimeout: 5.0)
        )
        guard case .success(let output) = outcome else {
            throw HarnessFailure.fixtureProbe(outcome)
        }
        guard output.text == "fixture transcript" else {
            throw HarnessFailure.fixtureProbe(outcome)
        }
        print("fixture probe: \(output.text)")
    }

    private static func runFixtureReadProof() async throws {
        let fileManager = FileManager.default
        let sourceURL = fileManager.temporaryDirectory
            .appendingPathComponent("t3a-harness-source-\(UUID().uuidString).txt")
        let original = Data("controlled inherited-sandbox source".utf8)
        try original.write(to: sourceURL, options: .atomic)
        defer { try? fileManager.removeItem(at: sourceURL) }

        let attributesBefore = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let outcome: WorkerInvocationOutcome<HarnessFixtureOutput> = await TranscriptionWorkerClient().submit(
            payload: HarnessFixturePayload(),
            identity: identity(sourceIdentity: "t3a-harness-fixture-read"),
            outputType: HarnessFixtureOutput.self,
            arguments: ["--mode=read-source-file", "--source-path=\(sourceURL.path)"],
            limits: WorkerInvocationLimits(overallTimeout: 5.0)
        )
        guard case .success(let output) = outcome else {
            throw HarnessFailure.fixtureRead(outcome)
        }
        guard output.text == "read \(original.count) bytes" else {
            throw HarnessFailure.unexpectedFixtureRead(output.text)
        }

        let contentAfter = try Data(contentsOf: sourceURL)
        let attributesAfter = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard contentAfter == original,
              attributesBefore[.modificationDate] as? Date == attributesAfter[.modificationDate] as? Date else {
            throw HarnessFailure.sourceChanged
        }
        print("fixture inherited read: \(output.text); source unchanged")
    }

    private static func runWhisperProbe() async throws {
        let outcome: WorkerInvocationOutcome<WhisperCapabilityProbeOutput> = await TranscriptionWorkerClient(
            workerDescriptor: .whisper
        ).submit(
            payload: WhisperCapabilityProbePayload(),
            identity: identity(sourceIdentity: "t3a-harness-whisper"),
            outputType: WhisperCapabilityProbeOutput.self,
            limits: WorkerInvocationLimits(overallTimeout: 5.0)
        )
        guard case .success(let output) = outcome else {
            throw HarnessFailure.whisperProbe(outcome)
        }
        guard !output.upstreamVersion.isEmpty else {
            throw HarnessFailure.emptyWhisperVersion
        }
        print("whisper capability: \(output.upstreamVersion)")
    }

    private static func runRealInference() async throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw HarnessFailure.realInference("The normally signed harness executable path was unavailable.")
        }
        let fixtureURL = executableURL.deletingLastPathComponent()
            .appendingPathComponent("T3BFixtures/technical-speech-44100-mono.caf")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw HarnessFailure.realInference("The tracked CAF fixture was not embedded in the normally signed harness.")
        }
        let appRoot = try harnessApplicationSupportRoot()
        let modelURL = WhisperModelCatalog.modelURL(applicationSupportRoot: appRoot)

        let sessionID = UUID()
        let sessionsRoot = appRoot.appendingPathComponent("Sessions", isDirectory: true)
        let sessionPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: sessionsRoot, sessionID: sessionID)
        let sourceURL = sessionPaths.chunksDirectory.appendingPathComponent("chunk_000000.caf")
        guard !FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw HarnessFailure.realInference("The unique acceptance source path unexpectedly existed.")
        }
        try FileManager.default.copyItem(at: fixtureURL, to: sourceURL)
        let original = try Data(contentsOf: sourceURL)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceDigest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        guard sourceDigest == "3e533c02910303097519875d53e6e4aa3b4b45ad290c3589991daa26b7caeba4" else {
            throw HarnessFailure.realInference("The embedded fixture digest was unexpected.")
        }

        var manifest = SessionManifest.newSession(
            id: sessionID,
            audioFormat: AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32"),
            targetChunkDurationSeconds: 30
        )
        manifest.status = .completed
        manifest.endedCleanly = true
        manifest.endDate = Date()
        manifest.chunks = [ChunkMetadata(
            sequenceNumber: 0, fileName: "chunk_000000.caf", startOffsetSeconds: 0,
            durationSeconds: Double(242_368) / 44_100, frameCount: 242_368, state: .completed
        )]
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        let timingBox = HarnessTimingBox()
        let transcriber = WhisperProcessTranscriber(
            applicationSupportRoot: { appRoot },
            timingObserver: { timingBox.set($0) }
        )
        let store = TranscriptionStore()
        let coordinator = TranscriptionCoordinator(store: store, transcriber: transcriber)
        _ = try await coordinator.enqueueEligibleChunks(manifest: manifest, sessionPaths: sessionPaths)
        let clock = ContinuousClock()
        let started = clock.now
        let job = try await coordinator.processJob(sequenceNumber: 0, paths: artifactPaths)
        let totalMS = Int64((durationInSeconds(started.duration(to: clock.now)) * 1_000).rounded())
        guard job.state == .completed,
              let reloaded = try await store.loadResult(sequenceNumber: 0, paths: artifactPaths),
              reloaded.schemaVersion == TranscriptResult.currentSchemaVersion,
              let provenance = reloaded.output.provenance,
              provenance == WhisperT3BPolicy.provenance,
              let segments = reloaded.output.segments,
              let timing = timingBox.get() else {
            throw HarnessFailure.realInference("The adapter result did not persist and reload with exact v2 provenance.")
        }
        let lower = reloaded.output.text.lowercased()
        for expected in ["lecture", "recorder", "neural", "network", "fourier", "transform", "technical", "transcription"] {
            guard lower.contains(expected) else {
                throw HarnessFailure.realInference("Transcript omitted expected broad word '\(expected)': \(reloaded.output.text)")
            }
        }
        let after = try Data(contentsOf: sourceURL)
        let afterDigest = SHA256.hash(data: after).map { String(format: "%02x", $0) }.joined()
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let mtimeUnchanged = originalAttributes[.modificationDate] as? Date == afterAttributes[.modificationDate] as? Date
        guard after == original, afterDigest == sourceDigest, mtimeUnchanged else {
            throw HarnessFailure.sourceChanged
        }
        let report = RealInferenceReport(
            sessionID: sessionID, transcript: reloaded.output.text, segments: segments, provenance: provenance,
            persistedSchemaVersion: reloaded.schemaVersion,
            modelInitializationMilliseconds: timing.modelInitializationMilliseconds,
            audioConversionMilliseconds: timing.audioConversionMilliseconds,
            inferenceMilliseconds: timing.inferenceMilliseconds, totalMilliseconds: totalMS,
            sourceByteCount: original.count, sourceSHA256Before: sourceDigest,
            sourceSHA256After: afterDigest,
            sourceModificationDateUnchanged: mtimeUnchanged,
            modelPath: modelURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func harnessApplicationSupportRoot() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw HarnessFailure.realInference("The harness Application Support directory could not be resolved.")
        }
        return base.appendingPathComponent(
            "com.dylanlee.LectureRecorder.WorkerLaunchHarness",
            isDirectory: true
        )
    }

    private static func harnessModelURL() throws -> URL {
        WhisperModelCatalog.modelURL(applicationSupportRoot: try harnessApplicationSupportRoot())
    }

    // Authoritative normally signed coverage for OS-process behavior that
    // Xcode 26.6's hosted test action cannot execute with inherit-entitled
    // children. Protocol-only decision-table coverage remains in XCTest.
    private static func runProcessSuite() async throws {
        try await runScenario("literal-arguments") { runner, fixture in
            let literalArguments = [
                "has space",
                "has\"quote",
                "semi;colon",
                "pipe|char",
                "$(command substitution)",
                "`backtick`",
                "unicode-日本語-emoji-🎧",
            ]
            let outcome = await runner.run(rawFixtureRequest(
                fixture,
                mode: "echo-args",
                extraArguments: literalArguments,
                stdin: Data()
            ))
            guard case .success(let result) = outcome,
                  try JSONDecoder().decode([String].self, from: result.stdout) == literalArguments else {
                throw scenarioFailure("literal-arguments", outcome)
            }
        }

        try await runScenario("exact-and-large-stdin") { runner, fixture in
            var exact = Data(0...255)
            exact.append(contentsOf: Array("special: \"quotes\" ; | $() `tick` 日本語 🎧".utf8))
            let exactOutcome = await runner.run(rawFixtureRequest(
                fixture,
                mode: "echo-stdin",
                stdin: exact
            ))
            guard case .success(let exactResult) = exactOutcome,
                  exactResult.stdout == exact else {
                throw scenarioFailure("exact-stdin", exactOutcome)
            }

            let large = Data(repeating: 0x41, count: 2 * 1024 * 1024)
            let largeOutcome = await runner.run(rawFixtureRequest(
                fixture,
                mode: "echo-stdin",
                stdin: large,
                maximumStdinBytes: 4 * 1024 * 1024
            ))
            guard case .success(let largeResult) = largeOutcome,
                  largeResult.stdout == large else {
                throw scenarioFailure("large-stdin", largeOutcome)
            }
        }

        try await runScenario("large-stdout-and-stderr") { runner, fixture in
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = await runner.run(try fixtureRequest(
                fixture,
                mode: "large-both",
                maximumStdoutBytes: 32 * 1024 * 1024,
                maximumStderrBytes: 8 * 1024 * 1024,
                overallTimeout: 10.0
            ))
            guard case .success(let result) = outcome,
                  result.stdout.count > 1024,
                  !result.stderr.isEmpty else {
                throw scenarioFailure("large-stdout-and-stderr", outcome)
            }
            try requireTiming(
                scenario: "large-stdout-and-stderr",
                elapsed: started.duration(to: clock.now),
                lessThanSeconds: 8.0
            )
        }

        try await runScenario("stdout-limit") { runner, fixture in
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = await runner.run(try fixtureRequest(
                fixture,
                mode: "large-stdout",
                extraArguments: ["--post-condition-delay-ms=10000"],
                maximumStdoutBytes: 1024,
                overallTimeout: 10.0,
                gracePeriod: 0.3
            ))
            guard case .failure(.stdoutLimitExceeded(limit: 1024)) = outcome else {
                throw scenarioFailure("stdout-limit", outcome)
            }
            try requireTiming(
                scenario: "stdout-limit",
                elapsed: started.duration(to: clock.now),
                lessThanSeconds: 5.0,
                naturalDelaySeconds: 10.0
            )
        }

        try await runScenario("stderr-limit-and-separation") { runner, fixture in
            let outcome = await runner.run(try fixtureRequest(
                fixture,
                mode: "large-stderr",
                maximumStderrBytes: 1024,
                overallTimeout: 10.0
            ))
            guard case .success(let result) = outcome,
                  result.stdout.count > 0,
                  result.stderr.count == 1024,
                  result.stderrTruncated else {
                throw scenarioFailure("stderr-limit-and-separation", outcome)
            }
        }

        try await runScenario("three-way-pressure") { runner, fixture in
            let clock = ContinuousClock()
            let started = clock.now
            let stdin = Data(repeating: 0x53, count: 4 * 1024 * 1024)
            let outcome = await runner.run(rawFixtureRequest(
                fixture,
                mode: "three-way-pipe-pressure",
                stdin: stdin,
                maximumStdinBytes: 8 * 1024 * 1024,
                maximumStdoutBytes: 16 * 1024 * 1024,
                maximumStderrBytes: 16 * 1024 * 1024,
                overallTimeout: 10.0
            ))
            guard case .success(let result) = outcome,
                  result.stdout.count > 2 * 1024 * 1024,
                  result.stderr.count >= 2 * 1024 * 1024,
                  String(decoding: result.stdout, as: UTF8.self).contains("STDIN_BYTES=\(stdin.count)") else {
                throw scenarioFailure("three-way-pressure", outcome)
            }
            try requireTiming(
                scenario: "three-way-pressure",
                elapsed: started.duration(to: clock.now),
                lessThanSeconds: 8.0
            )
        }

        try await runScenario("raw-byte-pass-through") { runner, fixture in
            let outcome = await runner.run(try fixtureRequest(
                fixture,
                mode: "malformed-json",
                overallTimeout: 5.0
            ))
            guard case .success(let result) = outcome,
                  result.stdout == Data("{not valid json".utf8) else {
                throw scenarioFailure("raw-byte-pass-through", outcome)
            }
        }

        for mode in ["close-stdin-early", "close-stdin-early-then-respond", "close-stdin-then-hang"] {
            try await runScenario("stdin-failure-\(mode)") { runner, fixture in
                let clock = ContinuousClock()
                let started = clock.now
                let outcome = await runner.run(rawFixtureRequest(
                    fixture,
                    mode: mode,
                    extraArguments: mode == "close-stdin-early"
                        ? ["--post-condition-delay-ms=10000"]
                        : [],
                    stdin: Data(repeating: 0x44, count: 4 * 1024 * 1024),
                    maximumStdinBytes: 8 * 1024 * 1024,
                    overallTimeout: 10.0
                ))
                guard case .failure(.stdinDeliveryFailed) = outcome else {
                    throw scenarioFailure("stdin-failure-\(mode)", outcome)
                }
                let bound = switch mode {
                case "close-stdin-early", "close-stdin-then-hang": 3.0
                default: 5.0
                }
                let naturalDelay: TimeInterval? = switch mode {
                case "close-stdin-early": 10.0
                case "close-stdin-then-hang": 30.0
                default: nil
                }
                try requireTiming(
                    scenario: "stdin-failure-\(mode)",
                    elapsed: started.duration(to: clock.now),
                    lessThanSeconds: bound,
                    naturalDelaySeconds: naturalDelay
                )
            }
        }

        try await runScenario("timeout") { runner, fixture in
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = await runner.run(try fixtureRequest(
                fixture,
                mode: "delayed-response",
                extraArguments: ["--delay-ms=3000"],
                overallTimeout: 0.3,
                gracePeriod: 0.3
            ))
            guard case .failure(.timedOut) = outcome else {
                throw scenarioFailure("timeout", outcome)
            }
            try requireTiming(
                scenario: "timeout",
                elapsed: started.duration(to: clock.now),
                lessThanSeconds: 2.0,
                naturalDelaySeconds: 3.0
            )
        }

        try await runScenario("cancellation") { runner, fixture in
            let request = try fixtureRequest(
                fixture,
                mode: "delayed-response",
                extraArguments: ["--delay-ms=3000"],
                overallTimeout: 10.0
            )
            let task = Task { await runner.run(request) }
            try await Task.sleep(for: .milliseconds(100))
            let clock = ContinuousClock()
            let cancelledAt = clock.now
            task.cancel()
            let outcome = await task.value
            guard case .failure(.cancelled) = outcome else {
                throw scenarioFailure("cancellation", outcome)
            }
            try requireTiming(
                scenario: "cancellation",
                elapsed: cancelledAt.duration(to: clock.now),
                lessThanSeconds: 2.0,
                naturalDelaySeconds: 3.0
            )
        }

        try await runScenario("blocked-stdin-cancellation") { runner, fixture in
            let clock = ContinuousClock()
            let ready = FileManager.default.temporaryDirectory
                .appendingPathComponent("t3a-harness-stdin-ready-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: ready) }
            let request = rawFixtureRequest(
                fixture,
                mode: "delay-read-stdin",
                extraArguments: ["--delay-ms=5000", "--ready-file=\(ready.path)"],
                stdin: Data(repeating: 0x43, count: 4 * 1024 * 1024),
                maximumStdinBytes: 8 * 1024 * 1024,
                overallTimeout: 10.0
            )
            let task = Task { await runner.run(request) }
            let deadline = clock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: ready.path) {
                if clock.now >= deadline {
                    task.cancel()
                    _ = await task.value
                    throw HarnessFailure.processScenario(name: "blocked-stdin-cancellation", detail: "fixture did not announce readiness")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await Task.sleep(for: .milliseconds(100))
            let cancelledAt = clock.now
            task.cancel()
            let outcome = await task.value
            guard case .failure(.cancelled) = outcome else {
                throw scenarioFailure("blocked-stdin-cancellation", outcome)
            }
            try requireTiming(
                scenario: "blocked-stdin-cancellation",
                elapsed: cancelledAt.duration(to: clock.now),
                lessThanSeconds: 3.0,
                naturalDelaySeconds: 5.0
            )
        }

        try await runScenario("graceful-sigterm") { runner, fixture in
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = await runner.run(try fixtureRequest(
                fixture,
                mode: "delayed-response",
                extraArguments: ["--delay-ms=5000"],
                overallTimeout: 0.3,
                gracePeriod: 3.0
            ))
            guard case .failure(.timedOut) = outcome else {
                throw scenarioFailure("graceful-sigterm", outcome)
            }
            try requireTiming(
                scenario: "graceful-sigterm",
                elapsed: started.duration(to: clock.now),
                lessThanSeconds: 1.75,
                naturalDelaySeconds: 5.0
            )
        }

        try await runScenario("forced-sigkill-grace") { runner, fixture in
            let grace = 0.5
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = await runner.run(rawFixtureRequest(
                fixture,
                mode: "ignore-sigterm",
                stdin: Data(),
                overallTimeout: 0.2,
                gracePeriod: grace
            ))
            guard case .failure(.timedOut) = outcome else {
                throw scenarioFailure("forced-sigkill-grace", outcome)
            }
            try requireTiming(
                scenario: "forced-sigkill-grace",
                elapsed: started.duration(to: clock.now),
                atLeastSeconds: grace * 0.8,
                lessThanSeconds: 5.0,
                naturalDelaySeconds: 30.0
            )
        }

        try await runScenario("cancelled-sigkill-grace") { runner, fixture in
            let clock = ContinuousClock()
            let ready = FileManager.default.temporaryDirectory
                .appendingPathComponent("t3a-harness-ready-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: ready) }
            let grace = 0.5
            let request = rawFixtureRequest(
                fixture,
                mode: "ignore-sigterm-announce-ready",
                extraArguments: ["--ready-file=\(ready.path)"],
                stdin: Data(),
                overallTimeout: 10.0,
                gracePeriod: grace
            )
            let task = Task { await runner.run(request) }
            let deadline = clock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: ready.path) {
                if clock.now >= deadline {
                    task.cancel()
                    _ = await task.value
                    throw HarnessFailure.processScenario(name: "cancelled-sigkill-grace", detail: "fixture did not announce readiness")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            let cancelledAt = clock.now
            task.cancel()
            let outcome = await task.value
            guard case .failure(.cancelled) = outcome else {
                throw scenarioFailure("cancelled-sigkill-grace", outcome)
            }
            try requireTiming(
                scenario: "cancelled-sigkill-grace",
                elapsed: cancelledAt.duration(to: clock.now),
                atLeastSeconds: grace * 0.8,
                lessThanSeconds: 5.0,
                naturalDelaySeconds: 30.0
            )
        }

        try await runScenario("timeout-grace-ignores-later-cancellation") { runner, fixture in
            let timeout = 0.2
            let grace = 0.5
            let clock = ContinuousClock()
            let request = rawFixtureRequest(
                fixture,
                mode: "ignore-sigterm",
                stdin: Data(),
                overallTimeout: timeout,
                gracePeriod: grace
            )
            let started = clock.now
            let task = Task { await runner.run(request) }
            try await Task.sleep(for: .milliseconds(350))
            task.cancel()
            let outcome = await task.value
            guard case .failure(.timedOut) = outcome else {
                throw scenarioFailure("timeout-grace-ignores-later-cancellation", outcome)
            }
            try requireTiming(
                scenario: "timeout-grace-ignores-later-cancellation",
                elapsed: started.duration(to: clock.now),
                atLeastSeconds: timeout + grace * 0.8,
                lessThanSeconds: 5.0,
                naturalDelaySeconds: 30.0
            )
        }

        try await runScenario("nonzero-and-signaled-exits") { runner, fixture in
            let nonzero = await runner.run(rawFixtureRequest(fixture, mode: "nonzero-no-response", stdin: Data()))
            guard case .success(let first) = nonzero,
                  first.terminationReason == .exited(status: 7) else {
                throw scenarioFailure("nonzero-exit", nonzero)
            }
            let signaled = await runner.run(rawFixtureRequest(fixture, mode: "self-signal", stdin: Data()))
            guard case .success(let second) = signaled,
                  case .uncaughtSignal = second.terminationReason else {
                throw scenarioFailure("signaled-exit", signaled)
            }
        }

        try await runScenario("response-before-timeout-precedence") { runner, fixture in
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = await runner.run(try fixtureRequest(
                fixture,
                mode: "respond-then-hang",
                overallTimeout: 0.3,
                gracePeriod: 0.3
            ))
            guard case .failure(.timedOut) = outcome else {
                throw scenarioFailure("response-before-timeout-precedence", outcome)
            }
            try requireTiming(
                scenario: "response-before-timeout-precedence",
                elapsed: started.duration(to: clock.now),
                lessThanSeconds: 2.0,
                naturalDelaySeconds: 30.0
            )
        }

        try await runScenario("completion-races") { runner, fixture in
            for index in 0..<12 {
                let request = try fixtureRequest(fixture, mode: "success", overallTimeout: 5.0)
                let clock = ContinuousClock()
                let started = clock.now
                let task = Task { await runner.run(request) }
                try? await Task.sleep(for: .milliseconds(index * 2))
                task.cancel()
                switch await task.value {
                case .success, .failure(.cancelled): break
                default: throw HarnessFailure.processScenario(name: "completion-races", detail: "unexpected cancellation race outcome")
                }
                try requireTiming(
                    scenario: "completion-races-cancellation-\(index)",
                    elapsed: started.duration(to: clock.now),
                    lessThanSeconds: 2.0
                )
            }
            let timeoutClock = ContinuousClock()
            let timeoutStarted = timeoutClock.now
            let timeoutRace = await runner.run(try fixtureRequest(fixture, mode: "success", overallTimeout: 0.001))
            switch timeoutRace {
            case .success, .failure(.timedOut): break
            default: throw scenarioFailure("completion-races", timeoutRace)
            }
            try requireTiming(
                scenario: "completion-races-timeout",
                elapsed: timeoutStarted.duration(to: timeoutClock.now),
                lessThanSeconds: 2.0
            )
        }
    }

    private static func runScenario(
        _ name: String,
        body: (FoundationProcessRunner, URL) async throws -> Void
    ) async throws {
        let fixture: URL
        switch EmbeddedWorkerLocator.resolve(descriptor: .fixture) {
        case .success(let url): fixture = url
        case .failure(let error):
            throw HarnessFailure.processScenario(name: name, detail: "fixture resolution failed: \(error)")
        }
        try await body(FoundationProcessRunner(pollInterval: 0.01), fixture)
        print("process scenario: \(name) passed")
    }

    private static func fixtureRequest(
        _ fixture: URL,
        mode: String,
        extraArguments: [String] = [],
        maximumStdoutBytes: Int = 8 * 1024 * 1024,
        maximumStderrBytes: Int = 1 * 1024 * 1024,
        overallTimeout: TimeInterval,
        gracePeriod: TimeInterval = 0.5
    ) throws -> ProcessInvocationRequest {
        let requestIdentity = identity(sourceIdentity: "t3a-harness-process")
        let envelope = WorkerRequestEnvelope(
            schemaVersion: WorkerProtocolConstants.currentSchemaVersion,
            requestID: requestIdentity.requestID,
            attemptID: requestIdentity.attemptID,
            sessionID: requestIdentity.sessionID,
            chunkSequenceNumber: requestIdentity.chunkSequenceNumber,
            sourceIdentity: requestIdentity.sourceIdentity,
            payload: HarnessFixturePayload()
        )
        return rawFixtureRequest(
            fixture,
            mode: mode,
            extraArguments: extraArguments,
            stdin: try JSONEncoder().encode(envelope),
            maximumStdoutBytes: maximumStdoutBytes,
            maximumStderrBytes: maximumStderrBytes,
            overallTimeout: overallTimeout,
            gracePeriod: gracePeriod
        )
    }

    private static func rawFixtureRequest(
        _ fixture: URL,
        mode: String,
        extraArguments: [String] = [],
        stdin: Data,
        maximumStdinBytes: Int = 8 * 1024 * 1024,
        maximumStdoutBytes: Int = 8 * 1024 * 1024,
        maximumStderrBytes: Int = 1 * 1024 * 1024,
        overallTimeout: TimeInterval = 5.0,
        gracePeriod: TimeInterval = 0.5
    ) -> ProcessInvocationRequest {
        ProcessInvocationRequest(
            executableURL: fixture,
            arguments: ["--mode=\(mode)"] + extraArguments,
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

    private static func requireTiming(
        scenario: String,
        elapsed: Duration,
        atLeastSeconds: TimeInterval? = nil,
        lessThanSeconds: TimeInterval,
        naturalDelaySeconds: TimeInterval? = nil
    ) throws {
        let measuredSeconds = durationInSeconds(elapsed)
        let lowerDescription = atLeastSeconds.map { " and >= \(formatSeconds($0))s" } ?? ""
        let naturalDelayDescription = naturalDelaySeconds.map { formatSeconds($0) + "s" } ?? "n/a"
        let measurement = "measured monotonic duration \(formatSeconds(measuredSeconds))s; permitted < \(formatSeconds(lessThanSeconds))s\(lowerDescription); configured natural delay \(naturalDelayDescription)"

        guard measuredSeconds < lessThanSeconds,
              atLeastSeconds.map({ measuredSeconds >= $0 }) ?? true else {
            throw HarnessFailure.processScenario(name: scenario, detail: measurement)
        }
        print("timing scenario: \(scenario); \(measurement)")
    }

    private static func durationInSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    private static func scenarioFailure(
        _ name: String,
        _ outcome: Result<ProcessRunResult, ProcessRunFailure>
    ) -> HarnessFailure {
        .processScenario(name: name, detail: String(describing: outcome))
    }
}
