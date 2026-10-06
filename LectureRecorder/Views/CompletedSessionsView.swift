import SwiftUI
import UniformTypeIdentifiers

/// Read-only completed-session browser. Owns only this window's local
/// selection; the transcription operation itself is owned exclusively by
/// the shared `CompletedSessionTranscriptionService` injected into the
/// environment — this view never becomes a second task/scheduler owner.
///
/// Also offers Import Lecture…: a user-chosen local media file becomes a new
/// completed session through `LectureMediaImporting`, after which the list
/// reloads and selects it. Importing never starts transcription, Notes, or
/// Summary.
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
    let transcriptNavigationLoader: any CompletedTranscriptNavigationLoading
    let lectureMediaImporter: any LectureMediaImporting
    @ObservedObject var sessionManager: SessionManager
    @StateObject private var presenter: CompletedSessionsListPresenter
    @State private var isChoosingImportFile = false
    @State private var isImporting = false
    @State private var importErrorMessage: String?
    @State private var isShowingCatalogProblems = false

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
        transcriptNavigationLoader: any CompletedTranscriptNavigationLoading,
        lectureMediaImporter: any LectureMediaImporting,
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
        self.transcriptNavigationLoader = transcriptNavigationLoader
        self.lectureMediaImporter = lectureMediaImporter
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
                    if let caption = SessionRecordingStatusDisplay.listCaption(for: entry.manifest) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
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
            // Kept out of the toolbar: the sidebar's toolbar segment is narrow
            // enough that macOS moves extra items into overflow, which would
            // hide both the action and the in-progress indicator.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                importBar
            }
            .fileImporter(isPresented: $isChoosingImportFile, allowedContentTypes: [.audio, .movie]) { result in
                guard case .success(let url) = result else { return }
                Task { await importLecture(from: url) }
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
                    summarySourceLoader: summarySourceLoader,
                    transcriptNavigationLoader: transcriptNavigationLoader
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
        // Any terminal recording finalization (completed or failed) refreshes
        // the list, so a recording that failed in this app appears without
        // a manual Refresh.
        .onChange(of: sessionManager.lastFinalizedSessionID) { oldValue, newValue in
            presenter.refreshAfterFinalization(oldLastCompletedSessionID: oldValue, newLastCompletedSessionID: newValue)
        }
        .alert(
            "Unable to Import Lecture",
            isPresented: Binding(get: { importErrorMessage != nil }, set: { if !$0 { importErrorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(importErrorMessage ?? "")
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

    /// Import Lecture… plus a visible in-progress indicator, pinned below the
    /// session list so neither can be hidden in toolbar overflow.
    private var importBar: some View {
        VStack(spacing: 0) {
            Divider()
            if !catalogProblems.isEmpty {
                catalogProblemsRow
                Divider()
            }
            HStack(spacing: 8) {
                Button {
                    isChoosingImportFile = true
                } label: {
                    Label("Import Lecture…", systemImage: "square.and.arrow.down")
                }
                .disabled(isImporting)
                .help("Import an existing lecture recording")
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var catalogProblems: [CompletedSessionCatalogProblem] {
        CompletedSessionCatalogProblem.problems(from: presenter.result?.errors ?? [])
    }

    /// Read-only notice for session records the catalog skipped. Never makes
    /// a skipped session selectable; the popover lists only a short ID and a
    /// fixed reason, never the raw diagnostic.
    private var catalogProblemsRow: some View {
        HStack(spacing: 8) {
            Button {
                isShowingCatalogProblems = true
            } label: {
                Label(CompletedSessionCatalogProblem.summary(count: catalogProblems.count), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $isShowingCatalogProblems, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(CompletedSessionCatalogProblem.summary(count: catalogProblems.count))
                        .font(.headline)
                    ForEach(catalogProblems, id: \.self) { problem in
                        Text("\(problem.shortSessionID) — \(problem.reason)")
                            .font(.callout.monospaced())
                    }
                    Button {
                        Task { await sessionManager.revealSessionsFolderInFinder() }
                    } label: {
                        Label("Show Sessions Folder", systemImage: "folder")
                    }
                }
                .padding(16)
                .frame(minWidth: 260, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Imports the chosen file, then reloads and selects the new session.
    /// The file picker grants access only while the security scope is held.
    private func importLecture(from url: URL) async {
        isImporting = true
        defer { isImporting = false }
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let result = try await lectureMediaImporter.importLecture(from: url)
            presenter.reload()
            presenter.selectedSessionID = result.sessionID
        } catch {
            if case LectureMediaImportError.publicationNotDurable = error {
                // The session is complete and in place; show it as well.
                presenter.reload()
            }
            importErrorMessage = error.localizedDescription
        }
    }
}

/// User-facing text for a listed session's terminal recording status.
/// Never presents `.interrupted` or `.failed` as completed; a clean user
/// Stop shows nothing extra.
nonisolated enum SessionRecordingStatusDisplay {
    /// A short caption for the session list row, or `nil` for an ordinary
    /// completed session.
    static func listCaption(for manifest: SessionManifest) -> String? {
        switch manifest.status {
        case .interrupted:
            return "Interrupted recording"
        case .failed:
            return "Recording failed"
        case .completed:
            return manifest.endReason == .appTerminated ? "Ended when the app quit" : nil
        case .recording:
            return nil
        }
    }

    /// The status line for the session detail metadata, or `nil` for an
    /// ordinary completed session. A failed session includes its existing
    /// `failureDescription`.
    static func detailStatus(for manifest: SessionManifest) -> String? {
        switch manifest.status {
        case .interrupted:
            return "Interrupted recording — recovered after the app stopped unexpectedly. Audio saved before the interruption is available."
        case .failed:
            if let description = manifest.failureDescription, !description.isEmpty {
                return "Recording failed: \(description)"
            }
            return "Recording failed."
        case .completed:
            return manifest.endReason == .appTerminated ? "Recording ended when the app quit." : nil
        case .recording:
            return nil
        }
    }
}

/// One session record the catalog could not show, reduced to a short ID and
/// a fixed reason. Built only from `CompletedSessionCatalogEntryError`s that
/// name a real session (a UUID-named directory) — a stray non-session entry
/// under the sessions root is never counted — and never carries the raw
/// decoder diagnostic of a corrupt manifest.
nonisolated struct CompletedSessionCatalogProblem: Hashable, Sendable {
    nonisolated enum Reason: String, Sendable {
        case unreadableRecord = "unreadable record"
        case missingRecord = "missing record"
        case unsupportedFormat = "unsupported format"
        case failsSafetyChecks = "fails safety checks"
    }

    let sessionID: UUID
    let reasonKind: Reason

    /// The first 8 characters of the session UUID.
    var shortSessionID: String { String(sessionID.uuidString.prefix(8)) }
    var reason: String { reasonKind.rawValue }

    static func problem(for error: CompletedSessionCatalogEntryError) -> CompletedSessionCatalogProblem? {
        switch error {
        case .invalidSessionDirectoryName:
            return nil
        case .unsafeSessionDirectory(let id):
            return CompletedSessionCatalogProblem(sessionID: id, reasonKind: .failsSafetyChecks)
        case .manifestUnavailable(let id):
            return CompletedSessionCatalogProblem(sessionID: id, reasonKind: .missingRecord)
        case .corruptManifest(let id, _):
            return CompletedSessionCatalogProblem(sessionID: id, reasonKind: .unreadableRecord)
        case .ineligible(let id, .unsupportedManifestSchema):
            return CompletedSessionCatalogProblem(sessionID: id, reasonKind: .unsupportedFormat)
        case .ineligible(let id, _):
            return CompletedSessionCatalogProblem(sessionID: id, reasonKind: .failsSafetyChecks)
        }
    }

    static func problems(from errors: [CompletedSessionCatalogEntryError]) -> [CompletedSessionCatalogProblem] {
        errors.compactMap(problem(for:))
    }

    static func summary(count: Int) -> String {
        count == 1 ? "1 session can't be shown" : "\(count) sessions can't be shown"
    }
}
