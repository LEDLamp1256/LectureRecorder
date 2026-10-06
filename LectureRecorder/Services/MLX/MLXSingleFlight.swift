import Foundation

/// Runs at most one in-flight `operation` per key and caches its successful
/// result, so concurrent cold callers (e.g. Notes and Summary both reaching
/// the first MLX model load) share exactly one underlying invocation.
///
/// Reentrancy: every state transition happens synchronously on this actor
/// between suspension points, and the only post-await transition
/// (`finish`) is guarded by the flight's generation number. The shared
/// task itself performs `finish` before any waiter can resume from it, so
/// waiters never mutate state, and a flight that was superseded (by a new
/// key, or a retry after failure) can never clear or overwrite the newer
/// flight's state.
///
/// Failure: a failed flight returns to `.idle` and is never cached; the
/// next caller starts a fresh flight. Every waiter of the failed flight
/// receives the same error.
///
/// Cancellation: the shared work runs in its own unstructured task, so
/// cancelling one waiter never cancels the work other waiters depend on.
/// Each caller checks its own cancellation before joining or starting a
/// flight and again after the shared result arrives, so a cancelled
/// caller never proceeds with a result it no longer wants. A cancelled
/// waiter still remains suspended until the shared work finishes (the
/// underlying work — model verification/loading — is not itself
/// cancellable).
actor MLXSingleFlight<Key: Equatable & Sendable, Value: Sendable> {
    private enum State {
        case idle
        case inFlight(key: Key, generation: UInt64, task: Task<Value, Error>)
        case loaded(key: Key, value: Value)
    }

    private var state: State = .idle
    private var lastGeneration: UInt64 = 0
    private var requestCount = 0

    init() {}

    /// The cached value for `key`, the result of the flight already
    /// running for `key`, or the result of a new flight running
    /// `operation`. `operation` runs off this actor, in a task owned by
    /// the flight rather than by any one caller.
    func value(
        for key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        requestCount += 1

        let task: Task<Value, Error>
        switch state {
        case .loaded(let loadedKey, let value) where loadedKey == key:
            return value
        case .inFlight(let inFlightKey, _, let inFlightTask) where inFlightKey == key:
            task = inFlightTask
        case .idle, .loaded, .inFlight:
            task = startFlight(key: key, operation: operation)
        }

        let value = try await task.value
        try Task.checkCancellation()
        return value
    }

    private func startFlight(
        key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) -> Task<Value, Error> {
        lastGeneration += 1
        let generation = lastGeneration
        let task = Task.detached(priority: Task.currentPriority) { [weak self] () async throws -> Value in
            let result: Result<Value, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            await self?.finish(generation: generation, key: key, result: result)
            return try result.get()
        }
        state = .inFlight(key: key, generation: generation, task: task)
        return task
    }

    private func finish(generation: UInt64, key: Key, result: Result<Value, Error>) {
        guard case .inFlight(_, let currentGeneration, _) = state, currentGeneration == generation else {
            return
        }
        switch result {
        case .success(let value):
            state = .loaded(key: key, value: value)
        case .failure:
            state = .idle
        }
    }

    // MARK: - Test observation

    /// The generation number of the flight currently in progress, if any —
    /// observation only, never consulted by production logic.
    var inFlightGenerationForTesting: UInt64? {
        if case .inFlight(_, let generation, _) = state { return generation }
        return nil
    }

    /// How many uncancelled `value(for:operation:)` calls have reached this
    /// actor, so tests can wait until every caller has joined a flight.
    var requestCountForTesting: Int { requestCount }
}
