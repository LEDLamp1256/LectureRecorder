import SwiftUI

/// Displays one selected completed session's Summary: durable
/// generation/recovery status, Generate/Continue/Retry/Cancel actions, and
/// (once available) the structured `LectureSummaryDocument`.
///
/// Mirrors `SessionNotesView`'s ownership contract exactly, adapted for the
/// Summary domain: observes the single, shared
/// `LectureSummaryGenerationService` (for live phase/progress) and owns one
/// window-local `SessionSummaryPresenter` for its own best-effort durable
/// status/document display cache — entirely independent of
/// `SessionNotesPresenter`/`SessionNotesView`. This view issues no
/// `LectureSummaryGenerationService` calls beyond the four explicit user
/// actions below (Generate/Continue/Retry/Cancel), owns no persistent
/// background `Task`, and never starts a generation merely because it
/// appeared, because a relaunch occurred, or because durable state
/// refreshed. Action enablement is computed by the pure
/// `SummaryActionAvailabilityCalculator` — this session's own saved
/// classification is never reinterpreted as an integrity problem merely
/// because a *different* session currently owns the shared operation.
struct SessionSummaryView: View {
    let entry: CompletedSessionEntry
    @ObservedObject var service: LectureSummaryGenerationService
    @StateObject private var presenter: SessionSummaryPresenter

    init(
        entry: CompletedSessionEntry,
        service: LectureSummaryGenerationService,
        summaryStore: any LectureSummaryStoring,
        summaryOperationStateStore: any LectureSummaryOperationStateStoring,
        notesStore: any LectureNotesStoring,
        summarySourceLoader: any LectureSummarySourceLoading
    ) {
        self.entry = entry
        self.service = service
        _presenter = StateObject(wrappedValue: SessionSummaryPresenter(
            summaryStore: summaryStore,
            summaryOperationStateStore: summaryOperationStateStore,
            notesStore: notesStore,
            summarySourceLoader: summarySourceLoader
        ))
    }

    /// Transient, presentation-only message for the most recent
    /// `AdmissionResult` explanation from an explicit Generate/Continue/
    /// Retry tap — view-local is fine here, mirrors
    /// `SessionNotesView.actionMessage` exactly (see its own header comment
    /// for why terminal failures are, by contrast, read from the shared
    /// service rather than kept here).
    @State private var actionMessage: String?

    private var sessionID: UUID { entry.manifest.sessionID }

    private var ownership: SessionOwnershipDisplay {
        SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: service.activeSessionID, sessionID: sessionID)
    }

    private var isActiveOperation: Bool { ownership == .activeHere }

    private var availability: SummaryActionAvailability {
        SummaryActionAvailabilityCalculator.availability(
            displayState: presenter.displayState,
            currentUsableNotesGenerationID: presenter.currentUsableNotesGenerationID,
            ownership: ownership
        )
    }

    /// This session's own most recent `.failed` terminal outcome, if any —
    /// read directly from the shared service's session-keyed transient
    /// state, never from this view's own lifetime.
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
    }

    private var header: some View {
        Text("Summary")
            .font(.title3.bold())
    }

    @ViewBuilder private var statusSection: some View {
        if isActiveOperation {
            liveStatusText(service.phase)
        } else if ownership == .busyElsewhere {
            Label("Busy — Summary generation is active for another session", systemImage: "hourglass.circle")
                .foregroundStyle(.secondary)
        } else {
            switch presenter.displayState {
            case .loading:
                ProgressView().controlSize(.small)
            case .noValidNotesSource, .noGeneration:
                EmptyView()
            case .loaded(_, let classification, let advisoryStateIntegrity):
                savedStatusText(classification, advisoryStateIntegrity: advisoryStateIntegrity)
            case .loadError(let message):
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func liveStatusText(_ phase: LectureSummaryGenerationService.OperationPhase) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .preparingSource:
            Label("Preparing…", systemImage: "hourglass")
        case .classifying:
            Label("Checking previous progress…", systemImage: "arrow.triangle.2.circlepath")
        case .planning:
            Label("Planning…", systemImage: "list.bullet.rectangle")
        case .analyzingBatch(let batchIndex, let totalBatches):
            Label("Analyzing section \(batchIndex + 1) of \(totalBatches)", systemImage: "text.magnifyingglass")
        case .synthesizing:
            Label("Synthesizing summary…", systemImage: "doc.text")
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

    @ViewBuilder private func savedStatusText(_ classification: SummaryGenerationRecoveryClassification, advisoryStateIntegrity: SummaryAdvisoryStateIntegrity) -> some View {
        switch classification {
        case .completed:
            Label("Summary ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .readyForSynthesis:
            if case .problem(let reason) = advisoryStateIntegrity {
                Label("Ready to synthesize, but cannot resume automatically — \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label("Ready to synthesize", systemImage: "hourglass")
            }
        case .resumable(let nextBatchIndex, let interruption):
            if case .problem(let reason) = advisoryStateIntegrity {
                Label("Cannot resume automatically — \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label(resumableLabel(nextBatchIndex: nextBatchIndex, interruption: interruption), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }
        case .staleSource:
            Label("The source Notes have changed since this Summary was generated; it can no longer resume", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .damaged:
            Label("This generation's saved data is damaged and cannot be resumed", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func resumableLabel(nextBatchIndex: Int, interruption: SummaryGenerationInterruptionReason) -> String {
        switch interruption {
        case .notStarted:
            return "Not started"
        case .cancelled:
            return "Cancelled — \(nextBatchIndex) section(s) saved"
        case .recoverableFailure(let description):
            if let description { return "Failed: \(description)" }
            return "Failed — \(nextBatchIndex) section(s) saved"
        case .interruptedRunningState:
            return "Interrupted — \(nextBatchIndex) section(s) saved"
        }
    }

    /// Records the service's own authoritative `AdmissionResult` as a
    /// transient message. The service remains the sole admission
    /// authority — this never duplicates admission logic before the call,
    /// only labels the result the call already returned.
    private func handle(_ result: LectureSummaryGenerationService.AdmissionResult) {
        actionMessage = SummaryAdmissionMessage.message(for: result)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Generate Summary") {
                guard let notesGenerationID = availability.generateNotesGenerationID else { return }
                handle(service.generate(sessionID: sessionID, notesGenerationID: notesGenerationID))
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
                SummaryDocumentView(document: document)
            }
        case .noGeneration:
            ContentUnavailableView(
                "No Summary Yet",
                systemImage: "doc.text.below.ecg",
                description: Text("Generate a structured summary for this lecture once you're ready.")
            )
        case .noValidNotesSource:
            ContentUnavailableView(
                "Notes Required",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Generate completed Notes for this lecture before creating a Summary.")
            )
        default:
            EmptyView()
        }
    }
}
