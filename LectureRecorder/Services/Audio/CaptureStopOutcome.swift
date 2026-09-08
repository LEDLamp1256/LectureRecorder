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
/// draining — including ones that begin after `stop()` starts closing
/// the cycle. It is not proof that the hardware or downstream pipeline
/// lost no audio; it reflects only what this accounting observed.
struct CaptureStopOutcome: Sendable {
    let failure: Error?
    let observedCopyFailureCount: Int
}
