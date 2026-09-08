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
        case stopping
    }

    private nonisolated final class RunningResources {
        let gate: InFlightCallbackGate
        let format: AVAudioFormat
        let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
        let coordinator: FailureCoordinator

        init(
            gate: InFlightCallbackGate,
            format: AVAudioFormat,
            onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
            coordinator: FailureCoordinator
        ) {
            self.gate = gate
            self.format = format
            self.onBuffer = onBuffer
            self.coordinator = coordinator
        }
    }

    private var cycleState: CycleState = .idle
    private var inProgressStopTask: Task<Void, Never>?
    private var inProgressStopOutcome: Error?
    private var lastCompletedOutcome: Error?

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
            lastCompletedOutcome = nil
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
            let resources = RunningResources(
                gate: gate,
                format: format,
                onBuffer: onBuffer,
                coordinator: coordinator
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
    func stop() async -> Error? {
        let taskToAwait: Task<Void, Never>?
        let outcome: Error?
        let hookToFire: (@Sendable () -> Void)?

        (taskToAwait, outcome, hookToFire) = controlQueue.sync {
            switch cycleState {
            case .idle:
                return (nil, lastCompletedOutcome, nil)

            case .stopping:
                return (inProgressStopTask, inProgressStopOutcome, didJoinInProgressStopHook)

            case .prepared:
                cycleState = .idle
                return (nil, lastCompletedOutcome, nil)

            case .running(let resources):
                cycleState = .stopping

                let closedOutcome = resources.coordinator.closeAdmission()
                resources.gate.close()

                inProgressStopOutcome = closedOutcome

                let gate = resources.gate
                let coordinator = resources.coordinator

                let task = Task { [weak self] in
                    async let bufferDrain: Void = gate.drain()
                    async let deliveryDrain: Void = coordinator.drainDelivery()
                    _ = await (bufferDrain, deliveryDrain)

                    guard let self else {
                        return
                    }

                    self.controlQueue.sync {
                        if case .stopping = self.cycleState {
                            self.cycleState = .idle
                            self.lastCompletedOutcome = closedOutcome
                        }

                        self.inProgressStopTask = nil
                        self.inProgressStopOutcome = nil
                    }
                }

                inProgressStopTask = task
                return (task, closedOutcome, didEnterStoppingHook)
            }
        }

        // Fired only after leaving controlQueue's synchronization, same
        // discipline as FailureCoordinator's delivery: test observation
        // must never run inside a lock.
        hookToFire?()

        await taskToAwait?.value
        return outcome
    }

    func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        let snapshot: (
            InFlightCallbackGate,
            @Sendable (AVAudioPCMBuffer) -> Void
        )? = controlQueue.sync {
            guard case .running(let resources) = cycleState else {
                return nil
            }

            return (resources.gate, resources.onBuffer)
        }

        guard let (gate, onBuffer) = snapshot else {
            return
        }

        guard gate.tryEnter() else {
            return
        }

        defer {
            gate.leave()
        }

        guard let copy = buffer.deepCopy() else {
            return
        }

        onBuffer(copy)
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
