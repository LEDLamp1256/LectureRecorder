import FoundationModels
import Foundation
@testable import LectureRecorder

nonisolated enum FakeFoundationModelsDriverError: Error, Equatable {
    case noScriptedResponse
    case typeMismatch
}

/// Deterministic, offline fake conforming to `FoundationModelsSessionDriving`
/// — test-only, no real on-device model is ever touched. Lets a test script
/// exactly which structured DTO (or error) comes back for each successive
/// `respond` call, records every prompt it was given (so grouping/ordering
/// can be asserted), and can gate one specific call so a cancellation test
/// can get a call genuinely in flight before cancelling — mirroring
/// `ControllableFakeLectureNotesGenerator`'s established gate pattern, but
/// as a lock-guarded class (not an actor) since the real
/// `FoundationModelsSessionDriving.availability()` requirement is
/// synchronous, not async.
final class FakeFoundationModelsSessionDriver: FoundationModelsSessionDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var scriptedAvailability: LectureNotesGenerationAvailability = .available
    private var responseQueue: [Result<Any, Error>] = []
    private var promptLog: [(instructions: String, prompt: String)] = []
    private var gateBeforeCallNumber: Int?
    private var enteredGateFlag = false
    private var scriptedContextTokenBudget = 4_096
    /// `nil` by default — deterministic tests must never depend on real
    /// on-device token counting, so the fake reports "can't tell" and lets
    /// `FoundationModelsLectureNotesGenerator` fall back to its
    /// deterministic byte-budget path, the only path a unit test can fully
    /// control. A test that specifically wants to prove the real-token-
    /// preflight branch is preferred when available can override this via
    /// `setTokenCountOverride`.
    private var tokenCountOverride: Int??

    func setAvailability(_ availability: LectureNotesGenerationAvailability) {
        lock.lock(); defer { lock.unlock() }
        scriptedAvailability = availability
    }

    func setContextTokenBudget(_ budget: Int) {
        lock.lock(); defer { lock.unlock() }
        scriptedContextTokenBudget = budget
    }

    /// Pass `nil` to simulate "real token counting unavailable" (the
    /// default), or a concrete `Int` to simulate a successful real
    /// preflight count for every subsequent `estimatedTokenCount` call.
    func setTokenCountOverride(_ value: Int?) {
        lock.lock(); defer { lock.unlock() }
        tokenCountOverride = .some(value)
    }

    func enqueue(_ value: Any) {
        lock.lock(); defer { lock.unlock() }
        responseQueue.append(.success(value))
    }

    func enqueueFailure(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        responseQueue.append(.failure(error))
    }

    /// Suspends the (1-indexed) `callNumber`-th `respond` call until the
    /// calling `Task` is cancelled — never releases normally.
    func armGate(beforeCallNumber callNumber: Int) {
        lock.lock(); defer { lock.unlock() }
        gateBeforeCallNumber = callNumber
    }

    var hasEnteredGate: Bool {
        lock.lock(); defer { lock.unlock() }
        return enteredGateFlag
    }

    var capturedPrompts: [(instructions: String, prompt: String)] {
        lock.lock(); defer { lock.unlock() }
        return promptLog
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return promptLog.count
    }

    func availability() -> LectureNotesGenerationAvailability {
        lock.lock(); defer { lock.unlock() }
        return scriptedAvailability
    }

    var contextTokenBudget: Int {
        lock.lock(); defer { lock.unlock() }
        return scriptedContextTokenBudget
    }

    func estimatedTokenCount<Content: Generable>(
        instructions: String,
        prompt: String,
        generating: Content.Type
    ) async -> Int? {
        lock.lock(); defer { lock.unlock() }
        return tokenCountOverride ?? nil
    }

    func respond<Content: Generable>(
        instructions: String,
        prompt: String,
        generating: Content.Type
    ) async throws -> Content {
        lock.lock()
        promptLog.append((instructions, prompt))
        let callNumber = promptLog.count
        let shouldGate = gateBeforeCallNumber == callNumber
        lock.unlock()

        if shouldGate {
            lock.lock(); enteredGateFlag = true; lock.unlock()
            while !Task.isCancelled {
                await Task.yield()
            }
            try Task.checkCancellation()
        }

        lock.lock()
        guard !responseQueue.isEmpty else {
            lock.unlock()
            throw FakeFoundationModelsDriverError.noScriptedResponse
        }
        let next = responseQueue.removeFirst()
        lock.unlock()

        switch next {
        case .success(let value):
            guard let typed = value as? Content else {
                throw FakeFoundationModelsDriverError.typeMismatch
            }
            return typed
        case .failure(let error):
            throw error
        }
    }
}
