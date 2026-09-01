import Foundation

enum FileSystemError: LocalizedError, Sendable {
    case unableToResolveApplicationSupportDirectory
    case pathExistsButIsNotADirectory(URL)
    case unableToCreateDirectory(URL, underlyingDescription: String)

    var errorDescription: String? {
        switch self {
        case .unableToResolveApplicationSupportDirectory:
            return "Unable to resolve the Application Support directory."
        case .pathExistsButIsNotADirectory(let url):
            return "A file already exists at \(url.path) where a directory was expected."
        case .unableToCreateDirectory(let url, let underlyingDescription):
            return "Unable to create directory at \(url.path): \(underlyingDescription)"
        }
    }
}

/// The resolved on-disk locations for a single session.
struct SessionPaths: Sendable, Equatable {
    let sessionDirectory: URL
    let chunksDirectory: URL
    let logsDirectory: URL
    let manifestURL: URL
    let logFileURL: URL
}

/// Abstraction over where session data lives on disk. The only purpose of
/// this protocol is to let tests substitute a temporary directory instead
/// of the real Application Support folder.
protocol FileSystemLocating: Sendable {
    func sessionsRootDirectory() throws -> URL
    func paths(for sessionID: UUID) throws -> SessionPaths
}

/// Resolves session storage under:
/// `<Application Support>/<bundle-id>/Sessions/<session-uuid>/`
///
/// ## Sandbox behavior — read this before trying to inspect files by hand
/// This app runs with App Sandbox enabled. When sandboxed,
/// `FileManager`'s `.applicationSupportDirectory` URL is **silently
/// redirected by the OS** into this app's sandbox container:
/// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/`.
/// No code in this type opts into that redirection — it happens
/// automatically for every sandboxed process, and there is no sandboxed
/// way to write directly to the unsandboxed `~/Library/Application
/// Support/` path.
///
/// This method then appends the bundle identifier again as a namespacing
/// subdirectory (the same code path is used whether or not sandboxing is
/// enabled), so the final resolved path looks like:
/// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/<bundle-id>/Sessions/`.
///
/// Don't type this path by hand — use the "Show Sessions Folder" button
/// in the app (wired to `SessionManager.revealSessionsFolderInFinder()`),
/// which asks the running process for the real resolved URL instead of
/// guessing it.
struct DefaultFileSystemLocator: FileSystemLocating {
    private static let sessionsDirectoryName = "Sessions"

    func applicationSupportDirectory() throws -> URL {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw FileSystemError.unableToResolveApplicationSupportDirectory
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "LectureRecorder"
        let appDirectory = base.appendingPathComponent(bundleID, isDirectory: true)
        try Self.ensureDirectoryExists(appDirectory)
        return appDirectory
    }

    func sessionsRootDirectory() throws -> URL {
        let root = try applicationSupportDirectory()
            .appendingPathComponent(Self.sessionsDirectoryName, isDirectory: true)
        try Self.ensureDirectoryExists(root)
        return root
    }

    func paths(for sessionID: UUID) throws -> SessionPaths {
        try Self.buildPaths(rootDirectory: try sessionsRootDirectory(), sessionID: sessionID)
    }

    /// Creates `directory` (and any missing intermediate directories) if it
    /// does not already exist. Throws if a regular file already occupies
    /// that path.
    static func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw FileSystemError.pathExistsButIsNotADirectory(url)
            }
            return
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw FileSystemError.unableToCreateDirectory(url, underlyingDescription: error.localizedDescription)
        }
    }

    /// Builds and creates the standard `chunks/` and `logs/` layout under
    /// `rootDirectory/<sessionID>/`. Shared by `DefaultFileSystemLocator`
    /// and test-only locators so the on-disk layout is defined in one place.
    static func buildPaths(rootDirectory: URL, sessionID: UUID) throws -> SessionPaths {
        let sessionDirectory = rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let chunksDirectory = sessionDirectory.appendingPathComponent("chunks", isDirectory: true)
        let logsDirectory = sessionDirectory.appendingPathComponent("logs", isDirectory: true)

        try ensureDirectoryExists(sessionDirectory)
        try ensureDirectoryExists(chunksDirectory)
        try ensureDirectoryExists(logsDirectory)

        let manifestURL = sessionDirectory.appendingPathComponent("session.json")
        let logFileURL = logsDirectory.appendingPathComponent("recording.log")

        return SessionPaths(
            sessionDirectory: sessionDirectory,
            chunksDirectory: chunksDirectory,
            logsDirectory: logsDirectory,
            manifestURL: manifestURL,
            logFileURL: logFileURL
        )
    }
}
