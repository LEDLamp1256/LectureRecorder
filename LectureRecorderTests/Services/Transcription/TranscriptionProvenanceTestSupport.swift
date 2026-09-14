@testable import LectureRecorder

func makeT3BProvenance() -> TranscriptionProvenance {
    TranscriptionProvenance(
        worker: TranscriptionWorkerProvenance(
            identifier: "LectureRecorderWhisperWorker",
            version: "1.0.0"
        ),
        engine: TranscriptionEngineProvenance(
            identifier: "whisper.cpp",
            version: "1.9.2",
            sourceRevision: "306c88f4d1286aec1bf96e544632897886af5501"
        ),
        model: TranscriptionModelProvenance(
            identifier: "large-v3-turbo",
            filename: "ggml-large-v3-turbo.bin",
            byteCount: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        ),
        configuration: TranscriptionInferenceConfigurationProvenance(
            identifier: "whisper-large-v3-turbo-cpu-greedy-en-v1",
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
            computeBackend: .cpuAccelerate
        )
    )
}
