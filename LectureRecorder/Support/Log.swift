import Foundation
import OSLog

enum Log {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.LectureRecorder"

    nonisolated static let session = Logger(subsystem: subsystem, category: "session")
    nonisolated static let fileSystem = Logger(subsystem: subsystem, category: "filesystem")
    nonisolated static let permission = Logger(subsystem: subsystem, category: "permission")
    nonisolated static let ui = Logger(subsystem: subsystem, category: "ui")
    nonisolated static let audio = Logger(subsystem: subsystem, category: "audio")
}
