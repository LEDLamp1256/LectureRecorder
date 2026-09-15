import XCTest
@testable import LectureRecorder

final class WhisperProcessTranscriberTests: XCTestCase {
    private enum Behavior: Sendable {
        case success(WhisperInferenceOutput)
        case declaredFailure
        case processFailure(ProcessRunFailure)
    }

    private struct Runner: LocalProcessRunning {
        let behavior: Behavior

        func run(_ request: ProcessInvocationRequest) async -> Result<ProcessRunResult, ProcessRunFailure> {
            if case .processFailure(let failure) = behavior { return .failure(failure) }
            guard request.arguments.isEmpty, request.environmentPolicy == .empty,
                  request.workingDirectoryURL == nil,
                  request.overallTimeout == WhisperT3BPolicy.processTimeout,
                  let envelope = try? JSONDecoder().decode(WorkerRequestEnvelope<WhisperInferencePayload>.self, from: request.stdin),
                  envelope.payload.schemaVersion == 1,
                  envelope.payload.operation == "transcribe" else {
                return .failure(.launchFailed(underlying: "closed request mismatch"))
            }
            let response: WorkerResponseEnvelope<WhisperInferenceOutput>
            switch behavior {
            case .success(let output):
                response = WorkerResponseEnvelope(
                    schemaVersion: 1, requestID: envelope.requestID, attemptID: envelope.attemptID,
                    sessionID: envelope.sessionID, chunkSequenceNumber: envelope.chunkSequenceNumber,
                    sourceIdentity: envelope.sourceIdentity,
                    workerIdentifier: WhisperCapabilityProbeConstants.workerIdentifier,
                    workerVersion: WhisperCapabilityProbeConstants.workerImplementationVersion,
                    outcome: .success, output: output, failure: nil
                )
            case .declaredFailure:
                response = WorkerResponseEnvelope(
                    schemaVersion: 1, requestID: envelope.requestID, attemptID: envelope.attemptID,
                    sessionID: envelope.sessionID, chunkSequenceNumber: envelope.chunkSequenceNumber,
                    sourceIdentity: envelope.sourceIdentity,
                    workerIdentifier: WhisperCapabilityProbeConstants.workerIdentifier,
                    workerVersion: WhisperCapabilityProbeConstants.workerImplementationVersion,
                    outcome: .failure, output: nil, failure: WorkerDeclaredFailure(message: "decode failed")
                )
            case .processFailure:
                fatalError("handled above")
            }
            return .success(ProcessRunResult(
                stdout: (try? JSONEncoder().encode(response)) ?? Data(), stderr: Data(), stderrTruncated: false,
                terminationReason: .exited(status: 0)
            ))
        }
    }

    func testAdapterBuildsClosedRequestMapsSegmentsAndPreservesSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperProcessTranscriberTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = makeSource()
        let audio = directory.appendingPathComponent(source.chunkFileName)
        let original = Data("immutable source bytes".utf8)
        try original.write(to: audio)
        let before = try FileManager.default.attributesOfItem(atPath: audio.path)
        let transcriber = WhisperProcessTranscriber(
            processRunner: Runner(behavior: .success(makeOutput())),
            applicationSupportRoot: { directory },
            preflightModel: { _ in },
            invocationGate: WhisperInvocationGate()
        )

        let mapped = try await transcriber.transcribe(audioURL: audio, source: source)

        XCTAssertEqual(mapped.text, " neural networks")
        XCTAssertEqual(mapped.engineIdentifier, "whisper.cpp")
        XCTAssertEqual(mapped.engineVersion, "1.9.2")
        XCTAssertEqual(mapped.modelIdentifier, "large-v3-turbo")
        XCTAssertEqual(mapped.language, "en")
        XCTAssertEqual(mapped.provenance, WhisperT3BPolicy.provenance)
        XCTAssertEqual(mapped.segments, [
            TranscriptionTimingSegment(startSeconds: 0, endSeconds: 1.25, text: " neural"),
            TranscriptionTimingSegment(startSeconds: 1.25, endSeconds: 2.5, text: " networks"),
        ])
        XCTAssertEqual(try Data(contentsOf: audio), original)
        let after = try FileManager.default.attributesOfItem(atPath: audio.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testAdapterPreservesCancellationAndDoesNotCollapseTimeoutOrWorkerFailureIntoCancellation() async {
        let source = makeSource()
        let audio = URL(fileURLWithPath: "/tmp/\(source.chunkFileName)")
        let gate = WhisperInvocationGate()
        let cases: [(Behavior, Bool)] = [
            (Behavior.processFailure(.cancelled), true),
            (Behavior.processFailure(.timedOut(afterSeconds: 300)), false),
            (Behavior.processFailure(.launchFailed(underlying: "controlled")), false),
            (Behavior.declaredFailure, false),
        ]
        for (index, item) in cases.enumerated() {
            let (behavior, expectedCancellation) = item
            let transcriber = WhisperProcessTranscriber(
                processRunner: Runner(behavior: behavior),
                applicationSupportRoot: { URL(fileURLWithPath: "/tmp/app-support") },
                preflightModel: { _ in },
                invocationGate: gate
            )
            do {
                _ = try await transcriber.transcribe(audioURL: audio, source: source)
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(error is CancellationError, expectedCancellation)
                if !expectedCancellation {
                    XCTAssertTrue(error is WhisperProcessTranscriberError)
                }
            }
            let snapshot = gate.snapshot()
            XCTAssertFalse(snapshot.isOccupied)
            XCTAssertEqual(snapshot.waitingCount, 0)
            XCTAssertEqual(snapshot.acquisitionCount, index + 1)
            XCTAssertEqual(snapshot.releaseCount, index + 1)
        }
    }

    func testResponseValidationRejectsTextSegmentAndDurationViolationsAndAcceptsEmpty() throws {
        XCTAssertNoThrow(try WhisperProcessTranscriber.validate(response: makeOutput(transcript: "", segments: [], duration: 0, samples: 0)))
        let invalid: [WhisperInferenceOutput] = [
            makeOutput(transcript: "wrong"),
            makeOutput(segments: [.init(startMilliseconds: -1, endMilliseconds: 10, text: " neural")]),
            makeOutput(segments: [.init(startMilliseconds: 20, endMilliseconds: 10, text: " neural")]),
            makeOutput(segments: [
                .init(startMilliseconds: 0, endMilliseconds: 20, text: " neural"),
                .init(startMilliseconds: 10, endMilliseconds: 30, text: " networks"),
            ]),
            makeOutput(segments: [.init(startMilliseconds: 0, endMilliseconds: 3_251, text: " neural")]),
            makeOutput(duration: 31_001),
            makeOutput(samples: 496_001),
            makeOutput(transcript: String(repeating: "x", count: WhisperT3BPolicy.maximumTranscriptBytes + 1), segments: []),
            makeOutput(segments: [.init(startMilliseconds: 0, endMilliseconds: 1, text: String(repeating: "x", count: WhisperT3BPolicy.maximumSegmentTextBytes + 1))]),
        ]
        for response in invalid {
            XCTAssertThrowsError(try WhisperProcessTranscriber.validate(response: response))
        }
    }

    func testResponseValidationRejectsEveryEffectiveConfigurationMutation() throws {
        let exact = WhisperT3BPolicy.provenance
        let mutations: [(inout TranscriptionProvenance) -> Void] = [
            { $0.configuration.samplingStrategy = .greedy; $0.configuration.threadCount = 3 },
            { $0.configuration.language = "auto" },
            { $0.configuration.automaticLanguageDetectionEnabled = true },
            { $0.configuration.translationEnabled = true },
            { $0.configuration.previousTextContextEnabled = true },
            { $0.configuration.initialPromptUsed = true },
            { $0.configuration.segmentTimestampsEnabled = false },
            { $0.configuration.tokenTimestampsEnabled = true },
            { $0.configuration.singleSegmentModeEnabled = true },
            { $0.configuration.vadEnabled = true },
            { $0.configuration.diarizationEnabled = true },
            { $0.configuration.printing.printSpecial = true },
            { $0.configuration.printing.printProgress = true },
            { $0.configuration.printing.printRealtime = true },
            { $0.configuration.printing.printTimestamps = true },
        ]
        for mutation in mutations {
            var provenance = exact
            mutation(&provenance)
            XCTAssertThrowsError(try WhisperProcessTranscriber.validate(response: makeOutput(provenance: provenance)))
        }
    }

    private func makeSource() -> TranscriptionSourceSnapshot {
        TranscriptionSourceSnapshot(
            sessionID: UUID(), chunkSequenceNumber: 0, chunkFileName: "chunk_000000.caf",
            frameCount: 44_100 * 3, startOffsetSeconds: 0, durationSeconds: 3,
            audioFormat: AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
        )
    }

    private func makeOutput(
        transcript: String = " neural networks",
        segments: [WhisperInferenceSegment] = [
            .init(startMilliseconds: 0, endMilliseconds: 1_250, text: " neural"),
            .init(startMilliseconds: 1_250, endMilliseconds: 2_500, text: " networks"),
        ],
        duration: Int64 = 3_000,
        samples: Int = 48_000,
        provenance: TranscriptionProvenance = WhisperT3BPolicy.provenance
    ) -> WhisperInferenceOutput {
        WhisperInferenceOutput(
            schemaVersion: 1, transcript: transcript, segments: segments,
            decodedDurationMilliseconds: duration, decodedSampleCount: samples, provenance: provenance,
            timing: WhisperInferenceTiming(modelInitializationMilliseconds: 10, audioConversionMilliseconds: 2, inferenceMilliseconds: 100)
        )
    }
}
