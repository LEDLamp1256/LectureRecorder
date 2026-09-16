import SwiftUI

@main
struct LectureRecorderApp: App {
    // `AppEnvironment` is owned by `AppTerminationDelegate`, not here — see
    // that type's header comment for why: it is also the app's sole normal-
    // termination lifecycle owner, and must exist before this `body` is
    // ever evaluated.
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.environment.sessionManager)
                .environmentObject(appDelegate.environment.completedSessionTranscriptionService)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: "completed-sessions") {
            CompletedSessionsView(
                catalog: appDelegate.environment.completedSessionCatalog,
                service: appDelegate.environment.completedSessionTranscriptionService,
                notesService: appDelegate.environment.lectureNotesGenerationService,
                notesStore: appDelegate.environment.notesStore,
                notesOperationStateStore: appDelegate.environment.notesOperationStateStore,
                notesSourceLoader: appDelegate.environment.notesTranscriptSourceLoader,
                sessionManager: appDelegate.environment.sessionManager
            )
        }
    }
}
