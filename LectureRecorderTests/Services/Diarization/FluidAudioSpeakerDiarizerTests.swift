import XCTest
@testable import LectureRecorder

final class FluidAudioSpeakerDiarizerTests: XCTestCase {
    private typealias F = DiarizationTestFixtures

    /// The shape of FluidAudio's `TimedSpeakerSegment` fields the adapter reads.
    private struct BackendSegment: FluidAudioSpeakerSegmentFields {
        var speakerId: String
        var startTimeSeconds: Float
        var endTimeSeconds: Float
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var count: Int { lock.withLock { stored } }
        func increment() { lock.withLock { stored += 1 } }
    }

    // MARK: - Adapter

    func testAdapterCopiesLabelsAndTimesInBackendOrder() {
        let segments = [
            BackendSegment(speakerId: "S2", startTimeSeconds: 4.5, endTimeSeconds: 6.25),
            BackendSegment(speakerId: "S1", startTimeSeconds: 0.5, endTimeSeconds: 2),
            BackendSegment(speakerId: "S2", startTimeSeconds: 1.75, endTimeSeconds: 3),
        ]
        XCTAssertEqual(FluidAudioSpeakerDiarizer.backendSegments(from: segments), [
            DiarizationBackendSegment(label: "S2", startSeconds: 4.5, endSeconds: 6.25),
            DiarizationBackendSegment(label: "S1", startSeconds: 0.5, endSeconds: 2),
            DiarizationBackendSegment(label: "S2", startSeconds: 1.75, endSeconds: 3),
        ])
    }

    func testAdapterWidensFloatSecondsExactly() {
        let segment = BackendSegment(speakerId: "S1", startTimeSeconds: 0.1, endTimeSeconds: 1234.567)
        let converted = FluidAudioSpeakerDiarizer.backendSegments(from: [segment])
        XCTAssertEqual(converted.first?.startSeconds, Double(Float(0.1)))
        XCTAssertEqual(converted.first?.endSeconds, Double(Float(1234.567)))
    }

    func testEmptyBackendOutputIsAnEmptyValidResult() throws {
        XCTAssertEqual(FluidAudioSpeakerDiarizer.backendSegments(from: [BackendSegment]()), [])
        let output = SpeakerDiarizationOutput(provenance: FluidAudioSpeakerDiarizer.provenance, segments: [])
        let result = try SpeakerDiarizationResult(output: output, source: try F.source(), createdDate: F.createdDate)
        XCTAssertEqual(result.ranges, [])
    }

    func testAdaptedOutputNormalizesThroughTheD1Layer() throws {
        let source = try F.source()
        let segments = [
            BackendSegment(speakerId: "S2", startTimeSeconds: 4, endTimeSeconds: 6),
            BackendSegment(speakerId: "S1", startTimeSeconds: 1, endTimeSeconds: 3),
            BackendSegment(speakerId: "S2", startTimeSeconds: 6, endTimeSeconds: 8),
            BackendSegment(speakerId: "S1", startTimeSeconds: 69, endTimeSeconds: 75),
        ]
        let output = SpeakerDiarizationOutput(
            provenance: FluidAudioSpeakerDiarizer.provenance,
            segments: FluidAudioSpeakerDiarizer.backendSegments(from: segments)
        )
        let result = try SpeakerDiarizationResult(output: output, source: source, createdDate: F.createdDate)
        // speaker_0 speaks first; touching S2 ranges merge; the range past
        // the 70 s session end is clipped — all by the D1 normalizer.
        XCTAssertEqual(result.ranges, [
            try F.range(0, 1, 3),
            try F.range(1, 4, 8),
            try F.range(0, 69, 70),
        ])
        XCTAssertEqual(result.provenance, FluidAudioSpeakerDiarizer.provenance)
    }

    func testMalformedBackendTimesArePassedThroughForTheNormalizerToReject() throws {
        let source = try F.source()
        let cases: [(String, BackendSegment)] = [
            ("NaN", BackendSegment(speakerId: "S1", startTimeSeconds: .nan, endTimeSeconds: 1)),
            ("infinite", BackendSegment(speakerId: "S1", startTimeSeconds: 0, endTimeSeconds: .infinity)),
            ("negative", BackendSegment(speakerId: "S1", startTimeSeconds: -1, endTimeSeconds: 1)),
            ("reversed", BackendSegment(speakerId: "S1", startTimeSeconds: 3, endTimeSeconds: 2)),
        ]
        for (name, bad) in cases {
            let segments = [BackendSegment(speakerId: "S0", startTimeSeconds: 0, endTimeSeconds: 1), bad]
            let adapted = FluidAudioSpeakerDiarizer.backendSegments(from: segments)
            XCTAssertEqual(adapted.count, 2, "\(name) is not dropped or repaired by the adapter")
            let output = SpeakerDiarizationOutput(provenance: FluidAudioSpeakerDiarizer.provenance, segments: adapted)
            XCTAssertThrowsError(try SpeakerDiarizationResult(output: output, source: source, createdDate: F.createdDate), name) {
                XCTAssertEqual($0 as? DiarizationSegmentNormalizerError, .malformedSegment(index: 1), name)
            }
        }
    }

    func testProvenanceNamesThePinnedBackendAndModel() throws {
        let provenance = FluidAudioSpeakerDiarizer.provenance
        XCTAssertEqual(provenance.backendIdentifier, "fluidaudio-offline-vbx")
        XCTAssertTrue(provenance.backendVersion.contains("0.16.1"))
        XCTAssertTrue(provenance.backendVersion.contains("b811a61569aa02691c99b808d08ee989b630c133"))
        XCTAssertTrue(provenance.configurationIdentifier.contains("FluidInference/speaker-diarization-coreml@df2625ac79a7ac6b65ad868fee6d80f320da4232"))
        XCTAssertFalse(provenance.configurationIdentifier.contains(NSHomeDirectory()), "no local paths")
        XCTAssertNoThrow(try SpeakerDiarizationResult(
            output: SpeakerDiarizationOutput(provenance: provenance, segments: []),
            source: try F.source(),
            createdDate: F.createdDate
        ))
    }

    // MARK: - Run failures (no model, no network)

    func testUnresolvableModelDirectoryFailsBeforeAnyAudioIsDecoded() async throws {
        let decodes = Counter()
        let diarizer = FluidAudioSpeakerDiarizer(
            modelDirectory: { throw CocoaError(.fileNoSuchFile) },
            audioStager: DiarizationAudioStager(decodeChunk: { _, _ in decodes.increment(); return [] })
        )
        do {
            _ = try await diarizer.diarize(SpeakerDiarizationRequest(source: try F.source()))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? FluidAudioDiarizationModelError, .modelDirectoryUnavailable)
        }
        XCTAssertEqual(decodes.count, 0)
    }

    func testUnprovisionedModelFailsVerificationBeforeAnyAudioIsDecoded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidAudioSpeakerDiarizerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = FluidAudioDiarizationModelManifest.pinned.modelDirectory(applicationSupportRoot: root)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
            .appendingPathComponent(FluidAudioDiarizationModelManifest.pinned.revision, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        for (directory, expected) in [
            (missing, FluidAudioDiarizationModelError.modelDirectoryUnavailable),
            (empty, .fileMissing("Segmentation.mlmodelc/analytics/coremldata.bin")),
        ] {
            let decodes = Counter()
            let diarizer = FluidAudioSpeakerDiarizer(
                modelDirectory: { directory },
                audioStager: DiarizationAudioStager(decodeChunk: { _, _ in decodes.increment(); return [] })
            )
            do {
                _ = try await diarizer.diarize(SpeakerDiarizationRequest(source: try F.source()))
                XCTFail("expected a failure for \(directory.lastPathComponent)")
            } catch {
                XCTAssertEqual(error as? FluidAudioDiarizationModelError, expected)
            }
            XCTAssertEqual(decodes.count, 0)
        }
    }

    func testCancelledCallDoesNoWork() async throws {
        let decodes = Counter()
        let resolutions = Counter()
        let diarizer = FluidAudioSpeakerDiarizer(
            modelDirectory: { resolutions.increment(); throw CocoaError(.fileNoSuchFile) },
            audioStager: DiarizationAudioStager(decodeChunk: { _, _ in decodes.increment(); return [] })
        )
        let request = SpeakerDiarizationRequest(source: try F.source())
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await diarizer.diarize(request)
        }.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(resolutions.count, 0)
        XCTAssertEqual(decodes.count, 0)
    }
}
