import FoundationModels
import Foundation
@testable import LectureRecorder

nonisolated enum FakeFoundationModelsDriverError: Error, Equatable {
    case noScriptedResponse
    case typeMismatch
}

nonisolated struct FakeFoundationModelsSchemaRequest: Equatable, Sendable {
    var instructions: String
    var prompt: String
    var schemaDescription: String
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
    private var responseTypeLog: [String] = []
    private var tokenCountCalls = 0
    private var schemaPreflightLog: [FakeFoundationModelsSchemaRequest] = []
    private var schemaResponseLog: [FakeFoundationModelsSchemaRequest] = []
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
    private var tokenCountHandler: (@Sendable (String, String) -> Int?)?

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

    /// Supplies deterministic prompt-sensitive token counts for context
    /// packing tests. Setting this clears the constant override.
    func setTokenCountHandler(_ handler: @escaping @Sendable (String, String) -> Int?) {
        lock.lock(); defer { lock.unlock() }
        tokenCountOverride = nil
        tokenCountHandler = handler
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

    var capturedResponseTypes: [String] {
        lock.lock(); defer { lock.unlock() }
        return responseTypeLog
    }

    var tokenCountCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tokenCountCalls
    }

    var capturedSchemaPreflights: [FakeFoundationModelsSchemaRequest] {
        lock.lock(); defer { lock.unlock() }
        return schemaPreflightLog
    }

    var capturedSchemaResponses: [FakeFoundationModelsSchemaRequest] {
        lock.lock(); defer { lock.unlock() }
        return schemaResponseLog
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
        lock.lock()
        tokenCountCalls += 1
        let override = tokenCountOverride
        let handler = tokenCountHandler
        lock.unlock()
        if let override { return override }
        return handler?(instructions, prompt)
    }

    func estimatedTokenCount(
        instructions: String,
        prompt: String,
        schema: GenerationSchema
    ) async -> Int? {
        lock.lock()
        tokenCountCalls += 1
        schemaPreflightLog.append(FakeFoundationModelsSchemaRequest(
            instructions: instructions,
            prompt: prompt,
            schemaDescription: schema.debugDescription
        ))
        let override = tokenCountOverride
        let handler = tokenCountHandler
        lock.unlock()
        if let override { return override }
        return handler?(instructions, prompt)
    }

    func respond<Content: Generable>(
        instructions: String,
        prompt: String,
        generating: Content.Type
    ) async throws -> Content {
        lock.lock()
        promptLog.append((instructions, prompt))
        responseTypeLog.append(String(reflecting: Content.self))
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

    func respond(
        instructions: String,
        prompt: String,
        schema: GenerationSchema
    ) async throws -> GeneratedContent {
        lock.lock()
        promptLog.append((instructions, prompt))
        responseTypeLog.append(String(reflecting: GeneratedContent.self))
        schemaResponseLog.append(FakeFoundationModelsSchemaRequest(
            instructions: instructions,
            prompt: prompt,
            schemaDescription: schema.debugDescription
        ))
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
            if let content = value as? GeneratedContent {
                return content
            }
            if let generable = value as? any Generable {
                return generable.generatedContent
            }
            throw FakeFoundationModelsDriverError.typeMismatch
        case .failure(let error):
            throw error
        }
    }
}
