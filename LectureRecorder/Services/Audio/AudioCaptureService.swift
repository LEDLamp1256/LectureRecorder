//
//  AudioCaptureServiceError.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/7/26.
//


import AVFoundation
import Foundation
import OSLog

nonisolated enum AudioCaptureServiceError: LocalizedError, Sendable {
    case prepareCalledFromInvalidState
    case startCalledFromInvalidState
    case invalidHardwareFormat(sampleRate: Double, channelCount: UInt32)
    case sampleRateConversionDetected(inputRate: Double, outputRate: Double)
    case channelCountConversionDetected(inputChannels: UInt32, outputChannels: UInt32)
    case unsupportedProcessingFormat(String)
    case formatChangedSincePrepare(prepared: String, current: String)
    case configurationChangedDuringRecording
    case engineStartFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .prepareCalledFromInvalidState:
            return "prepare() may only be called from the idle state — call stop() before preparing a new cycle."
        case .startCalledFromInvalidState:
            return "start() may only be called immediately after a successful prepare()."
        case .invalidHardwareFormat(let sampleRate, let channelCount):
            return "Input hardware reported an invalid format (sampleRate=\(sampleRate), channelCount=\(channelCount))."
        case .sampleRateConversionDetected(let inputRate, let outputRate):
            return "Refusing to capture: tap format (\(outputRate)Hz) differs from input hardware format (\(inputRate)Hz)."
        case .channelCountConversionDetected(let inputChannels, let outputChannels):
            return "Refusing to capture: tap channel count (\(outputChannels)) differs from input hardware channel count (\(inputChannels))."
        case .unsupportedProcessingFormat(let description):
            return "Input format is not usable as a chunk-writing format: \(description)"
        case .formatChangedSincePrepare(let prepared, let current):
            return "Input format changed between prepare() and start() — prepared \(prepared), now \(current)."
        case .configurationChangedDuringRecording:
            return "Audio input configuration changed while recording was active."
        case .engineStartFailed(let underlying):
            return "AVAudioEngine failed to start: \(underlying)"
        }
    }
}

nonisolated final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    private let controlQueue = DispatchQueue(
        label: "com.lecturerecorder.audiocaptureservice.control"
    )

    private nonisolated enum CycleState {
        case idle
        case prepared(engine: AVAudioEngine, format: AVAudioFormat)
        case running(RunningResources)
        case stopping
    }

    private nonisolated final class RunningResources {
        let engine: AVAudioEngine
        let gate: InFlightCallbackGate
        let format: AVAudioFormat
        let coordinator: FailureCoordinator
        var configObserver: NSObjectProtocol?

        init(
            engine: AVAudioEngine,
            gate: InFlightCallbackGate,
            format: AVAudioFormat,
            coordinator: FailureCoordinator
        ) {
            self.engine = engine
            self.gate = gate
            self.format = format
            self.coordinator = coordinator
        }
    }

    private var cycleState: CycleState = .idle
    private var inProgressStopTask: Task<Void, Never>?
    private var inProgressStopOutcome: Error?
    private var lastCompletedOutcome: Error?

    init() {}

    func prepare() throws -> AVAudioFormat {
        try controlQueue.sync {
            guard case .idle = cycleState else {
                throw AudioCaptureServiceError.prepareCalledFromInvalidState
            }

            let engine = AVAudioEngine()
            engine.prepare()

            let format = try Self.negotiateAndValidateFormat(
                inputNode: engine.inputNode
            )

            cycleState = .prepared(
                engine: engine,
                format: format
            )
            lastCompletedOutcome = nil

            Log.audio.info(
                "AudioCaptureService prepared: \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch"
            )

            return format
        }
    }

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        try controlQueue.sync {
            guard case .prepared(let engine, let preparedFormat) = cycleState else {
                throw AudioCaptureServiceError.startCalledFromInvalidState
            }

            let currentFormat = try Self.negotiateAndValidateFormat(
                inputNode: engine.inputNode
            )

            guard formatsMatch(preparedFormat, currentFormat) else {
                throw AudioCaptureServiceError.formatChangedSincePrepare(
                    prepared: Self.describe(preparedFormat),
                    current: Self.describe(currentFormat)
                )
            }

            let gate = InFlightCallbackGate()
            gate.open()

            let coordinator = FailureCoordinator()
            let resources = RunningResources(
                engine: engine,
                gate: gate,
                format: preparedFormat,
                coordinator: coordinator
            )

            // Realtime path: admission -> copy -> handoff -> leave.
            // No logging, I/O, await, MainActor hop, or blocking primitive.
            engine.inputNode.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: nil
            ) { buffer, _ in
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

            resources.configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [gate, coordinator] _ in
                // Gate closure happens only as the first-acceptance side
                // effect of reportFailure — never independently.
                coordinator.reportFailure(
                    AudioCaptureServiceError.configurationChangedDuringRecording
                ) {
                    gate.close()
                }
            }

            cycleState = .running(resources)

            do {
                try engine.start()
            } catch {
                throw AudioCaptureServiceError.engineStartFailed(
                    underlying: error.localizedDescription
                )
            }

            coordinator.markCommitted(
                onFailure: onFailure
            )

            Log.audio.info("AudioCaptureService started.")
        }
    }

    @discardableResult
    func stop() async -> Error? {
        let taskToAwait: Task<Void, Never>?
        let outcome: Error?

        (taskToAwait, outcome) = controlQueue.sync {
            switch cycleState {
            case .idle:
                return (nil, lastCompletedOutcome)

            case .stopping:
                return (inProgressStopTask, inProgressStopOutcome)

            case .prepared(let engine, _):
                engine.stop()
                cycleState = .idle
                return (nil, lastCompletedOutcome)

            case .running(let resources):
                cycleState = .stopping

                if let token = resources.configObserver {
                    NotificationCenter.default.removeObserver(token)
                }

                // Close failure admission before tearing anything else
                // down, so the returned outcome for this cycle is fixed
                // the moment it's known — any failure reported after
                // this point is rejected by the coordinator.
                let closedOutcome = resources.coordinator.closeAdmission()
                resources.gate.close()
                resources.engine.inputNode.removeTap(onBus: 0)
                resources.engine.stop()

                inProgressStopOutcome = closedOutcome

                let gate = resources.gate
                let coordinator = resources.coordinator

                // weak self is safe here: closedOutcome is already
                // captured locally and returned to this stop() call
                // regardless of whether self survives to run the
                // continuation below. If self is gone, no one can
                // observe cycleState again anyway.
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
                return (task, closedOutcome)
            }
        }

        await taskToAwait?.value
        return outcome
    }

    private static func negotiateAndValidateFormat(
        inputNode: AVAudioInputNode
    ) throws -> AVAudioFormat {
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        let tapFormat = inputNode.outputFormat(forBus: 0)

        guard
            hardwareFormat.sampleRate > 0,
            hardwareFormat.channelCount > 0
        else {
            throw AudioCaptureServiceError.invalidHardwareFormat(
                sampleRate: hardwareFormat.sampleRate,
                channelCount: hardwareFormat.channelCount
            )
        }

        guard tapFormat.sampleRate == hardwareFormat.sampleRate else {
            throw AudioCaptureServiceError.sampleRateConversionDetected(
                inputRate: hardwareFormat.sampleRate,
                outputRate: tapFormat.sampleRate
            )
        }

        guard tapFormat.channelCount == hardwareFormat.channelCount else {
            throw AudioCaptureServiceError.channelCountConversionDetected(
                inputChannels: hardwareFormat.channelCount,
                outputChannels: tapFormat.channelCount
            )
        }

        guard
            tapFormat.commonFormat == .pcmFormatFloat32,
            !tapFormat.isInterleaved
        else {
            throw AudioCaptureServiceError.unsupportedProcessingFormat(
                "commonFormat=\(tapFormat.commonFormat.rawValue) interleaved=\(tapFormat.isInterleaved)"
            )
        }

        return tapFormat
    }

    private func formatsMatch(
        _ lhs: AVAudioFormat,
        _ rhs: AVAudioFormat
    ) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func describe(
        _ format: AVAudioFormat
    ) -> String {
        "\(format.sampleRate)Hz/\(format.channelCount)ch"
    }
}

/// Serializes admission of at most one asynchronous capture failure per
/// recording cycle and hands it to the committed `onFailure` handler
/// exactly once.
///
/// A cycle has two independent things racing against each other: failure
/// admission (`reportFailure` / `closeAdmission`) and commitment of the
/// external failure handler (`markCommitted`, called once `start()` has
/// successfully committed to running). Whichever happens first is
/// remembered; delivery happens exactly once, as soon as both a retained
/// failure and a committed handler exist.
///
/// Delivery of the claimed handler is tracked, not fire-and-forget: the
/// moment a call claims the single allowed delivery, it enters
/// `deliveryGroup` inside the same synchronized state transition that
/// claims it, and only leaves after the handler invocation — run on a
/// dedicated `deliveryQueue`, never the state queue above — returns.
/// `drainDelivery()` lets a caller (e.g. `stop()`) await that completion
/// without a blocking wait, so admission can never be observed closed
/// while a claimed delivery is still unaccounted for.
nonisolated final class FailureCoordinator: @unchecked Sendable {
    /// Identifies which of the coordinator's two queues is currently
    /// executing. Exposed only so tests can deterministically prove
    /// delivery lands on `deliveryQueue`, never `queue`.
    enum QueueRole: Sendable {
        case state
        case delivery
    }

    private static let queueRoleKey = DispatchSpecificKey<QueueRole>()

    static func currentQueueRole() -> QueueRole? {
        DispatchQueue.getSpecific(key: queueRoleKey)
    }

    private let queue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private let deliveryGroup = DispatchGroup()

    private var isAdmitting = true
    private var retainedFailure: Error?
    private var hasCommitted = false
    private var committedHandler: (@Sendable (Error) -> Void)?
    private var hasDelivered = false

    init() {
        self.queue = DispatchQueue(
            label: "com.lecturerecorder.failurecoordinator"
        )
        self.deliveryQueue = DispatchQueue(
            label: "com.lecturerecorder.failurecoordinator.delivery"
        )
        Self.tagQueues(state: queue, delivery: deliveryQueue)
    }

    init(queue: DispatchQueue) {
        self.queue = queue
        self.deliveryQueue = DispatchQueue(
            label: "com.lecturerecorder.failurecoordinator.delivery"
        )
        Self.tagQueues(state: self.queue, delivery: self.deliveryQueue)
    }

    private static func tagQueues(
        state: DispatchQueue,
        delivery: DispatchQueue
    ) {
        state.setSpecific(key: queueRoleKey, value: .state)
        delivery.setSpecific(key: queueRoleKey, value: .delivery)
    }

    /// Reports an asynchronous capture failure for this cycle.
    ///
    /// Only the first accepted failure has any effect: it closes
    /// admission, retains the error for the lifetime of the cycle, and
    /// runs `onFirstAcceptance` exactly once, inside this call's
    /// synchronization. Every later call is rejected and cannot overwrite
    /// the retained error.
    ///
    /// `onFirstAcceptance` must be a small, synchronous, non-blocking
    /// state transition (e.g. closing a callback gate) — it runs inside
    /// the coordinator's critical section, so it must never perform
    /// logging, I/O, awaits, UI work, or call back into this coordinator.
    ///
    /// If this call also claims the cycle's single allowed delivery, it
    /// enters `deliveryGroup` before leaving the critical section, so a
    /// concurrent `drainDelivery()` can never observe delivery as
    /// unclaimed once this call returns.
    func reportFailure(
        _ error: Error,
        onFirstAcceptance: () -> Void
    ) {
        var handlerToInvoke: (@Sendable (Error) -> Void)?
        var errorToDeliver: Error?

        queue.sync {
            guard isAdmitting else {
                return
            }

            isAdmitting = false
            retainedFailure = error
            onFirstAcceptance()

            if
                hasCommitted,
                !hasDelivered,
                let handler = committedHandler
            {
                hasDelivered = true
                deliveryGroup.enter()
                handlerToInvoke = handler
                errorToDeliver = error
            }
        }

        deliver(handlerToInvoke, errorToDeliver)
    }

    /// Commits the external failure handler for this cycle. If a failure
    /// was already retained and not yet delivered, it is delivered
    /// exactly once as a result of this call.
    ///
    /// If this call claims the cycle's single allowed delivery, it enters
    /// `deliveryGroup` before leaving the critical section — see
    /// `reportFailure(_:onFirstAcceptance:)`.
    func markCommitted(
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        var handlerToInvoke: (@Sendable (Error) -> Void)?
        var errorToDeliver: Error?

        queue.sync {
            hasCommitted = true
            committedHandler = onFailure

            if
                !hasDelivered,
                let failure = retainedFailure
            {
                hasDelivered = true
                deliveryGroup.enter()
                handlerToInvoke = onFailure
                errorToDeliver = failure
            }
        }

        deliver(handlerToInvoke, errorToDeliver)
    }

    /// Idempotently closes failure admission and returns whatever error
    /// is retained for this cycle, without consuming or clearing it —
    /// callers may call this repeatedly (e.g. from repeated `stop()`
    /// calls) and keep getting the same answer.
    @discardableResult
    func closeAdmission() -> Error? {
        queue.sync {
            isAdmitting = false
            return retainedFailure
        }
    }

    /// Waits until this cycle's claimed delivery — if any was ever
    /// claimed — has finished invoking the handler. Returns immediately
    /// if no failure was ever claimed for delivery.
    ///
    /// Bridges `DispatchGroup.notify` through a checked continuation, so
    /// callers can `await` it without a blocking wait such as
    /// `DispatchGroup.wait()` or a semaphore.
    func drainDelivery() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            deliveryGroup.notify(queue: deliveryQueue) {
                continuation.resume()
            }
        }
    }

    /// Invokes a claimed handler strictly after leaving the coordinator's
    /// state queue and the calling thread's synchronous call stack, on a
    /// dedicated delivery queue distinct from the state queue — so a
    /// reentrant call from inside the handler back into this coordinator,
    /// or into a caller that serializes through its own control queue,
    /// can never deadlock. `deliveryGroup.leave()` runs only after the
    /// handler invocation returns, which is what lets `drainDelivery()`
    /// observe completion.
    private func deliver(
        _ handler: (@Sendable (Error) -> Void)?,
        _ error: Error?
    ) {
        guard let handler, let error else {
            return
        }

        deliveryQueue.async { [deliveryGroup] in
            defer {
                deliveryGroup.leave()
            }
            handler(error)
        }
    }
}

nonisolated extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameLength
            )
        else {
            return nil
        }

        copy.frameLength = frameLength

        let channelCount = Int(format.channelCount)
        let count = Int(frameLength)

        if
            let sourceFloat = floatChannelData,
            let destFloat = copy.floatChannelData
        {
            for channel in 0..<channelCount {
                destFloat[channel].update(
                    from: sourceFloat[channel],
                    count: count
                )
            }
        } else if
            let sourceInt16 = int16ChannelData,
            let destInt16 = copy.int16ChannelData
        {
            for channel in 0..<channelCount {
                destInt16[channel].update(
                    from: sourceInt16[channel],
                    count: count
                )
            }
        } else if
            let sourceInt32 = int32ChannelData,
            let destInt32 = copy.int32ChannelData
        {
            for channel in 0..<channelCount {
                destInt32[channel].update(
                    from: sourceInt32[channel],
                    count: count
                )
            }
        } else {
            return nil
        }

        return copy
    }
}
