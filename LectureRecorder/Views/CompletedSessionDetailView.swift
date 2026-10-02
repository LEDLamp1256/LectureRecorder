import SwiftUI

/// The completed-session workspace container: hosts the existing Transcript
/// experience and the Notes and Summary experiences for one selected
/// `CompletedSessionEntry`. Owns only the Transcript/Notes/Summary layout
/// choice — never transcription, Notes, or Summary orchestration, all of
/// which remain entirely owned by their respective shared services
/// (`CompletedSessionTranscriptionService`, `LectureNotesGenerationService`,
/// `LectureSummaryGenerationService`). Session selection itself remains
/// entirely owned by `CompletedSessionsListPresenter` in
/// `CompletedSessionsView` — this view only ever receives one
/// already-selected `CompletedSessionEntry`.
///
/// Transcript remains the default, full-width surface on narrow windows.
/// On sufficiently wide windows, Notes and Summary can both be shown
/// alongside Transcript in a resizable `HSplitView` with three panes; below
/// that width, exactly one destination uses the full content area via a
/// simple segmented switch instead of being forced into a cramped sidebar.
/// The exact breakpoint and per-pane minimum widths are placeholder
/// constants, chosen only so three panes are never mounted below a readable
/// width — precise tuning is deferred to a later, dedicated visual pass.
///
/// Also owns this window's `SessionTranscriptRevealPresenter`: a Notes
/// Source activation resolves here, and a ready target is handed to the
/// Transcript pane. Owning it here — not in either pane — lets a pending
/// target survive the narrow layout's Notes → Transcript remount.
///
/// Likewise owns this window's `SessionSummaryNotesRevealPresenter`: a
/// Summary Supporting Notes activation resolves here, and the resulting
/// pending target and exact Notes generation pin are handed to the Notes
/// pane. The pin lives here — not in `SessionNotesView` — so it survives
/// Summary → Notes remounts, and is dropped on session change. Summary
/// never navigates to Transcript directly; Notes' Source actions do. A
/// newly displayed completed Summary from a different source drops the pin
/// (`reconcilePin`), and starting either kind of navigation dismisses the
/// other kind's stale failure.
///
/// Owns this session's single `SessionPlaybackPresenter` too: playback
/// belongs to the session workspace, not the Transcript pane, so it keeps
/// playing (or stays paused) across narrow-layout pane switches, Source and
/// Supporting Notes navigation, and wide ↔ narrow breakpoint changes. It is
/// prepared (never auto-playing) when this view appears and torn down when
/// it disappears — which includes every session change, since
/// `CompletedSessionsView` gives this view the session's identity.
struct CompletedSessionDetailView: View {
    private enum ContentSelection: Hashable {
        case transcript
        case notes
        case summary
    }

    /// Three panes at the minimum widths below sum to 1,000pt; this leaves
    /// the same ~200pt side-by-side margin the prior two-pane breakpoint
    /// (900pt for a 680pt sum) reserved, rather than keeping the old
    /// breakpoint and letting three panes get compressed below their
    /// readable minimums.
    private static let sideBySideMinimumWidth: CGFloat = 1200
    private static let transcriptMinimumWidth: CGFloat = 360
    private static let notesMinimumWidth: CGFloat = 320
    private static let summaryMinimumWidth: CGFloat = 320

    let entry: CompletedSessionEntry
    @ObservedObject var transcriptionService: CompletedSessionTranscriptionService
    @ObservedObject var notesService: LectureNotesGenerationService
    @ObservedObject var summaryService: LectureSummaryGenerationService
    private let notesStore: any LectureNotesStoring
    private let notesOperationStateStore: any LectureNotesOperationStateStoring
    private let notesSourceLoader: any NotesTranscriptSourceLoading
    private let summaryStore: any LectureSummaryStoring
    private let summaryOperationStateStore: any LectureSummaryOperationStateStoring
    private let summarySourceLoader: any LectureSummarySourceLoading
    private let transcriptNavigationLoader: any CompletedTranscriptNavigationLoading

    @State private var contentSelection: ContentSelection = .transcript
    @StateObject private var revealPresenter: SessionTranscriptRevealPresenter
    @StateObject private var summaryNotesRevealPresenter: SessionSummaryNotesRevealPresenter
    @StateObject private var playback = SessionPlaybackPresenter()

    init(
        entry: CompletedSessionEntry,
        transcriptionService: CompletedSessionTranscriptionService,
        notesService: LectureNotesGenerationService,
        summaryService: LectureSummaryGenerationService,
        notesStore: any LectureNotesStoring,
        notesOperationStateStore: any LectureNotesOperationStateStoring,
        notesSourceLoader: any NotesTranscriptSourceLoading,
        summaryStore: any LectureSummaryStoring,
        summaryOperationStateStore: any LectureSummaryOperationStateStoring,
        summarySourceLoader: any LectureSummarySourceLoading,
        transcriptNavigationLoader: any CompletedTranscriptNavigationLoading
    ) {
        self.entry = entry
        self.transcriptionService = transcriptionService
        self.notesService = notesService
        self.summaryService = summaryService
        self.notesStore = notesStore
        self.notesOperationStateStore = notesOperationStateStore
        self.notesSourceLoader = notesSourceLoader
        self.summaryStore = summaryStore
        self.summaryOperationStateStore = summaryOperationStateStore
        self.summarySourceLoader = summarySourceLoader
        self.transcriptNavigationLoader = transcriptNavigationLoader
        _revealPresenter = StateObject(wrappedValue: SessionTranscriptRevealPresenter(sourceLoader: notesSourceLoader))
        _summaryNotesRevealPresenter = StateObject(wrappedValue: SessionSummaryNotesRevealPresenter(sourceLoader: summarySourceLoader))
    }

    private var sessionID: UUID { entry.manifest.sessionID }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.sideBySideMinimumWidth {
                HSplitView {
                    transcriptView
                        .frame(minWidth: Self.transcriptMinimumWidth)
                    notesView
                        .frame(minWidth: Self.notesMinimumWidth)
                    summaryView
                        .frame(minWidth: Self.summaryMinimumWidth)
                }
            } else {
                VStack(spacing: 0) {
                    Picker("Content", selection: $contentSelection) {
                        Text("Transcript").tag(ContentSelection.transcript)
                        Text("Notes").tag(ContentSelection.notes)
                        Text("Summary").tag(ContentSelection.summary)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding([.horizontal, .top], 12)

                    switch contentSelection {
                    case .transcript:
                        transcriptView
                    case .notes:
                        notesView
                    case .summary:
                        summaryView
                    }
                }
            }
        }
        // Attached outside the layout switch, so pane remounts and
        // breakpoint changes never prepare or tear down playback.
        .task(id: sessionID) {
            await playback.prepare(for: entry)
        }
        .onDisappear {
            playback.tearDown()
        }
        .onChange(of: sessionID) {
            revealPresenter.invalidate()
            summaryNotesRevealPresenter.invalidate()
        }
        .onChange(of: revealPresenter.pendingTarget) { _, target in
            // Only a successful, current resolution for this session moves
            // the narrow layout to Transcript; failures stay on Notes.
            // Harmless while wide, where every pane is already visible.
            guard let target, target.sessionID == sessionID else { return }
            contentSelection = .transcript
        }
        .onChange(of: summaryNotesRevealPresenter.pendingTarget) { _, target in
            // Only a successful, current Summary reveal for this session
            // moves the narrow layout to Notes; failures stay on Summary.
            guard let target, target.sessionID == sessionID else { return }
            contentSelection = .notes
        }
    }

    /// The newest Supporting Notes failure for this session, as user-facing
    /// text. Shown by both Summary and Notes.
    private var summaryNotesRevealFailureMessage: String? {
        guard summaryNotesRevealPresenter.sessionID == sessionID,
              case .failed(let failure) = summaryNotesRevealPresenter.state else { return nil }
        return SummaryNotesRevealFailureMessage.message(for: failure)
    }

    /// The newest reveal failure for this session, as user-facing text.
    private var revealFailureMessage: String? {
        guard revealPresenter.sessionID == sessionID,
              case .failed(let failure) = revealPresenter.state else { return nil }
        return TranscriptRevealFailureMessage.message(for: failure)
    }

    private var transcriptView: some View {
        SessionTranscriptView(
            entry: entry,
            service: transcriptionService,
            navigationLoader: transcriptNavigationLoader,
            revealPresenter: revealPresenter,
            playback: playback
        )
    }

    private var notesView: some View {
        SessionNotesView(
            entry: entry,
            service: notesService,
            transcriptionService: transcriptionService,
            notesStore: notesStore,
            operationStateStore: notesOperationStateStore,
            sourceLoader: notesSourceLoader,
            summaryRevealPresenter: summaryNotesRevealPresenter,
            summaryRevealFailureMessage: summaryNotesRevealFailureMessage,
            revealFailureMessage: revealFailureMessage,
            onSourceActivated: { reference, transcriptFingerprint in
                // A newer navigation supersedes stale Summary feedback.
                summaryNotesRevealPresenter.dismissFailure()
                Task {
                    await revealPresenter.requestReveal(reference: reference, generatedFrom: transcriptFingerprint, for: entry)
                }
            }
        )
    }

    private var summaryView: some View {
        SessionSummaryView(
            entry: entry,
            service: summaryService,
            summaryStore: summaryStore,
            summaryOperationStateStore: summaryOperationStateStore,
            notesStore: notesStore,
            summarySourceLoader: summarySourceLoader,
            supportingNotesFailureMessage: summaryNotesRevealFailureMessage,
            onDisplayedSummarySourceChanged: { displayedSource in
                summaryNotesRevealPresenter.reconcilePin(withDisplayedSummarySource: displayedSource)
            },
            onSupportingNotesActivated: { document, passage in
                // A newer navigation supersedes stale Source feedback.
                revealPresenter.dismissFailure()
                Task {
                    await summaryNotesRevealPresenter.requestReveal(document: document, passage: passage, for: entry)
                }
            }
        )
    }
}
