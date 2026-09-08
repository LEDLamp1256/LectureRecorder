//
//  CaptureStopOutcome.swift
//  LectureRecorder
//

/// The complete result of draining one capture cycle's `stop()`.
///
/// `failure` is the retained asynchronous capture failure for the cycle,
/// if any — frozen the moment failure admission closes, at the start of
/// `stop()`'s teardown. `observedCopyFailureCount` is the number of
/// buffer copies this mechanism observed failing during the cycle,
/// sampled only after every admitted buffer callback has finished
/// draining. A callback already admitted before `stop()` closes the
/// gate may still be in flight when `stop()` begins; its copy failure,
/// if any, is recorded — and counted here — only once that callback
/// actually finishes, which can happen after `stop()` has already begun
/// draining. No callback can be newly admitted once the gate is closed.
/// This count is not proof that the hardware or downstream pipeline
/// lost no audio; it reflects only what this accounting observed.
struct CaptureStopOutcome: Sendable {
    let failure: Error?
    let observedCopyFailureCount: Int
}
