import SwiftUI

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
struct SessionNotesView: View {
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

    init(
        entry: CompletedSessionEntry,
        service: LectureNotesGenerationService,
        transcriptionService: CompletedSessionTranscriptionService,
        notesStore: any LectureNotesStoring,
        operationStateStore: any LectureNotesOperationStateStoring,
        sourceLoader: any NotesTranscriptSourceLoading
    ) {
        self.entry = entry
        self.service = service
        self.transcriptionService = transcriptionService
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

    private var sessionID: UUID { entry.manifest.sessionID }

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
            Divider()
            contentSection
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: sessionID) {
            await presenter.refresh(for: entry)
        }
        .onChange(of: service.activeSessionID) { oldValue, newValue in
            guard SessionOwnershipTransition.shouldRefreshDurableState(
                oldActiveSessionID: oldValue,
                newActiveSessionID: newValue,
                sessionID: sessionID
            ) else { return }
            Task { await presenter.refresh(for: entry) }
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
            Task { await presenter.refresh(for: entry) }
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
            if case .problem(let reason) = advisoryStateIntegrity {
                Label("Ready to synthesize, but cannot resume automatically — \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label("Ready to synthesize", systemImage: "hourglass")
            }
        case .resumable(let nextWindowIndex, let interruption):
            if case .problem(let reason) = advisoryStateIntegrity {
                Label("Cannot resume automatically — \(reason)", systemImage: "exclamationmark.triangle")
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
        switch presenter.displayState {
        case .loaded(_, .completed(let document), _):
            ScrollView {
                NotesDocumentView(document: document)
            }
        case .noGeneration:
            ContentUnavailableView(
                "No Notes Yet",
                systemImage: "doc.text",
                description: Text("Generate structured notes for this lecture once you're ready.")
            )
        default:
            EmptyView()
        }
    }
}
