//
//  SpyChunkFinalizationFileSystem.swift
//  LectureRecorderTests
//


import Foundation
import Synchronization
@testable import LectureRecorder

/// A recording decorator over a real `ChunkFinalizationFileSystem`
/// conformer (`DarwinChunkFinalizationFileSystem` by default). Every call
/// is recorded in exact order; a call whose error has been injected throws
/// that error instead of delegating. When no error is injected, the call
/// delegates to the wrapped real conformer, so a "successful" rename in a
/// test actually renames a file on disk — a no-op recording-only rename
/// would let a test observe a canonical file that was never really
/// created.
///
/// All mutable state (call history, injected errors, the synchronizeFile
/// gate's armed flag) is confined behind `Synchronization.Mutex` and only
/// ever read or written through `withLock`. `@unchecked Sendable` is used
/// only because this type also stores two `DispatchSemaphore`s used as a
/// deterministic blocking gate for concurrency tests — `DispatchSemaphore`
/// is itself safely shared across threads by design (signal/wait are its
/// own synchronization), but the compiler does not treat a class holding
/// one as automatically `Sendable`-eligible under this project's strict
/// concurrency settings. Every other mutable access in this type goes
/// through the mutex; nothing is read or written outside `withLock` except
/// signaling/waiting on the semaphores themselves.
final class SpyChunkFinalizationFileSystem: ChunkFinalizationFileSystem, @unchecked Sendable {
    enum Call: Equatable {
        case synchronizeFile(URL)
        case rename(from: URL, to: URL)
        case synchronizeDirectory(URL)
    }

    private struct State {
        var calls: [Call] = []
        var synchronizeFileError: Error?
        var renameError: Error?
        var synchronizeDirectoryError: Error?
        var synchronizeFileGateArmed = false
    }

    private let real: any ChunkFinalizationFileSystem
    private let state = Mutex(State())

    /// Signaled once `synchronizeFile(at:)` has been entered while the gate
    /// is armed, so a test can deterministically wait until the writer's
    /// private queue is actually blocked before asserting anything about
    /// concurrent submission.
    private let synchronizeFileEntered = DispatchSemaphore(value: 0)
    /// Waited on by `synchronizeFile(at:)` while the gate is armed; a test
    /// must call `releaseSynchronizeFileGate()` to let the call proceed.
    private let synchronizeFileRelease = DispatchSemaphore(value: 0)

    init(wrapping real: any ChunkFinalizationFileSystem = DarwinChunkFinalizationFileSystem()) {
        self.real = real
    }

    var recordedCalls: [Call] {
        state.withLock { $0.calls }
    }

    func setSynchronizeFileError(_ error: Error?) {
        state.withLock { $0.synchronizeFileError = error }
    }

    func setRenameError(_ error: Error?) {
        state.withLock { $0.renameError = error }
    }

    func setSynchronizeDirectoryError(_ error: Error?) {
        state.withLock { $0.synchronizeDirectoryError = error }
    }

    /// Arms a one-shot gate on the next `synchronizeFile(at:)` call: that
    /// call will signal `waitForSynchronizeFileEntry` and then block until
    /// `releaseSynchronizeFileGate()` is called.
    func armSynchronizeFileGate() {
        state.withLock { $0.synchronizeFileGateArmed = true }
    }

    /// Blocks the calling thread (not the writer's queue) until a gated
    /// `synchronizeFile(at:)` call has actually been entered, or until
    /// `timeout`. Always call `releaseSynchronizeFileGate()` afterward —
    /// including via `defer`, before any assertion that could fail — so a
    /// failed test can never strand the writer's queue mid-call.
    @discardableResult
    func waitForSynchronizeFileEntry(timeout: DispatchTime) -> DispatchTimeoutResult {
        synchronizeFileEntered.wait(timeout: timeout)
    }

    /// Releases a gated `synchronizeFile(at:)` call so it can proceed to
    /// either throw its injected error or delegate to the real conformer.
    /// Safe to call even if no call is currently gated/blocked.
    func releaseSynchronizeFileGate() {
        synchronizeFileRelease.signal()
    }

    func synchronizeFile(at url: URL) throws {
        let (injectedError, gateArmed) = state.withLock { state -> (Error?, Bool) in
            state.calls.append(.synchronizeFile(url))
            let armed = state.synchronizeFileGateArmed
            state.synchronizeFileGateArmed = false
            return (state.synchronizeFileError, armed)
        }

        if gateArmed {
            synchronizeFileEntered.signal()
            synchronizeFileRelease.wait()
        }

        if let injectedError {
            throw injectedError
        }
        try real.synchronizeFile(at: url)
    }

    func rename(from source: URL, to destination: URL) throws {
        let injectedError = state.withLock { state -> Error? in
            state.calls.append(.rename(from: source, to: destination))
            return state.renameError
        }

        if let injectedError {
            throw injectedError
        }
        try real.rename(from: source, to: destination)
    }

    func synchronizeDirectory(at url: URL) throws {
        let injectedError = state.withLock { state -> Error? in
            state.calls.append(.synchronizeDirectory(url))
            return state.synchronizeDirectoryError
        }

        if let injectedError {
            throw injectedError
        }
        try real.synchronizeDirectory(at: url)
    }
}
