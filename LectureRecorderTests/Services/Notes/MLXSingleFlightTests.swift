import XCTest
@testable import LectureRecorder

/// A distinct object per successful load, so tests can assert that
/// callers share one loaded resource by identity.
private final class LoadedResource: Sendable {
    let loadNumber: Int
    init(loadNumber: Int) { self.loadNumber = loadNumber }
}

private struct ScriptedLoadFailure: Error, Equatable {
    let loadNumber: Int
}

/// Scriptable loader: every invocation is counted, waits on its own gate,
/// then succeeds or fails as scripted for that invocation's number.
private actor ScriptedLoader {
    private var invocationCount = 0
    private var openedGates: Set<Int> = []
    private var gateWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var failingLoadNumbers: Set<Int> = []

    var invocations: Int { invocationCount }

    func failLoad(number: Int) { failingLoadNumbers.insert(number) }

    func release(load number: Int) {
        openedGates.insert(number)
        gateWaiters.removeValue(forKey: number)?.forEach { $0.resume() }
    }

    func load() async throws -> LoadedResource {
        invocationCount += 1
        let number = invocationCount
        if !openedGates.contains(number) {
            await withCheckedContinuation { gateWaiters[number, default: []].append($0) }
        }
        if failingLoadNumbers.contains(number) { throw ScriptedLoadFailure(loadNumber: number) }
        return LoadedResource(loadNumber: number)
    }
}

final class MLXSingleFlightTests: XCTestCase {
    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    private func request(
        _ flight: MLXSingleFlight<String, LoadedResource>,
        _ loader: ScriptedLoader,
        key: String = "model"
    ) -> Task<LoadedResource, Error> {
        Task { try await flight.value(for: key) { try await loader.load() } }
    }

    // MARK: - Single-flight success

    func testConcurrentColdCallersShareExactlyOneLoad() async throws {
        let flight = MLXSingleFlight<String, LoadedResource>()
        let loader = ScriptedLoader()
        let callerCount = 8

        let callers = (0..<callerCount).map { _ in request(flight, loader) }
        await waitUntil { await flight.requestCountForTesting == callerCount }
        let invocationsWhileLoading = await loader.invocations
        XCTAssertEqual(invocationsWhileLoading, 1, "every cold caller must join the one in-flight load")

        await loader.release(load: 1)
        var results: [LoadedResource] = []
        for caller in callers { results.append(try await caller.value) }

        XCTAssertTrue(results.allSatisfy { $0 === results[0] }, "all callers must receive the same loaded resource")
        let cached = try await flight.value(for: "model") { try await loader.load() }
        XCTAssertTrue(cached === results[0], "the successful load must be cached")
        let totalInvocations = await loader.invocations
        XCTAssertEqual(totalInvocations, 1)
    }

    // MARK: - Failure and retry

    func testFailedLoadReachesEveryWaiterIsNotCachedAndALaterRetrySucceeds() async throws {
        let flight = MLXSingleFlight<String, LoadedResource>()
        let loader = ScriptedLoader()
        await loader.failLoad(number: 1)

        let failingCallers = (0..<3).map { _ in request(flight, loader) }
        await waitUntil { await flight.requestCountForTesting == 3 }
        await loader.release(load: 1)
        for caller in failingCallers {
            do {
                _ = try await caller.value
                XCTFail("every waiter of the failed load must receive its failure")
            } catch {
                XCTAssertEqual(error as? ScriptedLoadFailure, ScriptedLoadFailure(loadNumber: 1))
            }
        }
        let inFlightAfterFailure = await flight.inFlightGenerationForTesting
        XCTAssertNil(inFlightAfterFailure, "a failed load must not remain in flight")

        await loader.release(load: 2)
        let retried = try await flight.value(for: "model") { try await loader.load() }
        XCTAssertEqual(retried.loadNumber, 2, "a failure must not be cached; the next call loads again")
        let cached = try await flight.value(for: "model") { try await loader.load() }
        XCTAssertTrue(cached === retried)
        let totalInvocations = await loader.invocations
        XCTAssertEqual(totalInvocations, 2)
    }

    // MARK: - Stale generation safety

    /// Generation 1 fails; one of its waiters immediately starts generation
    /// 2; the remaining (stale) generation-1 waiters then resume. Nothing
    /// from generation 1 may clear or replace generation 2.
    func testStaleWaitersOfAFailedLoadCannotCorruptTheRetryLoad() async throws {
        let flight = MLXSingleFlight<String, LoadedResource>()
        let loader = ScriptedLoader()
        await loader.failLoad(number: 1)

        let firstWaiter = request(flight, loader)
        let staleWaiters = (0..<3).map { _ in request(flight, loader) }
        await waitUntil { await flight.requestCountForTesting == 4 }
        await loader.release(load: 1)

        do {
            _ = try await firstWaiter.value
            XCTFail("expected generation 1 to fail")
        } catch {}
        // Generation 2 starts (and stays blocked) before the stale
        // generation-1 waiters are observed to finish.
        let retryCaller = request(flight, loader)
        await waitUntil { await loader.invocations == 2 }
        let generationDuringRetry = await flight.inFlightGenerationForTesting
        XCTAssertEqual(generationDuringRetry, 2)

        for waiter in staleWaiters {
            do {
                _ = try await waiter.value
                XCTFail("stale waiters must receive generation 1's failure")
            } catch {
                XCTAssertEqual(error as? ScriptedLoadFailure, ScriptedLoadFailure(loadNumber: 1))
            }
        }
        let generationAfterStaleWaiters = await flight.inFlightGenerationForTesting
        XCTAssertEqual(generationAfterStaleWaiters, 2, "stale generation-1 waiters must not clear generation 2")

        let lateJoiner = request(flight, loader)
        await waitUntil { await flight.requestCountForTesting == 6 }
        let invocationsBeforeRelease = await loader.invocations
        XCTAssertEqual(invocationsBeforeRelease, 2, "a new caller must join generation 2, not start generation 3")

        await loader.release(load: 2)
        let retried = try await retryCaller.value
        let joined = try await lateJoiner.value
        XCTAssertEqual(retried.loadNumber, 2)
        XCTAssertTrue(joined === retried)
    }

    /// Forces the out-of-order completion directly: a superseded flight
    /// (generation 1) finishes — with a failure — while a newer flight
    /// (generation 2) is in progress. Generation 1's completion must not
    /// reset or replace generation 2.
    func testCompletionOfASupersededFlightLeavesTheNewerFlightIntact() async throws {
        let flight = MLXSingleFlight<String, LoadedResource>()
        let loader = ScriptedLoader()
        await loader.failLoad(number: 1)

        let oldKeyCaller = request(flight, loader, key: "revision-a")
        await waitUntil { await loader.invocations == 1 }
        let newKeyCaller = request(flight, loader, key: "revision-b")
        await waitUntil { await loader.invocations == 2 }

        await loader.release(load: 1)
        do {
            _ = try await oldKeyCaller.value
            XCTFail("expected generation 1 to fail")
        } catch {}
        let generationAfterStaleFailure = await flight.inFlightGenerationForTesting
        XCTAssertEqual(generationAfterStaleFailure, 2, "the superseded flight's failure must not reset the newer flight")

        let joiner = request(flight, loader, key: "revision-b")
        await waitUntil { await flight.requestCountForTesting == 3 }
        await loader.release(load: 2)
        let newValue = try await newKeyCaller.value
        let joinedValue = try await joiner.value
        XCTAssertTrue(joinedValue === newValue)
        let invocations = await loader.invocations
        XCTAssertEqual(invocations, 2)
    }

    func testSuccessForOneKeyIsNeverReturnedForADifferentKey() async throws {
        let flight = MLXSingleFlight<String, LoadedResource>()
        let loader = ScriptedLoader()
        await loader.release(load: 1)
        await loader.release(load: 2)

        let first = try await flight.value(for: "identity-x") { try await loader.load() }
        let second = try await flight.value(for: "identity-y") { try await loader.load() }
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.loadNumber, 2)
    }

    // MARK: - Waiter cancellation

    func testCancellingOneWaiterNeitherCancelsNorPoisonsTheSharedLoad() async throws {
        let flight = MLXSingleFlight<String, LoadedResource>()
        let loader = ScriptedLoader()
        let inferenceStarts = InferenceRecorder()

        func caller(_ name: String) -> Task<Void, Error> {
            Task {
                _ = try await flight.value(for: "model") { try await loader.load() }
                // Stands in for inference, which may begin only once the
                // caller is past the shared load and still wanted.
                await inferenceStarts.record(name)
            }
        }
        let cancelledCaller = caller("cancelled")
        let survivingCaller = caller("surviving")
        await waitUntil { await flight.requestCountForTesting == 2 }

        cancelledCaller.cancel()
        await loader.release(load: 1)

        do {
            try await cancelledCaller.value
            XCTFail("the cancelled waiter must not proceed past the shared load")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        try await survivingCaller.value

        let started = await inferenceStarts.names
        XCTAssertEqual(started, ["surviving"])
        let invocations = await loader.invocations
        XCTAssertEqual(invocations, 1)
        let cached = try await flight.value(for: "model") { try await loader.load() }
        XCTAssertEqual(cached.loadNumber, 1, "the load shared with a cancelled waiter must still be cached")
    }

    func testAnAlreadyCancelledCallerNeverStartsALoad() async throws {
        let flight = MLXSingleFlight<String, LoadedResource>()
        let loader = ScriptedLoader()

        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await flight.value(for: "model") { try await loader.load() }
        }
        do {
            _ = try await caller.value
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let invocations = await loader.invocations
        XCTAssertEqual(invocations, 0)
        let inFlight = await flight.inFlightGenerationForTesting
        XCTAssertNil(inFlight)
    }
}

private actor InferenceRecorder {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}
