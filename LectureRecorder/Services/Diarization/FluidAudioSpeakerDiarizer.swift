@preconcurrency import CoreML
import DiarizationRuntimeFluidAudio
import Foundation

/// Structural timings for one diarization run — no audio or transcript
/// content. Reported only to an explicitly supplied observer.
nonisolated struct FluidAudioDiarizationRunMetrics: Sendable, Equatable {
    var modelVerificationSeconds: Double
    var audioStagingSeconds: Double
    var modelLoadSeconds: Double
    var inferenceSeconds: Double
    var stagedAudioSeconds: Double
    var backendSegmentCount: Int
}

/// The fields of one backend speaker segment the adapter copies. FluidAudio's
/// `TimedSpeakerSegment` conforms below; tests supply their own values.
nonisolated protocol FluidAudioSpeakerSegmentFields {
    var speakerId: String { get }
    var startTimeSeconds: Float { get }
    var endTimeSeconds: Float { get }
}

nonisolated extension TimedSpeakerSegment: FluidAudioSpeakerSegmentFields {}

nonisolated enum FluidAudioSpeakerDiarizerError: LocalizedError, Sendable, Equatable {
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .inferenceFailed: return "Speaker diarization failed while analyzing the session audio."
        }
    }
}

/// The production `SpeakerDiarizing` backend: FluidAudio's offline VBx
/// pipeline (`OfflineDiarizerManager`) over a whole validated session.
///
/// Fully local. Models are loaded only from the provisioned, SHA-256-verified
/// directory (`FluidAudioDiarizationModelVerifier`) straight into Core ML —
/// FluidAudio's own model loader, which can download, is never called. No
/// FluidAudio type leaves this file: results become backend-neutral
/// `DiarizationBackendSegment`s and inference errors become
/// `FluidAudioSpeakerDiarizerError.inferenceFailed` (cancellation passes
/// through); normalization, fingerprinting, and storage stay with the D1
/// types.
///
/// Each call runs on the global concurrent executor (never the caller's
/// actor) and owns its own Core ML models and `OfflineDiarizerManager`,
/// which is not `Sendable`: both are created, used, and released inside
/// that one call and never shared with another. Concurrent calls are
/// independent; no process-wide scheduling is imposed here.
nonisolated struct FluidAudioSpeakerDiarizer: SpeakerDiarizing {
    static let provenance = SpeakerDiarizationProvenance(
        backendIdentifier: "fluidaudio-offline-vbx",
        backendVersion: "FluidAudio 0.16.1 (b811a61569aa02691c99b808d08ee989b630c133)",
        configurationIdentifier: "\(FluidAudioDiarizationModelManifest.pinned.repository)@\(FluidAudioDiarizationModelManifest.pinned.revision); OfflineDiarizerConfig.default; 16kHz mono from session frame 0"
    )

    private let modelDirectory: @Sendable () throws -> URL
    private let audioStager: DiarizationAudioStager
    private let metricsRecorder: (@Sendable (FluidAudioDiarizationRunMetrics) -> Void)?

    init(
        modelDirectory: @escaping @Sendable () throws -> URL = { try FluidAudioDiarizationModelManifest.defaultModelDirectory() },
        audioStager: DiarizationAudioStager = DiarizationAudioStager(),
        metricsRecorder: (@Sendable (FluidAudioDiarizationRunMetrics) -> Void)? = nil
    ) {
        self.modelDirectory = modelDirectory
        self.audioStager = audioStager
        self.metricsRecorder = metricsRecorder
    }

    func diarize(_ request: SpeakerDiarizationRequest) async throws -> SpeakerDiarizationOutput {
        try await run(request)
    }

    /// Verify → stage → re-verify → load → infer, checking for cancellation
    /// between phases (and, inside staging, between chunks; FluidAudio checks
    /// during segmentation and embedding, not during its final clustering).
    /// The first verification fails fast before staging; the second keeps
    /// the window between verification and Core ML loading short.
    @concurrent
    private func run(_ request: SpeakerDiarizationRequest) async throws -> SpeakerDiarizationOutput {
        let clock = ContinuousClock()
        try Task.checkCancellation()

        var mark = clock.now
        let directory: URL
        do {
            directory = try modelDirectory()
        } catch {
            throw FluidAudioDiarizationModelError.modelDirectoryUnavailable
        }
        try FluidAudioDiarizationModelVerifier.verify(directory: directory)
        let verificationSeconds = Self.seconds(since: mark, clock)
        try Task.checkCancellation()

        mark = clock.now
        let audio = try audioStager.stage(request.source)
        let stagingSeconds = Self.seconds(since: mark, clock)
        try Task.checkCancellation()

        mark = clock.now
        try FluidAudioDiarizationModelVerifier.verify(directory: directory)
        let models = try Self.loadModels(from: directory)
        let loadSeconds = Self.seconds(since: mark, clock)
        try Task.checkCancellation()

        mark = clock.now
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: models)
        let result: DiarizationResult
        do {
            result = try await manager.process(audio: audio.samples)
        } catch let error as CancellationError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw FluidAudioSpeakerDiarizerError.inferenceFailed
        }
        let inferenceSeconds = Self.seconds(since: mark, clock)
        try Task.checkCancellation()

        let segments = Self.backendSegments(from: result.segments)
        metricsRecorder?(FluidAudioDiarizationRunMetrics(
            modelVerificationSeconds: verificationSeconds,
            audioStagingSeconds: stagingSeconds,
            modelLoadSeconds: loadSeconds,
            inferenceSeconds: inferenceSeconds,
            stagedAudioSeconds: audio.durationSeconds,
            backendSegmentCount: segments.count
        ))
        return SpeakerDiarizationOutput(provenance: Self.provenance, segments: segments)
    }

    /// Backend segments → neutral segments, in backend order: a field copy
    /// only (`Float` seconds widen exactly to `Double`). Labels stay opaque
    /// and malformed times are passed through unrepaired;
    /// `DiarizationSegmentNormalizer` owns all policy — ID assignment,
    /// clipping, merging, ordering, and rejection.
    static func backendSegments<Segment: FluidAudioSpeakerSegmentFields>(
        from segments: [Segment]
    ) -> [DiarizationBackendSegment] {
        segments.map {
            DiarizationBackendSegment(
                label: $0.speakerId,
                startSeconds: Double($0.startTimeSeconds),
                endSeconds: Double($0.endTimeSeconds)
            )
        }
    }

    /// Loads the verified bundles directly, with the same Core ML settings
    /// FluidAudio's loader uses (FBank on the CPU, the rest on all units).
    private static func loadModels(from directory: URL) throws -> OfflineDiarizerModels {
        let start = ContinuousClock.now
        let components = try FluidAudioDiarizationModelComponents<MLModel>.load { component in
            let configuration = MLModelConfiguration()
            configuration.computeUnits = component.runsOnCPUOnly ? .cpuOnly : .all
            configuration.allowLowPrecisionAccumulationOnGPU = true
            return try MLModel(
                contentsOf: directory.appendingPathComponent(component.bundleName, isDirectory: true),
                configuration: configuration
            )
        }
        let pldaFile = FluidAudioDiarizationModelManifest.pldaParametersFile
        guard let pldaEntry = FluidAudioDiarizationModelManifest.pinned.files.first(where: { $0.relativePath == pldaFile }) else {
            throw FluidAudioDiarizationModelError.fileMissing(pldaFile)
        }
        let psi = try FluidAudioPLDAParameters.psi(
            contentsOf: directory.appendingPathComponent(pldaFile, isDirectory: false),
            expected: pldaEntry
        )
        return OfflineDiarizerModels(
            segmentationModel: components.segmentation,
            fbankModel: components.fbank,
            embeddingModel: components.embedding,
            pldaRhoModel: components.pldaRho,
            pldaPsi: psi,
            compilationDuration: seconds(since: start, ContinuousClock())
        )
    }

    private static func seconds(since start: ContinuousClock.Instant, _ clock: ContinuousClock) -> Double {
        let elapsed = start.duration(to: clock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
