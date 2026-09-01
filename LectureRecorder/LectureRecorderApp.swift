import SwiftUI

@main
struct LectureRecorderApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(environment.sessionManager)
        }
        .windowResizability(.contentSize)
    }
}
