import AppKit

/// The application's sole owner of normal-termination lifecycle policy, and
/// (moved here from `LectureRecorderApp`) the sole owner of `AppEnvironment`,
/// the app's single composition root. `@NSApplicationDelegateAdaptor`
/// constructs and retains exactly one instance of this type for the app's
/// entire lifetime, before `LectureRecorderApp.body` is ever evaluated —
/// so there is never more than one `AppEnvironment` and never any ambiguity
/// about who may call the app-wide transcription and Notes services'
/// shutdown entry points.
/// `SessionManager` and every SwiftUI view remain unaware this type exists.
///
/// All of the actual shutdown contract — closing admission, requesting
/// cancellation, and bounding the wait — lives on, and is unit-tested on,
/// the two app-wide services themselves (see `beginShutdown()` and
/// `shutdown(timeout:)`). This class is deliberately too thin to need its
/// own tests: it only bridges AppKit's termination callback to those two
/// calls using the standard `.terminateLater` / `reply(toApplicationShouldTerminate:)`
/// pattern, so that quitting while no transcription is active proceeds
/// immediately (macOS's own default `.terminateNow` behavior would also be
/// correct when both are idle, but returning `.terminateLater`
/// unconditionally and replying as soon as the bounded wait resolves keeps
/// a single, uniform path for both cases rather than two).
///
/// `@MainActor` (not just individually-isolated methods): AppKit always
/// calls `applicationShouldTerminate(_:)` on the main thread, and marking
/// the whole type `@MainActor` is what lets it call
/// `environment.completedSessionTranscriptionService.beginShutdown()`
/// *synchronously* — see that call site's comment for why synchronous
/// matters here.
@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Synchronous, before this function returns at all: closes
        // admission and requests cancellation immediately. Doing this only
        // inside the `Task` below (as an earlier version of this delegate
        // did) would leave a real window — between AppKit invoking this
        // callback and that `Task` actually being scheduled — in which
        // another window could still be admitted for a new
        // Transcribe/Continue/Retry after termination had already begun.
        environment.completedSessionTranscriptionService.beginShutdown()
        environment.lectureNotesGenerationService.beginShutdown()
        environment.lectureSummaryGenerationService.beginShutdown()

        Task { @MainActor in
            // `beginShutdown()` already ran above; this call's own
            // internal `beginShutdown()` is a no-op (idempotent) and it
            // proceeds straight to the bounded wait.
            async let transcriptionShutdown = self.environment.completedSessionTranscriptionService.shutdown()
            async let notesShutdown = self.environment.lectureNotesGenerationService.shutdown()
            async let summaryShutdown = self.environment.lectureSummaryGenerationService.shutdown()
            _ = await (transcriptionShutdown, notesShutdown, summaryShutdown)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
