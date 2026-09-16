import Foundation
@testable import LectureRecorder

/// Deterministic, controllable `LectureNotesGenerating` fake — test-target
/// only. Records every call; lets a test script a failure for a specific
/// window index or for synthesis, or arm a one-shot cooperative-polling
/// gate (mirroring `SequenceGatedTranscriber`'s established pattern) that
/// suspends the call until the enclosing `Task` is cancelled, so
/// cancellation tests can deterministically get a generator call genuinely
/// in flight before cancelling — no sleeps or polling from the test itself.
actor ControllableFakeLectureNotesGenerator: LectureNotesGenerating {
    private var gatedWindowIndices: Set<Int> = []
    private var gateSynthesis = false
    private var enteredWindowGates: Set<Int> = []
    private var enteredSynthesisGateFlag = false
    private var releaseSuccessfullyWindowIndices: Set<Int> = []
    private var releaseSynthesisSuccessfullyFlag = false
    private var failuresByWindowIndex: [Int: Error] = [:]
    private var synthesisFailure: Error?

    private(set) var analyzeCalls: [Int] = []
    private(set) var synthesizeCallCount = 0

    func armGate(beforeWindowIndex windowIndex: Int) {
        gatedWindowIndices.insert(windowIndex)
    }

    func armSynthesisGate() {
        gateSynthesis = true
    }

    func hasEnteredGate(forWindowIndex windowIndex: Int) -> Bool {
        enteredWindowGates.contains(windowIndex)
    }

    var hasEnteredSynthesisGate: Bool { enteredSynthesisGateFlag }

    func setFailure(_ error: Error, forWindowIndex windowIndex: Int) {
        failuresByWindowIndex[windowIndex] = error
    }

    func setSynthesisFailure(_ error: Error) {
        synthesisFailure = error
    }

    /// Releases a currently-gated window call with a normal successful
    /// result instead of cancellation — used to prove a value the
    /// generator returns *after* the durable source has already changed is
    /// still discarded by the caller's own post-return staleness check,
    /// as distinct from a cancellation-driven discard.
    func releaseGateSuccessfully(windowIndex: Int) {
        releaseSuccessfullyWindowIndices.insert(windowIndex)
    }

    func releaseSynthesisGateSuccessfully() {
        releaseSynthesisSuccessfullyFlag = true
    }

    func analyzeWindow(
        units: [NotesTranscriptSourceUnit],
        window: NotesInputWindow,
        generation: LectureNotesGenerationRecord
    ) async throws -> LectureNotesWindowAnalysis {
        analyzeCalls.append(window.windowIndex)

        if gatedWindowIndices.remove(window.windowIndex) != nil {
            enteredWindowGates.insert(window.windowIndex)
            while !Task.isCancelled && !releaseSuccessfullyWindowIndices.contains(window.windowIndex) {
                await Task.yield()
            }
            if releaseSuccessfullyWindowIndices.remove(window.windowIndex) == nil {
                try Task.checkCancellation()
            }
        }

        if let failure = failuresByWindowIndex[window.windowIndex] {
            throw failure
        }

        let ownedUnits = units.filter {
            $0.sequenceNumber >= window.firstSequenceNumber && $0.sequenceNumber <= window.lastSequenceNumber
        }
        let items = ownedUnits.map { unit in
            LectureNoteItem(
                kind: .explanation,
                body: unit.text,
                fidelity: .transcriptSupported,
                sourceReferences: [NotesSourceReference(sessionID: generation.sessionID, sequenceNumber: unit.sequenceNumber)]
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
        synthesizeCallCount += 1

        if gateSynthesis {
            gateSynthesis = false
            enteredSynthesisGateFlag = true
            while !Task.isCancelled && !releaseSynthesisSuccessfullyFlag {
                await Task.yield()
            }
            if releaseSynthesisSuccessfullyFlag {
                releaseSynthesisSuccessfullyFlag = false
            } else {
                try Task.checkCancellation()
            }
        }

        if let synthesisFailure {
            throw synthesisFailure
        }

        let sections = analyses
            .sorted { $0.windowIndex < $1.windowIndex }
            .map { LectureNoteSection(heading: "Window \($0.windowIndex)", items: $0.items) }
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

/// A distinct, unclassified error type — used to prove
/// `LectureNotesGenerationService` reports generator failures without
/// depending on any particular error shape.
struct FakeGeneratorFailure: Error, Equatable {
    var message: String
}
