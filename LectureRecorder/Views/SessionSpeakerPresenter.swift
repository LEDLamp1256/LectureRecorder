import Combine
import Foundation

/// Read-only durable diarization state for presentation.
/// `SessionDiarizationService` is the production conformer; a presenter
/// holding this reference can read durable state but owns no operation.
protocol SessionDiarizationPresentationPeeking: AnyObject {
    func peekPresentationState(sessionID: UUID) async -> SessionDiarizationService.PresentationState
}

extension SessionDiarizationService: SessionDiarizationPresentationPeeking {}

/// One transcript pane's speaker-label presentation for the displayed
/// completed session — the diarization analog of
/// `SessionTranscriptPresenter`, and deliberately separate from it so
/// speaker state can never delay or block the transcript.
///
/// Durable state comes only from disk, through the read-only
/// `peekPresentationState`; the single, app-wide
/// `SessionDiarizationService` alone owns, reports, and cancels the live
/// operation, and the view calls it directly. This presenter owns no
/// `Task`, never starts or cancels diarization, never writes anything, and
/// never uses an operation's in-memory result: a release only prompts a
/// fresh durable read.
///
/// Decoration is computed once per change of its inputs — the loaded
/// result and source, or the transcript navigation — never per render, and
/// is joined to the transcript only by existing
/// `TranscriptPlaybackItem.ID`s. Stale-load protection mirrors
/// `SessionTranscriptPresenter`: `refresh(for:)` bumps `generation` up front
/// and a superseded read is discarded.
@MainActor
final class SessionSpeakerPresenter: ObservableObject {
    private let peeker: any SessionDiarizationPresentationPeeking
    private let aligner: SpeakerTranscriptAligner
    private var generation = 0
    private var durableState: SessionDiarizationService.PresentationState?
    private var navigation: TranscriptPlaybackNavigation?
    /// The newest release epoch this presenter has seen, starting with the
    /// one already published when it was created.
    private var lastSeenReleaseEpoch: Int

    @Published private(set) var displayedSessionID: UUID?
    @Published private(set) var display: SpeakerDurableDisplay = .loading
    /// Non-`nil` only for a usable result aligned to the current navigation.
    @Published private(set) var decoration: TranscriptSpeakerDecoration?
    /// The result of an operation for this session released while this
    /// presenter existed. Cleared when a new operation is admitted here.
    @Published private(set) var releaseMessage: String?
    /// Why the most recent Identify Speakers tap here was refused.
    @Published private(set) var admissionMessage: String?

    /// - Parameter initialRelease: the service's `lastReleasedOperation` at
    ///   creation. It is acknowledged without a message: an operation that
    ///   ended before this pane existed is reflected by durable state alone.
    init(
        peeker: any SessionDiarizationPresentationPeeking,
        initialRelease: SessionDiarizationService.OperationRelease?,
        aligner: SpeakerTranscriptAligner = SpeakerTranscriptAligner()
    ) {
        self.peeker = peeker
        self.aligner = aligner
        self.lastSeenReleaseEpoch = initialRelease?.operationEpoch ?? 0
    }

    /// The loaded result currently presented, if any.
    var presentedResult: SpeakerDiarizationResult? {
        if case .available(let result, _) = durableState { return result }
        return nil
    }

    // MARK: - Durable state

    /// The pane's appearance step. First reconciles `currentRelease` — the
    /// service's `lastReleasedOperation` now — so a release published after
    /// this presenter was created but before the view began observing
    /// changes is processed exactly once (one already seen, including the
    /// one current at creation, is ignored); then reads durable state.
    func reconcileOnAppear(for entry: CompletedSessionEntry, currentRelease: SessionDiarizationService.OperationRelease?) async {
        _ = observeRelease(currentRelease, sessionID: entry.manifest.sessionID)
        await refresh(for: entry)
    }

    /// Re-reads `entry`'s durable speaker state. While the read is in
    /// flight the previous presentation of the same session stays visible.
    func refresh(for entry: CompletedSessionEntry) async {
        generation += 1
        let myGeneration = generation
        let sessionID = entry.manifest.sessionID
        if displayedSessionID != sessionID {
            durableState = nil
            display = .loading
            decoration = nil
        }

        let state = await peeker.peekPresentationState(sessionID: sessionID)
        guard myGeneration == generation else { return }

        displayedSessionID = sessionID
        durableState = state
        recompute()
    }

    /// The transcript navigation to decorate, or `nil` when none is shown.
    /// Any previous decoration is dropped before the new one is computed.
    func update(navigation: TranscriptPlaybackNavigation?) {
        guard navigation != self.navigation else { return }
        self.navigation = navigation
        decoration = nil
        recompute()
    }

    private func recompute() {
        guard let durableState else {
            display = .loading
            decoration = nil
            return
        }
        guard case .available(let result, let source) = durableState else {
            display = SpeakerDurableDisplay(durableState)
            decoration = nil
            return
        }
        // A valid result with no transcript to decorate is still available.
        guard let navigation, navigation.sessionID == result.sessionID else {
            display = .available(speakerCount: result.speakerIDs.count)
            decoration = nil
            return
        }
        do {
            let alignments = try aligner.align(navigation, with: result, source: source)
            decoration = TranscriptSpeakerDecoration.build(navigation: navigation, alignments: alignments)
            display = .available(speakerCount: result.speakerIDs.count)
        } catch {
            decoration = nil
            let alignmentError = (error as? SpeakerTranscriptAlignmentError) ?? .sessionMismatch
            display = alignmentError == .audioSourceMismatch ? .outOfDate : .unreadable(.alignment(alignmentError))
        }
    }

    // MARK: - Operation signals

    /// Records a newly published release. Returns `true` when it is a new
    /// release of `sessionID`'s operation — its message is then shown and
    /// the caller should `refresh` from disk. Releases already seen
    /// (including the one current at creation) and other sessions'
    /// releases change nothing.
    func observeRelease(_ release: SessionDiarizationService.OperationRelease?, sessionID: UUID) -> Bool {
        guard let release, release.operationEpoch > lastSeenReleaseEpoch else { return false }
        lastSeenReleaseEpoch = release.operationEpoch
        guard release.sessionID == sessionID else { return false }
        releaseMessage = SpeakerIdentificationMessage.message(for: release.outcome)
        return true
    }

    /// Labels the service's own admission result for an Identify Speakers
    /// tap here; an admitted operation clears earlier messages.
    func recordAdmission(_ result: SessionDiarizationService.AdmissionResult) {
        admissionMessage = SpeakerIdentificationMessage.message(for: result)
        if result == .admitted {
            releaseMessage = nil
        }
    }
}
