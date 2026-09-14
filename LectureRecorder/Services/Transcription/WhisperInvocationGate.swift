import Foundation
import Synchronization

/// Capacity-one admission control for complete production Whisper process
/// invocations. The shared instance is used only by the production adapter;
/// tests can inject an isolated gate without affecting other tests.
nonisolated final class WhisperInvocationGate: Sendable {
    static let shared = WhisperInvocationGate()

    nonisolated struct Snapshot: Sendable, Equatable {
        let isOccupied: Bool
        let waitingCount: Int
        let acquisitionCount: Int
        let releaseCount: Int
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct Storage {
        var isOccupied = false
        var waiters: [Waiter] = []
        var acquisitionCount = 0
        var releaseCount = 0
    }

    private enum Registration {
        case acquired
        case cancelled
        case waiting
    }

    private let storage = Mutex(Storage())

    init() {
#if DEBUG
        testHooks = nil
#endif
    }

#if DEBUG
    /// Observation/barrier hooks only: never expose or resume a continuation.
    /// All hooks run outside the state mutex and are absent in Release builds.
    struct TestHooks: Sendable {
        var registered: @Sendable () -> Void = {}
        var selectedBeforeResume: @Sendable () -> Void = {}
        var returnedBeforeOwnership: @Sendable () async -> Void = {}
    }
    private let testHooks: TestHooks?

    init(testHooks: TestHooks) { self.testHooks = testHooks }
#endif

    func withPermit<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
#if DEBUG
        // Nonthrowing suspension: even cancellation here must reach the defer.
        if let testHooks { await testHooks.returnedBeforeOwnership() }
#endif
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func snapshot() -> Snapshot {
        storage.withLock {
            Snapshot(
                isOccupied: $0.isOccupied,
                waitingCount: $0.waiters.count,
                acquisitionCount: $0.acquisitionCount,
                releaseCount: $0.releaseCount
            )
        }
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registration = storage.withLock { state -> Registration in
                    if Task.isCancelled {
                        return .cancelled
                    }
                    if !state.isOccupied {
                        state.isOccupied = true
                        state.acquisitionCount += 1
                        return .acquired
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return .waiting
                }
                switch registration {
                case .acquired:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .waiting:
#if DEBUG
                    testHooks?.registered()
#endif
                    break
                }
            }
        } onCancel: {
            cancelWaiter(id: id)
        }
    }

    private func cancelWaiter(id: UUID) {
        let continuation = storage.withLock { state -> CheckedContinuation<Void, Error>? in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.waiters.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func release() {
        let continuation = storage.withLock { state -> CheckedContinuation<Void, Error>? in
            precondition(state.isOccupied, "Whisper invocation permit released without ownership.")
            state.releaseCount += 1
            if state.waiters.isEmpty {
                state.isOccupied = false
                return nil
            }
            state.acquisitionCount += 1
            return state.waiters.removeFirst().continuation
        }
        if let continuation {
#if DEBUG
            testHooks?.selectedBeforeResume()
#endif
            continuation.resume()
        }
    }
}
