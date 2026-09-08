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
                gate.close()
                coordinator.reportAsyncFailure(
                    AudioCaptureServiceError.configurationChangedDuringRecording
                )
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

    func stop() async {
        let taskToAwait: Task<Void, Never>? = controlQueue.sync {
            switch cycleState {
            case .idle:
                return nil

            case .stopping:
                return inProgressStopTask

            case .prepared(let engine, _):
                engine.stop()
                cycleState = .idle
                return nil

            case .running(let resources):
                cycleState = .stopping

                if let token = resources.configObserver {
                    NotificationCenter.default.removeObserver(token)
                }

                resources.coordinator.invalidate()
                resources.gate.close()
                resources.engine.inputNode.removeTap(onBus: 0)
                resources.engine.stop()

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

nonisolated final class FailureCoordinator: @unchecked Sendable {
    private let queue: DispatchQueue
    private var hasCommitted = false
    private var hasReportedFailure = false
    private var pendingFailure: Error?
    private var onFailureHandler: (@Sendable (Error) -> Void)?

    init() {
        self.queue = DispatchQueue(
            label: "com.lecturerecorder.failurecoordinator"
        )
    }

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func markCommitted(
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        queue.sync {
            hasCommitted = true
            onFailureHandler = onFailure

            if
                !hasReportedFailure,
                let pending = pendingFailure
            {
                hasReportedFailure = true
                pendingFailure = nil

                queue.async {
                    onFailure(pending)
                }
            }
        }
    }

    func reportAsyncFailure(
        _ error: Error
    ) {
        queue.async { [self] in
            guard !hasReportedFailure else {
                return
            }

            if
                hasCommitted,
                let handler = onFailureHandler
            {
                hasReportedFailure = true
                handler(error)
            } else {
                pendingFailure = error
            }
        }
    }

    func invalidate() {
        queue.sync {
            hasReportedFailure = true
            onFailureHandler = nil
            pendingFailure = nil
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
