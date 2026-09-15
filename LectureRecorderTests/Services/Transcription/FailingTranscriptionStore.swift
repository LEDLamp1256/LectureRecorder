import Foundation
@testable import LectureRecorder

/// Wraps a real `TranscriptionStore` and lets individual tests force
/// specific operations to fail deterministically — mirrors
/// `FailingSessionStore`'s pattern from `SessionManagerTests.swift`. Never
/// uses filesystem permissions or an unwritable directory.
actor FailingTranscriptionStore {
    struct TestInjectedError: Error, LocalizedError, Sendable {
        var errorDescription: String? { "Injected test failure" }
    }

    private let wrapped: TranscriptionStore
    private var failReplaceJobQueue: [Bool] = []
    private var failNextCommitResult = false
    private var failNextCreateJobIfAbsent = false
    private var failNextLoadAllJobArtifacts = false
    private var failLoadAllJobArtifactsOnCallNumber: Int?
    private var loadAllJobArtifactsCallCount = 0
    private var forcedConfirmResultsDirectoryDurable: Bool?

    init(wrapped: TranscriptionStore) {
        self.wrapped = wrapped
    }

    /// The *next* call to `createJobIfAbsent` fails outright — used to
    /// model an enqueue-time storage failure (T4 fault injection).
    func setFailNextCreateJobIfAbsent(_ value: Bool) {
        failNextCreateJobIfAbsent = value
    }

    /// The *next* call to `loadAllJobArtifacts` fails outright (as opposed
    /// to a per-artifact `ArtifactLoadResult.failure`) — used to model a
    /// hard enumeration failure that must abort `reconcileState` entirely
    /// (T4 fault injection).
    func setFailNextLoadAllJobArtifacts(_ value: Bool) {
        failNextLoadAllJobArtifacts = value
    }

    /// Fails only the Nth call (1-indexed) to `loadAllJobArtifacts`, so a
    /// test can target a specific stage (e.g. the terminal reconciliation
    /// call) without guessing exact call ordering by hand.
    func setFailLoadAllJobArtifacts(onCallNumber callNumber: Int) {
        failLoadAllJobArtifactsOnCallNumber = callNumber
    }

    /// Forces every subsequent call to `confirmResultsDirectoryDurable` to
    /// return this exact value instead of delegating to the wrapped store —
    /// `nil` (the default) delegates normally. Used to deterministically
    /// simulate a durability-confirmation failure, then a later success,
    /// without touching the real filesystem sync path.
    func setForcedConfirmResultsDirectoryDurable(_ value: Bool?) {
        forcedConfirmResultsDirectoryDurable = value
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
        if failNextCreateJobIfAbsent {
            failNextCreateJobIfAbsent = false
            throw TestInjectedError()
        }
        return try await wrapped.createJobIfAbsent(job, paths: paths)
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

    func confirmResultsDirectoryDurable(paths: TranscriptionArtifactPaths) async throws -> Bool {
        if let forced = forcedConfirmResultsDirectoryDurable {
            return forced
        }
        return try await wrapped.confirmResultsDirectoryDurable(paths: paths)
    }

    func loadAllJobArtifacts(paths: TranscriptionArtifactPaths) async throws -> [ArtifactLoadResult<TranscriptionJob>] {
        loadAllJobArtifactsCallCount += 1
        if failNextLoadAllJobArtifacts {
            failNextLoadAllJobArtifacts = false
            throw TestInjectedError()
        }
        if failLoadAllJobArtifactsOnCallNumber == loadAllJobArtifactsCallCount {
            throw TestInjectedError()
        }
        return try await wrapped.loadAllJobArtifacts(paths: paths)
    }

    func loadAllResultArtifacts(
        paths: TranscriptionArtifactPaths
    ) async throws -> [ArtifactLoadResult<TranscriptResult>] {
        try await wrapped.loadAllResultArtifacts(paths: paths)
    }
}

extension FailingTranscriptionStore: TranscriptionStoring {}
