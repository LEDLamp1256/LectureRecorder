import Foundation

/// The operations `SessionManager` needs against durable storage,
/// expressed as a protocol so tests can inject a store that fails specific
/// operations on demand (see `FailingSessionStore` in
/// `SessionManagerTests.swift`).
protocol SessionStoring: Sendable {
    func createSessionDirectories(sessionID: UUID) async throws -> SessionPaths
    func writeManifest(_ manifest: SessionManifest, paths: SessionPaths) async throws
    func readManifest(paths: SessionPaths) async throws -> SessionManifest
    func createSessionLogger(paths: SessionPaths) async throws -> SessionFileLogger
    func sessionsRootDirectory() async throws -> URL
}

/// Serializes access to session storage.
///
/// Marking this type as an `actor` guarantees mutual exclusion — calls to
/// its methods from multiple tasks are automatically serialized and can
/// never run concurrently with each other — but it does NOT guarantee
/// this work runs on a dedicated background thread or an I/O-optimized
/// executor. Non-`@MainActor` actor-isolated code runs on Swift's shared,
/// size-limited concurrent executor pool alongside other tasks. Because
/// the JSON payloads here are small and writes are infrequent (created
/// once per session, updated at start/stop/failure), performing this
/// synchronous file I/O directly inside the actor is a reasonable, simple
/// choice for this phase — it will not meaningfully starve the shared
/// thread pool. If a later phase performs frequent or large synchronous
/// I/O (e.g. writing audio chunk files many times a minute), reconsider
/// this: options include a dedicated `DispatchQueue`-backed serial
/// executor, `Task.detached(priority:)` with explicit backpressure, or
/// asynchronous file I/O APIs.
actor SessionStore: SessionStoring {
    private let locator: FileSystemLocating

    init(locator: FileSystemLocating = DefaultFileSystemLocator()) {
        self.locator = locator
    }

    func createSessionDirectories(sessionID: UUID) throws -> SessionPaths {
        try locator.paths(for: sessionID)
    }

    func writeManifest(_ manifest: SessionManifest, paths: SessionPaths) throws {
        try AtomicFileWriter.writeJSON(manifest, to: paths.manifestURL)
    }

    func readManifest(paths: SessionPaths) throws -> SessionManifest {
        try AtomicFileWriter.readJSON(SessionManifest.self, from: paths.manifestURL)
    }

    func createSessionLogger(paths: SessionPaths) throws -> SessionFileLogger {
        try SessionFileLogger(fileURL: paths.logFileURL)
    }

    func sessionsRootDirectory() throws -> URL {
        try locator.sessionsRootDirectory()
    }
}
