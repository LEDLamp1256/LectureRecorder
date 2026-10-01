import Combine
import Foundation

/// Why the newest Summary → Notes reveal produced no applicable target. No
/// destination is ever guessed after a failure.
nonisolated enum SummaryNotesRevealFailure: Equatable, Sendable {
    /// The Summary's source Notes generation could not be loaded as a valid,
    /// current Summary source, or the loaded source belongs to a different
    /// session or generation.
    case sourceUnavailable
    /// The source loaded, but its Notes document or transcript fingerprint
    /// differs from the one the Summary recorded.
    case sourceChanged
    /// The source is current, but the passage's supporting Note items are
    /// missing, repeated, or not all present in the displayed Notes.
    case locationUnavailable
}

/// Concise, user-facing wording for a `SummaryNotesRevealFailure`. Never
/// exposes storage paths or underlying error detail.
nonisolated enum SummaryNotesRevealFailureMessage {
    static let sourceUnavailable = "The Notes this Summary was generated from are no longer available."
    static let sourceChanged = "The Notes or transcript have changed since this Summary was generated, so its supporting Notes are no longer current."
    static let locationUnavailable = "The supporting Notes for this passage are unavailable."

    static func message(for failure: SummaryNotesRevealFailure) -> String {
        switch failure {
        case .sourceUnavailable: return sourceUnavailable
        case .sourceChanged: return sourceChanged
        case .locationUnavailable: return locationUnavailable
        }
    }
}

/// Exact-identity check of a freshly loaded Summary source against a target:
/// the same session, Notes generation, Notes document fingerprint, and
/// transcript fingerprint, with every supporting Note item present exactly
/// once. Pure; matches by ID only.
nonisolated enum SummaryNotesRevealSourceValidation {
    /// `nil` when `snapshot` is exactly the source `target` was derived from.
    static func failure(of target: SummaryNotesRevealTarget, against snapshot: LectureSummarySourceSnapshot) -> SummaryNotesRevealFailure? {
        guard snapshot.sessionID == target.sessionID,
              snapshot.sourceNotesGenerationID == target.sourceNotesGenerationID else {
            return .sourceUnavailable
        }
        guard snapshot.sourceNotesDocumentFingerprint == target.sourceNotesDocumentFingerprint,
              snapshot.transcriptFingerprint == target.transcriptFingerprint else {
            return .sourceChanged
        }
        let supportIDs = Set(target.supportingNoteItemIDs)
        guard !supportIDs.isEmpty, supportIDs.count == target.supportingNoteItemIDs.count else {
            return .locationUnavailable
        }
        var occurrences: [UUID: Int] = [:]
        for sourceItem in snapshot.sourceItems where supportIDs.contains(sourceItem.item.id) {
            occurrences[sourceItem.item.id, default: 0] += 1
        }
        guard occurrences.count == supportIDs.count, occurrences.values.allSatisfy({ $0 == 1 }) else {
            return .locationUnavailable
        }
        return nil
    }
}

/// A `.ready` target that passed application-time revalidation, bound to the
/// request that produced it. Only the same request's application can later
/// be consumed or rejected, even if a newer request resolves to an equal
/// target.
struct SummaryNotesRevealApplication: Equatable {
    let target: SummaryNotesRevealTarget
    fileprivate let requestGeneration: Int
}

/// The newest Summary → Notes reveal request's state. Never persisted.
nonisolated enum SummaryNotesRevealState: Equatable, Sendable {
    case idle
    /// A request is in flight; any earlier target and pin were dropped.
    case resolving
    case ready(SummaryNotesRevealTarget)
    case failed(SummaryNotesRevealFailure)
}

/// What the Notes pane is showing for the pinned generation, as far as
/// applying a Summary reveal is concerned.
nonisolated enum SummaryNotesRevealDisplayedNotes: Equatable {
    /// The pinned generation's refresh has not published yet: wait.
    case loading
    /// The pinned refresh published this completed document.
    case completed(LectureNotesDocument)
    /// The pinned refresh published anything but a completed document.
    case unavailable
}

/// What the Notes pane should do with a pending Summary reveal. Pure.
nonisolated enum SummaryNotesRevealApplicationOutcome: Equatable {
    /// Not for this pane (another session or generation) or still loading:
    /// leave the target pending.
    case notApplicable
    /// Scroll to the selection's scroll target and highlight every item.
    case apply(SummaryNotesRevealSelection)
    /// The displayed Notes cannot represent the target; nothing is applied.
    case unavailable(SummaryNotesRevealFailure)
}

nonisolated enum SummaryNotesRevealApplicationPlanner {
    static func outcome(
        for target: SummaryNotesRevealTarget,
        sessionID: UUID,
        pinnedNotesGenerationID: UUID?,
        notes: SummaryNotesRevealDisplayedNotes
    ) -> SummaryNotesRevealApplicationOutcome {
        guard target.sessionID == sessionID,
              pinnedNotesGenerationID == target.sourceNotesGenerationID else {
            return .notApplicable
        }
        switch notes {
        case .loading:
            return .notApplicable
        case .unavailable:
            return .unavailable(.sourceUnavailable)
        case .completed(let document):
            guard let selection = SummaryNotesRevealSelectionBuilder.select(target, in: document) else {
                return .unavailable(.locationUnavailable)
            }
            return .apply(selection)
        }
    }
}

/// The exact Summary source a pin stands for: the Notes generation, Notes
/// document version, and transcript one `LectureSummaryDocument` was
/// generated from. Two Summary reveals share a pin only when all four
/// fields match — the generation ID alone is not enough. Never persisted.
nonisolated struct SummaryNotesSourceIdentity: Equatable, Sendable {
    let sessionID: UUID
    let sourceNotesGenerationID: UUID
    let sourceNotesDocumentFingerprint: NotesDocumentFingerprint
    let transcriptFingerprint: TranscriptSourceFingerprint

    init(document: LectureSummaryDocument) {
        sessionID = document.sessionID
        sourceNotesGenerationID = document.sourceNotesGenerationID
        sourceNotesDocumentFingerprint = document.sourceNotesDocumentFingerprint
        transcriptFingerprint = document.transcriptFingerprint
    }

    init(target: SummaryNotesRevealTarget) {
        sessionID = target.sessionID
        sourceNotesGenerationID = target.sourceNotesGenerationID
        sourceNotesDocumentFingerprint = target.sourceNotesDocumentFingerprint
        transcriptFingerprint = target.transcriptFingerprint
    }
}

/// One window's presentation-only coordinator for Summary → Notes reveals.
/// Owned by `CompletedSessionDetailView` so both the pending target and the
/// Notes generation pin survive Summary → Notes remounts; it starts no
/// persistent `Task`, writes nothing, touches no playback, and is never
/// shared across windows.
///
/// Holds two related but distinct pieces of state:
/// - `state`: the newest request's pending reveal, consumed once applied.
/// - `pinnedSource`: the exact Summary source whose Notes generation the
///   Notes pane must display while browsing Summary evidence.
///
/// Pin transitions:
/// - A new request always supersedes the pending reveal and bumps
///   `revealRequestCount` (so the Notes pane drops the old highlight). It
///   keeps the pin when the new passage's Summary has the same exact source
///   identity, and drops it immediately otherwise.
/// - Only a successful request establishes a pin.
/// - A failure that means the source itself is invalid or changed drops the
///   pin; `locationUnavailable`, an operational load failure, and
///   cancellation keep a still-valid same-source pin.
/// - Consuming a reveal keeps the pin; `clearPin()` (Show Latest Notes) and
///   `invalidate()` (session change) drop it.
///
/// Validation goes only through `LectureSummarySourceLoading`, by exact
/// session, generation, fingerprints, and Note item IDs — never text.
///
/// Stale-request protection mirrors `SessionTranscriptRevealPresenter`: an
/// explicit generation counter bumped by every request, `clearPin()`, and
/// `invalidate()`, and re-checked after every `await`.
@MainActor
final class SessionSummaryNotesRevealPresenter: ObservableObject {
    private let sourceLoader: any LectureSummarySourceLoading
    private var generation = 0

    /// The session the newest request was made for; `nil` when idle.
    @Published private(set) var sessionID: UUID?
    @Published private(set) var state: SummaryNotesRevealState = .idle
    /// The exact Summary source currently pinned, set only by a successful
    /// request.
    @Published private(set) var pinnedSource: SummaryNotesSourceIdentity?
    /// Bumped by every `requestReveal`, so the Notes pane can drop a previous
    /// reveal's highlight even when the pin itself does not change.
    @Published private(set) var revealRequestCount = 0

    init(sourceLoader: any LectureSummarySourceLoading) {
        self.sourceLoader = sourceLoader
    }

    /// The pinned Notes generation, if any.
    var pinnedNotesGenerationID: UUID? { pinnedSource?.sourceNotesGenerationID }

    /// The target the newest request resolved to, if it succeeded and has
    /// not been applied yet.
    var pendingTarget: SummaryNotesRevealTarget? {
        if case .ready(let target) = state { return target }
        return nil
    }

    /// The pin, only when it belongs to `sessionID`.
    func pinnedNotesGenerationID(forSessionID sessionID: UUID) -> UUID? {
        self.sessionID == sessionID ? pinnedNotesGenerationID : nil
    }

    /// Whether `failure` means the pinned source itself can no longer be
    /// trusted, as opposed to one passage's support being unshowable.
    private static func invalidatesPin(_ failure: SummaryNotesRevealFailure) -> Bool {
        switch failure {
        case .sourceUnavailable, .sourceChanged: return true
        case .locationUnavailable: return false
        }
    }

    private func fail(_ failure: SummaryNotesRevealFailure, keepingPin: Bool) {
        if !keepingPin { pinnedSource = nil }
        state = .failed(failure)
    }

    /// Maps a thrown source load error: `nil` for cancellation (leave state
    /// alone); otherwise the failure and whether a valid pin survives it.
    /// Only an ordinary operational error leaves the source's validity
    /// unknown, so only it keeps the pin.
    private static func loadFailure(_ error: Error) -> (failure: SummaryNotesRevealFailure, keepsPin: Bool)? {
        if error is CancellationError || Task.isCancelled { return nil }
        switch SummarySourceLoadFailureClassification.classify(error) {
        case .operational: return (.sourceUnavailable, true)
        case .sourceInvalid: return (.sourceUnavailable, false)
        }
    }

    /// Supersedes any earlier request immediately — dropping the pin unless
    /// `document` has the pinned source's exact identity — then validates
    /// `passage`'s support against a fresh load of that source.
    func requestReveal(
        document: LectureSummaryDocument,
        passage: LectureSummaryPassage,
        for entry: CompletedSessionEntry
    ) async {
        generation += 1
        let myGeneration = generation
        let requestedSessionID = entry.manifest.sessionID
        let identity = SummaryNotesSourceIdentity(document: document)
        let isSameSource = identity == pinnedSource
            && identity.sessionID == requestedSessionID
            && sessionID == requestedSessionID
        if !isSameSource { pinnedSource = nil }
        sessionID = requestedSessionID
        revealRequestCount += 1
        state = .resolving

        guard let target = SummaryNotesRevealTarget(document: document, passage: passage) else {
            fail(.locationUnavailable, keepingPin: true)
            return
        }
        guard target.sessionID == requestedSessionID else {
            fail(.sourceUnavailable, keepingPin: false)
            return
        }

        let snapshot: LectureSummarySourceSnapshot
        do {
            snapshot = try await sourceLoader.loadSourceSnapshot(
                sessionID: target.sessionID,
                notesGenerationID: target.sourceNotesGenerationID
            )
        } catch {
            guard myGeneration == generation else { return }
            guard let loadFailure = Self.loadFailure(error) else {
                state = .idle
                return
            }
            fail(loadFailure.failure, keepingPin: loadFailure.keepsPin)
            return
        }
        guard myGeneration == generation else { return }

        if let failure = SummaryNotesRevealSourceValidation.failure(of: target, against: snapshot) {
            fail(failure, keepingPin: !Self.invalidatesPin(failure))
            return
        }
        pinnedSource = identity
        state = .ready(target)
    }

    /// Application-time identity check for the current `.ready` target
    /// against a second fresh source load. Never regenerates or re-derives
    /// support. Returns `nil` — publishing a failure (and dropping the pin
    /// when the source itself is no longer trusted), unless the request was
    /// superseded, cleared, consumed, or cancelled meanwhile — when there is
    /// nothing current to apply.
    func revalidateReadyTarget(for entry: CompletedSessionEntry) async -> SummaryNotesRevealApplication? {
        guard case .ready(let target) = state else { return nil }
        let myGeneration = generation

        func isStillCurrent() -> Bool {
            myGeneration == generation && state == .ready(target)
        }

        guard entry.manifest.sessionID == target.sessionID else {
            fail(.sourceUnavailable, keepingPin: false)
            return nil
        }

        let snapshot: LectureSummarySourceSnapshot
        do {
            snapshot = try await sourceLoader.loadSourceSnapshot(
                sessionID: target.sessionID,
                notesGenerationID: target.sourceNotesGenerationID
            )
        } catch {
            // A cancelled application attempt (e.g. the Notes pane went
            // away) says nothing about the source: leave the target pending
            // and the pin in place for the next attempt.
            guard isStillCurrent(), let loadFailure = Self.loadFailure(error) else { return nil }
            fail(loadFailure.failure, keepingPin: loadFailure.keepsPin)
            return nil
        }
        guard isStillCurrent() else { return nil }

        if let failure = SummaryNotesRevealSourceValidation.failure(of: target, against: snapshot) {
            fail(failure, keepingPin: !Self.invalidatesPin(failure))
            return nil
        }
        return SummaryNotesRevealApplication(target: target, requestGeneration: myGeneration)
    }

    /// Marks `application` as applied so a remounted Notes pane does not
    /// reveal it again. Keeps the pin. A no-op unless it is still the
    /// current `.ready` target of the same request.
    func consume(_ application: SummaryNotesRevealApplication) {
        guard isCurrent(application) else { return }
        state = .idle
    }

    /// Replaces `application`'s still-current target with `failure`. Drops
    /// the pin only when `failure` means the pinned source is no longer
    /// trusted; an unshowable location keeps it.
    func reject(_ application: SummaryNotesRevealApplication, with failure: SummaryNotesRevealFailure) {
        guard isCurrent(application) else { return }
        fail(failure, keepingPin: !Self.invalidatesPin(failure))
    }

    private func isCurrent(_ application: SummaryNotesRevealApplication) -> Bool {
        application.requestGeneration == generation && state == .ready(application.target)
    }

    /// Show Latest Notes: drops the pin and any pending reveal or failure,
    /// and makes in-flight work stale. Never touches Notes storage.
    func clearPin() {
        generation += 1
        pinnedSource = nil
        state = .idle
    }

    /// For a change of the window's selected session: drops everything and
    /// makes every in-flight request stale.
    func invalidate() {
        generation += 1
        sessionID = nil
        pinnedSource = nil
        state = .idle
    }
}
