import Foundation
import Synchronization
import XCTest
@testable import LectureRecorder

final class WhisperInvocationGateTests: XCTestCase {
    private nonisolated final class Signals: Sendable {
        private struct State {
            var count = 0
            var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        }
        private let state = Mutex(State())
        @discardableResult func signal() -> Int {
            let ready = state.withLock { state -> (Int, [CheckedContinuation<Void, Never>]) in
                state.count += 1
                let ready = state.waiters.filter { $0.0 <= state.count }.map(\.1)
                state.waiters.removeAll { $0.0 <= state.count }
                return (state.count, ready)
            }
            ready.1.forEach { $0.resume() }
            return ready.0
        }
        func wait(_ count: Int = 1) async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state in
                    if state.count >= count { return true }
                    state.waiters.append((count, continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    private nonisolated final class Region: Sendable {
        private let state = Mutex((active: 0, maximum: 0, entries: 0))
        func enter() { state.withLock { $0.active += 1; $0.entries += 1; $0.maximum = max($0.maximum, $0.active) } }
        func leave() { state.withLock { $0.active -= 1 } }
        var values: (active: Int, maximum: Int, entries: Int) { state.withLock { $0 } }
    }

    func testCancellationAfterSelectionBeforeContinuationResumeTransfersExactlyOnce() async throws {
        try await exerciseTransfer(cancelBeforeResume: true)
    }

    func testCancellationAfterResumeBeforeCallerOwnershipTransfersExactlyOnce() async throws {
        try await exerciseTransfer(cancelBeforeResume: false)
    }

    private func exerciseTransfer(cancelBeforeResume: Bool) async throws {
        let registered = Signals(), selections = Signals(), returned = Signals()
        let boundary = Signals(), continueOwnership = Signals()
        let holderEntered = Signals(), holderRelease = Signals()
        let thirdEntered = Signals(), thirdRelease = Signals()
        let selectedTask = Mutex<Task<Void, Error>?>(nil)
        let region = Region(), cancelledOperation = Counter()
        let gate = WhisperInvocationGate(testHooks: .init(
            registered: { registered.signal() },
            selectedBeforeResume: {
                if selections.signal() == 1 && cancelBeforeResume {
                    selectedTask.withLock { $0 }?.cancel()
                }
            },
            returnedBeforeOwnership: {
                if returned.signal() == 2 {
                    boundary.signal()
                    await continueOwnership.wait()
                }
            }
        ))
        let holder = Task {
            try await gate.withPermit {
                region.enter(); defer { region.leave() }
                holderEntered.signal()
                await holderRelease.wait()
            }
        }
        await holderEntered.wait()
        let selected = Task {
            try await gate.withPermit { cancelledOperation.increment() }
        }
        selectedTask.withLock { $0 = selected }
        await registered.wait()
        let third = Task {
            try await gate.withPermit {
                region.enter(); defer { region.leave() }
                thirdEntered.signal()
                await thirdRelease.wait()
            }
        }
        await registered.wait(2)
        XCTAssertEqual(gate.snapshot().waitingCount, 2)
        holderRelease.signal()
        await boundary.wait()
        // The selected continuation has returned, but the caller has not yet
        // installed its ownership defer. The third waiter cannot enter here.
        if !cancelBeforeResume { selected.cancel() }
        XCTAssertTrue(selected.isCancelled)
        XCTAssertEqual(gate.snapshot(), .init(isOccupied: true, waitingCount: 1, acquisitionCount: 2, releaseCount: 1))
        XCTAssertEqual(region.values.entries, 1)
        XCTAssertEqual(cancelledOperation.count, 0)
        continueOwnership.signal()
        do { try await selected.value; XCTFail("Selected waiter must cancel") }
        catch is CancellationError {}
        try await holder.value
        await thirdEntered.wait()
        XCTAssertEqual(gate.snapshot(), .init(isOccupied: true, waitingCount: 0, acquisitionCount: 3, releaseCount: 2))
        let subsequent = Task {
            try await gate.withPermit { region.enter(); region.leave(); return 42 }
        }
        await registered.wait(3)
        XCTAssertEqual(region.values.entries, 2)
        XCTAssertEqual(region.values.active, 1)
        thirdRelease.signal()
        try await third.value
        let value = try await subsequent.value
        XCTAssertEqual(value, 42)
        XCTAssertEqual(region.values.maximum, 1)
        XCTAssertEqual(region.values.active, 0)
        XCTAssertEqual(region.values.entries, 3)
        XCTAssertEqual(cancelledOperation.count, 0)
        XCTAssertEqual(gate.snapshot(), .init(isOccupied: false, waitingCount: 0, acquisitionCount: 4, releaseCount: 4))
    }

    private actor BlockingProbe {
        private(set) var starts = 0
        private(set) var active = 0
        private(set) var maximumActive = 0
        private var releases = 0

        func run() async throws {
            starts += 1
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            while releases == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
            releases -= 1
        }

        func release(_ count: Int = 1) { releases += count }
    }

    private struct BlockingRunner: LocalProcessRunning {
        let probe: BlockingProbe
        func run(_ request: ProcessInvocationRequest) async -> Result<ProcessRunResult, ProcessRunFailure> {
            do {
                try await probe.run()
                return .failure(.launchFailed(underlying: "controlled completion"))
            } catch {
                return .failure(.cancelled)
            }
        }
    }

    private final class Counter: Sendable {
        private let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    func testCapacityOneWaiterProceedsAfterReleaseWithoutOverlap() async throws {
        let gate = WhisperInvocationGate()
        let probe = BlockingProbe()
        let first = Task { try await gate.withPermit { try await probe.run() } }
        try await waitForStarts(1, probe: probe)
        let second = Task { try await gate.withPermit { try await probe.run() } }
        for _ in 0..<100 { await Task.yield() }
        let startsWhileHeld = await probe.starts
        let maximumWhileHeld = await probe.maximumActive
        XCTAssertEqual(startsWhileHeld, 1)
        XCTAssertEqual(maximumWhileHeld, 1)
        await probe.release()
        try await waitForStarts(2, probe: probe)
        await probe.release()
        _ = try await first.value
        _ = try await second.value
        let finalMaximum = await probe.maximumActive
        XCTAssertEqual(finalMaximum, 1)
        XCTAssertEqual(gate.snapshot(), .init(isOccupied: false, waitingCount: 0, acquisitionCount: 2, releaseCount: 2))
    }

    func testCancellationWhileWaitingRemovesWaiterWithoutConsumingPermitOrRunningPreflight() async throws {
        let gate = WhisperInvocationGate()
        let probe = BlockingProbe()
        let preflight = Counter()
        let holder = Task { try await gate.withPermit { try await probe.run() } }
        try await waitForStarts(1, probe: probe)
        let waiter = Task {
            try await gate.withPermit {
                preflight.increment()
                return 1
            }
        }
        try await waitForWaiters(1, gate: gate)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(preflight.count, 0)
        XCTAssertEqual(gate.snapshot().waitingCount, 0)
        await probe.release()
        _ = try await holder.value
        XCTAssertEqual(gate.snapshot(), .init(isOccupied: false, waitingCount: 0, acquisitionCount: 1, releaseCount: 1))
    }

    func testCancellationWhileHoldingReleasesExactlyOnceAndNextWaiterRuns() async throws {
        let gate = WhisperInvocationGate()
        let probe = BlockingProbe()
        let holder = Task { try await gate.withPermit { try await probe.run() } }
        try await waitForStarts(1, probe: probe)
        holder.cancel()
        do {
            _ = try await holder.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        let value = try await gate.withPermit { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(gate.snapshot(), .init(isOccupied: false, waitingCount: 0, acquisitionCount: 2, releaseCount: 2))
    }

    func testThrownLaunchTimeoutAndMalformedFailuresCannotLeakOrInflatePermit() async {
        enum Controlled: Error { case launch, timeout, malformed }
        let gate = WhisperInvocationGate()
        for failure in [Controlled.launch, .timeout, .malformed] {
            do {
                _ = try await gate.withPermit { () async throws -> Int in throw failure }
                XCTFail("Expected controlled failure")
            } catch {
            }
        }
        XCTAssertEqual(gate.snapshot(), .init(isOccupied: false, waitingCount: 0, acquisitionCount: 3, releaseCount: 3))
    }

    func testSeparateProductionTranscriberInstancesShareDefaultGate() async throws {
        let probe = BlockingProbe()
        let first = makeTranscriber(runner: BlockingRunner(probe: probe))
        let second = makeTranscriber(runner: BlockingRunner(probe: probe))
        let source1 = makeSource(sequence: 1)
        let source2 = makeSource(sequence: 2)
        let task1 = Task { try await first.transcribe(audioURL: URL(fileURLWithPath: "/tmp/\(source1.chunkFileName)"), source: source1) }
        try await waitForStarts(1, probe: probe)
        let task2 = Task { try await second.transcribe(audioURL: URL(fileURLWithPath: "/tmp/\(source2.chunkFileName)"), source: source2) }
        for _ in 0..<100 { await Task.yield() }
        let startsWhileHeld = await probe.starts
        XCTAssertEqual(startsWhileHeld, 1)
        await probe.release()
        try await waitForStarts(2, probe: probe)
        await probe.release()
        _ = await task1.result
        _ = await task2.result
        let maximum = await probe.maximumActive
        XCTAssertEqual(maximum, 1)
    }

    func testInjectedGatesAreIsolated() async throws {
        let probe = BlockingProbe()
        let first = makeTranscriber(runner: BlockingRunner(probe: probe), gate: WhisperInvocationGate())
        let second = makeTranscriber(runner: BlockingRunner(probe: probe), gate: WhisperInvocationGate())
        let source1 = makeSource(sequence: 3)
        let source2 = makeSource(sequence: 4)
        let task1 = Task { try await first.transcribe(audioURL: URL(fileURLWithPath: "/tmp/\(source1.chunkFileName)"), source: source1) }
        let task2 = Task { try await second.transcribe(audioURL: URL(fileURLWithPath: "/tmp/\(source2.chunkFileName)"), source: source2) }
        try await waitForStarts(2, probe: probe)
        let maximum = await probe.maximumActive
        XCTAssertEqual(maximum, 2)
        await probe.release(2)
        _ = await task1.result
        _ = await task2.result
    }

    private func makeTranscriber(
        runner: any LocalProcessRunning,
        gate: WhisperInvocationGate? = nil
    ) -> WhisperProcessTranscriber {
        if let gate {
            return WhisperProcessTranscriber(
                processRunner: runner,
                applicationSupportRoot: { URL(fileURLWithPath: "/tmp/app-support") },
                preflightModel: { _ in },
                invocationGate: gate
            )
        }
        return WhisperProcessTranscriber(
            processRunner: runner,
            applicationSupportRoot: { URL(fileURLWithPath: "/tmp/app-support") },
            preflightModel: { _ in }
        )
    }

    private func makeSource(sequence: Int) -> TranscriptionSourceSnapshot {
        TranscriptionSourceSnapshot(
            sessionID: UUID(), chunkSequenceNumber: sequence,
            chunkFileName: String(format: "chunk_%06d.caf", sequence),
            frameCount: 1, startOffsetSeconds: 0, durationSeconds: 1.0 / 16_000,
            audioFormat: AudioFormatDescriptor(
                sampleRate: 16_000, channelCount: 1, bitsPerChannel: 32,
                formatIdentifier: "lpcm-float32"
            )
        )
    }

    private func waitForStarts(_ expected: Int, probe: BlockingProbe) async throws {
        for _ in 0..<10_000 {
            if await probe.starts >= expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(expected) starts")
    }

    private func waitForWaiters(_ expected: Int, gate: WhisperInvocationGate) async throws {
        for _ in 0..<10_000 {
            if gate.snapshot().waitingCount == expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(expected) gate waiters")
    }
}
