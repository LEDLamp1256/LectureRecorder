import Foundation

/// Pure decision of whether an open Completed Sessions window should
/// reload its catalog listing, given a `SessionManager.lastCompletedSession`
/// transition observed via
/// `.onChange(of: sessionManager.lastCompletedSession?.sessionID)`.
///
/// `lastCompletedSession` is set only once a session's final manifest has
/// been durably persisted as `.completed` (see `SessionManager`'s own
/// documentation) — so keying on *that* publishing a genuinely new session
/// id already guarantees no refresh happens while a session is still being
/// finalized, with no polling required. Never fires for `nil -> nil` (no
/// completion has ever happened) or `A -> A` (no change); fires for
/// `nil -> A` and `A -> B` alike, since both name a newly-finalized session.
nonisolated enum CompletedSessionsRefreshTrigger {
    static func shouldRefresh(oldLastCompletedSessionID: UUID?, newLastCompletedSessionID: UUID?) -> Bool {
        guard let newLastCompletedSessionID else { return false }
        return newLastCompletedSessionID != oldLastCompletedSessionID
    }
}
