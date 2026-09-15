import Darwin
import Foundation
import Synchronization

/// Owns the sole `Foundation.Process` instance for one invocation and
/// mediates every operation on it through a `Mutex`-protected critical
/// section — configuration, launch, termination-handler installation,
/// `isRunning`/`processIdentifier` reads, graceful `terminate()`, and the
/// decision of whether forced escalation is still warranted. `Process` is
/// not documented by Apple as thread-safe; this type exists so nothing in
/// `FoundationProcessRunner` deliberately touches it concurrently from
/// more than one call site at a time, and so the raw `Process` reference
/// itself never escapes this type's own methods.
///
/// ## `Sendable`, not `@unchecked Sendable`
/// `Foundation.Process` does not itself conform to `Sendable`, but this
/// type needs no `@unchecked` assertion to compile as `Sendable`:
/// `Synchronization.Mutex<Value>` is unconditionally `Sendable` — it does
/// not require `Value: Sendable` — because a mutex's entire purpose is to
/// make safe, synchronized cross-thread access possible for whatever it
/// wraps. This type's only stored property is `Mutex<Storage>`, so the
/// compiler verifies the conformance on its own; T2 has no `@unchecked
/// Sendable` anywhere. That does **not** mean the compiler has proven
/// this type race-free on its own — `Mutex` being `Sendable` is a
/// capability the compiler grants, not a guarantee that every caller uses
/// it correctly. The actual safety argument is the same as it would be
/// under `@unchecked`, just carried by discipline this file enforces
/// rather than by an explicit escape hatch: every method that touches the
/// stored `Process` does so exclusively inside `storage.withLock`, and no
/// method here ever returns, captures, or otherwise leaks the raw
/// reference — every public API surface is a `Sendable` value type
/// (`Bool`, `Int32`, `ProcessTerminationReason`, `Result<Void, Error>`).
///
/// One narrow, intentional exception: `observeTermination`'s installed
/// closure receives the raw, already-finished `Process` back from
/// `Foundation` itself (as `finished`, on Foundation's own callback
/// thread) and reads `finished.terminationReason`/`.terminationStatus`
/// without holding this type's mutex. This is not a call path this type
/// controls — `Process.terminationHandler` is Foundation's own API
/// surface — and it is benign rather than eliminated: those two
/// properties are written once by Foundation before the handler is
/// invoked and never mutated afterward, so there is a happens-before edge
/// even without an explicit lock. Do not read the claim above as "no code
/// ever touches `Process` outside the mutex" — it does not, and cannot,
/// cover a callback Foundation itself invokes.
///
/// `init(configure:)`'s closure is also, technically, a second way a
/// caller *could* leak the reference (`var leaked: Process?;
/// ManagedProcess { leaked = $0 }` would compile) — nothing in this file
/// does that, and every call site in `FoundationProcessRunner` only sets
/// properties on it, but this is caller discipline, not something the
/// type itself prevents.
///
/// ## What this type does not do
/// It narrows, but does not eliminate, the residual PID-reuse race
/// documented on `FoundationProcessRunner`: `forceKillIfStillRunning()`
/// checks `isRunning` and sends `SIGKILL` inside the *same* critical
/// section, which removes any race between *this process's own threads*,
/// but cannot make the check-then-signal sequence atomic with respect to
/// the *kernel* reaping this exact PID and reassigning it to an unrelated
/// process in between. POSIX exposes no such atomic primitive on Darwin
/// (unlike Linux's `pidfd_send_signal`). Do not read this type's mutex as
/// having solved that; it has not, and cannot.
nonisolated final class ManagedProcess: Sendable {
    private struct Storage {
        let process: Process
        var hasLaunched = false
        var hasObservedTermination = false
    }

    private let storage: Mutex<Storage>

    /// `configure` runs synchronously, here in `init`, before this
    /// instance is shared with anything else — the only point at which
    /// direct, unsynchronized access to the underlying `Process` is
    /// legitimate, since no other reference to this `ManagedProcess` can
    /// exist yet for anything to race against.
    init(configure: (Process) -> Void) {
        let process = Process()
        configure(process)
        storage = Mutex(Storage(process: process))
    }

    /// Launches the owned process. Synchronous — `Process.run()` itself
    /// never suspends — so there is no continuation, no `async let`, and
    /// therefore no window in which a launch failure could leave anything
    /// un-awaited. (An earlier implementation created the termination-
    /// observation bridge before calling this, and returned on failure
    /// without awaiting it — a real, independently-reproduced deadlock.
    /// Making launch itself fully synchronous removes that class of bug
    /// structurally rather than by careful ordering.)
    func launch() -> Result<Void, Error> {
        storage.withLock { state in
            precondition(!state.hasLaunched, "ManagedProcess.launch() called more than once")
            do {
                try state.process.run()
                state.hasLaunched = true
                return .success(())
            } catch {
                return .failure(error)
            }
        }
    }

    /// Installs the termination-handler bridge. Must only be called
    /// exactly once, after a successful `launch()` — both are enforced by
    /// precondition, matching `launch()`'s own style, because violating
    /// either produces the same class of bug that motivated moving launch
    /// off the old `async let`-before-`run()` shape: calling this before
    /// a successful launch, or calling it twice (silently replacing the
    /// first closure), leaves whichever continuation depended on the
    /// dropped handler permanently unresumed. `onTermination` is invoked
    /// by `Foundation.Process` on its own callback thread, strictly after
    /// this call returns — never while this type's mutex is held, and
    /// never synchronously from within this method.
    func observeTermination(_ onTermination: @escaping @Sendable (ProcessTerminationReason) -> Void) {
        storage.withLock { state in
            precondition(state.hasLaunched, "ManagedProcess.observeTermination() called before a successful launch()")
            precondition(!state.hasObservedTermination, "ManagedProcess.observeTermination() called more than once")
            state.hasObservedTermination = true
            state.process.terminationHandler = { finished in
                let reason: ProcessTerminationReason = finished.terminationReason == .exit
                    ? .exited(status: finished.terminationStatus)
                    : .uncaughtSignal(finished.terminationStatus)
                onTermination(reason)
            }
        }
    }

    var isRunning: Bool {
        storage.withLock { $0.process.isRunning }
    }

    /// Requests graceful termination. Idempotent — safe to call more than
    /// once, including after the process has already exited: `SIGTERM` to
    /// an already-exited, not-yet-reaped process is harmless. Unlike
    /// `forceKillIfStillRunning()`, this does **not** check `isRunning`
    /// first inside the critical section — every caller in
    /// `FoundationProcessRunner` already separately observes a reason to
    /// terminate (a fatal intervention was just recorded, or the timeout
    /// deadline elapsed) before calling this, so the extra check would be
    /// redundant for those call sites. This is unchanged from this type's
    /// predecessor and not something this pass altered; noted here so the
    /// asymmetry with `forceKillIfStillRunning()` below is intentional,
    /// not an oversight.
    func terminate() {
        storage.withLock { $0.process.terminate() }
    }

    /// Sends `SIGKILL` only if the process is still observed running at
    /// the moment this call takes the lock, checked and signaled inside
    /// the same critical section. See this type's header comment for
    /// exactly what that does and does not guarantee.
    @discardableResult
    func forceKillIfStillRunning() -> Bool {
        storage.withLock { state in
            guard state.process.isRunning else { return false }
            kill(state.process.processIdentifier, SIGKILL)
            return true
        }
    }
}
