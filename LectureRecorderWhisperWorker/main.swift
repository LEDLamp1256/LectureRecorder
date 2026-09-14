import Darwin
import Foundation
import WhisperC

enum WhisperWorkerMainError: Error {
    case requestTooLarge, invalidRequest, unsupportedSchema, unavailableVersion
    case invalidSource, modelMissing, modelInvalid, modelInitialization, inference, malformedEngineOutput
}

func readBoundedRequest() throws -> Data {
    var data = Data()
    while true {
        let remaining = WhisperWorkerConstants.maximumRequestBytes + 1 - data.count
        guard remaining > 0 else { throw WhisperWorkerMainError.requestTooLarge }
        let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, remaining)) ?? Data()
        guard !chunk.isEmpty else { return data }
        data.append(chunk)
        guard data.count <= WhisperWorkerConstants.maximumRequestBytes else { throw WhisperWorkerMainError.requestTooLarge }
    }
}

func diagnostic(_ error: Error) -> String {
    switch error {
    case WhisperWorkerMainError.requestTooLarge: return "Worker request exceeded the permitted byte limit."
    case WhisperWorkerMainError.invalidRequest: return "Worker request was malformed or contained unrecognized fields."
    case WhisperWorkerMainError.unsupportedSchema: return "Worker request used an unsupported schema."
    case WhisperWorkerMainError.unavailableVersion: return "whisper.cpp version was unavailable or unexpected."
    case WhisperWorkerMainError.invalidSource: return "The immutable CAF source failed identity validation."
    case WhisperWorkerMainError.modelMissing: return "The prepared large-v3-turbo model is missing."
    case WhisperWorkerMainError.modelInvalid: return "The prepared large-v3-turbo model failed size or SHA-256 verification."
    case WhisperWorkerMainError.modelInitialization: return "whisper.cpp could not initialize the approved model."
    case WhisperWorkerMainError.inference: return "whisper.cpp inference failed."
    case WhisperWorkerMainError.malformedEngineOutput: return "whisper.cpp returned malformed or oversized output."
    case WhisperAudioDecodeError.invalidCAF: return "The source is not a valid CAF file."
    case WhisperAudioDecodeError.metadataMismatch: return "CAF metadata did not match the trusted source snapshot."
    case WhisperAudioDecodeError.invalidChannels: return "CAF channel count or layout is unsupported."
    case WhisperAudioDecodeError.unsupportedFormat: return "CAF decoding is unsupported or truncated."
    case WhisperAudioDecodeError.nonfiniteSample: return "CAF conversion produced a nonfinite sample."
    case WhisperAudioDecodeError.limitExceeded: return "CAF audio exceeded the 31-second or 496,000-sample limit."
    case WhisperAudioDecodeError.conversionFailed: return "CAF conversion failed."
    default: return "Whisper worker failed."
    }
}

func failureCode(_ error: Error) -> String {
    switch error {
    case WhisperWorkerMainError.invalidSource: return "invalid-source"
    case WhisperWorkerMainError.modelMissing: return "model-open"
    case WhisperWorkerMainError.modelInvalid: return "model-integrity"
    case WhisperWorkerMainError.modelInitialization: return "model-initialization"
    case WhisperWorkerMainError.inference: return "inference"
    case WhisperWorkerMainError.malformedEngineOutput: return "malformed-engine-output"
    case WhisperWorkerMainError.unavailableVersion: return "version-mismatch"
    case is WhisperAudioDecodeError: return "decoding"
    default: return "malformed-engine-output"
    }
}

func exactKeys(_ object: Any, _ expected: Set<String>) -> Bool {
    guard let dictionary = object as? [String: Any] else { return false }
    return Set(dictionary.keys) == expected
}

func validateInferenceJSON(_ data: Data) throws {
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          exactKeys(envelope, ["schemaVersion", "requestID", "attemptID", "sessionID", "chunkSequenceNumber", "sourceIdentity", "payload"]),
          let payload = envelope["payload"] as? [String: Any],
          exactKeys(payload, ["schemaVersion", "operation", "sourcePath", "source"]),
          let source = payload["source"] as? [String: Any],
          exactKeys(source, ["sessionID", "chunkSequenceNumber", "chunkFileName", "frameCount", "startOffsetSeconds", "durationSeconds", "audioFormat"]),
          let format = source["audioFormat"] as? [String: Any],
          exactKeys(format, ["sampleRate", "channelCount", "bitsPerChannel", "formatIdentifier"]) else {
        throw WhisperWorkerMainError.invalidRequest
    }
}

func elapsedMilliseconds(_ duration: Duration) -> Int64 {
    let parts = duration.components
    let seconds = parts.seconds.multipliedReportingOverflow(by: 1_000)
    guard !seconds.overflow else { return .max }
    return seconds.partialValue + Int64(parts.attoseconds / 1_000_000_000_000_000)
}

func approvedModelURL(sourceURL: URL, request: WhisperInferenceRequestEnvelope) throws -> URL {
    let source = sourceURL.standardizedFileURL
    let chunks = source.deletingLastPathComponent()
    let session = chunks.deletingLastPathComponent()
    let sessions = session.deletingLastPathComponent()
    let expectedSourceIdentity = "\(request.sessionID.uuidString)/\(request.chunkSequenceNumber)/\(request.payload.source.chunkFileName)"
    guard source.lastPathComponent == request.payload.source.chunkFileName,
          chunks.lastPathComponent == "chunks",
          session.lastPathComponent == request.sessionID.uuidString,
          sessions.lastPathComponent == "Sessions",
          request.sourceIdentity == expectedSourceIdentity,
          request.payload.source.sessionID == request.sessionID,
          request.payload.source.chunkSequenceNumber == request.chunkSequenceNumber,
          request.chunkSequenceNumber >= 0,
          request.payload.source.startOffsetSeconds.isFinite,
          request.payload.source.startOffsetSeconds >= 0 else {
        throw WhisperWorkerMainError.invalidSource
    }
    let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WhisperWorkerMainError.invalidSource }
    return sessions.deletingLastPathComponent()
        .appendingPathComponent("Models/Whisper/large-v3-turbo/1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69/ggml-large-v3-turbo.bin")
}

let fixedProvenance = WorkerProvenance(
    worker: WorkerIdentityProvenance(identifier: "LectureRecorderWhisperWorker", version: "1.0.0"),
    engine: WorkerEngineProvenance(identifier: "whisper.cpp", version: "1.9.2", sourceRevision: "306c88f4d1286aec1bf96e544632897886af5501"),
    model: WorkerModelProvenance(identifier: "large-v3-turbo", filename: "ggml-large-v3-turbo.bin", byteCount: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
    configuration: WorkerConfigurationProvenance(
        identifier: "whisper-large-v3-turbo-metal-greedy-en-v1", samplingStrategy: "greedy", threadCount: 4, language: "en",
        automaticLanguageDetectionEnabled: false, translationEnabled: false, previousTextContextEnabled: false,
        initialPromptUsed: false, segmentTimestampsEnabled: true, tokenTimestampsEnabled: false,
        singleSegmentModeEnabled: false, vadEnabled: false, diarizationEnabled: false,
        printing: WorkerPrinting(printSpecial: false, printProgress: false, printRealtime: false, printTimestamps: false),
        computeBackend: "metal-preferred-with-cpu-fallback"
    )
)

final class CWhisperEngineBoundary: WhisperEngineBoundary {
    typealias Context = LRWhisperContext
    private var verifiedModel: LRWhisperVerifiedModel?
    private(set) var report: LRWhisperModelReport

    init(modelURL: URL) throws {
        report = LRWhisperModelReport()
        verifiedModel = modelURL.path.withCString {
            lr_whisper_model_open_verified($0, &report)
        }
        guard verifiedModel != nil else {
            if report.status == LR_WHISPER_MODEL_OPEN_FAILED {
                throw WhisperWorkerMainError.modelMissing
            }
            throw WhisperWorkerMainError.modelInvalid
        }
    }

    deinit { discardVerifiedModelIfNeeded() }

    func initialize() -> Context? {
        guard let model = verifiedModel else { return nil }
        verifiedModel = nil
        return lr_whisper_model_initialize(model, &report)
    }

    func discardVerifiedModelIfNeeded() {
        guard let model = verifiedModel else { return }
        verifiedModel = nil
        lr_whisper_model_discard(model, &report)
    }

    func destroy(_ context: Context) { lr_whisper_destroy(context) }
    func run(_ context: Context, samples: [Float]) -> Int32 {
        samples.withUnsafeBufferPointer { lr_whisper_run(context, $0.baseAddress, Int32($0.count)) }
    }
    func segmentCount(_ context: Context) -> Int { Int(lr_whisper_segment_count(context)) }
    func segmentStart(_ context: Context, index: Int) -> Int64 { lr_whisper_segment_start(context, Int32(index)) }
    func segmentEnd(_ context: Context, index: Int) -> Int64 { lr_whisper_segment_end(context, Int32(index)) }
    func segmentText(_ context: Context, index: Int) -> String? {
        guard let pointer = lr_whisper_segment_text(context, Int32(index)) else { return nil }
        return String(validatingUTF8: pointer)
    }
}

func performInference(_ request: WhisperInferenceRequestEnvelope) throws -> WorkerInferenceOutput {
    guard request.schemaVersion == 1, request.payload.schemaVersion == 1, request.payload.operation == "transcribe" else {
        throw WhisperWorkerMainError.unsupportedSchema
    }
    let sourceURL = URL(fileURLWithPath: request.payload.sourcePath)
    let modelURL = try approvedModelURL(sourceURL: sourceURL, request: request)
    let clock = ContinuousClock()
    let conversionStart = clock.now
    let snapshot = request.payload.source
    let audio = try WhisperAudioDecoder.decode(
        url: sourceURL,
        source: WhisperAudioSourceMetadata(
            frameCount: snapshot.frameCount,
            durationSeconds: snapshot.durationSeconds,
            sampleRate: snapshot.audioFormat.sampleRate,
            channelCount: snapshot.audioFormat.channelCount,
            bitsPerChannel: snapshot.audioFormat.bitsPerChannel,
            formatIdentifier: snapshot.audioFormat.formatIdentifier
        )
    )
    let conversionMS = elapsedMilliseconds(conversionStart.duration(to: clock.now))
    let boundary = try CWhisperEngineBoundary(modelURL: modelURL)
    guard let version = lr_whisper_version(), String(cString: version) == "1.9.2",
          lr_whisper_configuration_is_expected() == 1 else {
        throw WhisperWorkerMainError.unavailableVersion
    }
    if audio.samples.isEmpty {
        boundary.discardVerifiedModelIfNeeded()
        return WorkerInferenceOutput(schemaVersion: 1, transcript: "", segments: [], decodedDurationMilliseconds: 0,
            decodedSampleCount: 0, provenance: fixedProvenance,
            timing: WorkerInferenceTiming(modelInitializationMilliseconds: 0, audioConversionMilliseconds: conversionMS, inferenceMilliseconds: 0))
    }
    let initializationStart = clock.now
    var initializationMS: Int64 = 0
    var inferenceStart = clock.now
    let bridgeSegments: [WhisperBridgeSegment]
    do {
        bridgeSegments = try WhisperBridgePipeline.infer(
            samples: audio.samples,
            boundary: boundary,
            initialized: {
                initializationMS = elapsedMilliseconds(initializationStart.duration(to: clock.now))
                inferenceStart = clock.now
            }
        )
    } catch WhisperBridgePipelineError.initialization {
        if boundary.report.status == LR_WHISPER_MODEL_MUTATED ||
            boundary.report.status == LR_WHISPER_MODEL_CLOSE_FAILED {
            throw WhisperWorkerMainError.modelInvalid
        }
        throw WhisperWorkerMainError.modelInitialization
    } catch WhisperBridgePipelineError.inference {
        throw WhisperWorkerMainError.inference
    } catch {
        throw WhisperWorkerMainError.malformedEngineOutput
    }
    let inferenceMS = elapsedMilliseconds(inferenceStart.duration(to: clock.now))
    var segments: [WorkerInferenceSegment] = []
    var transcript = ""
    for bridgeSegment in bridgeSegments {
        guard bridgeSegment.endMilliseconds <= audio.durationMilliseconds + 250 else {
            throw WhisperWorkerMainError.malformedEngineOutput
        }
        transcript += bridgeSegment.text
        guard transcript.utf8.count <= 1 * 1024 * 1024 else { throw WhisperWorkerMainError.malformedEngineOutput }
        segments.append(WorkerInferenceSegment(
            startMilliseconds: bridgeSegment.startMilliseconds,
            endMilliseconds: bridgeSegment.endMilliseconds,
            text: bridgeSegment.text
        ))
    }
    return WorkerInferenceOutput(schemaVersion: 1, transcript: transcript, segments: segments,
        decodedDurationMilliseconds: audio.durationMilliseconds, decodedSampleCount: audio.samples.count,
        provenance: fixedProvenance,
        timing: WorkerInferenceTiming(modelInitializationMilliseconds: initializationMS,
            audioConversionMilliseconds: conversionMS, inferenceMilliseconds: inferenceMS))
}

do {
    let requestData = try readBoundedRequest()
    guard let object = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
          let payload = object["payload"] as? [String: Any],
          let operation = payload["operation"] as? String else { throw WhisperWorkerMainError.invalidRequest }
    if operation == "capabilityProbe" {
        guard let request = try? JSONDecoder().decode(WhisperWorkerRequestEnvelope.self, from: requestData),
              request.schemaVersion == 1, let version = whisper_version() else { throw WhisperWorkerMainError.invalidRequest }
        let response = WhisperWorkerResponseEnvelope(schemaVersion: 1, requestID: request.requestID, attemptID: request.attemptID,
            sessionID: request.sessionID, chunkSequenceNumber: request.chunkSequenceNumber, sourceIdentity: request.sourceIdentity,
            workerIdentifier: "LectureRecorderWhisperWorker", workerVersion: "1.0.0", outcome: .success,
            output: WhisperProbeOutput(schemaVersion: 1, upstreamVersion: String(cString: version)), failure: nil)
        FileHandle.standardOutput.write(try JSONEncoder().encode(response))
    } else {
        try validateInferenceJSON(requestData)
        guard let request = try? JSONDecoder().decode(WhisperInferenceRequestEnvelope.self, from: requestData) else {
            throw WhisperWorkerMainError.invalidRequest
        }
        let response: WhisperInferenceResponseEnvelope
        do {
            response = WhisperInferenceResponseEnvelope(schemaVersion: 1, requestID: request.requestID, attemptID: request.attemptID,
                sessionID: request.sessionID, chunkSequenceNumber: request.chunkSequenceNumber, sourceIdentity: request.sourceIdentity,
                workerIdentifier: "LectureRecorderWhisperWorker", workerVersion: "1.0.0", outcome: .success,
                output: try performInference(request), failure: nil)
        } catch {
            response = WhisperInferenceResponseEnvelope(schemaVersion: 1, requestID: request.requestID, attemptID: request.attemptID,
                sessionID: request.sessionID, chunkSequenceNumber: request.chunkSequenceNumber, sourceIdentity: request.sourceIdentity,
                workerIdentifier: "LectureRecorderWhisperWorker", workerVersion: "1.0.0", outcome: .failure, output: nil,
                failure: WhisperWorkerFailure(
                    message: String(diagnostic(error).prefix(4096)),
                    code: failureCode(error)
                ))
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(response))
    }
    exit(EXIT_SUCCESS)
} catch {
    FileHandle.standardError.write(Data(String(diagnostic(error).prefix(4096)).utf8))
    exit(EXIT_FAILURE)
}
