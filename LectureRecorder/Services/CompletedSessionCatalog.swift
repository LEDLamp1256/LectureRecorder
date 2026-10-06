import Foundation

/// One structurally-valid, listable session discovered by
/// `CompletedSessionCatalog`: `.completed`, or a terminal `.interrupted` /
/// `.failed` recording with durable audio (see `isListable`).
nonisolated struct CompletedSessionEntry: Sendable, Equatable {
    let manifest: SessionManifest
    let sessionPaths: SessionPaths
}

/// One session directory the catalog could not include, and why. Never
/// aborts the rest of the scan — see `CompletedSessionCatalog.listCompletedSessions`.
nonisolated enum CompletedSessionCatalogEntryError: Sendable, Equatable {
    /// A directory entry directly under the sessions root whose name is
    /// not a valid session UUID.
    case invalidSessionDirectoryName(String)
    /// The session directory itself is a symlink or not a directory.
    case unsafeSessionDirectory(UUID)
    /// `session.json` is missing, a symlink, or not a regular file. Since
    /// this check never follows a symlink, a symlinked manifest's target
    /// is never opened or read.
    case manifestUnavailable(UUID)
    /// `session.json` exists and is safe to read, but failed to decode.
    case corruptManifest(UUID, String)
    /// The manifest decoded, has `status == .completed`, but failed T4's
    /// structural/identity eligibility check.
    case ineligible(UUID, SessionEligibilityError)

    var sessionID: UUID? {
        switch self {
        case .invalidSessionDirectoryName:
            return nil
        case .unsafeSessionDirectory(let id), .manifestUnavailable(let id), .corruptManifest(let id, _), .ineligible(let id, _):
            return id
        }
    }
}

nonisolated struct CompletedSessionCatalogResult: Sendable, Equatable {
    var sessions: [CompletedSessionEntry] = []
    var errors: [CompletedSessionCatalogEntryError] = []
}

/// Read-only, non-mutating discovery of completed recording sessions.
///
/// Never creates the sessions root or any session directory merely by
/// browsing (a missing root is reported as an empty catalog, not an
/// error, and the root is never created as a side effect). Never
/// reconciles, mutates, or runs transcription — it only enumerates and
/// structurally validates manifests already on disk. Deliberately does
/// not depend on `SessionStore`, so browsing never serializes behind or
/// interferes with active recording writes.
nonisolated struct CompletedSessionCatalog: Sendable {
    private let sessionsRootResolver: @Sendable () throws -> URL

    init(
        sessionsRootResolver: @escaping @Sendable () throws -> URL = {
            try DefaultFileSystemLocator.resolveSessionsRootPathWithoutCreating()
        }
    ) {
        self.sessionsRootResolver = sessionsRootResolver
    }

    /// Whether a decoded manifest belongs in the session library:
    /// `.completed` (unchanged behavior, including zero-chunk), or a
    /// terminal `.interrupted`/`.failed` recording that durably captured at
    /// least one chunk of audio. Never `.recording`. The session's actual
    /// status is preserved and shown — it is never presented as completed.
    static func isListable(_ manifest: SessionManifest) -> Bool {
        switch manifest.status {
        case .completed:
            return true
        case .interrupted, .failed:
            return !manifest.chunks.isEmpty
        case .recording:
            return false
        }
    }

    func listCompletedSessions() throws -> CompletedSessionCatalogResult {
        let root = try sessionsRootResolver()

        guard CompletedSessionPathSafety.checkExistingDirectory(root) == .safe else {
            // A missing root is an empty catalog, not an error. A root
            // that exists but is unsafe (symlink/wrong type) is also
            // reported as empty here — the root itself is not an
            // app-owned session, so no per-session error entry applies;
            // callers relying on `revealSessionsFolderInFinder` etc. will
            // separately surface a genuine filesystem problem there.
            return CompletedSessionCatalogResult()
        }

        let entryURLs = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var result = CompletedSessionCatalogResult()

        for entryURL in entryURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entryURL.lastPathComponent
            guard let sessionID = UUID(uuidString: name) else {
                result.errors.append(.invalidSessionDirectoryName(name))
                continue
            }

            guard CompletedSessionPathSafety.checkExistingDirectory(entryURL) == .safe else {
                result.errors.append(.unsafeSessionDirectory(sessionID))
                continue
            }

            let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)

            guard CompletedSessionPathSafety.checkExistingRegularFile(sessionPaths.manifestURL) == .safe else {
                result.errors.append(.manifestUnavailable(sessionID))
                continue
            }

            let manifest: SessionManifest
            do {
                manifest = try AtomicFileWriter.readJSON(SessionManifest.self, from: sessionPaths.manifestURL)
            } catch {
                result.errors.append(.corruptManifest(sessionID, error.localizedDescription))
                continue
            }

            guard Self.isListable(manifest) else {
                // A legitimately unlisted session (still recording or
                // awaiting recovery, or a failed/interrupted attempt that
                // captured no audio) — not part of this catalog and not an
                // error.
                continue
            }

            do {
                let validated = try SessionTranscriptionEligibility.validate(
                    expectedSessionID: sessionID,
                    manifest: manifest,
                    sessionPaths: sessionPaths
                )
                result.sessions.append(
                    CompletedSessionEntry(manifest: validated.manifest, sessionPaths: validated.sessionPaths)
                )
            } catch let error as SessionEligibilityError {
                result.errors.append(.ineligible(sessionID, error))
            }
        }

        // Newest-first by authoritative manifest metadata — never by
        // filesystem enumeration or mtime. `endDate` is the timestamp
        // `SessionManager` persists when a session durably finalizes;
        // `creationDate` is the authoritative fallback when it is absent —
        // always so for a recovered `.interrupted` session, whose true end
        // time is unknown. Equal timestamps
        // break the tie on `sessionID` so ordering is deterministic and
        // stable across repeated calls, not dependent on scan order.
        result.sessions.sort { lhs, rhs in
            let lhsDate = lhs.manifest.endDate ?? lhs.manifest.creationDate
            let rhsDate = rhs.manifest.endDate ?? rhs.manifest.creationDate
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.manifest.sessionID.uuidString < rhs.manifest.sessionID.uuidString
        }

        return result
    }
}
