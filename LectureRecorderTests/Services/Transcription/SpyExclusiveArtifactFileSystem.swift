import Foundation
@testable import LectureRecorder

/// A recording decorator over a real `ExclusiveArtifactFileSystem`
/// conformer (`DarwinExclusiveArtifactFileSystem` by default), mirroring
/// `SpyChunkFinalizationFileSystem`'s pattern. Lets a test force a specific
/// outcome (including `.createdDurabilityUncertain`, to deterministically
/// exercise the crash-window behavior in `TranscriptionCoordinator`) for
/// one specific URL without touching real filesystem permissions.
final class SpyExclusiveArtifactFileSystem: ExclusiveArtifactFileSystem, @unchecked Sendable {
    enum Call: Equatable {
        case createExclusive(URL)
    }

    private struct State {
        var calls: [Call] = []
        var forcedResults: [URL: Result<ExclusiveCreateOutcome, TestInjectedError>] = [:]
    }

    struct TestInjectedError: Error, Sendable {
        let message: String
    }

    private let real: any ExclusiveArtifactFileSystem
    private let lock = NSLock()
    private var state = State()

    init(wrapping real: any ExclusiveArtifactFileSystem = DarwinExclusiveArtifactFileSystem()) {
        self.real = real
    }

    var recordedCalls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return state.calls
    }

    /// Forces the *next* call for this exact `url` to return/throw the
    /// given result instead of delegating to the real implementation.
    /// One-shot per URL.
    func forceResult(_ result: Result<ExclusiveCreateOutcome, TestInjectedError>, forURL url: URL) {
        lock.lock(); defer { lock.unlock() }
        state.forcedResults[url] = result
    }

    func createExclusive(data: Data, at url: URL) throws -> ExclusiveCreateOutcome {
        lock.lock()
        state.calls.append(.createExclusive(url))
        let forced = state.forcedResults.removeValue(forKey: url)
        lock.unlock()

        if let forced {
            switch forced {
            case .success(let outcome):
                return outcome
            case .failure(let error):
                throw error
            }
        }
        return try real.createExclusive(data: data, at: url)
    }
}
