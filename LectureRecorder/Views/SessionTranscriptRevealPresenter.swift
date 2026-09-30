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

    /// Drops any pending target or failure and makes every in-flight request
    /// stale — e.g. when the window's selected session changes.
    func invalidate() {
        generation += 1
        sessionID = nil
        state = .idle
    }
}
