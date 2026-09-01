import AppKit
import Combine
import Foundation
import OSLog

/// A failure that requires an explicit user action (retry or abandon)
/// before a new session can be started, because we cannot confirm the
/// on-disk manifest accurately reflects what happened.
struct UnresolvedSessionIssue: Equatable, Sendable {
    let sessionID: UUID
    let message: String
    let canRetry: Bool
}

/// Distinguishes what a pending retry is trying to accomplish, so
/// `retryResolution()` knows how to finish the job on success.
private enum RetryKind {
    case prepareFailure
    case stopFinalization
}

/// The single owner of recording state and the active session's lifecycle.
///
/// ## Resource ownership model
/// - `activeSession` is non-nil only while a session is being prepared,
///   recording, stopping, or while a failure involving that session is
///   still unresolved. Its value is always a manifest state we actually
///   confirmed was persisted to disk — never an attempted-but-unconfirmed
///   write. Two places this matters:
///   - If `stopSession()`'s final write fails, `activeSession` is left at
///     the still-`.recording` manifest that was confirmed earlier, not
///     the completed manifest we merely attempted to write; the attempted
///     completed manifest lives only in `pendingManifestForRetry` until a
///     write for it actually succeeds.
///   - If session preparation fails and the resulting `.failed` failure
///     record also fails to persist, `activeSession` is set to the
///     original prepared `.recording` manifest **only if that manifest's
///     own initial write is known to have succeeded**; otherwise it is
///     `nil`. The unconfirmed `.failed` manifest lives only in
///     `pendingManifestForRetry`.
/// - `lastCompletedSession` is set only once a session's final manifest
///   has been durably persisted and its logger closed. It exists purely
///   for display and is never mutated afterward.
/// - `unresolvedIssue` is non-nil only when we could not confirm a
///   session's on-disk state matches reality (a manifest write failed).
///   While it is non-nil, starting a new session is refused; the user
///   must call `retryResolution()` or `discardUnresolvedSession()` first.
/// - Leaving `.failed` for `.idle` only ever happens through the explicit
///   `resetAfterFailure()` call, which itself requires `unresolvedIssue`
///   to already be `nil`.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var activeSession: SessionManifest?
    @Published private(set) var lastCompletedSession: SessionManifest?
    @Published private(set) var unresolvedIssue: UnresolvedSessionIssue?
    @Published private(set) var lastKnownPermissionStatus: PermissionStatus = .undetermined
    @Published private(set) var revealFolderErrorMessage: String?

    private let store: any SessionStoring
    private let permissionService: MicrophonePermissionServing

    private var currentSessionPaths: SessionPaths?
    private var currentSessionLogger: SessionFileLogger?
    private var pendingManifestForRetry: SessionManifest?
    private var retryKind: RetryKind?
    private var isRetryInFlight = false
    private var isDiscardInFlight = false

    init(store: any SessionStoring, permissionService: MicrophonePermissionServing) {
        self.store = store
        self.permissionService = permissionService
    }

    var canStart: Bool {
        unresolvedIssue == nil && (state == .idle || state == .completed)
    }

    var canStop: Bool {
        state.isRecording
    }

    var canReset: Bool {
        state.isFailed && unresolvedIssue == nil
    }

    var canRetry: Bool {
        unresolvedIssue?.canRetry == true
    }

    var canDiscard: Bool {
        unresolvedIssue != nil
    }

    func refreshPermissionStatus() async {
        lastKnownPermissionStatus = permissionService.currentStatus()
    }

    /// Asks Finder to reveal the resolved sessions directory. Uses the
    /// actual URL the running process resolves at the time of the call —
    /// this is the only reliable way to locate the directory when the app
    /// is sandboxed, since the container path includes an
    /// OS-assigned/redirected prefix that isn't safe to hardcode.
    func revealSessionsFolderInFinder() async {
        revealFolderErrorMessage = nil
        do {
            let root = try await store.sessionsRootDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } catch {
            Log.fileSystem.error("Unable to resolve sessions directory: \(error.localizedDescription, privacy: .public)")
            revealFolderErrorMessage = "Unable to open the sessions folder: \(error.localizedDescription)"
        }
    }

    func startSession() async {
        guard canStart else {
            Log.session.notice(
                "startSession() ignored; state=\(String(describing: self.state), privacy: .public) unresolved=\(self.unresolvedIssue != nil, privacy: .public)"
            )
            return
        }

        transition(to: .requestingPermission)
        let status = await permissionService.requestPermission()
        lastKnownPermissionStatus = status

        guard status == .granted else {
            Log.permission.error("Microphone permission not granted: \(String(describing: status), privacy: .public)")
            transition(to: .failed("Microphone permission not granted."))
            return
        }

        transition(to: .preparing)

        let sessionID = UUID()
        var createdPaths: SessionPaths?
        var preparedManifest: SessionManifest?
        var initialManifestPersisted = false
        do {
            let paths = try await store.createSessionDirectories(sessionID: sessionID)
            createdPaths = paths

            let manifest = SessionManifest.newSession(
                id: sessionID,
                audioFormat: .defaultTarget,
                targetChunkDurationSeconds: 30.0
            )
            preparedManifest = manifest

            try await store.writeManifest(manifest, paths: paths)
            initialManifestPersisted = true

            let logger = try await store.createSessionLogger(paths: paths)
            await logger.log("Session \(sessionID.uuidString) created.")

            activeSession = manifest
            currentSessionPaths = paths
            currentSessionLogger = logger

            transition(to: .recording)
            Log.session.info("Session started: \(sessionID.uuidString, privacy: .public)")
        } catch {
            await handlePreparationFailure(
                sessionID: sessionID,
                paths: createdPaths,
                preparedManifest: preparedManifest,
                initialManifestPersisted: initialManifestPersisted,
                underlyingError: error
            )
        }
    }

    func stopSession() async {
        guard state.isRecording else {
            Log.session.notice("stopSession() ignored; state=\(String(describing: self.state), privacy: .public)")
            return
        }

        guard let session = activeSession, let paths = currentSessionPaths else {
            Log.session.fault("stopSession() reached .recording with no active session state; this indicates a bug.")
            transition(to: .failed("Internal error: no active session to stop."))
            return
        }

        transition(to: .stopping)

        var finalManifest = session
        finalManifest.endDate = Date()
        finalManifest.status = .completed
        finalManifest.endReason = .userStopped
        finalManifest.endedCleanly = true
        finalManifest.failureDescription = nil

        do {
            try await store.writeManifest(finalManifest, paths: paths)
            await currentSessionLogger?.log("Session \(finalManifest.sessionID.uuidString) stopped by user.")
            await currentSessionLogger?.close()

            lastCompletedSession = finalManifest
            activeSession = nil
            currentSessionPaths = nil
            currentSessionLogger = nil
            pendingManifestForRetry = nil
            retryKind = nil

            transition(to: .completed)
            Log.session.info("Session stopped: \(finalManifest.sessionID.uuidString, privacy: .public)")
        } catch {
            // We do not know whether "session.json" on disk reflects a
            // completed session, so `finalManifest` must not be presented
            // as confirmed anywhere in the UI. `activeSession` is left at
            // `session` — the manifest state we know was actually
            // persisted earlier (still status == .recording) — while the
            // desired completed version is held only in
            // `pendingManifestForRetry` until a write for it actually
            // succeeds (see retryResolution()).
            Log.session.error(
                "Failed to finalize session \(finalManifest.sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            await currentSessionLogger?.log(
                "Failed to persist final manifest: \(error.localizedDescription)",
                level: "ERROR"
            )

            activeSession = session
            pendingManifestForRetry = finalManifest
            retryKind = .stopFinalization
            unresolvedIssue = UnresolvedSessionIssue(
                sessionID: finalManifest.sessionID,
                message: "Could not confirm session \(finalManifest.sessionID.uuidString) finished saving: \(error.localizedDescription)",
                canRetry: true
            )

            transition(to: .failed(error.localizedDescription))
        }
    }

    /// Retries whichever manifest write previously failed — either
    /// finishing a preparation failure's persisted failure record, or
    /// finalizing a stopped session. Safe to call repeatedly; concurrent
    /// invocations are ignored while one is already in flight.
    func retryResolution() async {
        guard !isRetryInFlight else {
            Log.session.notice("retryResolution() ignored; a retry is already in progress")
            return
        }
        guard let issue = unresolvedIssue, issue.canRetry,
              let pending = pendingManifestForRetry,
              let paths = currentSessionPaths,
              let kind = retryKind else {
            Log.session.notice("retryResolution() called with nothing eligible to retry")
            return
        }

        isRetryInFlight = true
        defer { isRetryInFlight = false }

        do {
            try await store.writeManifest(pending, paths: paths)

            switch kind {
            case .stopFinalization:
                await currentSessionLogger?.log("Session \(pending.sessionID.uuidString) finalized on retry.")
                await currentSessionLogger?.close()
                lastCompletedSession = pending
                activeSession = nil
                currentSessionPaths = nil
                currentSessionLogger = nil
                pendingManifestForRetry = nil
                retryKind = nil
                unresolvedIssue = nil
                transition(to: .completed)
                Log.session.info("Session finalized on retry: \(pending.sessionID.uuidString, privacy: .public)")

            case .prepareFailure:
                await currentSessionLogger?.close()
                activeSession = nil
                currentSessionPaths = nil
                currentSessionLogger = nil
                pendingManifestForRetry = nil
                retryKind = nil
                unresolvedIssue = nil
                Log.session.info(
                    "Failure record persisted on retry for session \(pending.sessionID.uuidString, privacy: .public); call resetAfterFailure() to continue."
                )
            }
        } catch {
            Log.session.error("retryResolution() failed again: \(error.localizedDescription, privacy: .public)")
            unresolvedIssue = UnresolvedSessionIssue(
                sessionID: pending.sessionID,
                message: "Retry failed again: \(error.localizedDescription)",
                canRetry: true
            )
        }
    }

    /// Gives up on confirming what happened to the unresolved session.
    /// Closes any open resources best-effort and clears in-memory
    /// references, but deliberately does NOT overwrite the on-disk
    /// manifest with unverified data and does NOT delete any session
    /// files. Only ever invoked in response to an explicit, confirmed
    /// user action — never automatically.
    func discardUnresolvedSession() async {
        guard !isDiscardInFlight else {
            Log.session.notice("discardUnresolvedSession() ignored; already in progress")
            return
        }
        guard let issue = unresolvedIssue else {
            Log.session.notice("discardUnresolvedSession() called with no unresolved issue")
            return
        }

        isDiscardInFlight = true
        defer { isDiscardInFlight = false }

        Log.session.error(
            "Abandoning recovery attempt for session \(issue.sessionID.uuidString, privacy: .public) without confirmed finalization. Session files are left untouched on disk."
        )
        await currentSessionLogger?.log(
            "Recovery attempt abandoned by user without confirmed finalization.",
            level: "ERROR"
        )
        await currentSessionLogger?.close()

        activeSession = nil
        currentSessionPaths = nil
        currentSessionLogger = nil
        pendingManifestForRetry = nil
        retryKind = nil
        unresolvedIssue = nil
    }

    /// Explicitly clears a resolved failure and returns to `.idle`. Only
    /// valid once `unresolvedIssue` is nil — i.e., after either the
    /// failure path automatically persisted an accurate failed manifest,
    /// or the user called `retryResolution()` / `discardUnresolvedSession()`.
    func resetAfterFailure() {
        guard canReset else {
            Log.session.notice(
                "resetAfterFailure() ignored; state=\(String(describing: self.state), privacy: .public) unresolved=\(self.unresolvedIssue != nil, privacy: .public)"
            )
            return
        }
        activeSession = nil
        currentSessionPaths = nil
        currentSessionLogger = nil
        transition(to: .idle)
    }

    /// Persists a failure record for a session that failed somewhere
    /// during preparation (directory creation, initial manifest write, or
    /// logger creation).
    ///
    /// `preparedManifest` is the exact in-memory `SessionManifest` that
    /// was constructed — and possibly already written — before the
    /// failure occurred. It is mutated into a *copy* representing its
    /// failed form (`failedManifest`) rather than reconstructed via
    /// `SessionManifest.newSession`, so its original `creationDate` and
    /// any other prepared metadata survive into the persisted failure
    /// record. `preparedManifest` itself is never mutated.
    ///
    /// `initialManifestPersisted` tells us whether `preparedManifest`'s
    /// own `.recording` write is confirmed to have reached disk. This
    /// matters only in the branch where writing `failedManifest` *also*
    /// fails: `activeSession` must reflect a manifest state we actually
    /// confirmed was persisted, so it is set to `preparedManifest` when
    /// that initial write succeeded, and to `nil` when it did not —
    /// never to the unconfirmed `failedManifest`, which lives only in
    /// `pendingManifestForRetry` until a write for it actually succeeds.
    private func handlePreparationFailure(
        sessionID: UUID,
        paths: SessionPaths?,
        preparedManifest: SessionManifest?,
        initialManifestPersisted: Bool,
        underlyingError: Error
    ) async {
        let description = underlyingError.localizedDescription
        Log.session.error("Session preparation failed: \(description, privacy: .public)")

        guard let paths else {
            // Directories were never created; nothing on disk to
            // reconcile, and startSession()'s ordering means a manifest
            // could not have been constructed without paths existing
            // first, so preparedManifest/initialManifestPersisted would
            // also be nil/false here.
            transition(to: .failed(description))
            return
        }

        // preparedManifest should always be non-nil whenever paths is
        // non-nil, given startSession()'s ordering (paths are created,
        // then the manifest is constructed, and only afterward can
        // writeManifest or createSessionLogger fail). The fallback below
        // is defensive only, in case that ordering ever changes.
        var failedManifest = preparedManifest ?? SessionManifest.newSession(
            id: sessionID,
            audioFormat: .defaultTarget,
            targetChunkDurationSeconds: 30.0
        )
        failedManifest.status = .failed
        failedManifest.endDate = Date()
        failedManifest.endReason = .error
        failedManifest.endedCleanly = false
        failedManifest.failureDescription = description

        do {
            try await store.writeManifest(failedManifest, paths: paths)
            // The failure is fully and accurately recorded on disk.
            // There is no logger to close here (creating it is exactly
            // what may have failed), and nothing is left unresolved.
            activeSession = nil
            currentSessionPaths = nil
            currentSessionLogger = nil
            transition(to: .failed(description))
        } catch let persistError {
            Log.session.error(
                "Failed to persist failure state for session \(sessionID.uuidString, privacy: .public): \(persistError.localizedDescription, privacy: .public)"
            )
            // failedManifest was NOT confirmed persisted, so it must not
            // become activeSession. Only preparedManifest (unmutated,
            // still .recording) is eligible, and only if its own write
            // is known to have succeeded.
            activeSession = initialManifestPersisted ? preparedManifest : nil
            currentSessionPaths = paths
            pendingManifestForRetry = failedManifest
            retryKind = .prepareFailure
            unresolvedIssue = UnresolvedSessionIssue(
                sessionID: sessionID,
                message: "Failed to save failure record for session \(sessionID.uuidString): \(persistError.localizedDescription)",
                canRetry: true
            )
            transition(to: .failed(description))
        }
    }

    private func transition(to newState: RecordingState) {
        guard RecordingState.isValidTransition(from: state, to: newState) else {
            Log.session.fault(
                "Rejected invalid state transition: \(String(describing: self.state), privacy: .public) -> \(String(describing: newState), privacy: .public)"
            )
            return
        }
        Log.session.debug(
            "State transition: \(String(describing: self.state), privacy: .public) -> \(String(describing: newState), privacy: .public)"
        )
        state = newState
    }
}
