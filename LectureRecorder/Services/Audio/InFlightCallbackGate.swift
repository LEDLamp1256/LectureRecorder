//
//  InFlightCallbackGate.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/7/26.
//


import Synchronization

/// Lock-free realtime/non-realtime handoff for exactly one recording
/// cycle. NOT reusable — construct a fresh instance for every
/// prepare()/start()/stop() cycle.
nonisolated final class InFlightCallbackGate: Sendable {
    private let hasOpened = Atomic<Bool>(false)
    private let accepting = Atomic<Bool>(false)
    private let inFlightCount = Atomic<Int>(0)

    /// Call exactly once for this gate instance.
    func open() {
        let wasAlreadyOpened = hasOpened.exchange(
            true,
            ordering: .sequentiallyConsistent
        )

        precondition(
            wasAlreadyOpened == false,
            "InFlightCallbackGate is single-cycle and cannot be reopened."
        )

        precondition(
            accepting.load(ordering: .sequentiallyConsistent) == false,
            "InFlightCallbackGate.open() called while already accepting."
        )

        precondition(
            inFlightCount.load(ordering: .sequentiallyConsistent) == 0,
            "InFlightCallbackGate.open() called with a nonzero in-flight count."
        )

        accepting.store(true, ordering: .sequentiallyConsistent)
    }

    /// Called synchronously from the realtime tap. NEVER blocks.
    /// Returns true iff the caller now owes exactly one leave() call.
    func tryEnter() -> Bool {
        guard accepting.load(ordering: .sequentiallyConsistent) else {
            return false
        }

        inFlightCount.wrappingAdd(
            1,
            ordering: .sequentiallyConsistent
        )

        guard accepting.load(ordering: .sequentiallyConsistent) else {
            inFlightCount.wrappingSubtract(
                1,
                ordering: .sequentiallyConsistent
            )
            return false
        }

        return true
    }

    /// Called exactly once per successful tryEnter().
    func leave() {
        inFlightCount.wrappingSubtract(
            1,
            ordering: .sequentiallyConsistent
        )
    }

    /// Permanently closes admission for this single-cycle gate.
    func close() {
        accepting.store(
            false,
            ordering: .sequentiallyConsistent
        )
    }

    /// Non-realtime stop-side wait. Call only after close().
    func drain() async {
        while inFlightCount.load(ordering: .sequentiallyConsistent) != 0 {
            await Task.yield()
        }
    }
}
