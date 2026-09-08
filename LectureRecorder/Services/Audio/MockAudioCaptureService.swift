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

    private let formatToPrepare: AVAudioFormat
    private var shouldFailNextStartStorage = false

    init(formatToPrepare: AVAudioFormat) {
        self.formatToPrepare = formatToPrepare
    }

    func setShouldFailNextStart(_ value: Bool) {
        controlQueue.sync {
            shouldFailNextStartStorage = value
        }
    }

    func prepare() throws -> AVAudioFormat {
        try controlQueue.sync {
            guard case .idle = cycleState else {
                throw MockAudioCaptureServiceError.prepareCalledFromInvalidState
            }

            cycleState = .prepared(format: formatToPrepare)
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

    func stop() async {
        let taskToAwait: Task<Void, Never>? = controlQueue.sync {
            switch cycleState {
            case .idle:
                return nil

            case .stopping:
                return inProgressStopTask

            case .prepared:
                cycleState = .idle
                return nil

            case .running(let resources):
                cycleState = .stopping
                resources.coordinator.invalidate()
                resources.gate.close()

                let gate = resources.gate

                let task = Task { [weak self] in
                    await gate.drain()

                    guard let self else {
                        return
                    }

                    self.controlQueue.sync {
                        if case .stopping = self.cycleState {
                            self.cycleState = .idle
                        }

                        self.inProgressStopTask = nil
                    }
                }

                inProgressStopTask = task
                return task
            }
        }

        await taskToAwait?.value
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

            resources.gate.close()
            resources.coordinator.reportAsyncFailure(error)
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
