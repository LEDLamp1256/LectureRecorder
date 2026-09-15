import Combine
import Foundation

/// One Completed Sessions window's presentation state: the last-loaded
/// catalog listing, any load error, and this window's own local selection.
///
/// A thin presentation helper, not a second operation owner: it only calls
/// the injected, already-read-only `CompletedSessionCatalog` and remembers
/// the result — never reconciliation, inference, or transcription
/// scheduling, and it owns no persistent background `Task` or polling
/// timer. On a successful `reload()`, `selectedSessionID` survives as long
/// as that session is still present in the refreshed result; it is cleared
/// to `nil` only when the previously-selected session has genuinely
/// disappeared (never auto-moved to some other, newly-appearing session).
/// A *failed* reload never touches `selectedSessionID` at all.
@MainActor
final class CompletedSessionsListPresenter: ObservableObject {
    private let catalog: CompletedSessionCatalog

    @Published private(set) var result: CompletedSessionCatalogResult?
    @Published var loadErrorMessage: String?
    @Published var selectedSessionID: UUID?

    init(catalog: CompletedSessionCatalog) {
        self.catalog = catalog
    }

    func reload() {
        do {
            let refreshed = try catalog.listCompletedSessions()
            result = refreshed
            if let selectedSessionID, !refreshed.sessions.contains(where: { $0.manifest.sessionID == selectedSessionID }) {
                self.selectedSessionID = nil
            }
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    /// The live, no-polling refresh entry point: reloads only when
    /// `CompletedSessionsRefreshTrigger` confirms this is a genuine
    /// newly-finalized completion, never merely because the window
    /// observed some other change.
    func refreshAfterFinalization(oldLastCompletedSessionID: UUID?, newLastCompletedSessionID: UUID?) {
        guard CompletedSessionsRefreshTrigger.shouldRefresh(
            oldLastCompletedSessionID: oldLastCompletedSessionID,
            newLastCompletedSessionID: newLastCompletedSessionID
        ) else { return }
        reload()
    }
}
