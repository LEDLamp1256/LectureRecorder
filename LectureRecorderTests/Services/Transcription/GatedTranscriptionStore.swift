import Foundation
@testable import LectureRecorder

/// Wraps a real `TranscriptionStore` and lets a test deterministically
/// suspend one specific `loadJob(sequenceNumber:)` call mid-flight, so two
/// `Task`s can be driven through a genuinely observed interleaving around
/// that suspension point — proving real overlap — instead of relying on
/// incidental scheduling. Mirrors `CancellationAwareFakeTranscriber`'s
/// cooperative-polling gate pattern (`while ... { await Task.yield() }`),
/// but as an `actor` rather than a lock-guarded class, since every method
/// here already runs on this type's own actor isolation.
actor GatedTranscriptionStore: TranscriptionStoring {
    private let wrapped: TranscriptionStore
    private var gatedSequenceNumber: Int?
    private var hasEnteredGateFlag = false
    private var isReleased = false

    init(wrapped: TranscriptionStore) {
        self.wrapped = wrapped
    }

    /// Arms a one-shot gate: the next `loadJob` call for `sequenceNumber`
    /// records that it has entered, then cooperatively polls until
    /// `release()` is called, before delegating to the wrapped store.
    func armGate(forSequenceNumber sequenceNumber: Int) {
        gatedSequenceNumber = sequenceNumber
        hasEnteredGateFlag = false
        isReleased = false
    }

    /// True once a gated call has actually started polling — lets a test
    /// deterministically wait until that call is really suspended inside
    /// `loadJob` before proceeding to race a second call against it.
    var hasEnteredGate: Bool {
        hasEnteredGateFlag
    }

    func release() {
        isReleased = true
    }

    func ensureDirectoriesExist(paths: TranscriptionArtifactPaths) async throws {
        try await wrapped.ensureDirectoriesExist(paths: paths)
    }

    func loadJob(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptionJob? {
        if gatedSequenceNumber == sequenceNumber, !isReleased {
            gatedSequenceNumber = nil
            hasEnteredGateFlag = true
            while !isReleased {
                await Task.yield()
            }
        }
        return try await wrapped.loadJob(sequenceNumber: sequenceNumber, paths: paths)
    }

    func createJobIfAbsent(_ job: TranscriptionJob, paths: TranscriptionArtifactPaths) async throws -> JobCreationOutcome {
        try await wrapped.createJobIfAbsent(job, paths: paths)
    }

    func replaceJob(_ job: TranscriptionJob, paths: TranscriptionArtifactPaths) async throws {
        try await wrapped.replaceJob(job, paths: paths)
    }

    func loadResult(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptResult? {
        try await wrapped.loadResult(sequenceNumber: sequenceNumber, paths: paths)
    }

    func commitResult(_ result: TranscriptResult, paths: TranscriptionArtifactPaths) async throws -> ResultCommitOutcome {
        try await wrapped.commitResult(result, paths: paths)
    }

    func confirmResultsDirectoryDurable(paths: TranscriptionArtifactPaths) async throws -> Bool {
        try await wrapped.confirmResultsDirectoryDurable(paths: paths)
    }

    func loadAllJobArtifacts(paths: TranscriptionArtifactPaths) async throws -> [ArtifactLoadResult<TranscriptionJob>] {
        try await wrapped.loadAllJobArtifacts(paths: paths)
    }

    func loadAllResultArtifacts(paths: TranscriptionArtifactPaths) async throws -> [ArtifactLoadResult<TranscriptResult>] {
        try await wrapped.loadAllResultArtifacts(paths: paths)
    }
}
