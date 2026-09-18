import SwiftUI

/// Read-only completed-session browser. Owns only this window's local
/// selection; the transcription operation itself is owned exclusively by
/// the shared `CompletedSessionTranscriptionService` injected into the
/// environment — this view never becomes a second task/scheduler owner.
struct CompletedSessionsView: View {
    let service: CompletedSessionTranscriptionService
    let notesService: LectureNotesGenerationService
    let summaryService: LectureSummaryGenerationService
    let notesStore: any LectureNotesStoring
    let notesOperationStateStore: any LectureNotesOperationStateStoring
    let notesSourceLoader: any NotesTranscriptSourceLoading
    let summaryStore: any LectureSummaryStoring
    let summaryOperationStateStore: any LectureSummaryOperationStateStoring
    let summarySourceLoader: any LectureSummarySourceLoading
    @ObservedObject var sessionManager: SessionManager
    @StateObject private var presenter: CompletedSessionsListPresenter

    init(
        catalog: CompletedSessionCatalog,
        service: CompletedSessionTranscriptionService,
        notesService: LectureNotesGenerationService,
        summaryService: LectureSummaryGenerationService,
        notesStore: any LectureNotesStoring,
        notesOperationStateStore: any LectureNotesOperationStateStoring,
        notesSourceLoader: any NotesTranscriptSourceLoading,
        summaryStore: any LectureSummaryStoring,
        summaryOperationStateStore: any LectureSummaryOperationStateStoring,
        summarySourceLoader: any LectureSummarySourceLoading,
        sessionManager: SessionManager
    ) {
        self.service = service
        self.notesService = notesService
        self.summaryService = summaryService
        self.notesStore = notesStore
        self.notesOperationStateStore = notesOperationStateStore
        self.notesSourceLoader = notesSourceLoader
        self.summaryStore = summaryStore
        self.summaryOperationStateStore = summaryOperationStateStore
        self.summarySourceLoader = summarySourceLoader
        self.sessionManager = sessionManager
        _presenter = StateObject(wrappedValue: CompletedSessionsListPresenter(catalog: catalog))
    }

    private var selectedEntry: CompletedSessionEntry? {
        presenter.result?.sessions.first { $0.manifest.sessionID == presenter.selectedSessionID }
    }

    var body: some View {
        NavigationSplitView {
            List(presenter.result?.sessions ?? [], id: \.manifest.sessionID, selection: $presenter.selectedSessionID) { entry in
                VStack(alignment: .leading) {
                    Text(entry.manifest.sessionID.uuidString)
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(entry.manifest.chunks.count) chunks · \(entry.manifest.creationDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(entry.manifest.sessionID)
            }
            .navigationTitle("Completed Sessions")
            .toolbar {
                Button {
                    presenter.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .overlay {
                if let result = presenter.result, result.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Completed Sessions",
                        systemImage: "waveform",
                        description: Text("Recordings appear here once Stop has finished saving them.")
                    )
                }
            }
        } detail: {
            if let selectedEntry {
                CompletedSessionDetailView(
                    entry: selectedEntry,
                    transcriptionService: service,
                    notesService: notesService,
                    summaryService: summaryService,
                    notesStore: notesStore,
                    notesOperationStateStore: notesOperationStateStore,
                    notesSourceLoader: notesSourceLoader,
                    summaryStore: summaryStore,
                    summaryOperationStateStore: summaryOperationStateStore,
                    summarySourceLoader: summarySourceLoader
                )
                .id(selectedEntry.manifest.sessionID)
            } else {
                Text("Select a completed session")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            presenter.reload()
        }
        .onChange(of: sessionManager.lastCompletedSession?.sessionID) { oldValue, newValue in
            presenter.refreshAfterFinalization(oldLastCompletedSessionID: oldValue, newLastCompletedSessionID: newValue)
        }
        .alert(
            "Unable to Load Completed Sessions",
            isPresented: Binding(get: { presenter.loadErrorMessage != nil }, set: { if !$0 { presenter.loadErrorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(presenter.loadErrorMessage ?? "")
        }
    }
}
