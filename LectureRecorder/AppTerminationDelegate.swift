import AppKit
import OSLog

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
    /// Composed once, at launch. Abandoned-recording recovery runs here —
    /// synchronously, before any window or recording exists — except when
    /// this process is only hosting XCTest: the test host shares the real
    /// application container, and a test run must never mutate real
    /// sessions.
    let environment = AppEnvironment(
        abandonedRecordingRecovery: AppTerminationDelegate.launchRecovery()
    )

    /// The launch-time recovery to run, or `nil` (logged) when this process
    /// is only hosting XCTest.
    private static func launchRecovery() -> AbandonedRecordingRecovery? {
        guard !isHostingXCTest else {
            Log.session.notice("Abandoned-recording recovery skipped: process is hosting XCTest")
            return nil
        }
        return AbandonedRecordingRecovery()
    }

    /// True when this application process was launched as an XCTest host.
    nonisolated static var isHostingXCTest: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Synchronous, before this function returns at all: closes
        // admission and requests cancellation immediately. Doing this only
        // inside the `Task` below (as an earlier version of this delegate
        // did) would leave a real window — between AppKit invoking this
        // callback and that `Task` actually being scheduled — in which
        // another window could still be admitted for a new
        // Transcribe/Continue/Retry — or a new recording Start — after
        // termination had already begun. This also begins finalizing a
        // live recording through `SessionManager`'s one shared shutdown.
        environment.beginTermination()

        Task { @MainActor in
            // `beginTermination()` already ran above; its repeat inside
            // this call is a no-op (idempotent), so this proceeds straight
            // to the bounded waits for recording release and every
            // downstream service.
            await self.environment.shutdownForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
