import CryptoKit
import XCTest
@testable import LectureRecorder

/// Opt-in, real FluidAudio smoke test — never part of the deterministic
/// suite. Diarizes the leading chunks of one existing terminal session on a
/// temporary copy, so the real session directory is only read. Requires the
/// model provisioned by `Scripts/provision-fluidaudio-diarization-model.sh`;
/// never downloads anything. Enable with (via `TEST_RUNNER_` for
/// `xcodebuild`):
///
///     LECTURE_RECORDER_RUN_DIARIZATION_SMOKE=1
///     LECTURE_RECORDER_DIARIZATION_SMOKE_SESSION_ID=<session UUID>
///     LECTURE_RECORDER_DIARIZATION_SMOKE_CHUNK_COUNT=<leading chunks; default 8>
///     LECTURE_RECORDER_DIARIZATION_SMOKE_OUTPUT_DIRECTORY=<optional absolute path the test host can write>
final class FluidAudioDiarizationSmokeTests: XCTestCase {
    private struct SmokeResult: Encodable {
        var sessionID: String
        var chunkCount: Int
        var sourceSampleRate: Double
        var sourceDurationSeconds: Double
        var metrics: Metrics
        var peakResidentMemoryBytes: Int
        var speakerCount: Int
        var rangeCount: Int
        var ranges: [Range]
        var provenance: SpeakerDiarizationProvenance
        var sidecarReloaded: Bool
        var originalChunksUnchanged: Bool

        struct Metrics: Encodable {
            var modelVerificationSeconds: Double
            var audioStagingSeconds: Double
            var modelLoadSeconds: Double
            var inferenceSeconds: Double
            var stagedAudioSeconds: Double
            var backendSegmentCount: Int
        }

        struct Range: Encodable {
            var speakerID: String
            var startSeconds: Double
            var endSeconds: Double
        }
    }

    private final class MetricsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: FluidAudioDiarizationRunMetrics?
        var value: FluidAudioDiarizationRunMetrics? { lock.withLock { stored } }
        func set(_ metrics: FluidAudioDiarizationRunMetrics) { lock.withLock { stored = metrics } }
    }

    func testRealFluidAudioDiarizationOnLeadingChunksOfAnExistingSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["LECTURE_RECORDER_RUN_DIARIZATION_SMOKE"] == "1",
            "Set LECTURE_RECORDER_RUN_DIARIZATION_SMOKE=1 to run the real diarization smoke test."
        )
        let sessionID = try XCTUnwrap(
            environment["LECTURE_RECORDER_DIARIZATION_SMOKE_SESSION_ID"].flatMap(UUID.init(uuidString:)),
            "LECTURE_RECORDER_DIARIZATION_SMOKE_SESSION_ID must be a session UUID"
        )
        let chunkLimit = try XCTUnwrap(Int(environment["LECTURE_RECORDER_DIARIZATION_SMOKE_CHUNK_COUNT"] ?? "8"))
        XCTAssertGreaterThan(chunkLimit, 0)
        let outputRoot = environment["LECTURE_RECORDER_DIARIZATION_SMOKE_OUTPUT_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("diarization-smoke", isDirectory: true)

        // The real session, read only.
        let sessionsRoot = try DefaultFileSystemLocator.resolveSessionsRootPathWithoutCreating()
        let realPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: sessionsRoot, sessionID: sessionID)
        var manifest = try AtomicFileWriter.readJSON(SessionManifest.self, from: realPaths.manifestURL)
        manifest.chunks = Array(manifest.chunks.sorted { $0.sequenceNumber < $1.sequenceNumber }.prefix(chunkLimit))
        let digestsBefore = try manifest.chunks.map { try Self.sha256(realPaths.chunksDirectory.appendingPathComponent($0.fileName)) }

        // A temporary copy of just those chunks, validated exactly as
        // playback validates a session.
        let runDirectory = outputRoot.appendingPathComponent("diarization-smoke-\(UUID().uuidString)", isDirectory: true)
        let copyPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: runDirectory, sessionID: sessionID)
        try FileManager.default.createDirectory(at: copyPaths.chunksDirectory, withIntermediateDirectories: true)
        for chunk in manifest.chunks {
            try FileManager.default.copyItem(
                at: realPaths.chunksDirectory.appendingPathComponent(chunk.fileName),
                to: copyPaths.chunksDirectory.appendingPathComponent(chunk.fileName)
            )
        }
        try AtomicFileWriter.writeJSON(manifest, to: copyPaths.manifestURL)
        let source = try LecturePlaybackSourceLoader.load(expectedSessionID: sessionID, manifest: manifest, sessionPaths: copyPaths)

        let box = MetricsBox()
        let diarizer = FluidAudioSpeakerDiarizer(metricsRecorder: { box.set($0) })
        let output = try await diarizer.diarize(SpeakerDiarizationRequest(source: source))
        // Whole seconds: sidecar dates persist at millisecond precision, so
        // a raw `Date()` would not compare equal after the reload below.
        let createdDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let result = try SpeakerDiarizationResult(output: output, source: source, createdDate: createdDate)
        let store = SpeakerDiarizationStore()
        try store.save(result, source: source, sessionPaths: copyPaths)
        let reloaded = store.load(source: source, sessionPaths: copyPaths)

        let digestsAfter = try manifest.chunks.map { try Self.sha256(realPaths.chunksDirectory.appendingPathComponent($0.fileName)) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)

        let metrics = try XCTUnwrap(box.value)
        let smoke = SmokeResult(
            sessionID: sessionID.uuidString,
            chunkCount: manifest.chunks.count,
            sourceSampleRate: source.timeline.sampleRate,
            sourceDurationSeconds: source.timeline.durationSeconds,
            metrics: SmokeResult.Metrics(
                modelVerificationSeconds: metrics.modelVerificationSeconds,
                audioStagingSeconds: metrics.audioStagingSeconds,
                modelLoadSeconds: metrics.modelLoadSeconds,
                inferenceSeconds: metrics.inferenceSeconds,
                stagedAudioSeconds: metrics.stagedAudioSeconds,
                backendSegmentCount: metrics.backendSegmentCount
            ),
            peakResidentMemoryBytes: Int(usage.ru_maxrss),
            speakerCount: result.speakerIDs.count,
            rangeCount: result.ranges.count,
            ranges: result.ranges.map { SmokeResult.Range(speakerID: $0.speakerID.rawValue, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) },
            provenance: result.provenance,
            sidecarReloaded: reloaded == .loaded(result),
            originalChunksUnchanged: digestsBefore == digestsAfter
        )
        let resultURL = runDirectory.appendingPathComponent("smoke-result.json")
        try AtomicFileWriter.writeJSON(smoke, to: resultURL)
        print("diarization smoke result: \(resultURL.path)")

        XCTAssertEqual(digestsBefore, digestsAfter, "the real session's chunks are only read")
        XCTAssertEqual(reloaded, .loaded(result))
        XCTAssertFalse(result.ranges.isEmpty, "expected speech to be attributed")
        XCTAssertEqual(metrics.stagedAudioSeconds, source.timeline.durationSeconds, accuracy: 1.0 / 32_000)
        XCTAssertTrue(result.ranges.allSatisfy { $0.endSeconds <= source.timeline.durationSeconds })
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
