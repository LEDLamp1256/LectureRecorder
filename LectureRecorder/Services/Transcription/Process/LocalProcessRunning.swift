import Foundation

/// How the child process's environment is populated. Deliberately explicit —
/// never silently falls back to inheriting this process's full environment,
/// since that could leak unrelated ambient state into a worker invocation.
nonisolated enum ProcessEnvironmentPolicy: Sendable, Equatable {
    /// The child receives an empty environment.
    case empty
    /// The child receives exactly this environment, nothing else.
    case explicit([String: String])
}

/// How a child process actually terminated, as reported by `Foundation.Process`.
nonisolated enum ProcessTerminationReason: Sendable, Equatable {
    case exited(status: Int32)
    case uncaughtSignal(Int32)
}

/// Everything one `LocalProcessRunning.run(_:)` call needs, and nothing else.
/// This type knows about executables, arguments, bytes, and limits — never
/// about JSON, transcription jobs, or worker protocol versions.
nonisolated struct ProcessInvocationRequest: Sendable {
    var executableURL: URL
    var arguments: [String]
    var stdin: Data
    var environmentPolicy: ProcessEnvironmentPolicy
    var workingDirectoryURL: URL?
    var maximumStdinBytes: Int
    var maximumStdoutBytes: Int
    var maximumStderrBytes: Int
    var overallTimeout: TimeInterval
    var gracePeriod: TimeInterval

    init(
        executableURL: URL,
        arguments: [String] = [],
        stdin: Data = Data(),
        environmentPolicy: ProcessEnvironmentPolicy = .empty,
        workingDirectoryURL: URL? = nil,
        maximumStdinBytes: Int,
        maximumStdoutBytes: Int,
        maximumStderrBytes: Int,
        overallTimeout: TimeInterval,
        gracePeriod: TimeInterval
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.stdin = stdin
        self.environmentPolicy = environmentPolicy
        self.workingDirectoryURL = workingDirectoryURL
        self.maximumStdinBytes = maximumStdinBytes
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        self.overallTimeout = overallTimeout
        self.gracePeriod = gracePeriod
    }
}

/// A process that ran to completion under the runner's care and was
/// observed to terminate — regardless of whether its exit status was zero.
/// A nonzero or signaled exit is still a `ProcessRunResult`, not a
/// `ProcessRunFailure`: whether a given exit status is acceptable is a
/// judgment the worker-protocol layer makes, not this layer.
nonisolated struct ProcessRunResult: Sendable, Equatable {
    var stdout: Data
    var stderr: Data
    var stderrTruncated: Bool
    var terminationReason: ProcessTerminationReason
}

/// Every way `LocalProcessRunning.run(_:)` can fail to produce a trustworthy
/// `ProcessRunResult`. Follows this repository's existing typed-error
/// convention (`nonisolated enum ... : LocalizedError, Sendable`), matching
/// `TranscriptionCoordinatorError`/`TranscriptionStoreError` — never a
/// free-form string, never inferred from an arbitrary `Swift.Error`'s type.
nonisolated enum ProcessRunFailure: LocalizedError, Sendable, Equatable {
    case requestTooLarge(byteCount: Int, limit: Int)
    case stdinPipeConfigurationFailed(errno: Int32)
    case launchFailed(underlying: String)
    /// Fail-closed rule: if complete stdin delivery cannot be confirmed,
    /// no response may ever be trusted — even if the child exits zero and
    /// stdout contains apparently valid, identity-matching JSON. The
    /// worker did not receive the complete canonical request; accepting
    /// its response would let a prematurely-responding or protocol-
    /// violating worker manufacture success from partial input.
    /// `FoundationProcessRunner` enforces this unconditionally: recording
    /// this case as the invocation's fatal intervention (via
    /// `ProcessInvocationState.recordFatalIntervention`) permanently
    /// blocks `tryCommitSuccess()` for the remainder of the call,
    /// regardless of what the child later writes to stdout or which exit
    /// status it reports. See
    /// `FoundationProcessRunnerTests.testStdinDeliveryFailureDiscardsAnOtherwiseValidResponse`
    /// for the deterministic proof.
    case stdinDeliveryFailed(underlying: String)
    case stdoutReadFailed(underlying: String)
    case stderrReadFailed(underlying: String)
    case stdoutLimitExceeded(limit: Int)
    case timedOut(afterSeconds: TimeInterval)
    case cancelled
    case terminationUncertain(underlying: String)

    var errorDescription: String? {
        switch self {
        case .requestTooLarge(let byteCount, let limit):
            return "Encoded request is \(byteCount) bytes, exceeding the \(limit)-byte limit; not launched."
        case .stdinPipeConfigurationFailed(let errno):
            return "Failed to configure descriptor-scoped SIGPIPE suppression on the stdin pipe (errno \(errno): \(String(cString: strerror(errno))))."
        case .launchFailed(let underlying):
            return "Process launch failed: \(underlying)"
        case .stdinDeliveryFailed(let underlying):
            return "Stdin delivery failed: \(underlying)"
        case .stdoutReadFailed(let underlying):
            return "Reading stdout failed: \(underlying)"
        case .stderrReadFailed(let underlying):
            return "Reading stderr failed: \(underlying)"
        case .stdoutLimitExceeded(let limit):
            return "Stdout exceeded the \(limit)-byte retained limit; process terminated."
        case .timedOut(let afterSeconds):
            return "Process did not complete within \(afterSeconds) seconds; terminated."
        case .cancelled:
            return "Invocation was cancelled."
        case .terminationUncertain(let underlying):
            return "Process termination/cleanup could not be confirmed: \(underlying)"
        }
    }
}

/// The narrow, worker-protocol-agnostic seam that knows how to launch one
/// external executable, deliver bounded stdin, capture bounded stdout and
/// stderr concurrently, and observe termination — and nothing else. A
/// `TranscriptionWorkerClient` (or any other future caller) composes this;
/// this protocol never becomes aware of JSON, transcription identity, or
/// worker versioning. Mirrors this repository's existing narrow-seam
/// pattern (`ExclusiveArtifactFileSystem` composed by `TranscriptionStore`).
nonisolated protocol LocalProcessRunning: Sendable {
    /// Runs `request` to completion (or to a definitive failure) and does
    /// not return until the child has been observed to terminate and every
    /// spawned I/O operation for this invocation has been joined.
    func run(_ request: ProcessInvocationRequest) async -> Result<ProcessRunResult, ProcessRunFailure>
}
