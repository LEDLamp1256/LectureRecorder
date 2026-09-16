import SwiftUI

/// The completed-session workspace container: hosts the existing Transcript
/// experience and the new Notes experience for one selected
/// `CompletedSessionEntry`. Owns only the Transcript/Notes layout choice —
/// never transcription or Notes orchestration, both of which remain
/// entirely owned by their respective shared services
/// (`CompletedSessionTranscriptionService`, `LectureNotesGenerationService`).
/// Session selection itself remains entirely owned by
/// `CompletedSessionsListPresenter` in `CompletedSessionsView` — this view
/// only ever receives one already-selected `CompletedSessionEntry`.
///
/// Transcript remains the default, full-width surface on narrow windows.
/// On sufficiently wide windows, Notes can be shown alongside Transcript in
/// a resizable `HSplitView` pane; below that width, Notes uses the full
/// content area via a simple segmented switch instead of being forced into
/// a cramped sidebar. The exact breakpoint is a placeholder constant —
/// precise tuning is deferred to a later, dedicated visual pass.
struct CompletedSessionDetailView: View {
    private enum ContentSelection: Hashable {
        case transcript
        case notes
    }

    private static let sideBySideMinimumWidth: CGFloat = 900

    let entry: CompletedSessionEntry
    @ObservedObject var transcriptionService: CompletedSessionTranscriptionService
    @ObservedObject var notesService: LectureNotesGenerationService
    private let notesStore: any LectureNotesStoring
    private let notesOperationStateStore: any LectureNotesOperationStateStoring
    private let notesSourceLoader: any NotesTranscriptSourceLoading

    @State private var contentSelection: ContentSelection = .transcript

    init(
        entry: CompletedSessionEntry,
        transcriptionService: CompletedSessionTranscriptionService,
        notesService: LectureNotesGenerationService,
        notesStore: any LectureNotesStoring,
        notesOperationStateStore: any LectureNotesOperationStateStoring,
        notesSourceLoader: any NotesTranscriptSourceLoading
    ) {
        self.entry = entry
        self.transcriptionService = transcriptionService
        self.notesService = notesService
        self.notesStore = notesStore
        self.notesOperationStateStore = notesOperationStateStore
        self.notesSourceLoader = notesSourceLoader
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.sideBySideMinimumWidth {
                HSplitView {
                    transcriptView
                        .frame(minWidth: 360)
                    notesView
                        .frame(minWidth: 320)
                }
            } else {
                VStack(spacing: 0) {
                    Picker("Content", selection: $contentSelection) {
                        Text("Transcript").tag(ContentSelection.transcript)
                        Text("Notes").tag(ContentSelection.notes)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding([.horizontal, .top], 12)

                    switch contentSelection {
                    case .transcript:
                        transcriptView
                    case .notes:
                        notesView
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
}
