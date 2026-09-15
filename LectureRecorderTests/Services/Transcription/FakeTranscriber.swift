import Foundation
@testable import LectureRecorder

/// A concrete, typed engine failure a test can script `FakeTranscriber` to
/// throw — conforms to `TranscriptionEngineFailing` so
/// `TranscriptionCoordinator` classifies it precisely rather than falling
/// back to its conservative `.unknown`/`.permanent` mapping.
struct FakeTranscriberFailure: TranscriptionEngineFailing {
    var category: TranscriptionFailureCategory
    var diagnosticMessage: String
    var retryDisposition: RetryDisposition
}

/// An error deliberately *not* conforming to `TranscriptionEngineFailing`,
/// used to exercise the coordinator's conservative fallback mapping for an
/// unclassified `Error`.
struct UnclassifiedFakeError: Error {}

/// Deterministic, configurable `Transcribing` fake — test-target only, per
/// the approved plan (T1 has no production transcriber call site).
final class FakeTranscriber: Transcribing, @unchecked Sendable {
    static var defaultFakeOutput: TranscriptionEngineOutput {
        TranscriptionEngineOutput(
            text: "fake transcript",
            engineIdentifier: "fake-v1",
            modelIdentifier: "fake-model",
            language: "en",
            segments: nil,
            engineVersion: "1.0"
        )
    }

    private let lock = NSLock()
    private var scriptedOutputs: [Int: TranscriptionEngineOutput] = [:]
    private var scriptedFailures: [Int: Error] = [:]
    private var defaultOutput: TranscriptionEngineOutput
    private var calls: [(sequenceNumber: Int, audioURL: URL)] = []

    init(defaultOutput: TranscriptionEngineOutput = FakeTranscriber.defaultFakeOutput) {
        self.defaultOutput = defaultOutput
    }

    func setOutput(_ output: TranscriptionEngineOutput, forSequenceNumber sequenceNumber: Int) {
        lock.lock(); defer { lock.unlock() }
        scriptedOutputs[sequenceNumber] = output
    }

    func setFailure(_ error: Error, forSequenceNumber sequenceNumber: Int) {
        lock.lock(); defer { lock.unlock() }
        scriptedFailures[sequenceNumber] = error
    }

    var recordedCalls: [(sequenceNumber: Int, audioURL: URL)] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
        lock.lock()
        calls.append((source.chunkSequenceNumber, audioURL))
        let failure = scriptedFailures[source.chunkSequenceNumber]
        let output = scriptedOutputs[source.chunkSequenceNumber] ?? defaultOutput
        lock.unlock()

        if let failure {
            throw failure
        }
        return output
    }
}

/// Cooperative-polling, cancellation-aware fake — deliberately not built
/// on a raw unchecked/checked continuation, which cannot itself react to
/// `Task` cancellation. Modeled on `InFlightCallbackGate.drain()`'s
/// existing `while ... { await Task.yield() }` pattern.
final class CancellationAwareFakeTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var isGateArmed = false
    private var hasEnteredGateFlag = false

    /// Arms a one-shot gate: the next `transcribe` call cooperatively
    /// polls for cancellation instead of returning immediately.
    func armGate() {
        lock.lock(); defer { lock.unlock() }
        isGateArmed = true
        hasEnteredGateFlag = false
    }

    /// True once a gated call has actually started polling — lets a test
    /// deterministically wait until the call is really in flight before
    /// cancelling the enclosing `Task`.
    var hasEnteredGate: Bool {
        lock.lock(); defer { lock.unlock() }
        return hasEnteredGateFlag
    }

    func transcribe(audioURL: URL, source: TranscriptionSourceSnapshot) async throws -> TranscriptionEngineOutput {
        let gated: Bool = {
            lock.lock(); defer { lock.unlock() }
            let wasArmed = isGateArmed
            isGateArmed = false
            if wasArmed { hasEnteredGateFlag = true }
            return wasArmed
        }()

        if gated {
            while !Task.isCancelled {
                await Task.yield()
            }
            try Task.checkCancellation()
        }

        return FakeTranscriber.defaultFakeOutput
    }
}
