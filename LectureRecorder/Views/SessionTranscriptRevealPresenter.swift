import Combine
import Foundation

/// Why the newest reveal request produced no `TranscriptRevealTarget`. No
/// destination is ever invented after a failure.
nonisolated enum TranscriptRevealFailure: Equatable, Sendable {
    /// No current transcript snapshot could be loaded for the requested
    /// session (transcript missing, incomplete, unreadable, or the loader
    /// returned a different session's snapshot).
    case sourceUnavailable(reason: String)
    /// The fresh snapshot loaded, but `TranscriptSourceResolver` rejected the
    /// reference against it — e.g. `.transcriptMismatch` when the transcript
    /// changed after the notes were generated. Never repaired.
    case unresolvable(TranscriptSourceResolutionError)
    /// The target was current, but the displayed transcript has no complete
    /// set of rows for its chunks. Nothing is partially revealed.
    case locationUnavailable
}

/// Concise, user-facing wording for a `TranscriptRevealFailure`. Never
/// exposes storage paths or underlying error detail.
nonisolated enum TranscriptRevealFailureMessage {
    static let transcriptChanged = "The transcript has changed since these notes were generated, so this source is no longer current."
    static let locationUnavailable = "The supporting transcript location is unavailable."
    static let sourceUnavailable = "The transcript source is unavailable."

    static func message(for failure: TranscriptRevealFailure) -> String {
        switch failure {
        case .unresolvable(.transcriptMismatch):
            return transcriptChanged
        case .unresolvable, .locationUnavailable:
            return locationUnavailable
        case .sourceUnavailable:
            return sourceUnavailable
        }
    }
}

/// A `.ready` target that passed application-time revalidation, bound to the
/// request that produced it. Only the same request's application can later
/// be consumed or rejected, even if a newer request resolves to an equal
/// target.
struct TranscriptRevealApplication: Equatable {
    let target: TranscriptRevealTarget
    fileprivate let requestGeneration: Int
}

/// What the Transcript pane should do with a pending target. Pure.
nonisolated enum TranscriptRevealApplicationOutcome: Equatable {
    /// Not for this pane (another session) or navigation not loaded yet:
    /// leave the target pending.
    case notApplicable
    /// Scroll to `scrollTargetID` and highlight every selected row.
    case apply(TranscriptRevealSelection)
    /// Navigation is loaded but cannot represent every referenced chunk.
    case locationUnavailable
}

nonisolated enum TranscriptRevealApplicationPlanner {
    static func outcome(
        for target: TranscriptRevealTarget,
        sessionID: UUID,
        navigation: TranscriptPlaybackNavigation?
    ) -> TranscriptRevealApplicationOutcome {
        guard target.sessionID == sessionID,
              let navigation, navigation.sessionID == sessionID else {
            return .notApplicable
        }
        guard let selection = TranscriptRevealSelectionBuilder.select(target, in: navigation) else {
            return .locationUnavailable
        }
        return .apply(selection)
    }
}

/// The newest reveal request's presentation state. Never persisted.
nonisolated enum TranscriptRevealState: Equatable, Sendable {
    case idle
    /// A request is in flight; any earlier target has already been dropped.
    case resolving
    case ready(TranscriptRevealTarget)
    case failed(TranscriptRevealFailure)
}

/// One window's presentation-only coordinator that turns a user-selected
/// Notes source reference into a pending `TranscriptRevealTarget`. Intended
/// to be owned by `CompletedSessionDetailView` so the pending target
/// survives Notes → Transcript remounts; it owns no playback state, starts
/// no persistent `Task`, writes nothing, and is never shared across windows.
///
/// Resolution goes only through the existing authoritative path: a fresh
/// `NotesTranscriptSourceLoading.loadCurrentSnapshot` followed by
/// `TranscriptSourceResolver.resolve` — nothing here re-validates or
/// reinterprets a reference itself.
///
/// Stale-request protection mirrors `SessionNotesPresenter` and
/// `SessionPlaybackPresenter`: an explicit generation counter, bumped by
/// every `requestReveal` and by `invalidate()`, and re-checked after the sole
/// `await`, so an older request — or one for a session the window has since
/// left — can never publish, regardless of `Task` cancellation.
@MainActor
final class SessionTranscriptRevealPresenter: ObservableObject {
    private let sourceLoader: any NotesTranscriptSourceLoading
    private var generation = 0

    /// The session the newest request was made for; `nil` when idle.
    @Published private(set) var sessionID: UUID?
    @Published private(set) var state: TranscriptRevealState = .idle

    init(sourceLoader: any NotesTranscriptSourceLoading) {
        self.sourceLoader = sourceLoader
    }

    /// The target the newest request resolved to, if it succeeded.
    var pendingTarget: TranscriptRevealTarget? {
        if case .ready(let target) = state { return target }
        return nil
    }

    /// Supersedes any earlier request immediately, then resolves `reference`
    /// against a freshly loaded snapshot of `entry`'s session.
    /// `transcriptFingerprint` is the fingerprint recorded by the document
    /// holding `reference` (`LectureNotesDocument.transcriptFingerprint`).
    func requestReveal(
        reference: NotesSourceReference,
        generatedFrom transcriptFingerprint: TranscriptSourceFingerprint,
        for entry: CompletedSessionEntry
    ) async {
        generation += 1
        let myGeneration = generation
        let requestedSessionID = entry.manifest.sessionID
        sessionID = requestedSessionID
        state = .resolving

        let snapshot: NotesTranscriptSourceSnapshot
        do {
            snapshot = try await sourceLoader.loadCurrentSnapshot(sessionID: requestedSessionID)
        } catch {
            guard myGeneration == generation else { return }
            state = .failed(.sourceUnavailable(reason: error.localizedDescription))
            return
        }
        guard myGeneration == generation else { return }

        guard snapshot.sessionID == requestedSessionID else {
            state = .failed(.sourceUnavailable(reason: "The loaded transcript belongs to a different session."))
            return
        }

        do {
            let resolved = try TranscriptSourceResolver.resolve(reference, generatedFrom: transcriptFingerprint, in: snapshot)
            state = .ready(TranscriptRevealTarget(resolved))
        } catch let error as TranscriptSourceResolutionError {
            state = .failed(.unresolvable(error))
        } catch {
            // `resolve` throws only `TranscriptSourceResolutionError`.
            state = .failed(.sourceUnavailable(reason: error.localizedDescription))
        }
    }

    /// Application-time identity check for the current `.ready` target: the
    /// transcript it was resolved against must still be the session's
    /// current transcript. Loads a fresh snapshot but never re-resolves the
    /// range. Returns `nil` — publishing a failure unless the request was
    /// superseded, invalidated, or already consumed meanwhile — when there
    /// is nothing current to apply.
    func revalidateReadyTarget(for entry: CompletedSessionEntry) async -> TranscriptRevealApplication? {
        guard case .ready(let target) = state else { return nil }
        let myGeneration = generation

        func isStillCurrent() -> Bool {
            myGeneration == generation && state == .ready(target)
        }

        guard entry.manifest.sessionID == target.sessionID else {
            state = .failed(.unresolvable(.sessionMismatch))
            return nil
        }

        let snapshot: NotesTranscriptSourceSnapshot
        do {
            snapshot = try await sourceLoader.loadCurrentSnapshot(sessionID: target.sessionID)
        } catch {
            guard isStillCurrent() else { return nil }
            state = .failed(.sourceUnavailable(reason: error.localizedDescription))
            return nil
        }
        guard isStillCurrent() else { return nil }

        guard snapshot.sessionID == target.sessionID else {
            state = .failed(.sourceUnavailable(reason: "The loaded transcript belongs to a different session."))
            return nil
        }
        guard snapshot.fingerprint == target.transcriptFingerprint else {
            state = .failed(.unresolvable(.transcriptMismatch))
            return nil
        }
        return TranscriptRevealApplication(target: target, requestGeneration: myGeneration)
    }

    /// Marks `application` as applied so a remounted Transcript pane does
    /// not reveal it again. A no-op unless it is still the current `.ready`
    /// target of the same request. Keeps the session association and does
    /// not advance the request generation — this is not an invalidation.
    func consume(_ application: TranscriptRevealApplication) {
        guard isCurrent(application) else { return }
        state = .idle
    }

    /// Replaces `application`'s still-current `.ready` target with
    /// `failure`, so an unrepresentable target is never retried in a loop.
    func reject(_ application: TranscriptRevealApplication, with failure: TranscriptRevealFailure) {
        guard isCurrent(application) else { return }
        state = .failed(failure)
    }

    private func isCurrent(_ application: TranscriptRevealApplication) -> Bool {
        application.requestGeneration == generation && state == .ready(application.target)
    }

    /// Drops any pending target or failure and makes every in-flight request
    /// stale — e.g. when the window's selected session changes.
    func invalidate() {
        generation += 1
        sessionID = nil
        state = .idle
    }
}
