import Foundation
@testable import LectureRecorder

/// Deterministic, call-counting double used by `LectureNotesGeneratorRouterTests`
/// to prove routing/no-fallback behavior. Conforms to both
/// `LectureNotesGenerating` and `NewLectureNotesGenerationAvailabilityChecking`
/// so the same type can stand in for either the Apple or the OpenAI route in
/// a test; a test using it as the "OpenAI" route simply never calls
/// `availabilityForNewGeneration()` on it.
final class RecordingLectureNotesGenerator: LectureNotesGenerating, NewLectureNotesGenerationAvailabilityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _analyzeCallCount = 0
    private var _synthesizeCallCount = 0

    var availabilityResult: LectureNotesGenerationAvailability = .available
    var analyzeFailure: Error?
    var synthesizeFailure: Error?

    var analyzeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _analyzeCallCount
    }

    var synthesizeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _synthesizeCallCount
    }

    func availabilityForNewGeneration() -> LectureNotesGenerationAvailability {
        lock.lock(); defer { lock.unlock() }
        return availabilityResult
    }

    func analyzeWindow(
        units: [NotesTranscriptSourceUnit],
        window: NotesInputWindow,
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesWindowAnalysis {
        lock.lock()
        _analyzeCallCount += 1
        let failure = analyzeFailure
        lock.unlock()
        if let failure { throw failure }
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
            items: [LectureNoteItem(
                kind: .explanation,
                body: "stub",
                fidelity: .transcriptSupported,
                sourceReferences: [NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: window.firstSequenceNumber)]
            )]
        )
    }

    func synthesize(
        analyses: [LectureNotesWindowAnalysis],
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesDocument {
        lock.lock()
        _synthesizeCallCount += 1
        let failure = synthesizeFailure
        lock.unlock()
        if let failure { throw failure }
        return LectureNotesDocument(
            generationID: generation.generationID,
            sessionID: generation.sessionID,
            transcriptFingerprint: generation.transcriptFingerprint,
            provenance: generation.provenance,
            overview: "stub overview",
            sections: [LectureNoteSection(heading: "stub", items: [LectureNoteItem(
                kind: .explanation,
                body: "stub",
                fidelity: .transcriptSupported,
                sourceReferences: [NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: 0)]
            )])]
        )
    }
}

nonisolated struct RecordingGeneratorFailure: Error, Equatable {
    var message: String
}
