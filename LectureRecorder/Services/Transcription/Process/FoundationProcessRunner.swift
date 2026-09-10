import Darwin
import Foundation

/// `Foundation.Process`-backed `LocalProcessRunning` implementation.
///
/// ## Concurrency shape
/// After a successful launch, three independent operations run
/// concurrently via `async let` (structured — each is guaranteed joined
/// before this function returns, satisfying "no unstructured task may
/// outlive the invocation" without any extra bookkeeping): chunked stdin
/// delivery, bounded stdout drainage, and bounded stderr drainage. A
/// fourth `async let` watches for timeout/cancellation and drives the
/// graceful-then-forced termination escalation. All four are `await`ed
/// together before any terminal classification is read back from
/// `ProcessInvocationState`.
///
/// Every blocking `FileHandle` call happens inside a closure dispatched
/// onto `ioQueue`, a dedicated, non-MainActor, non-cooperative-pool
/// `DispatchQueue` — never inside a bare `Task { }` body, which would risk
/// starving Swift's deliberately size-limited cooperative thread pool with
/// synchronous I/O.
///
/// ## Termination proof
/// `Process.terminate()`/`SIGKILL` are requests, never proof. The only
/// accepted proof of termination is `Process.terminationHandler` firing —
/// per `Foundation`'s own documented behavior, that handler fires only
/// after the process has already been reaped internally. This type never
/// uses `kill(pid, 0)` after completion to "confirm" anything.
///
/// ## Residual PID-reuse risk
/// The final `SIGKILL` escalation step signals `process.processIdentifier`
/// directly. Between this type's own `process.isRunning` check and the
/// `kill()` call that follows it, there is an inherent, unavoidable-on-
/// Darwin race: if the process exits and is reaped by something else in
/// that narrow window, the OS could in principle recycle the PID before
/// the signal is delivered. No mutex or atomic flag owned by this process
/// can close that window — POSIX simply does not expose an atomic
/// "signal this process unless it has already exited" primitive on macOS
/// (unlike Linux's `pidfd_send_signal`). This is documented, not denied:
/// the window is narrow (typically microseconds, bounded by how promptly
/// this process's own `Process` reaps its own direct child), and is an
/// accepted, industry-standard limitation of any PID-based signaling
/// scheme, not something a lower-level `posix_spawn`/owned-`waitpid`
/// reimplementation would remove either.
nonisolated final class FoundationProcessRunner: LocalProcessRunning, @unchecked Sendable {
    private let ioQueue: DispatchQueue
    private let pollInterval: TimeInterval

    /// `pollInterval` is exposed for tests that need tight, deterministic
    /// grace-period/timeout bounds; production callers should accept the
    /// default.
    init(pollInterval: TimeInterval = 0.02) {
        self.ioQueue = DispatchQueue(
            label: "com.lecturerecorder.transcription.processrunner.io",
            attributes: .concurrent
        )
        self.pollInterval = pollInterval
    }

    func run(_ request: ProcessInvocationRequest) async -> Result<ProcessRunResult, ProcessRunFailure> {
        guard request.stdin.count <= request.maximumStdinBytes else {
            return .failure(.requestTooLarge(byteCount: request.stdin.count, limit: request.maximumStdinBytes))
        }

        let state = ProcessInvocationState()

        return await withTaskCancellationHandler {
            await performInvocation(request: request, state: state)
        } onCancel: {
            // Synchronous, non-isolated: only ever touches `state`'s
            // internal lock. Actual process termination is driven by the
            // escalation watcher inside `performInvocation`, which polls
            // `state.claimedFailure` — see its doc comment for why this
            // indirection exists instead of terminating the process
            // directly from here.
            state.recordFatalIntervention(.cancelled)
        }
    }

    private func performInvocation(
        request: ProcessInvocationRequest,
        state: ProcessInvocationState
    ) async -> Result<ProcessRunResult, ProcessRunFailure> {
        // Cancellation before launch must prevent launch if observed in time.
        if let already = state.claimedFailure {
            return .failure(already)
        }

        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        switch request.environmentPolicy {
        case .empty:
            process.environment = [:]
        case .explicit(let environment):
            process.environment = environment
        }
        if let workingDirectoryURL = request.workingDirectoryURL {
            process.currentDirectoryURL = workingDirectoryURL
        }

        let stdinPipe = Pipe()

        // Darwin-specific, descriptor-scoped fix: without this, a write to
        // `stdinPipe`'s write end after the child has already closed its
        // read end raises SIGPIPE with the default, process-terminating
        // disposition — `FileHandle.write(contentsOf:)`'s throwing
        // overload does NOT catch this on this toolchain (confirmed via
        // "Test crashed with signal pipe." in FoundationProcessRunnerTests
        // before this fix was added). `F_SETNOSIGPIPE` disables signal
        // generation for this one file descriptor only — it never touches
        // process-wide `signal()`/`sigaction()` disposition, so it is not
        // the "process-global SIGPIPE handler" this type's own header
        // comment (and the approved architecture) prohibits. Configured
        // immediately after creating the stdin pipe, before the stdout/
        // stderr pipes exist, before the child is launched, and before
        // this handle is exposed to any concurrent work or write.
        let stdinWriteDescriptor = stdinPipe.fileHandleForWriting.fileDescriptor
        guard fcntl(stdinWriteDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let capturedErrno = errno
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            return .failure(.stdinPipeConfigurationFailed(errno: capturedErrno))
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(underlying: String(describing: error)))
        }

        // Only created once launch has actually succeeded. Creating this
        // `async let` before `process.run()` (an earlier version of this
        // function did) is a real deadlock: if `run()` throws, returning
        // without ever awaiting an already-created `async let` triggers
        // Swift's implicit cancel-and-await at scope exit, which blocks
        // forever on `waitForTerminationHandler`'s `withCheckedContinuation`
        // — a continuation that can never resume, because no process was
        // ever launched for `terminationHandler` to fire on, and a checked
        // continuation has no cancellation escape hatch. Placing this only
        // after a confirmed-successful launch removes that window
        // entirely. (`async let` does not run its body synchronously at
        // the declaration point — empirically confirmed the child task
        // starts after its enclosing scope continues in the overwhelming
        // majority of runs — but that is irrelevant to correctness here:
        // `Foundation.Process` fires `terminationHandler` correctly even
        // when it is assigned after the process has already exited and
        // been reaped, which is the actual property this code depends on.)
        async let terminationObservation = Self.waitForTerminationHandler(process)

        // A cancellation that landed in the narrow window between the
        // pre-launch check above and this point must still be honored.
        if state.claimedFailure != nil {
            process.terminate()
        }

        async let stdinResult = Self.deliverStdin(
            request.stdin,
            to: stdinPipe,
            state: state,
            ioQueue: ioQueue
        )
        async let stdoutResult = Self.drainBounded(
            pipe: stdoutPipe,
            limit: request.maximumStdoutBytes,
            ioQueue: ioQueue,
            onOverflow: {
                state.recordFatalIntervention(.stdoutLimitExceeded(limit: request.maximumStdoutBytes))
                process.terminate()
            },
            makeReadFailure: { .stdoutReadFailed(underlying: $0) }
        )
        async let stderrResult = Self.drainBounded(
            pipe: stderrPipe,
            limit: request.maximumStderrBytes,
            ioQueue: ioQueue,
            onOverflow: nil,
            makeReadFailure: { .stderrReadFailed(underlying: $0) }
        )
        async let escalation: Void = Self.watchAndEscalate(
            process: process,
            state: state,
            overallTimeout: request.overallTimeout,
            gracePeriod: request.gracePeriod,
            pollInterval: pollInterval
        )

        let stdin = await stdinResult
        let stdout = await stdoutResult
        let stderr = await stderrResult
        let termination = await terminationObservation
        await escalation

        if case .failure(let failure) = stdin {
            state.recordFatalIntervention(failure)
        }
        if case .failure(let failure) = stdout {
            state.recordFatalIntervention(failure)
        }
        if case .failure(let failure) = stderr {
            state.recordFatalIntervention(failure)
        }

        if let failure = state.claimedFailure {
            return .failure(failure)
        }

        // At this point stdin/stdout/stderr all completed without a
        // recorded failure (drainBounded never fails on overflow by
        // itself — it reports overflow via `onOverflow`, which already
        // recorded the intervention above if it fired).
        guard
            case .success = stdin,
            case .success(let stdoutOutcome) = stdout,
            case .success(let stderrOutcome) = stderr
        else {
            return .failure(state.claimedFailure ?? .terminationUncertain(underlying: "Unreachable: I/O failed without a recorded intervention."))
        }

        guard state.tryCommitSuccess() else {
            return .failure(state.claimedFailure ?? .terminationUncertain(underlying: "Outcome could not be determined after commitment was refused."))
        }

        return .success(ProcessRunResult(
            stdout: stdoutOutcome.data,
            stderr: stderrOutcome.data,
            stderrTruncated: stderrOutcome.truncated,
            terminationReason: termination
        ))
    }

    // MARK: - Termination observation

    /// Bridges `Process.terminationHandler` through a checked continuation
    /// — the same pattern this repository's own `FailureCoordinator`
    /// already uses for `DispatchGroup.notify` (`drainDelivery()`), chosen
    /// there and here over a blocking wait. Per `Foundation.Process`'s
    /// documented behavior, this handler fires only after the process has
    /// already been reaped; observing it firing is this runner's sole
    /// accepted proof of termination.
    private static func waitForTerminationHandler(_ process: Process) async -> ProcessTerminationReason {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessTerminationReason, Never>) in
            process.terminationHandler = { finishedProcess in
                let reason: ProcessTerminationReason
                if finishedProcess.terminationReason == .exit {
                    reason = .exited(status: finishedProcess.terminationStatus)
                } else {
                    reason = .uncaughtSignal(finishedProcess.terminationStatus)
                }
                continuation.resume(returning: reason)
            }
        }
    }

    /// Watches for a reason to terminate the child (an already-recorded
    /// fatal intervention, or `overallTimeout` elapsing) and, once
    /// termination is warranted, drives the graceful-then-forced
    /// escalation sequence. Deliberately polls `process.isRunning` — a
    /// `Foundation`-maintained, thread-safe-to-read stored property —
    /// rather than registering a second consumer of
    /// `terminationHandler`, since that property can only ever have one
    /// meaningful assignment per process. This polling idiom matches this
    /// repository's own established callback-to-async bridge pattern
    /// (`InFlightCallbackGate.drain()`: `while … { await Task.yield() }`).
    private static func watchAndEscalate(
        process: Process,
        state: ProcessInvocationState,
        overallTimeout: TimeInterval,
        gracePeriod: TimeInterval,
        pollInterval: TimeInterval
    ) async {
        let nanoseconds = UInt64(max(pollInterval, 0.001) * 1_000_000_000)
        let timeoutDeadline = Date().addingTimeInterval(overallTimeout)

        while process.isRunning, state.claimedFailure == nil, Date() < timeoutDeadline {
            try? await Task.sleep(nanoseconds: nanoseconds)
        }

        guard process.isRunning else {
            return
        }

        if state.claimedFailure == nil {
            state.recordFatalIntervention(.timedOut(afterSeconds: overallTimeout))
        }

        // A fatal intervention is now recorded (ours, or one that raced in
        // from cancellation/overflow). Graceful termination is idempotent
        // to request more than once.
        process.terminate()

        let escalationDeadline = Date().addingTimeInterval(gracePeriod)
        while process.isRunning, Date() < escalationDeadline {
            try? await Task.sleep(nanoseconds: nanoseconds)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Stdin delivery

    /// Delivers `data` to `pipe`'s write end in bounded chunks, then closes
    /// it. Chunking (rather than one monolithic write) is what makes a
    /// blocked write promptly observe the child's read end disappearing:
    /// once `process.terminate()` kills the child, the kernel closes the
    /// child's inherited copy of the pipe's read end, and the *next*
    /// `write()` — or the one currently blocked, once buffer space frees
    /// or the pipe closes — fails with a caught Swift error rather than
    /// hanging or raising `SIGPIPE` into this process. This write handle
    /// is owned exclusively by this function for the duration of the call;
    /// nothing else ever closes or writes to it concurrently.
    private static func deliverStdin(
        _ data: Data,
        to pipe: Pipe,
        state: ProcessInvocationState,
        ioQueue: DispatchQueue
    ) async -> Result<Void, ProcessRunFailure> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, ProcessRunFailure>, Never>) in
            ioQueue.async {
                let handle = pipe.fileHandleForWriting
                defer { try? handle.close() }

                let chunkSize = 8 * 1024
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunkSize, data.count)
                    let chunk = data.subdata(in: offset..<end)
                    do {
                        try handle.write(contentsOf: chunk)
                    } catch {
                        continuation.resume(returning: .failure(.stdinDeliveryFailed(underlying: String(describing: error))))
                        return
                    }
                    offset = end
                }
                continuation.resume(returning: .success(()))
            }
        }
    }

    // MARK: - Bounded concurrent drainage

    private struct DrainOutcome {
        var data: Data
        var truncated: Bool
    }

    /// Drains `pipe` to EOF, retaining at most `limit` bytes. "Bounded
    /// capture" means bounded *retained memory*, never stopping
    /// consumption of a live pipe — a live pipe nobody drains can block
    /// the child indefinitely. On crossing `limit` for the first time,
    /// invokes `onOverflow` at most once (nil for stderr, whose overflow
    /// only truncates and never fails the invocation) and continues
    /// draining-and-discarding until EOF regardless.
    ///
    /// Uses `FileHandle.read(upToCount:)` (the throwing overload), never
    /// the legacy `availableData` — on a genuine read error, `availableData`
    /// raises an Objective-C `NSFileHandleOperationException` that Swift
    /// cannot catch, crashing the process outright. This is the same class
    /// of hazard already fixed on the stdin write side via
    /// `F_SETNOSIGPIPE`; the read side gets the equivalent treatment here.
    private static func drainBounded(
        pipe: Pipe,
        limit: Int,
        ioQueue: DispatchQueue,
        onOverflow: (@Sendable () -> Void)?,
        makeReadFailure: @Sendable @escaping (String) -> ProcessRunFailure
    ) async -> Result<DrainOutcome, ProcessRunFailure> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<DrainOutcome, ProcessRunFailure>, Never>) in
            ioQueue.async {
                let handle = pipe.fileHandleForReading
                defer { try? handle.close() }

                var buffer = Data()
                var truncated = false
                var overflowSignaled = false
                let readChunkSize = 64 * 1024

                while true {
                    let chunk: Data
                    do {
                        guard let readChunk = try handle.read(upToCount: readChunkSize), !readChunk.isEmpty else {
                            break // EOF
                        }
                        chunk = readChunk
                    } catch {
                        continuation.resume(returning: .failure(makeReadFailure(String(describing: error))))
                        return
                    }

                    if buffer.count < limit {
                        let room = limit - buffer.count
                        if chunk.count <= room {
                            buffer.append(chunk)
                        } else {
                            buffer.append(chunk.prefix(room))
                            truncated = true
                        }
                    } else {
                        truncated = true
                    }

                    if truncated, !overflowSignaled, let onOverflow {
                        overflowSignaled = true
                        onOverflow()
                    }
                }

                continuation.resume(returning: .success(DrainOutcome(data: buffer, truncated: truncated)))
            }
        }
    }
}
