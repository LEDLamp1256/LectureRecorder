import Foundation

/// A backend-neutral, hierarchical lecture-notes generator: analyze each
/// planned window into grounded intermediate material, then synthesize
/// every completed analysis into one final document. Deliberately never
/// assumes "whole transcript → one summary string" — every conformer
/// (including future real OpenAI/Anthropic/local-model backends) must fit
/// this two-stage shape. T5-A ships no conformer that calls a real
/// backend; tests use deterministic fakes only.
nonisolated protocol LectureNotesGenerating: Sendable {
    /// Analyzes one planned input window's transcript units into
    /// structured, grounded intermediate note items. `window` states the
    /// exact source range this call owns — a conforming generator must
    /// only ever claim source references within that range; a claim
    /// outside it is a validation failure, not a generator responsibility
    /// to self-police (see `NotesIntegrityValidator`).
    func analyzeWindow(
        units: [NotesTranscriptSourceUnit],
        window: NotesInputWindow,
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesWindowAnalysis

    /// Synthesizes every window analysis belonging to one generation into
    /// a final `LectureNotesDocument`. `analyses` is expected to cover
    /// every planned window for `generation`, but this protocol does not
    /// itself enforce that — callers validate coverage before calling.
    func synthesize(
        analyses: [LectureNotesWindowAnalysis],
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesDocument
}
