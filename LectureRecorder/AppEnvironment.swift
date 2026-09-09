import Combine

/// Composition root for the app's dependency graph. Keeps object
/// construction in one place so future phases (transcription service, etc.)
/// have a single, obvious spot to wire in new dependencies.
@MainActor
final class AppEnvironment: ObservableObject {
    let sessionManager: SessionManager

    init() {
        let store = SessionStore()
        let permissionService = MicrophonePermissionService()
        let captureService = AudioCaptureService()
        self.sessionManager = SessionManager(
            store: store,
            permissionService: permissionService,
            captureService: captureService
        )
    }
}
