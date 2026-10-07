import Foundation

/// Why a session's audio cannot currently be diarized. Non-sensitive:
/// carries no paths, file contents, or underlying error text.
nonisolated enum SessionDiarizationSourceError: LocalizedError, Sendable, Equatable {
    /// The sessions root cannot be resolved, or the root, the session
    /// directory, or `session.json` is missing, a symlink, or the wrong file
    /// type.
    case sessionUnavailable
    /// `session.json` exists but cannot be read or decoded.
    case manifestUnreadable
    /// The manifest on disk belongs to a different session.
    case sessionIdentityMismatch
    /// The session is not terminal — a live or not-yet-recovered recording
    /// whose audio may still change.
    case notTerminal(SessionStatus)
    /// The terminal session's durable chunks do not form a valid, complete
    /// `LecturePlaybackSource` (no chunks, non-completed or missing chunks,
    /// unsafe files, frame-count or format mismatch, invalid timeline).
    case audioUnavailable(LecturePlaybackSourceError)

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "The session's files are missing or unsafe."
        case .manifestUnreadable:
            return "The session record could not be read."
        case .sessionIdentityMismatch:
            return "The session record belongs to a different session."
        case .notTerminal:
            return "The session is still recording or has not been recovered yet."
        case .audioUnavailable(let underlying):
            return underlying.errorDescription
        }
    }
}

/// One freshly validated reading of a terminal session's audio: the source a
/// diarizer analyzes, the paths its sidecar lives under, and the D1
/// fingerprint identifying exactly that audio.
nonisolated struct SessionDiarizationSourceSnapshot: Equatable, Sendable {
    let source: LecturePlaybackSource
    let sessionPaths: SessionPaths
    let audioSource: DiarizationAudioSourceFingerprint

    init(source: LecturePlaybackSource, sessionPaths: SessionPaths) {
        self.source = source
        self.sessionPaths = sessionPaths
        self.audioSource = DiarizationAudioSourceFingerprint.compute(source: source)
    }
}

/// Loads the current diarization source for a session, always freshly from
/// durable state on disk — never from a cached manifest.
nonisolated protocol SessionDiarizationSourceLoading: Sendable {
    func loadSourceSnapshot(sessionID: UUID) async throws -> SessionDiarizationSourceSnapshot
}

/// Production `SessionDiarizationSourceLoading`. Read-only: never creates a
/// directory, never writes the manifest, and never modifies, converts, or
/// copies audio.
///
/// Diarization's own eligibility rule is enforced here, explicitly, before
/// the shared playback validation: the manifest status must be terminal
/// (`.completed`, `.interrupted`, or `.failed`; `.recording` is rejected).
/// Terminal status is necessary but not sufficient — the durable chunks must
/// then form a valid `LecturePlaybackSource`. `endedCleanly`, transcription,
/// Notes, and Summary state are deliberately not consulted.
///
/// All filesystem work (manifest read, opening every chunk once) runs on the
/// global concurrent executor, never the caller's actor.
nonisolated struct SessionDiarizationSourceLoader: SessionDiarizationSourceLoading {
    private let sessionsRootResolver: @Sendable () throws -> URL

    init(
        sessionsRootResolver: @escaping @Sendable () throws -> URL = {
            try DefaultFileSystemLocator.resolveSessionsRootPathWithoutCreating()
        }
    ) {
        self.sessionsRootResolver = sessionsRootResolver
    }

    func loadSourceSnapshot(sessionID: UUID) async throws -> SessionDiarizationSourceSnapshot {
        try await load(sessionID: sessionID)
    }

    @concurrent
    private func load(sessionID: UUID) async throws -> SessionDiarizationSourceSnapshot {
        try Self.loadSynchronously(sessionID: sessionID, sessionsRootResolver: sessionsRootResolver)
    }

    /// The diarization status rule, stated independently of transcription's
    /// structural helpers so it cannot drift with them.
    static func isEligibleStatus(_ status: SessionStatus) -> Bool {
        switch status {
        case .completed, .interrupted, .failed:
            return true
        case .recording:
            return false
        }
    }

    /// Path safety is proven outermost-first (root, session directory,
    /// manifest) before anything beneath is read, mirroring the other
    /// completed-session loaders.
    private static func loadSynchronously(
        sessionID: UUID,
        sessionsRootResolver: () throws -> URL
    ) throws -> SessionDiarizationSourceSnapshot {
        let root: URL
        do {
            root = try sessionsRootResolver()
        } catch {
            throw SessionDiarizationSourceError.sessionUnavailable
        }
        guard CompletedSessionPathSafety.checkExistingDirectory(root) == .safe else {
            throw SessionDiarizationSourceError.sessionUnavailable
        }
        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)
        guard CompletedSessionPathSafety.checkExistingDirectory(sessionPaths.sessionDirectory) == .safe,
              CompletedSessionPathSafety.checkExistingRegularFile(sessionPaths.manifestURL) == .safe else {
            throw SessionDiarizationSourceError.sessionUnavailable
        }

        let manifest: SessionManifest
        do {
            manifest = try AtomicFileWriter.readJSON(SessionManifest.self, from: sessionPaths.manifestURL)
        } catch {
            throw SessionDiarizationSourceError.manifestUnreadable
        }
        guard manifest.sessionID == sessionID else {
            throw SessionDiarizationSourceError.sessionIdentityMismatch
        }
        guard isEligibleStatus(manifest.status) else {
            throw SessionDiarizationSourceError.notTerminal(manifest.status)
        }

        let source: LecturePlaybackSource
        do {
            source = try LecturePlaybackSourceLoader.load(
                expectedSessionID: sessionID,
                manifest: manifest,
                sessionPaths: sessionPaths
            )
        } catch let error as LecturePlaybackSourceError {
            throw SessionDiarizationSourceError.audioUnavailable(error)
        }
        return SessionDiarizationSourceSnapshot(source: source, sessionPaths: sessionPaths)
    }
}
