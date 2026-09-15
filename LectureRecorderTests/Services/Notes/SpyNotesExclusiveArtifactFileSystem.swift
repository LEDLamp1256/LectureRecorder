import Foundation
@testable import LectureRecorder

/// A recording decorator over a real `NotesExclusiveArtifactFileSystem`
/// conformer (`DarwinNotesExclusiveArtifactFileSystem` by default),
/// mirroring transcription's own `SpyExclusiveArtifactFileSystem` pattern.
/// Lets a test force `.createdDurabilityUncertain` for one specific URL,
/// deterministically exercising `LectureNotesStore`'s durability-uncertain
/// outcome propagation without touching real filesystem fault conditions.
final class SpyNotesExclusiveArtifactFileSystem: NotesExclusiveArtifactFileSystem, @unchecked Sendable {
    private let real: any NotesExclusiveArtifactFileSystem
    private let lock = NSLock()
    private var forcedOutcomes: [URL: NotesExclusiveCreateOutcome] = [:]

    init(wrapping real: any NotesExclusiveArtifactFileSystem = DarwinNotesExclusiveArtifactFileSystem()) {
        self.real = real
    }

    /// Forces the *next* call for this exact `url` to return the given
    /// outcome instead of delegating to the real implementation. One-shot
    /// per URL.
    func forceOutcome(_ outcome: NotesExclusiveCreateOutcome, forURL url: URL) {
        lock.lock(); defer { lock.unlock() }
        forcedOutcomes[url] = outcome
    }

    func createExclusive(data: Data, at url: URL) throws -> NotesExclusiveCreateOutcome {
        lock.lock()
        let forced = forcedOutcomes.removeValue(forKey: url)
        lock.unlock()

        if let forced {
            return forced
        }
        return try real.createExclusive(data: data, at: url)
    }
}
