//
//  MockAudioCaptureService.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/7/26.
//


import AVFoundation
import Foundation

#if DEBUG
/// Hardware-free test double for AudioCapturing.
///
/// Mutable state is confined to controlQueue. A fresh single-cycle
/// InFlightCallbackGate is created for every start().
nonisolated final class MockAudioCaptureService: AudioCapturing, @unchecked Sendable {
    private let controlQueue = DispatchQueue(
        label: "com.lecturerecorder.mockaudiocaptureservice.control"
    )

    private nonisolated enum CycleState {
        case idle
        case prepared(format: AVAudioFormat)
        case running(RunningResources)
        case stopping(Task<CaptureStopOutcome, Never>)
    }

    private nonisolated final class RunningResources {
        let gate: InFlightCallbackGate
        let format: AVAudioFormat
        let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
        let coordinator: FailureCoordinator
        let copyFailureCounter: CopyFailureCounter

        init(
            gate: InFlightCallbackGate,
            format: AVAudioFormat,
            onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
            coordinator: FailureCoordinator,
            copyFailureCounter: CopyFailureCounter
        ) {
            self.gate = gate
            self.format = format
            self.onBuffer = onBuffer
            self.coordinator = coordinator
            self.copyFailureCounter = copyFailureCounter
        }
    }

    private var cycleState: CycleState = .idle
    private var lastCompletedOutcome = CaptureStopOutcome(
        failure: nil,
        observedCopyFailureCount: 0
    )

    private let formatToPrepare: AVAudioFormat
    private var shouldFailNextStartStorage = false

    // Test-only observation seams (below), so tests can prove ordering
    // deterministically instead of relying on a fixed delay before
    // releasing a held callback. Never used outside this DEBUG-only
    // mock, and never influence production control flow.
    private var didEnterStoppingHook: (@Sendable () -> Void)?
    private var didJoinInProgressStopHook: (@Sendable () -> Void)?

    init(formatToPrepare: AVAudioFormat) {
        self.formatToPrepare = formatToPrepare
    }

    func setShouldFailNextStart(_ value: Bool) {
        controlQueue.sync {
            shouldFailNextStartStorage = value
        }
    }

    /// Test-only seam: fires once this cycle's `stop()` call has
    /// synchronously transitioned `cycleState` to `.stopping` — i.e. once
    /// it has entered its draining path. This confirms the transition
    /// happened; it does not guarantee the fire happens before the
    /// asynchronous draining task itself begins running, since that task
    /// is started concurrently and may already be executing by the time
    /// this hook is invoked.
    func setDidEnterStoppingHookForTesting(
        _ hook: @escaping @Sendable () -> Void
    ) {
        controlQueue.sync {
            didEnterStoppingHook = hook
        }
    }

    /// Test-only seam: fires exactly once a `stop()` call observes an
    /// already-`.stopping` cycle and joins its in-progress drain, rather
    /// than starting a new one.
    func setDidJoinInProgressStopHookForTesting(
        _ hook: @escaping @Sendable () -> Void
    ) {
        controlQueue.sync {
            didJoinInProgressStopHook = hook
        }
    }

    func prepare() throws -> AVAudioFormat {
        try controlQueue.sync {
            guard case .idle = cycleState else {
                throw MockAudioCaptureServiceError.prepareCalledFromInvalidState
            }

            cycleState = .prepared(format: formatToPrepare)
            lastCompletedOutcome = CaptureStopOutcome(
                failure: nil,
                observedCopyFailureCount: 0
            )
            return formatToPrepare
        }
    }

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        try controlQueue.sync {
            guard case .prepared(let format) = cycleState else {
                throw MockAudioCaptureServiceError.startCalledFromInvalidState
            }

            let gate = InFlightCallbackGate()
            gate.open()

            let coordinator = FailureCoordinator()
            let copyFailureCounter = CopyFailureCounter()
            let resources = RunningResources(
                gate: gate,
                format: format,
                onBuffer: onBuffer,
                coordinator: coordinator,
                copyFailureCounter: copyFailureCounter
            )

            cycleState = .running(resources)

            if shouldFailNextStartStorage {
                shouldFailNextStartStorage = false
                throw MockAudioCaptureServiceError.simulatedStartFailure
            }

            coordinator.markCommitted(onFailure: onFailure)
        }
    }

    @discardableResult
    func stop() async -> CaptureStopOutcome {
        enum Action {
            case returnImmediately(CaptureStopOutcome)
            case awaitTask(Task<CaptureStopOutcome, Never>)
        }

        let action: Action
        let hookToFire: (@Sendable () -> Void)?

        (action, hookToFire) = controlQueue.sync {
            switch cycleState {
            case .idle:
                return (.returnImmediately(lastCompletedOutcome), nil)

            case .stopping(let task):
                return (.awaitTask(task), didJoinInProgressStopHook)

            case .prepared:
                cycleState = .idle
                return (.returnImmediately(lastCompletedOutcome), nil)

            case .running(let resources):
                let closedFailure = resources.coordinator.closeAdmission()
                resources.gate.close()

                let gate = resources.gate
                let coordinator = resources.coordinator
                let copyFailureCounter = resources.copyFailureCounter

                let task = Task<CaptureStopOutcome, Never> { [weak self] in
                    async let bufferDrain: Void = gate.drain()
                    async let deliveryDrain: Void = coordinator.drainDelivery()
                    _ = await (bufferDrain, deliveryDrain)

                    let outcome = CaptureStopOutcome(
                        failure: closedFailure,
                        observedCopyFailureCount: copyFailureCounter.load()
                    )

                    guard let self else {
                        return outcome
                    }

                    self.controlQueue.sync {
                        if case .stopping = self.cycleState {
                            self.cycleState = .idle
                            self.lastCompletedOutcome = outcome
                        }
                    }

                    return outcome
                }

                cycleState = .stopping(task)
                return (.awaitTask(task), didEnterStoppingHook)
            }
        }

        // Fired only after leaving controlQueue's synchronization, same
        // discipline as FailureCoordinator's delivery: test observation
        // must never run inside a lock.
        hookToFire?()

        switch action {
        case .returnImmediately(let outcome):
            return outcome
        case .awaitTask(let task):
            return await task.value
        }
    }

    func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        let snapshot: (
            InFlightCallbackGate,
            CopyFailureCounter,
            @Sendable (AVAudioPCMBuffer) -> Void
        )? = controlQueue.sync {
            guard case .running(let resources) = cycleState else {
                return nil
            }

            return (resources.gate, resources.copyFailureCounter, resources.onBuffer)
        }

        guard let (gate, copyFailureCounter, onBuffer) = snapshot else {
            return
        }

        guard gate.tryEnter() else {
            return
        }

        defer {
            gate.leave()
        }

        handleCopiedBuffer(
            buffer.deepCopy(),
            copyFailureCounter: copyFailureCounter,
            onBuffer: onBuffer
        )
    }

    /// Test-only seam: enters the same admission gate as `injectBuffer`,
    /// but passes `nil` straight to the shared `handleCopiedBuffer` —
    /// the same handler the production tap and `injectBuffer` use —
    /// instead of a real deep copy. Proves the failure-accounting/
    /// no-handoff branch deterministically, without needing to
    /// construct an actually-malformed buffer.
    func injectBufferForcingCopyFailure(_ buffer: AVAudioPCMBuffer) {
        let snapshot: (
            InFlightCallbackGate,
            CopyFailureCounter,
            @Sendable (AVAudioPCMBuffer) -> Void
        )? = controlQueue.sync {
            guard case .running(let resources) = cycleState else {
                return nil
            }

            return (resources.gate, resources.copyFailureCounter, resources.onBuffer)
        }

        guard let (gate, copyFailureCounter, onBuffer) = snapshot else {
            return
        }

        guard gate.tryEnter() else {
            return
        }

        defer {
            gate.leave()
        }

        handleCopiedBuffer(
            nil,
            copyFailureCounter: copyFailureCounter,
            onBuffer: onBuffer
        )
    }

    /// Test-only seam: same admission path, but blocks — after calling
    /// `onCopyStarted` — until `releaseCopy` is signaled, remaining
    /// admitted (the gate is not left) the entire time, then forces the
    /// copy to fail via the same shared `handleCopiedBuffer`. Lets tests
    /// prove `stop()` waits for a copy failure that resolves only after
    /// `stop()` has already begun draining, and that the failure is
    /// still counted. Must be called from a background thread — it
    /// blocks synchronously on `releaseCopy`.
    func injectBufferForcingCopyFailureBlockingUntilReleased(
        _ buffer: AVAudioPCMBuffer,
        onCopyStarted: @escaping @Sendable () -> Void,
        releaseCopy: DispatchSemaphore
    ) {
        let snapshot: (
            InFlightCallbackGate,
            CopyFailureCounter,
            @Sendable (AVAudioPCMBuffer) -> Void
        )? = controlQueue.sync {
            guard case .running(let resources) = cycleState else {
                return nil
            }

            return (resources.gate, resources.copyFailureCounter, resources.onBuffer)
        }

        guard let (gate, copyFailureCounter, onBuffer) = snapshot else {
            return
        }

        guard gate.tryEnter() else {
            return
        }

        defer {
            gate.leave()
        }

        onCopyStarted()
        releaseCopy.wait()

        handleCopiedBuffer(
            nil,
            copyFailureCounter: copyFailureCounter,
            onBuffer: onBuffer
        )
    }

    func simulateAsyncFailure(_ error: Error) {
        controlQueue.sync {
            guard case .running(let resources) = cycleState else {
                return
            }

            // Gate closure happens only as the first-acceptance side
            // effect of reportFailure — never independently.
            resources.coordinator.reportFailure(error) {
                resources.gate.close()
            }
        }
    }
}

nonisolated enum MockAudioCaptureServiceError: LocalizedError, Sendable {
    case prepareCalledFromInvalidState
    case startCalledFromInvalidState
    case simulatedStartFailure

    var errorDescription: String? {
        switch self {
        case .prepareCalledFromInvalidState:
            return "prepare() may only be called from the idle state."
        case .startCalledFromInvalidState:
            return "start() may only be called immediately after prepare()."
        case .simulatedStartFailure:
            return "Simulated start failure."
        }
    }
}
#endif
