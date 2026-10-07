import Foundation

/// Where one session's diarization sidecar lives:
/// `<session>/diarization/result.json` — its own namespace beside
/// `chunks/`, `transcription/`, `notes/`, and `summaries/`. Nothing else in
/// the session directory, including the manifest, refers to it.
nonisolated enum DiarizationArtifactPaths {
    static let directoryName = "diarization"
    static let resultFileName = "result.json"

    static func directory(sessionPaths: SessionPaths) -> URL {
        sessionPaths.sessionDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func resultURL(sessionPaths: SessionPaths) -> URL {
        directory(sessionPaths: sessionPaths).appendingPathComponent(resultFileName)
    }
}

/// Why an existing sidecar cannot be used. Non-sensitive: carries no paths
/// or file contents.
nonisolated enum SpeakerDiarizationUnavailableReason: Equatable, Sendable {
    /// The session directory, `diarization/`, or `result.json` is missing
    /// where it must exist, a symlink, or the wrong file type; or the paths
    /// do not belong to the session.
    case unsafePath
    /// The file cannot be read or is not a decodable result.
    case corrupt
    case unsupportedSchemaVersion(Int)
    /// Decodes, but violates a result invariant.
    case invalidResult(SpeakerDiarizationValidationError)
    /// Belongs to another session.
    case sessionMismatch
    /// Produced from audio other than the session's current terminal audio.
    case audioSourceMismatch
}

/// What reading a session's diarization sidecar found. Reading never
/// throws: a session without diarization, or with a damaged or stale
/// sidecar, is still a complete, openable session — diarization is simply
/// unavailable. Nothing is ever deleted or repaired on read.
nonisolated enum SpeakerDiarizationLoadOutcome: Equatable, Sendable {
    /// No sidecar exists — the normal state for any session never diarized.
    case absent
    case loaded(SpeakerDiarizationResult)
    case unavailable(SpeakerDiarizationUnavailableReason)
}

nonisolated enum SpeakerDiarizationStoreError: LocalizedError, Equatable, Sendable {
    case invalidResult(SpeakerDiarizationValidationError)
    case sessionMismatch
    case audioSourceMismatch
    case sessionDirectoryUnavailable
    case unsafeSidecarPath

    var errorDescription: String? {
        switch self {
        case .invalidResult(let underlying):
            return underlying.errorDescription
        case .sessionMismatch:
            return "The diarization result, session audio, and session paths do not belong to the same session."
        case .audioSourceMismatch:
            return "The diarization result was not produced from the session's current audio."
        case .sessionDirectoryUnavailable:
            return "The session directory is missing or unsafe; diarization was not saved."
        case .unsafeSidecarPath:
            return "The diarization sidecar path is a symlink or the wrong file type."
        }
    }
}

/// Reads and atomically replaces the diarization sidecar. It touches only
/// `diarization/`: never the manifest, chunks, transcription artifacts,
/// Notes, or Summary, and never creates a missing session directory.
///
/// Both directions are checked against the session's validated
/// `LecturePlaybackSource`, so a result is only ever stored or returned
/// for the exact terminal audio it describes.
nonisolated struct SpeakerDiarizationStore: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        encoder: JSONEncoder = AtomicFileWriter.defaultEncoder,
        decoder: JSONDecoder = AtomicFileWriter.defaultDecoder
    ) {
        self.encoder = encoder
        self.decoder = decoder
    }

    /// Only the schema version, decoded first so a future-schema file is
    /// reported as unsupported rather than corrupt.
    private struct SchemaProbe: Decodable {
        var schemaVersion: Int
    }

    func load(source: LecturePlaybackSource, sessionPaths: SessionPaths) -> SpeakerDiarizationLoadOutcome {
        let sessionID = source.timeline.sessionID
        guard sessionPaths.sessionDirectory.lastPathComponent == sessionID.uuidString,
              CompletedSessionPathSafety.checkExistingDirectory(sessionPaths.sessionDirectory) == .safe else {
            return .unavailable(.unsafePath)
        }
        switch CompletedSessionPathSafety.checkExistingDirectory(DiarizationArtifactPaths.directory(sessionPaths: sessionPaths)) {
        case .missing: return .absent
        case .unsafe: return .unavailable(.unsafePath)
        case .safe: break
        }
        let url = DiarizationArtifactPaths.resultURL(sessionPaths: sessionPaths)
        switch CompletedSessionPathSafety.checkExistingRegularFile(url) {
        case .missing: return .absent
        case .unsafe: return .unavailable(.unsafePath)
        case .safe: break
        }

        let data: Data
        let probe: SchemaProbe
        do {
            data = try Data(contentsOf: url)
            probe = try decoder.decode(SchemaProbe.self, from: data)
        } catch {
            return .unavailable(.corrupt)
        }
        guard probe.schemaVersion == SpeakerDiarizationResult.currentSchemaVersion else {
            return .unavailable(.unsupportedSchemaVersion(probe.schemaVersion))
        }

        let result: SpeakerDiarizationResult
        do {
            result = try decoder.decode(SpeakerDiarizationResult.self, from: data)
        } catch let error as SpeakerDiarizationValidationError {
            // A value type's own decoding validation (for example a
            // malformed speaker ID) is an invalid result, not corruption.
            return .unavailable(.invalidResult(error))
        } catch {
            return .unavailable(.corrupt)
        }

        switch Self.check(result, source: source) {
        case .success: return .loaded(result)
        case .failure(.invalidResult(let error)): return .unavailable(.invalidResult(error))
        case .failure(.sessionMismatch): return .unavailable(.sessionMismatch)
        case .failure(.audioSourceMismatch): return .unavailable(.audioSourceMismatch)
        case .failure: return .unavailable(.unsafePath)
        }
    }

    /// Atomically writes, or replaces, the session's sidecar. Every check
    /// runs before anything is written, so on any failure an existing
    /// sidecar is left exactly as it was; the replacement itself is an
    /// atomic rename (`AtomicFileWriter`), so a reader observes either the
    /// whole previous result or the whole new one.
    func save(_ result: SpeakerDiarizationResult, source: LecturePlaybackSource, sessionPaths: SessionPaths) throws {
        try Self.check(result, source: source).get()
        guard sessionPaths.sessionDirectory.lastPathComponent == result.sessionID.uuidString else {
            throw SpeakerDiarizationStoreError.sessionMismatch
        }
        guard CompletedSessionPathSafety.checkExistingDirectory(sessionPaths.sessionDirectory) == .safe else {
            throw SpeakerDiarizationStoreError.sessionDirectoryUnavailable
        }
        let url = DiarizationArtifactPaths.resultURL(sessionPaths: sessionPaths)
        guard CompletedSessionPathSafety.checkExistingDirectory(DiarizationArtifactPaths.directory(sessionPaths: sessionPaths)) != .unsafe,
              CompletedSessionPathSafety.checkExistingRegularFile(url) != .unsafe else {
            throw SpeakerDiarizationStoreError.unsafeSidecarPath
        }
        // `AtomicFileWriter.writeJSON` creates `diarization/` if missing —
        // beneath a session directory already proven to exist and be safe.
        try AtomicFileWriter.writeJSON(result, to: url, encoder: encoder)
    }

    /// The result invariants, then session identity, then audio identity —
    /// shared by load and save so both enforce the same contract.
    private static func check(
        _ result: SpeakerDiarizationResult,
        source: LecturePlaybackSource
    ) -> Result<Void, SpeakerDiarizationStoreError> {
        do {
            try result.validate(against: source.timeline)
        } catch let error as SpeakerDiarizationValidationError {
            return .failure(.invalidResult(error))
        } catch {
            return .failure(.invalidResult(.unsupportedSchemaVersion(result.schemaVersion)))
        }
        guard result.sessionID == source.timeline.sessionID else {
            return .failure(.sessionMismatch)
        }
        guard result.audioSource == DiarizationAudioSourceFingerprint.compute(source: source) else {
            return .failure(.audioSourceMismatch)
        }
        return .success(())
    }
}
