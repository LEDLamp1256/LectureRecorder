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
/// ## Process ownership
/// The only `Foundation.Process` instance for an invocation is owned by a
/// single `ManagedProcess`, which mediates every operation on it through
/// its own internal `Mutex`. This type never holds or passes around a raw
/// `Process` reference — see `ManagedProcess`'s header comment for the
/// full argument. T2 has no `@unchecked Sendable` anywhere at all:
/// `Synchronization.Mutex` is unconditionally `Sendable` regardless of
/// what it wraps, so both `ManagedProcess` and this type compile as plain
/// `Sendable` without an escape hatch.
///
/// ## Deadlines
/// `overallTimeout`/`gracePeriod` are measured against `ContinuousClock`,
/// never wall-clock `Date()` — a system clock adjustment (NTP sync,
/// manual change, DST) cannot extend, shorten, or reverse a timeout or
/// grace period.
///
/// ## Termination proof
/// `Process.terminate()`/`SIGKILL` are requests, never proof. The only
/// accepted proof of termination is `Process.terminationHandler` firing —
/// that handler fires only after the process has already been reaped
/// internally. Apple does not publish this as a documented contract; it is
/// empirically verified on this project's exact supported toolchain (see
/// `ManagedProcessTerminationHandlerTests`, which stress-tests it directly,
/// including the specific case this design depends on — a handler
/// installed after the process has already exited). This type never uses
/// `kill(pid, 0)` after completion to "confirm" anything.
///
/// ## Fail-closed stdin
/// If stdin delivery cannot be confirmed complete, no response is ever
/// trusted — see `ProcessRunFailure.stdinDeliveryFailed`'s doc comment for
/// the full rationale. This is enforced structurally: a stdin failure is
/// recorded via `ProcessInvocationState.recordFatalIntervention` exactly
/// like any other fatal intervention, which unconditionally blocks
/// `tryCommitSuccess()` for the rest of the call.
///
/// ## Residual PID-reuse risk
/// The final `SIGKILL` escalation step (via `ManagedProcess.forceKillIfStillRunning()`)
/// checks `isRunning` and signals inside one critical section, which
/// removes any race between this process's own threads — but there is an
/// inherent, unavoidable-on-Darwin race against the *kernel*: if the
/// process exits and is reaped by something else in the narrow window
/// between that check and the signal reaching the kernel, the OS could in
/// principle recycle the PID before delivery. No mutex owned by this
/// process can close that window — POSIX exposes no atomic "signal this
/// process unless it has already exited" primitive on macOS (unlike
/// Linux's `pidfd_send_signal`). This is documented, not denied: the
/// window is narrow, and is an accepted, industry-standard limitation of
/// any PID-based signaling scheme, not something a lower-level
/// `posix_spawn`/owned-`waitpid` reimplementation would remove either.
///
/// ## T3 note
/// This type is safe *per invocation*. It has no built-in concurrency
/// limit: `ioQueue` is a `.concurrent` `DispatchQueue`, and each
/// invocation occupies up to three of its worker threads simultaneously
/// for the duration of its I/O. T2 has no concurrent-invocation caller,
/// so this is not a defect today — but T3 scheduling must explicitly
/// bound how many worker invocations run simultaneously and account for
/// this queue's concurrency budget before production transcription is
/// connected.
nonisolated final class FoundationProcessRunner: LocalProcessRunning, Sendable {
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
        // a process-global SIGPIPE handler. Configured immediately after
        // creating the stdin pipe, before the stdout/stderr pipes exist,
        // before the child is launched, and before this handle is exposed
        // to any concurrent work or write.
        let stdinWriteDescriptor = stdinPipe.fileHandleForWriting.fileDescriptor
        guard fcntl(stdinWriteDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let capturedErrno = errno
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            return .failure(.stdinPipeConfigurationFailed(errno: capturedErrno))
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let managedProcess = ManagedProcess { process in
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
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
        }

        switch managedProcess.launch() {
        case .success:
            break
        case .failure(let error):
            return .failure(.launchFailed(underlying: String(describing: error)))
        }

        // A cancellation that landed in the narrow window between the
        // pre-launch check above and this point must still be honored.
        if state.claimedFailure != nil {
            managedProcess.terminate()
        }

        // Only created once launch has actually succeeded — see
        // `ManagedProcess.launch()`'s doc comment for why this ordering
        // is what actually matters (not merely when this async let's
        // child task happens to start).
        async let terminationObservation = Self.waitForTermination(managedProcess)

        // Every discovered I/O failure (stdin delivery, stdout/stderr read)
        // is published to `state` and triggers termination at the moment
        // of discovery, inside these closures — not only after all four
        // `async let`s have already been joined. Recording only after the
        // join was a real, confirmed bug: a child that broke the stdin
        // contract and then hung would previously wait out the *entire*
        // `overallTimeout` before ever classifying as anything,
        // and `watchAndEscalate`'s own timeout would win the race to
        // `recordFatalIntervention` first, misreporting `.timedOut`
        // instead of `.stdinDeliveryFailed`. Publishing here lets
        // `watchAndEscalate`'s `state.claimedFailure == nil` polling loop
        // (which it already had) observe the failure on its very next
        // poll tick and terminate promptly instead. First-intervention-
        // wins precedence is unaffected: `recordFatalIntervention` is
        // still the single, idempotent, mutex-guarded arbiter — calling
        // it earlier only changes *when* a failure can win, never
        // *whether* an already-recorded earlier intervention can be
        // overridden.
        async let stdinResult = Self.deliverStdin(
            request.stdin,
            to: stdinPipe,
            ioQueue: ioQueue,
            onFailure: { failure in
                state.recordFatalIntervention(failure)
                managedProcess.terminate()
            }
        )
        async let stdoutResult = Self.drainBounded(
            pipe: stdoutPipe,
            limit: request.maximumStdoutBytes,
            ioQueue: ioQueue,
            onOverflow: {
                state.recordFatalIntervention(.stdoutLimitExceeded(limit: request.maximumStdoutBytes))
                managedProcess.terminate()
            },
            onReadFailure: { failure in
                state.recordFatalIntervention(failure)
                managedProcess.terminate()
            },
            makeReadFailure: { .stdoutReadFailed(underlying: $0) }
        )
        async let stderrResult = Self.drainBounded(
            pipe: stderrPipe,
            limit: request.maximumStderrBytes,
            ioQueue: ioQueue,
            onOverflow: nil,
            onReadFailure: { failure in
                state.recordFatalIntervention(failure)
                managedProcess.terminate()
            },
            makeReadFailure: { .stderrReadFailed(underlying: $0) }
        )
        async let escalation: Void = Self.watchAndEscalate(
            managedProcess: managedProcess,
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

        // Fail-closed stdin rule: a stdin-delivery failure is recorded
        // here exactly like any other fatal intervention, so the check
        // below (`state.claimedFailure`) is what actually enforces "no
        // response may be trusted without confirmed complete delivery" —
        // it is checked before, and takes precedence over, whatever
        // `stdout`/`stderr` ended up containing.
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

    /// Bridges `ManagedProcess.observeTermination` through a checked
    /// continuation — the same pattern this repository's own
    /// `FailureCoordinator` already uses for `DispatchGroup.notify`
    /// (`drainDelivery()`), chosen there and here over a blocking wait.
    /// Only ever called after `ManagedProcess.launch()` has already
    /// succeeded (there is no launch-failure path through this function
    /// at all), so `onTermination` firing exactly once is guaranteed by
    /// `Foundation.Process`'s empirically-verified behavior on this
    /// project's exact supported toolchain — not an Apple-published
    /// contract; see `ManagedProcessTerminationHandlerTests`.
    private static func waitForTermination(_ managedProcess: ManagedProcess) async -> ProcessTerminationReason {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessTerminationReason, Never>) in
            managedProcess.observeTermination { reason in
                continuation.resume(returning: reason)
            }
        }
    }

    /// Watches for a reason to terminate the child (an already-recorded
    /// fatal intervention, or `overallTimeout` elapsing) and, once
    /// termination is warranted, drives the graceful-then-forced
    /// escalation sequence. Deliberately polls `managedProcess.isRunning`
    /// rather than registering a second consumer of the termination
    /// handler, since that can only ever have one meaningful assignment
    /// per process. This polling idiom matches this repository's own
    /// established callback-to-async bridge pattern
    /// (`InFlightCallbackGate.drain()`: `while … { await Task.yield() }`).
    /// All deadline arithmetic is monotonic — never wall-clock `Date()` —
    /// so a system clock adjustment cannot affect timeout or grace-period
    /// behavior. The timeout-wait phase uses `ContinuousClock` directly;
    /// the grace-period phase deliberately switches to a
    /// `DispatchTime`/`DispatchQueue.asyncAfter`-based wait instead — see
    /// the comment at that call site for why `ContinuousClock.sleep`
    /// specifically is unsafe to use once termination has already been
    /// requested under cancellation.
    private static func watchAndEscalate(
        managedProcess: ManagedProcess,
        state: ProcessInvocationState,
        overallTimeout: TimeInterval,
        gracePeriod: TimeInterval,
        pollInterval: TimeInterval
    ) async {
        let clock = ContinuousClock()
        let pollDuration = Self.duration(fromSeconds: max(pollInterval, 0.001))
        let timeoutDeadline = clock.now.advanced(by: Self.duration(fromSeconds: overallTimeout))

        while managedProcess.isRunning, state.claimedFailure == nil, clock.now < timeoutDeadline {
            try? await clock.sleep(for: pollDuration)
        }

        guard managedProcess.isRunning else {
            return
        }

        if state.claimedFailure == nil {
            state.recordFatalIntervention(.timedOut(afterSeconds: overallTimeout))
        }

        // A fatal intervention is now recorded (ours, or one that raced in
        // from cancellation/overflow). Graceful termination is idempotent
        // to request more than once.
        managedProcess.terminate()

        // The grace-period wait deliberately does NOT use `clock.sleep`
        // (or any other Task-cancellation-aware sleep API) here. An
        // earlier version did, discovered `clock.sleep(for:)` throws
        // immediately once this task is cancelled, and "fixed" the
        // resulting `try?`-swallowed busy-spin (measured ~1,700x against
        // production's 2-second default grace period) by adding a
        // `!Task.isCancelled` loop clause — which is wrong for a
        // different reason: `watchAndEscalate` runs as a structured child
        // of the very task `run(_:)`'s cancellation propagates through,
        // so by the time execution reaches this point (cancellation is
        // almost always what triggered termination in the first place),
        // `Task.isCancelled` is already `true`, and that loop exited on
        // its very first check — skipping the entire configured grace
        // period rather than merely avoiding the spin. Cancelling the
        // *caller's* interest in the outcome must never shorten this
        // type's own internal grace-period policy: the grace period is
        // this runner's own escalation contract, not something a caller
        // opts out of by cancelling. `waitWhileRunningOrDeadline` below
        // uses a `DispatchQueue.asyncAfter`-backed timer instead — a real
        // GCD timer that is not a Swift Task cancellation checkpoint at
        // all, so it neither spins nor observes cancellation, while still
        // returning promptly (per-tick, bounded by `pollInterval`) if the
        // child exits naturally partway through the wait.
        let escalationDeadline = DispatchTime.now() + Self.dispatchTimeInterval(fromSeconds: gracePeriod)
        await Self.waitWhileRunningOrDeadline(
            managedProcess,
            pollInterval: pollInterval,
            deadline: escalationDeadline
        )

        managedProcess.forceKillIfStillRunning()
    }

    /// Waits, in bounded `pollInterval`-sized ticks, until either the
    /// process is no longer running or `deadline` passes — whichever
    /// comes first — using `DispatchQueue.asyncAfter`, which is immune to
    /// Swift Task cancellation (unlike `Task.sleep`/`ContinuousClock.sleep`,
    /// which both throw the instant the calling task is cancelled). This
    /// is what lets the grace period elapse for real, in monotonic elapsed
    /// time, even when the invocation that requested termination has
    /// itself already been cancelled — while still returning as soon as
    /// the child actually exits, rather than always waiting out the full
    /// period. `DispatchTime` is `mach_absolute_time`-based (monotonic),
    /// never wall-clock `Date()`.
    private static func waitWhileRunningOrDeadline(
        _ managedProcess: ManagedProcess,
        pollInterval: TimeInterval,
        deadline: DispatchTime
    ) async {
        let tick = Self.dispatchTimeInterval(fromSeconds: max(pollInterval, 0.001))
        while managedProcess.isRunning, DispatchTime.now() < deadline {
            await Self.nonCancellableDelay(tick)
        }
    }

    /// A suspension that is not a Swift Task cancellation checkpoint:
    /// `withCheckedContinuation` (the non-throwing overload) never checks
    /// or reacts to cancellation on its own — it only resumes when
    /// `resume()` is explicitly called, which here happens strictly from
    /// the GCD timer firing. The timer is always scheduled to fire
    /// eventually regardless of what the caller does afterward, so this
    /// function — and by extension `waitWhileRunningOrDeadline` and
    /// `watchAndEscalate` — always completes and is always fully joined
    /// before `performInvocation` returns; nothing here can outlive the
    /// invocation.
    private static func nonCancellableDelay(_ interval: DispatchTimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
                continuation.resume()
            }
        }
    }

    /// Converts a `TimeInterval` (seconds) into a `DispatchTimeInterval`
    /// for use with `DispatchTime`/`DispatchQueue.asyncAfter`. Negative or
    /// non-finite input clamps to zero (an immediate/no-op delay) rather
    /// than trapping or producing an unbounded wait.
    private static func dispatchTimeInterval(fromSeconds seconds: TimeInterval) -> DispatchTimeInterval {
        guard seconds.isFinite, seconds > 0 else {
            return .nanoseconds(0)
        }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds < Double(Int.max) else {
            return .nanoseconds(Int.max)
        }
        return .nanoseconds(Int(nanoseconds))
    }

    /// Converts a `TimeInterval` (seconds, `Double`) into a `Duration`
    /// without relying on any particular `Duration.seconds` overload
    /// existing for `Double` — deliberately explicit so this compiles
    /// identically regardless of stdlib version. Clamps non-finite input
    /// (`.infinity`, `.nan`) to a large-but-finite duration rather than
    /// trapping: `Int64(seconds)` on `.infinity`/`.nan` is a runtime crash,
    /// and the `Date()`-based arithmetic this replaced did not crash on
    /// `.infinity` (a caller's idiomatic way to request "no timeout").
    /// Unreachable with every current call site (all pass small finite
    /// literals), but a public `TimeInterval` parameter with no upstream
    /// validation should not be able to crash the process.
    private static func duration(fromSeconds seconds: TimeInterval) -> Duration {
        // A safe, comfortably-large-but-exactly-representable bound —
        // roughly 31 billion years — well clear of `Int64`'s own limits
        // (unlike `Double(Int64.max)`, which is not exactly representable
        // as a `Double` and would itself risk a boundary conversion trap).
        let safeMaximumSeconds: Double = 1e18
        guard seconds.isFinite else {
            return .seconds(Int64(safeMaximumSeconds))
        }
        let clampedSeconds = Swift.min(Swift.max(seconds, -safeMaximumSeconds), safeMaximumSeconds)
        let wholeSeconds = Int64(clampedSeconds)
        let fractionalSeconds = clampedSeconds - Double(wholeSeconds)
        let attoseconds = Int64((fractionalSeconds * 1_000_000_000_000_000_000).rounded())
        return Duration(secondsComponent: wholeSeconds, attosecondsComponent: attoseconds)
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
    ///
    /// Any failure here is fail-closed for the whole invocation: see
    /// `ProcessRunFailure.stdinDeliveryFailed`'s doc comment. `onFailure`
    /// is invoked synchronously, on `ioQueue`, at the exact moment the
    /// write fails — before the continuation resumes — so the failure is
    /// published to `ProcessInvocationState` (and termination requested)
    /// at discovery time rather than only after every `async let` in
    /// `performInvocation` has already been joined.
    private static func deliverStdin(
        _ data: Data,
        to pipe: Pipe,
        ioQueue: DispatchQueue,
        onFailure: @Sendable @escaping (ProcessRunFailure) -> Void
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
                        let failure = ProcessRunFailure.stdinDeliveryFailed(underlying: String(describing: error))
                        onFailure(failure)
                        continuation.resume(returning: .failure(failure))
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
    ///
    /// `onReadFailure` (distinct from `onOverflow`) is invoked
    /// synchronously, on `ioQueue`, the moment a genuine read error is
    /// discovered — before the continuation resumes — publishing the
    /// failure to `ProcessInvocationState` and requesting termination at
    /// discovery time, exactly like `onOverflow` already did for the
    /// overflow case; a real read failure used to only be recorded after
    /// every operation in `performInvocation` had already been joined.
    private static func drainBounded(
        pipe: Pipe,
        limit: Int,
        ioQueue: DispatchQueue,
        onOverflow: (@Sendable () -> Void)?,
        onReadFailure: @Sendable @escaping (ProcessRunFailure) -> Void,
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
                        let failure = makeReadFailure(String(describing: error))
                        onReadFailure(failure)
                        continuation.resume(returning: .failure(failure))
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
