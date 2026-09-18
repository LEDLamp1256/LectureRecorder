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

    @State private var contentSelection: ContentSelection = .transcript

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
        summarySourceLoader: any LectureSummarySourceLoading
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
    }

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
    }

    private var transcriptView: some View {
        SessionTranscriptView(entry: entry, service: transcriptionService)
    }

    private var notesView: some View {
        SessionNotesView(
            entry: entry,
            service: notesService,
            notesStore: notesStore,
            operationStateStore: notesOperationStateStore,
            sourceLoader: notesSourceLoader
        )
    }

    private var summaryView: some View {
        SessionSummaryView(
            entry: entry,
            service: summaryService,
            summaryStore: summaryStore,
            summaryOperationStateStore: summaryOperationStateStore,
            notesStore: notesStore,
            summarySourceLoader: summarySourceLoader
        )
    }
}
