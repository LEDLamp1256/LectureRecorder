import Synchronization

/// Owns exactly one invocation's terminal-outcome linearization.
///
/// This is a plain `Mutex`-guarded class, deliberately not an `actor`.
/// `Foundation.Process.terminationHandler` fires on an arbitrary thread, and
/// `withTaskCancellationHandler(onCancel:)`'s `onCancel` closure is
/// synchronous, non-isolated, and cannot `await` — reaching actor isolation
/// from either would require spawning a new unstructured `Task` merely to
/// record an event, which this repository's own `FailureCoordinator`
/// (`Services/Audio/AudioCaptureService.swift`) avoids for the identical
/// reason, using a synchronized critical section instead. This type follows
/// that same precedent, simplified: `FailureCoordinator` also guarantees
/// exactly-once, off-critical-section *delivery* of a claimed failure to an
/// external handler; this type has no equivalent delivery step; the caller
/// itself reads the outcome once every concurrent operation has already
/// been joined.
///
/// ## Linearization
/// Exactly one of two things may ever happen to an instance of this type:
/// either `tryCommitSuccess()` returns `true` (nothing was ever recorded
/// before it), or one or more calls to `recordFatalIntervention(_:)`
/// establish a failure that every later `tryCommitSuccess()` call is
/// refused against. Whichever happens first, under this type's internal
/// lock, wins — permanently. There is no `Phase` enum: acceptance begins
/// the instant an instance is constructed (i.e. at `notStarted`, before any
/// process is even launched), because the lock has no separate "not yet
/// listening" state to be caught in.
///
/// Genuinely `Sendable`, not `@unchecked` — `Storage` (`ProcessRunFailure?`,
/// `Bool`) is entirely `Sendable`, so `Mutex<Storage>` is `Sendable` too,
/// and this `final` class's only stored property is that mutex.
nonisolated final class ProcessInvocationState: Sendable {
    private struct Storage {
        var claimedFailure: ProcessRunFailure?
        var hasCommittedSuccess = false
    }

    private let storage = Mutex(Storage())

    init() {}

    /// Records `failure` as the invocation's terminal outcome, unless a
    /// fatal intervention was already recorded or success was already
    /// committed. Returns `true` iff this call was the one that
    /// established the recorded failure — natural exit, a duplicate
    /// intervention from another concurrent source, or an intervention
    /// arriving after success was already committed, all return `false`
    /// and change nothing. Idempotent: safe to call more than once from
    /// more than one racing source (e.g. a timeout firing at the same
    /// moment cancellation is observed).
    @discardableResult
    func recordFatalIntervention(_ failure: ProcessRunFailure) -> Bool {
        storage.withLock { state in
            guard state.claimedFailure == nil, state.hasCommittedSuccess == false else {
                return false
            }
            state.claimedFailure = failure
            return true
        }
    }

    /// Attempts to commit success. Refused (returns `false`) if any fatal
    /// intervention was already recorded — a fully-valid response is
    /// discarded rather than allowed to override an earlier intervention.
    /// A cancellation or timeout that arrives *after* this call has already
    /// returned `true` has no further effect: `recordFatalIntervention`
    /// above will itself refuse once `hasCommittedSuccess` is set.
    func tryCommitSuccess() -> Bool {
        storage.withLock { state in
            guard state.claimedFailure == nil else { return false }
            state.hasCommittedSuccess = true
            return true
        }
    }

    /// The currently-recorded fatal intervention, if any. Safe to read at
    /// any point, including before launch, to decide whether to skip
    /// launching at all.
    var claimedFailure: ProcessRunFailure? {
        storage.withLock { $0.claimedFailure }
    }
}
