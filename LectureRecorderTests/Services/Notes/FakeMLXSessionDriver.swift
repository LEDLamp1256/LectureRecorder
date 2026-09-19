import Foundation
@testable import LectureRecorder

nonisolated enum FakeMLXSessionDriverError: Error, Equatable {
    case noScriptedResponse
}

/// Deterministic, offline fake conforming to `MLXSessionDriving` — never
/// loads the real ~4–5 GB model. Lets a test script exactly which
/// `MLXGuidedGenerationOutcome` (or error) comes back for each successive
/// `respond` call, and independently which token count (or error) comes
/// back for each `preparedInputTokenCount` call.
final class FakeMLXSessionDriver: MLXSessionDriving, @unchecked Sendable {
    private let lock = NSLock()

    var nativeContextLength: Int
    var operationalContextCeiling: Int
    private var scriptedAvailability: LectureNotesGenerationAvailability = .available
    private var tokenCountQueue: [Result<Int, Error>] = []
    private var defaultTokenCount: Result<Int, Error> = .success(100)
    private var respondQueue: [Result<MLXGuidedGenerationOutcome, Error>] = []
    private var _respondCallCount = 0
    private var _tokenCountCallCount = 0
    private var respondArgumentLog: [(instructions: String, prompt: String, jsonSchema: String, maxOutputTokens: Int)] = []

    init(nativeContextLength: Int = 32_768, operationalContextCeiling: Int = 24_576) {
        self.nativeContextLength = nativeContextLength
        self.operationalContextCeiling = operationalContextCeiling
    }

    func setAvailability(_ availability: LectureNotesGenerationAvailability) {
        lock.lock(); defer { lock.unlock() }
        scriptedAvailability = availability
    }

    /// Every subsequent `preparedInputTokenCount` call returns this unless
    /// `enqueueTokenCount` has queued a more specific one-shot result.
    func setDefaultTokenCount(_ result: Result<Int, Error>) {
        lock.lock(); defer { lock.unlock() }
        defaultTokenCount = result
    }

    func enqueueTokenCount(_ result: Result<Int, Error>) {
        lock.lock(); defer { lock.unlock() }
        tokenCountQueue.append(result)
    }

    /// Queues one response per successive `respond` call — the Nth call
    /// consumes the Nth queued result. A call beyond the queue's length
    /// throws `FakeMLXSessionDriverError.noScriptedResponse`.
    func enqueueRespond(_ result: Result<MLXGuidedGenerationOutcome, Error>) {
        lock.lock(); defer { lock.unlock() }
        respondQueue.append(result)
    }

    var respondCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _respondCallCount
    }

    var tokenCountCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _tokenCountCallCount
    }

    var respondArguments: [(instructions: String, prompt: String, jsonSchema: String, maxOutputTokens: Int)] {
        lock.lock(); defer { lock.unlock() }
        return respondArgumentLog
    }

    func availability() -> LectureNotesGenerationAvailability {
        lock.lock(); defer { lock.unlock() }
        return scriptedAvailability
    }

    func preparedInputTokenCount(instructions: String, prompt: String) async throws -> Int {
        lock.lock()
        _tokenCountCallCount += 1
        let result: Result<Int, Error>
        if !tokenCountQueue.isEmpty {
            result = tokenCountQueue.removeFirst()
        } else {
            result = defaultTokenCount
        }
        lock.unlock()
        switch result {
        case .success(let count): return count
        case .failure(let error): throw error
        }
    }

    func respond(
        instructions: String, prompt: String, jsonSchema: String, maxOutputTokens: Int
    ) async throws -> MLXGuidedGenerationOutcome {
        lock.lock()
        let index = _respondCallCount
        _respondCallCount += 1
        respondArgumentLog.append((instructions, prompt, jsonSchema, maxOutputTokens))
        lock.unlock()

        guard index < respondQueue.count else {
            throw FakeMLXSessionDriverError.noScriptedResponse
        }
        switch respondQueue[index] {
        case .success(let outcome): return outcome
        case .failure(let error): throw error
        }
    }
}

extension MLXGuidedGenerationOutcome {
    /// Convenience for tests: a scripted outcome carrying only the JSON
    /// text a test cares about, with plausible-but-arbitrary token counts.
    static func stub(jsonText: String, promptTokenCount: Int = 50, generatedTokenCount: Int = 50) -> MLXGuidedGenerationOutcome {
        MLXGuidedGenerationOutcome(
            jsonText: jsonText,
            promptTokenCount: promptTokenCount,
            generatedTokenCount: generatedTokenCount,
            generationSeconds: 0.01,
            memory: nil
        )
    }
}
