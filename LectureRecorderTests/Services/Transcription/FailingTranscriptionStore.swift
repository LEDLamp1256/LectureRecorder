import Foundation
@testable import LectureRecorder

/// Wraps a real `TranscriptionStore` and lets individual tests force
/// specific operations to fail deterministically — mirrors
/// `FailingSessionStore`'s pattern from `SessionManagerTests.swift`. Never
/// uses filesystem permissions or an unwritable directory.
actor FailingTranscriptionStore: TranscriptionStoring {
    struct TestInjectedError: Error, LocalizedError, Sendable {
        var errorDescription: String? { "Injected test failure" }
    }

    private let wrapped: TranscriptionStore
    private var failReplaceJobQueue: [Bool] = []
    private var failNextCommitResult = false

    init(wrapped: TranscriptionStore) {
        self.wrapped = wrapped
    }

    /// Each call to `replaceJob` pops one entry from the front of this
    /// queue: `true` forces that call to fail, `false` delegates normally.
    /// Once empty, all further calls succeed normally.
    func setReplaceJobFailureQueue(_ values: [Bool]) {
        failReplaceJobQueue = values
    }

    /// The *next* call to `commitResult` fails before it ever reaches the
    /// wrapped store (i.e. before any file is written) — used to model
    /// "result commit fails outright", distinct from the exclusive
    /// filesystem's own `.createdDurabilityUncertain` outcome.
    func setFailNextCommitResult(_ value: Bool) {
        failNextCommitResult = value
    }

    func ensureDirectoriesExist(paths: TranscriptionArtifactPaths) async throws {
        try await wrapped.ensureDirectoriesExist(paths: paths)
    }

    func loadJob(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptionJob? {
        try await wrapped.loadJob(sequenceNumber: sequenceNumber, paths: paths)
    }

    func createJobIfAbsent(
        _ job: TranscriptionJob,
        paths: TranscriptionArtifactPaths
    ) async throws -> JobCreationOutcome {
        try await wrapped.createJobIfAbsent(job, paths: paths)
    }

    func replaceJob(_ job: TranscriptionJob, paths: TranscriptionArtifactPaths) async throws {
        if !failReplaceJobQueue.isEmpty {
            let shouldFail = failReplaceJobQueue.removeFirst()
            if shouldFail {
                throw TestInjectedError()
            }
        }
        try await wrapped.replaceJob(job, paths: paths)
    }

    func loadResult(sequenceNumber: Int, paths: TranscriptionArtifactPaths) async throws -> TranscriptResult? {
        try await wrapped.loadResult(sequenceNumber: sequenceNumber, paths: paths)
    }

    func commitResult(
        _ result: TranscriptResult,
        paths: TranscriptionArtifactPaths
    ) async throws -> ResultCommitOutcome {
        if failNextCommitResult {
            failNextCommitResult = false
            throw TestInjectedError()
        }
        return try await wrapped.commitResult(result, paths: paths)
    }

    func loadAllJobArtifacts(paths: TranscriptionArtifactPaths) async throws -> [ArtifactLoadResult<TranscriptionJob>] {
        try await wrapped.loadAllJobArtifacts(paths: paths)
    }

    func loadAllResultArtifacts(
        paths: TranscriptionArtifactPaths
    ) async throws -> [ArtifactLoadResult<TranscriptResult>] {
        try await wrapped.loadAllResultArtifacts(paths: paths)
    }
}
