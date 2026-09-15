import Foundation

/// Every reason a `.completed`-status session can fail T4's structural/
/// identity eligibility check, on top of what
/// `TranscriptionArtifactPaths.validated` already enforces. Checked in the
/// exact order listed in `SessionTranscriptionEligibility.validate`.
nonisolated enum SessionEligibilityError: LocalizedError, Sendable, Equatable {
    case unsupportedManifestSchema(Int)
    case sessionIdentityMismatch
    case artifactPathValidation(TranscriptionArtifactPaths.ValidationError)
    case chunksDirectoryUnsafe
    case nonCompletedChunk(sequenceNumber: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedManifestSchema(let version):
            return "Session manifest schema version \(version) is not supported."
        case .sessionIdentityMismatch:
            return "The manifest's session ID does not match the selected session."
        case .artifactPathValidation(let underlying):
            return underlying.errorDescription
        case .chunksDirectoryUnsafe:
            return "The session's chunks directory is missing, a symlink, or not a directory."
        case .nonCompletedChunk(let sequenceNumber):
            return "Chunk #\(sequenceNumber) is not marked completed."
        }
    }
}

/// A `.completed`-status session that has passed every T4 structural/
/// identity check: supported schema, matching session ID, valid transcription
/// artifact-path topology (contiguous canonical chunk sequence, no path
/// escape), a safe chunks directory, and every chunk explicitly
/// `.completed`. Reused by both read-only discovery
/// (`CompletedSessionCatalog`) and `CompletedSessionTranscriptionService`'s
/// fresh pre-operation eligibility check — the service never trusts a
/// catalog-cached copy and always re-derives this from a freshly reloaded
/// manifest.
nonisolated struct ValidatedCompletedSession: Sendable, Equatable {
    let manifest: SessionManifest
    let sessionPaths: SessionPaths
    let artifactPaths: TranscriptionArtifactPaths
}

nonisolated enum SessionTranscriptionEligibility {
    /// Validates a session already known to have `manifest.status ==
    /// .completed`. Never touches transcription jobs/results — purely
    /// structural/identity validation of the recording itself. Does not
    /// require a nonempty chunk workload; a zero-chunk session validates
    /// successfully here (it is a legitimately completed recording) —
    /// callers that require nonempty coverage (e.g. the completion
    /// validator) enforce that separately.
    static func validate(
        expectedSessionID: UUID,
        manifest: SessionManifest,
        sessionPaths: SessionPaths
    ) throws -> ValidatedCompletedSession {
        guard manifest.schemaVersion == SessionManifest.currentSchemaVersion else {
            throw SessionEligibilityError.unsupportedManifestSchema(manifest.schemaVersion)
        }
        guard manifest.sessionID == expectedSessionID else {
            throw SessionEligibilityError.sessionIdentityMismatch
        }

        let artifactPaths: TranscriptionArtifactPaths
        do {
            artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: sessionPaths)
        } catch let error as TranscriptionArtifactPaths.ValidationError {
            throw SessionEligibilityError.artifactPathValidation(error)
        }

        guard CompletedSessionPathSafety.checkExistingDirectory(sessionPaths.chunksDirectory) == .safe else {
            throw SessionEligibilityError.chunksDirectoryUnsafe
        }

        for chunk in manifest.chunks where chunk.state != .completed {
            throw SessionEligibilityError.nonCompletedChunk(sequenceNumber: chunk.sequenceNumber)
        }

        return ValidatedCompletedSession(manifest: manifest, sessionPaths: sessionPaths, artifactPaths: artifactPaths)
    }
}
