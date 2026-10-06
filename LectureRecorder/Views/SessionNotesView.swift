import SwiftUI

/// Why `SessionNotesView` is refreshing its durable Notes display.
nonisolated enum SessionNotesRefreshCause: Equatable, CaseIterable {
    case sessionAppeared
    case notesServiceReleased
    case transcriptionServiceReleased
    case pinChanged
}

/// Which Notes generation a refresh loads. Pure.
nonisolated enum SessionNotesRefreshMode: Equatable {
    /// The default, newest-generation selection.
    case latest
    /// Exactly this generation, never another.
    case exact(generationID: UUID)

    /// A Summary pin always wins, whatever caused the refresh: no automatic
    /// event may silently switch a pinned Notes pane to the newest Notes.
    /// `cause` is accepted so any future cause-specific rule has to live
    /// here, next to the tests that pin this contract.
    static func mode(for cause: SessionNotesRefreshCause, pinnedNotesGenerationID: UUID?) -> SessionNotesRefreshMode {
        if let pinnedNotesGenerationID { return .exact(generationID: pinnedNotesGenerationID) }
        return .latest
    }
}

/// Displays one selected completed session's Notes: durable
/// generation/recovery status, Generate/Continue/Retry/Cancel actions, and
/// (once available) the structured `LectureNotesDocument`.
///
/// Mirrors `SessionTranscriptView`'s ownership contract exactly, adapted for
/// the Notes domain: observes the single, shared
/// `LectureNotesGenerationService` (for live phase/progress) and owns one
/// window-local `SessionNotesPresenter` for its own best-effort durable
/// status/document display cache. This view issues no
/// `LectureNotesGenerationService` calls beyond the four explicit user
/// actions below (Generate/Continue/Retry/Cancel), owns no persistent
/// background `Task`, and never starts a generation merely because it
/// appeared, because a relaunch occurred, or because durable state
/// refreshed. Action enablement is computed by the pure
/// `NotesActionAvailabilityCalculator` — this session's own saved
/// classification is never reinterpreted as an integrity problem merely
/// because a *different* session currently owns the shared operation.
///
/// Also observes the shared `CompletedSessionTranscriptionService`'s
/// `activeSessionID`, purely as a refresh cue: when transcription for this
/// session releases ownership (completion, cancellation, or failure), the
/// transcript on disk may have just become — or remain — eligible/ineligible
/// notes input, so durable state is re-read the same way it already is when
/// this view's own `service.activeSessionID` releases. This never calls
/// `CompletedSessionTranscriptionService` beyond reading that one published
/// property, and never couples `LectureNotesGenerationService` itself to
/// transcription.
///
/// While the parent-owned `SessionSummaryNotesRevealPresenter` pins a Notes
/// generation for this session, every refresh — initial, either service's
/// ownership release, or the pin changing — loads exactly that generation
/// (`refreshPresentedNotes()`), and the pane is read-only evidence browsing:
/// Generate/Continue/Retry/Cancel are hidden, a "Viewing Notes used by this
/// Summary" row offers Show Latest Notes, and Source actions still hand off
/// to the Transcript reveal. A pending Summary reveal is applied once the
/// pinned document has loaded and passes application-time revalidation:
/// every supporting item is highlighted and the first is scrolled to.
struct SessionNotesView: View {
    /// Re-runs Summary reveal application when a new target arrives, the pin
    /// changes, or the pinned Notes finish loading.
    private struct SummaryRevealTrigger: Equatable {
        enum NotesKind: Equatable {
            case loading, unavailable
            case completed(generationID: UUID)
        }

        let target: SummaryNotesRevealTarget?
        let pinnedNotesGenerationID: UUID?
        let notesKind: NotesKind
    }

    let entry: CompletedSessionEntry
    @ObservedObject var service: LectureNotesGenerationService
    /// Observed only for its `activeSessionID` ownership-release signal —
    /// this view never calls any `CompletedSessionTranscriptionService`
    /// method. Notes generation itself remains entirely decoupled from
    /// transcription (see `NotesTranscriptSourceLoading`); this is purely a
    /// "durable state may have changed on disk, refresh the display" cue,
    /// the same role `service.activeSessionID` already plays below for
    /// Notes' own operations.
    @ObservedObject var transcriptionService: CompletedSessionTranscriptionService
    @StateObject private var presenter: SessionNotesPresenter
    /// Forwards a Source activation to the parent, which owns transcript
    /// reveal; this view never resolves references itself.
    private let onSourceActivated: ((NotesSourceReference, TranscriptSourceFingerprint) -> Void)?
    /// The parent's current reveal failure for this session, if any.
    private let revealFailureMessage: String?
    /// Parent-owned Summary → Notes reveal coordinator: the source of the
    /// pin and of pending Summary reveals. This view owns neither.
    @ObservedObject var summaryRevealPresenter: SessionSummaryNotesRevealPresenter
    /// The parent's current Supporting Notes failure for this session, if any.
    private let summaryRevealFailureMessage: String?

    init(
        entry: CompletedSessionEntry,
        service: LectureNotesGenerationService,
        transcriptionService: CompletedSessionTranscriptionService,
        notesStore: any LectureNotesStoring,
        operationStateStore: any LectureNotesOperationStateStoring,
        sourceLoader: any NotesTranscriptSourceLoading,
        summaryRevealPresenter: SessionSummaryNotesRevealPresenter,
        summaryRevealFailureMessage: String? = nil,
        revealFailureMessage: String? = nil,
        onSourceActivated: ((NotesSourceReference, TranscriptSourceFingerprint) -> Void)? = nil
    ) {
        self.entry = entry
        self.service = service
        self.transcriptionService = transcriptionService
        self.summaryRevealPresenter = summaryRevealPresenter
        self.summaryRevealFailureMessage = summaryRevealFailureMessage
        self.revealFailureMessage = revealFailureMessage
        self.onSourceActivated = onSourceActivated
        _presenter = StateObject(wrappedValue: SessionNotesPresenter(
            notesStore: notesStore,
            operationStateStore: operationStateStore,
            sourceLoader: sourceLoader
        ))
    }

    /// Transient, presentation-only message for the most recent
    /// `AdmissionResult` explanation from an explicit Generate/Continue/
    /// Retry tap — view-local is fine here, since it only ever needs to
    /// explain the outcome of a tap this same view instance just made.
    /// Never a second lifecycle state machine: it holds a plain string,
    /// never re-derives or overrides durable classification. Cleared on
    /// the next admitted action.
    ///
    /// A terminal `.failed(description:)` outcome, by contrast, is *not*
    /// kept here — it is read directly from the shared service's own
    /// `lastFailureDescriptionBySessionID` (see `terminalFailureMessage`
    /// below), since this view's lifetime cannot be relied upon to still
    /// exist at the moment a run for this session actually finishes (the
    /// Notes pane may be unmounted on a narrow layout while Transcript is
    /// selected).
    @State private var actionMessage: String?

    /// The mode of the newest refresh that has finished; `nil` while one is
    /// in flight, so a pending reveal never applies to an older display.
    @State private var presentedRefreshMode: SessionNotesRefreshMode?
    @State private var refreshRequestCount = 0
    /// Supporting items of the last applied Summary reveal, and the
    /// generation they were mapped in. Kept until the pin or session changes,
    /// the displayed document changes, or this view unmounts.
    @State private var summaryHighlightedItemIDs: Set<UUID> = []
    @State private var summaryHighlightGenerationID: UUID?
    @State private var summaryScrollTargetItemID: UUID?
    /// Bumped once per applied reveal so a later activation scrolls again.
    @State private var summaryScrollRequest = 0

    private var sessionID: UUID { entry.manifest.sessionID }

    private var pinnedNotesGenerationID: UUID? {
        summaryRevealPresenter.pinnedNotesGenerationID(forSessionID: sessionID)
    }

    private var isPinned: Bool { pinnedNotesGenerationID != nil }

    private var ownership: SessionOwnershipDisplay {
        SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: service.activeSessionID, sessionID: sessionID)
    }

    private var isActiveOperation: Bool { ownership == .activeHere }

    private var availability: NotesActionAvailability {
        NotesActionAvailabilityCalculator.availability(displayState: presenter.displayState, ownership: ownership)
    }

    /// This session's own most recent `.failed` terminal outcome, if any —
    /// read directly from the shared service's session-keyed transient
    /// state, never from this view's own lifetime. Never another
    /// session's failure: keyed by `sessionID`.
    private var terminalFailureMessage: String? {
        service.lastFailureDescription(forSessionID: sessionID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if isPinned {
                // Historical evidence, not the active Notes workflow: no
                // lifecycle status or Generate/Continue/Retry/Cancel here.
                pinnedEvidenceRow
            } else {
                statusSection
                actionButtons
                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let terminalFailureMessage {
                    Text(terminalFailureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if let summaryRevealFailureMessage {
                Label(summaryRevealFailureMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            contentSection
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: sessionID) {
            clearSummaryHighlight()
            await refreshPresentedNotes(.sessionAppeared)
        }
        .onChange(of: pinnedNotesGenerationID) {
            // Cleared, replaced by a newer reveal, or newly established:
            // old highlighting never carries over, and the display follows.
            clearSummaryHighlight()
            Task { await refreshPresentedNotes(.pinChanged) }
        }
        .onChange(of: summaryRevealPresenter.revealRequestCount) {
            // A newer Summary reveal began: its passage's support replaces
            // the old highlight even when the pin itself is kept.
            clearSummaryHighlight()
        }
        .onChange(of: displayedCompletedDocument) {
            // Highlighted IDs belong to the document they were mapped in.
            if displayedCompletedDocument?.generationID != summaryHighlightGenerationID {
                clearSummaryHighlight()
            }
        }
        .task(id: SummaryRevealTrigger(
            target: summaryRevealPresenter.pendingTarget,
            pinnedNotesGenerationID: pinnedNotesGenerationID,
            notesKind: summaryRevealNotesKind
        )) {
            await applyPendingSummaryReveal()
        }
        .onChange(of: service.activeSessionID) { oldValue, newValue in
            guard SessionOwnershipTransition.shouldRefreshDurableState(
                oldActiveSessionID: oldValue,
                newActiveSessionID: newValue,
                sessionID: sessionID
            ) else { return }
            Task { await refreshPresentedNotes(.notesServiceReleased) }
        }
        // A visible Notes pane must reflect transcription finishing for
        // this session without requiring the user to navigate away and
        // back — otherwise Generate stays incorrectly disabled until some
        // unrelated re-mount happens to occur. Reuses the exact same
        // ownership-release cue already used for `service.activeSessionID`
        // above, now against the shared transcription service instead.
        .onChange(of: transcriptionService.activeSessionID) { oldValue, newValue in
            guard SessionOwnershipTransition.shouldRefreshDurableState(
                oldActiveSessionID: oldValue,
                newActiveSessionID: newValue,
                sessionID: sessionID
            ) else { return }
            Task { await refreshPresentedNotes(.transcriptionServiceReleased) }
        }
    }

    // MARK: - Refresh

    /// The one refresh route: exact pinned generation while pinned, the
    /// default newest selection otherwise.
    private func refreshPresentedNotes(_ cause: SessionNotesRefreshCause) async {
        let mode = SessionNotesRefreshMode.mode(for: cause, pinnedNotesGenerationID: pinnedNotesGenerationID)
        refreshRequestCount += 1
        let request = refreshRequestCount
        presentedRefreshMode = nil
        switch mode {
        case .latest:
            await presenter.refresh(for: entry)
        case .exact(let generationID):
            await presenter.refresh(for: entry, generationID: generationID)
        }
        guard request == refreshRequestCount else { return }
        presentedRefreshMode = mode
    }

    // MARK: - Summary evidence

    private var pinnedEvidenceRow: some View {
        HStack(spacing: 12) {
            Label("Viewing Notes used by this Summary", systemImage: "pin")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Show Latest Notes") {
                clearSummaryHighlight()
                summaryRevealPresenter.clearPin()
            }
            .buttonStyle(.bordered)
        }
    }

    /// The completed document the pane currently shows for this session.
    private var displayedCompletedDocument: LectureNotesDocument? {
        guard presenter.displayedSessionID == sessionID,
              case .loaded(_, .completed(let document), _) = presenter.displayState else { return nil }
        return document
    }

    /// What the pane shows for the pin. The pinned generation's completed
    /// document stays visible across automatic refreshes; anything else is
    /// `.unavailable` only once the newest refresh — the exact one — has
    /// finished, and `.loading` before that.
    private var pinnedNotes: SummaryNotesRevealDisplayedNotes {
        guard let pinnedNotesGenerationID, presenter.displayedSessionID == sessionID else { return .loading }
        if case .loaded(let record, .completed(let document), _) = presenter.displayState,
           record.generationID == pinnedNotesGenerationID {
            return .completed(document)
        }
        guard presentedRefreshMode == .exact(generationID: pinnedNotesGenerationID),
              presenter.displayState != .loading else { return .loading }
        return .unavailable
    }

    /// `pinnedNotes`, but only once the newest refresh — the exact one — has
    /// finished, so a reveal is never applied to a display about to change.
    private var summaryRevealNotes: SummaryNotesRevealDisplayedNotes {
        guard let pinnedNotesGenerationID,
              presentedRefreshMode == .exact(generationID: pinnedNotesGenerationID) else { return .loading }
        return pinnedNotes
    }

    private var summaryRevealNotesKind: SummaryRevealTrigger.NotesKind {
        switch summaryRevealNotes {
        case .loading: .loading
        case .unavailable: .unavailable
        case .completed(let document): .completed(generationID: document.generationID)
        }
    }

    private func clearSummaryHighlight() {
        summaryHighlightedItemIDs = []
        summaryHighlightGenerationID = nil
        summaryScrollTargetItemID = nil
    }

    /// Applies the pending Summary reveal once the pinned document has
    /// loaded. Never partially applies: a target the document cannot fully
    /// represent is rejected (see `SessionSummaryNotesRevealPresenter.reject`
    /// for when that also drops the pin).
    private func applyPendingSummaryReveal() async {
        guard let target = summaryRevealPresenter.pendingTarget,
              SummaryNotesRevealApplicationPlanner.outcome(
                  for: target,
                  sessionID: sessionID,
                  pinnedNotesGenerationID: pinnedNotesGenerationID,
                  notes: summaryRevealNotes
              ) != .notApplicable else {
            return
        }
        // Failures are published by the coordinator and shown through
        // `summaryRevealFailureMessage`.
        guard let application = await summaryRevealPresenter.revalidateReadyTarget(for: entry) else { return }
        // A superseded run leaves the still-ready target to the newer run.
        guard !Task.isCancelled else { return }
        switch SummaryNotesRevealApplicationPlanner.outcome(
            for: application.target,
            sessionID: sessionID,
            pinnedNotesGenerationID: pinnedNotesGenerationID,
            notes: summaryRevealNotes
        ) {
        case .notApplicable:
            return
        case .unavailable(let failure):
            clearSummaryHighlight()
            summaryRevealPresenter.reject(application, with: failure)
        case .apply(let selection):
            summaryHighlightedItemIDs = Set(selection.selectedItemIDs)
            summaryHighlightGenerationID = application.target.sourceNotesGenerationID
            summaryScrollTargetItemID = selection.scrollTargetItemID
            summaryScrollRequest += 1
            summaryRevealPresenter.consume(application)
        }
    }

    private var header: some View {
        Text("Notes")
            .font(.title3.bold())
    }

    @ViewBuilder private var statusSection: some View {
        if isActiveOperation {
            liveStatusText(service.phase)
        } else if ownership == .busyElsewhere {
            Label("Busy — Notes generation is active for another session", systemImage: "hourglass.circle")
                .foregroundStyle(.secondary)
        } else {
            switch presenter.displayState {
            case .loading:
                ProgressView().controlSize(.small)
            case .noGeneration:
                EmptyView()
            case .loaded(_, let classification, let advisoryStateIntegrity):
                savedStatusText(classification, advisoryStateIntegrity: advisoryStateIntegrity)
            case .loadError(let message):
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func liveStatusText(_ phase: LectureNotesGenerationService.OperationPhase) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .preparingSource:
            Label("Preparing…", systemImage: "hourglass")
        case .classifying:
            Label("Checking previous progress…", systemImage: "arrow.triangle.2.circlepath")
        case .analyzing(let windowIndex, let totalWindows):
            Label("Analyzing section \(windowIndex + 1) of \(totalWindows)", systemImage: "text.magnifyingglass")
        case .synthesizing:
            Label("Synthesizing notes…", systemImage: "doc.text")
        case .cancelling:
            Label("Cancelling…", systemImage: "xmark.circle")
        case .finished:
            // The terminal transition also clears `activeSessionID`
            // (`releaseOperation`), which triggers this view's
            // `onChange(of: service.activeSessionID)` refresh — durable
            // state, not this transient phase value, is what ends up
            // driving display once that refresh lands.
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private func savedStatusText(_ classification: NotesGenerationRecoveryClassification, advisoryStateIntegrity: NotesAdvisoryStateIntegrity) -> some View {
        switch classification {
        case .completed:
            Label("Notes ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .readyForSynthesis:
            if case .problem = advisoryStateIntegrity {
                Label(NotesRecoveryMessage.advisoryStateProblem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label("Ready to synthesize", systemImage: "hourglass")
            }
        case .resumable(let nextWindowIndex, let interruption):
            if case .problem = advisoryStateIntegrity {
                Label(NotesRecoveryMessage.advisoryStateProblem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label(resumableLabel(nextWindowIndex: nextWindowIndex, interruption: interruption), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }
        case .staleSource:
            Label("The transcript has changed since this generation started; it can no longer resume", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .damaged:
            Label("This generation's saved data is damaged and cannot be resumed", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        case .incompatibleProvenance:
            Label(NotesRecoveryMessage.incompatibleProvenance, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func resumableLabel(nextWindowIndex: Int, interruption: NotesGenerationInterruptionReason) -> String {
        switch interruption {
        case .notStarted:
            return "Not started"
        case .cancelled:
            return "Cancelled — \(nextWindowIndex) section(s) saved"
        case .recoverableFailure(let description):
            if let description { return "Failed: \(description)" }
            return "Failed — \(nextWindowIndex) section(s) saved"
        case .interruptedRunningState:
            return "Interrupted — \(nextWindowIndex) section(s) saved"
        }
    }

    /// Records the service's own authoritative `AdmissionResult` as a
    /// transient message. The service remains the sole admission
    /// authority — this never duplicates admission logic before the call,
    /// only labels the result the call already returned.
    private func handle(_ result: LectureNotesGenerationService.AdmissionResult) {
        actionMessage = NotesAdmissionMessage.message(for: result)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Generate Notes") {
                handle(service.generate(sessionID: sessionID))
            }
            .disabled(!availability.canGenerate)

            Button(availability.continueOrRetryIsRetry ? "Retry" : "Continue") {
                guard case .loaded(let record, _, _) = presenter.displayState else { return }
                if availability.continueOrRetryIsRetry {
                    handle(service.retry(sessionID: sessionID, generationID: record.generationID))
                } else {
                    handle(service.continueGeneration(sessionID: sessionID, generationID: record.generationID))
                }
            }
            .disabled(!availability.canContinueOrRetry)

            Button("Cancel", role: .destructive) {
                service.cancel(sessionID: sessionID)
            }
            .disabled(!availability.canCancel)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var contentSection: some View {
        if isPinned {
            pinnedContentSection
        } else {
            latestContentSection
        }
    }

    /// Only the exact pinned generation's completed document is ever shown
    /// while pinned — never whatever an earlier refresh left displayed.
    @ViewBuilder private var pinnedContentSection: some View {
        switch pinnedNotes {
        case .completed(let document):
            notesDocument(document)
        case .unavailable:
            Label(SummaryNotesRevealFailureMessage.sourceUnavailable, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .loading:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private func notesDocument(_ document: LectureNotesDocument) -> some View {
        if let revealFailureMessage {
            Label(revealFailureMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        ScrollViewReader { proxy in
            ScrollView {
                NotesDocumentView(
                    document: document,
                    onSourceActivated: onSourceActivated,
                    highlightedItemIDs: summaryHighlightGenerationID == document.generationID ? summaryHighlightedItemIDs : []
                )
            }
            .onChange(of: summaryScrollRequest) {
                guard let summaryScrollTargetItemID else { return }
                withAnimation {
                    proxy.scrollTo(summaryScrollTargetItemID, anchor: .top)
                }
            }
        }
    }

    @ViewBuilder private var latestContentSection: some View {
        switch presenter.displayState {
        case .loaded(_, .completed(let document), _):
            notesDocument(document)
        case .noGeneration(transcriptSourceReady: true):
            ContentUnavailableView(
                "No Notes Yet",
                systemImage: "doc.text",
                description: Text("Generate structured notes for this lecture once you're ready.")
            )
        case .noGeneration(transcriptSourceReady: false):
            ContentUnavailableView(
                NotesRecoveryMessage.transcriptRequiredTitle,
                systemImage: "text.badge.xmark",
                description: Text(NotesRecoveryMessage.transcriptRequiredDescription)
            )
        default:
            EmptyView()
        }
    }
}
