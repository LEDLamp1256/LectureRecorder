import Foundation

nonisolated enum WhisperT3BPolicy {
    static let configurationIdentifier = "whisper-large-v3-turbo-metal-greedy-en-v1"
    static let engineIdentifier = "whisper.cpp"
    static let engineVersion = "1.9.2"
    static let engineSourceRevision = "306c88f4d1286aec1bf96e544632897886af5501"
    static let maximumOutputSamples = 496_000
    static let maximumDecodedDurationMilliseconds: Int64 = 31_000
    static let maximumTranscriptBytes = 1 * 1024 * 1024
    static let maximumSegmentTextBytes = 64 * 1024
    static let maximumSegments = 10_000
    /// A finite process-wide deadline that leaves substantial headroom for
    /// unquantized large-v3-turbo initialization and one 31-second Metal-preferred inference on the
    /// approved M4 while retaining T2's timeout and termination guarantees.
    static let processTimeout: TimeInterval = 300

    static var provenance: TranscriptionProvenance {
        let model = WhisperModelCatalog.largeV3Turbo
        return TranscriptionProvenance(
            worker: TranscriptionWorkerProvenance(
                identifier: WhisperCapabilityProbeConstants.workerIdentifier,
                version: WhisperCapabilityProbeConstants.workerImplementationVersion
            ),
            engine: TranscriptionEngineProvenance(
                identifier: engineIdentifier,
                version: engineVersion,
                sourceRevision: engineSourceRevision
            ),
            model: TranscriptionModelProvenance(
                identifier: model.identifier,
                filename: model.filename,
                byteCount: model.byteCount,
                sha256: model.sha256
            ),
            configuration: TranscriptionInferenceConfigurationProvenance(
                identifier: configurationIdentifier,
                samplingStrategy: .greedy,
                threadCount: 4,
                language: "en",
                automaticLanguageDetectionEnabled: false,
                translationEnabled: false,
                previousTextContextEnabled: false,
                initialPromptUsed: false,
                segmentTimestampsEnabled: true,
                tokenTimestampsEnabled: false,
                singleSegmentModeEnabled: false,
                vadEnabled: false,
                diarizationEnabled: false,
                printing: TranscriptionPrintingConfiguration(
                    printSpecial: false,
                    printProgress: false,
                    printRealtime: false,
                    printTimestamps: false
                ),
                computeBackend: .metalPreferredWithCPUFallback
            )
        )
    }
}
