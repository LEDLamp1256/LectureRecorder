import Foundation

nonisolated enum WhisperProcessTranscriberError: LocalizedError, TranscriptionEngineFailing, Sendable, Equatable {
    case model(WhisperModelVerificationError)
    case invalidSource(String)
    case worker(String)
    case invalidResponse(String)

    var category: TranscriptionFailureCategory { .engineThrew }
    var retryDisposition: RetryDisposition {
        switch self {
        case .invalidSource, .invalidResponse: return .permanent
        case .model, .worker: return .retryable
        }
    }
    var diagnosticMessage: String { errorDescription ?? "Whisper transcription failed." }
    var errorDescription: String? {
        switch self {
        case .model(let error): return error.localizedDescription
        case .invalidSource(let detail): return "Whisper source validation failed: \(detail)"
        case .worker(let detail): return "Whisper worker failed: \(detail)"
        case .invalidResponse(let detail): return "Whisper response validation failed: \(detail)"
        }
    }
}

nonisolated enum WhisperWorkerFailureCode: String, Codable, Sendable, Equatable {
    case invalidSource = "invalid-source"
    case decoding = "decoding"
    case modelOpen = "model-open"
    case modelIntegrity = "model-integrity"
    case modelInitialization = "model-initialization"
    case inference
    case malformedEngineOutput = "malformed-engine-output"
    case versionMismatch = "version-mismatch"
}

/// Production `Transcribing` adapter. The worker descriptor, model, language,
/// decoding configuration, process arguments, and timeout are all closed here;
/// callers supply only T1's immutable source URL and trusted source snapshot.
nonisolated struct WhisperProcessTranscriber: Transcribing, Sendable {
    private let client: TranscriptionWorkerClient
    private let applicationSupportRoot: @Sendable () throws -> URL
    private let preflightModel: @Sendable (URL) throws -> Void
    private let timingObserver: @Sendable (WhisperInferenceTiming) -> Void
    private let invocationGate: WhisperInvocationGate

    init(
        processRunner: any LocalProcessRunning = FoundationProcessRunner(),
        applicationSupportRoot: @escaping @Sendable () throws -> URL = {
            try DefaultFileSystemLocator().applicationSupportDirectory()
        },
        preflightModel: @escaping @Sendable (URL) throws -> Void = {
            try WhisperModelVerifier.preflight(url: $0)
        },
        timingObserver: @escaping @Sendable (WhisperInferenceTiming) -> Void = { _ in },
        invocationGate: WhisperInvocationGate = .shared
    ) {
        client = TranscriptionWorkerClient(processRunner: processRunner, workerDescriptor: .whisper)
        self.applicationSupportRoot = applicationSupportRoot
        self.preflightModel = preflightModel
        self.timingObserver = timingObserver
        self.invocationGate = invocationGate
    }

    func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
        try await invocationGate.withPermit {
            try await performTranscription(audioURL: audioURL, source: source)
        }
    }

    private func performTranscription(
        audioURL: URL,
        source: TranscriptionSourceSnapshot
    ) async throws -> TranscriptionEngineOutput {
        guard audioURL.pathExtension.lowercased() == "caf",
              audioURL.lastPathComponent == source.chunkFileName else {
            throw WhisperProcessTranscriberError.invalidSource("Only the snapshot's canonical CAF file is accepted.")
        }
        let modelURL = WhisperModelCatalog.modelURL(applicationSupportRoot: try applicationSupportRoot())
        do { try preflightModel(modelURL) }
        catch let error as WhisperModelVerificationError { throw WhisperProcessTranscriberError.model(error) }

        let identity = WorkerRequestIdentity(
            requestID: UUID(), attemptID: UUID(), sessionID: source.sessionID,
            chunkSequenceNumber: source.chunkSequenceNumber,
            sourceIdentity: "\(source.sessionID.uuidString)/\(source.chunkSequenceNumber)/\(source.chunkFileName)"
        )
        let outcome: WorkerInvocationOutcome<WhisperInferenceOutput> = await client.submit(
            payload: WhisperInferencePayload(sourcePath: audioURL.path, source: source),
            identity: identity,
            outputType: WhisperInferenceOutput.self,
            limits: WorkerInvocationLimits(overallTimeout: WhisperT3BPolicy.processTimeout)
        )
        let response: WhisperInferenceOutput
        switch outcome {
        case .success(let output): response = output
        case .workerDeclaredFailure(let failure):
            guard failure.message.utf8.count <= 4_096,
                  let rawCode = failure.code,
                  let code = WhisperWorkerFailureCode(rawValue: rawCode) else {
                throw WhisperProcessTranscriberError.invalidResponse("Worker failure classification was absent or unrecognized.")
            }
            switch code {
            case .invalidSource, .decoding, .modelIntegrity, .malformedEngineOutput, .versionMismatch:
                throw WhisperProcessTranscriberError.invalidSource(failure.message)
            case .modelOpen, .modelInitialization, .inference:
                throw WhisperProcessTranscriberError.worker(failure.message)
            }
        case .infrastructureFailure(.process(.cancelled)): throw CancellationError()
        case .infrastructureFailure(let failure): throw WhisperProcessTranscriberError.worker(failure.localizedDescription)
        }
        try Self.validate(response: response)
        timingObserver(response.timing)
        return TranscriptionEngineOutput(
            text: response.transcript,
            engineIdentifier: WhisperT3BPolicy.engineIdentifier,
            modelIdentifier: WhisperModelCatalog.largeV3Turbo.identifier,
            language: "en",
            segments: response.segments.map {
                TranscriptionTimingSegment(
                    startSeconds: Double($0.startMilliseconds) / 1_000,
                    endSeconds: Double($0.endMilliseconds) / 1_000,
                    text: $0.text
                )
            },
            engineVersion: WhisperT3BPolicy.engineVersion,
            provenance: response.provenance
        )
    }

    /// Segment text is joined with no inserted separator because whisper.cpp
    /// segment strings already contain their engine-selected leading spacing.
    static func validate(response: WhisperInferenceOutput) throws {
        guard response.schemaVersion == 1 else { throw WhisperProcessTranscriberError.invalidResponse("Unsupported output schema.") }
        guard response.provenance == WhisperT3BPolicy.provenance else { throw WhisperProcessTranscriberError.invalidResponse("Provenance mismatch.") }
        try response.provenance.validate()
        guard response.decodedSampleCount >= 0,
              response.decodedSampleCount <= WhisperT3BPolicy.maximumOutputSamples,
              response.decodedDurationMilliseconds >= 0,
              response.decodedDurationMilliseconds <= WhisperT3BPolicy.maximumDecodedDurationMilliseconds else {
            throw WhisperProcessTranscriberError.invalidResponse("Decoded audio bounds were invalid.")
        }
        guard response.transcript.utf8.count <= WhisperT3BPolicy.maximumTranscriptBytes,
              response.segments.count <= WhisperT3BPolicy.maximumSegments else {
            throw WhisperProcessTranscriberError.invalidResponse("Text or segment count exceeded its bound.")
        }
        guard response.transcript == response.segments.map(\.text).joined() else {
            throw WhisperProcessTranscriberError.invalidResponse("Transcript did not equal ordered segment concatenation.")
        }
        var priorEnd: Int64 = 0
        for segment in response.segments {
            guard segment.text.utf8.count <= WhisperT3BPolicy.maximumSegmentTextBytes,
                  segment.startMilliseconds >= 0,
                  segment.endMilliseconds >= segment.startMilliseconds,
                  segment.startMilliseconds >= priorEnd,
                  segment.endMilliseconds <= response.decodedDurationMilliseconds + 250 else {
                throw WhisperProcessTranscriberError.invalidResponse("A segment was malformed, overlapping, or outside the audio duration.")
            }
            priorEnd = segment.endMilliseconds
        }
    }
}
