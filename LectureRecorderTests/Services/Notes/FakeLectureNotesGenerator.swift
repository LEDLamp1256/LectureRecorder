@testable import LectureRecorder
import Foundation

/// Deterministic, offline fake conforming to `LectureNotesGenerating`. Used
/// only by tests — no network, no model, no randomness. Produces exactly
/// one `.explanation` item per source unit in its owned window, and turns
/// each window analysis into one document section when synthesizing.
struct FakeLectureNotesGenerator: LectureNotesGenerating {
    /// When `true`, `analyzeWindow` deliberately claims a source reference
    /// one past its owned window's last sequence number, letting tests
    /// exercise `NotesIntegrityValidator`'s rejection of malformed
    /// generator output.
    var claimsOutOfRangeSourceReference = false

    func analyzeWindow(
        units: [NotesTranscriptSourceUnit],
        window: NotesInputWindow,
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesWindowAnalysis {
        let ownedUnits = units.filter {
            $0.sequenceNumber >= window.firstSequenceNumber && $0.sequenceNumber <= window.lastSequenceNumber
        }
        let items = ownedUnits.map { unit -> LectureNoteItem in
            let referenceSequence = claimsOutOfRangeSourceReference ? window.lastSequenceNumber + 1 : unit.sequenceNumber
            return LectureNoteItem(
                kind: .explanation,
                body: unit.text,
                fidelity: .transcriptSupported,
                sourceReferences: [NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: referenceSequence)]
            )
        }
        return LectureNotesWindowAnalysis(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            windowIndex: window.windowIndex,
            ownedRange: NotesSourceReference(
                sessionID: generation.sessionID,
                firstSequenceNumber: window.firstSequenceNumber,
                lastSequenceNumber: window.lastSequenceNumber
            ),
            items: items
        )
    }

    func synthesize(
        analyses: [LectureNotesWindowAnalysis],
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesDocument {
        let sections = analyses
            .sorted { $0.windowIndex < $1.windowIndex }
            .map { analysis in LectureNoteSection(heading: "Window \(analysis.windowIndex)", items: analysis.items) }
        return LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: "Fake deterministic overview.",
            sections: sections
        )
    }
}
