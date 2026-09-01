/// Explicit state machine for the recording lifecycle.
///
/// This intentionally replaces any combination of independent Boolean
/// flags with a single source of truth. `SessionManager` is the only type
/// permitted to mutate this state, and only through
/// `isValidTransition(from:to:)`.
enum RecordingState: Equatable, Sendable {
    case idle
    case requestingPermission
    case preparing
    case recording
    case stopping
    case completed
    case failed(String)

    /// True only in `.recording`.
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// True for any `.failed` case, regardless of message.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension RecordingState {
    /// The full set of transitions this app permits. Any transition not
    /// explicitly listed here is rejected by `SessionManager.transition(to:)`.
    ///
    /// Notably, there is no direct `.failed -> .requestingPermission`
    /// transition: starting a new session after a failure always requires
    /// going through `.idle` via `SessionManager.resetAfterFailure()`,
    /// which itself requires that failure's resources to be resolved
    /// first. See `SessionManager` for the resource-ownership model this
    /// enforces.
    static func isValidTransition(from: RecordingState, to: RecordingState) -> Bool {
        switch (from, to) {
        case (.idle, .requestingPermission):
            return true
        case (.requestingPermission, .preparing):
            return true
        case (.requestingPermission, .failed):
            return true
        case (.preparing, .recording):
            return true
        case (.preparing, .failed):
            return true
        case (.recording, .stopping):
            return true
        case (.recording, .failed):
            return true
        case (.stopping, .completed):
            return true
        case (.stopping, .failed):
            return true
        case (.failed, .completed):
            // Used only by SessionManager.retryResolution() when a
            // previously-unresolved stop-finalization failure is
            // confirmed successful on retry.
            return true
        case (.failed, .idle):
            // Used only by SessionManager.resetAfterFailure(), which
            // requires unresolvedIssue == nil (all resources already
            // resolved, closed, and accurately persisted).
            return true
        case (.completed, .requestingPermission):
            // Safe direct restart: a clean stop already finalized and
            // closed everything, so there is nothing left to resolve.
            return true
        default:
            return false
        }
    }
}
