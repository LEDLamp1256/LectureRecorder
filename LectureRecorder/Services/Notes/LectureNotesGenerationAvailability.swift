import Foundation

/// Whether a backend is ready to run a brand-new Notes generation right
/// now. Deliberately generic over "which backend" — the concrete reason
/// (Apple Intelligence disabled, assets not ready, etc.) is reduced to a
/// user-facing description here so `LectureNotesGenerationService` never
/// needs to know which concrete backend produced it.
nonisolated enum LectureNotesGenerationAvailability: Sendable, Equatable {
    case available
    case unavailable(description: String)
}

/// Checked once, synchronously, before `LectureNotesGenerationService`
/// creates a brand-new immutable generation record (Generate only —
/// Continue/Retry always resume an already-persisted generation and never
/// consult this). Conformers never perform a network request or otherwise
/// mutate state merely by answering this question.
nonisolated protocol NewLectureNotesGenerationAvailabilityChecking: Sendable {
    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability
}

/// Default used wherever no real availability precondition applies (e.g.
/// constructing a `LectureNotesGenerationService` around a generator that
/// has no admission-time readiness check of its own) — always reports
/// available, never itself a source of a `.backendUnavailable` outcome.
nonisolated struct AlwaysAvailableNewGenerationChecker: NewLectureNotesGenerationAvailabilityChecking {
    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability { .available }
}
