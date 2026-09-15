import Foundation

/// A stable, closed classification of an engine-level transcription
/// failure, deliberately mirroring the shape of
/// `TranscriptionFailureCategory`/`RetryDisposition` so a conforming error
/// can be translated into a durable `TranscriptionFailure` without the
/// coordinator ever having to infer retryability from an arbitrary
/// `Swift.Error`'s type. A `Transcribing` conformer that wants its failures
/// classified precisely should throw a value conforming to this protocol;
/// anything else is mapped conservatively (`.unknown`, `.permanent`) by
/// `TranscriptionCoordinator`.
nonisolated protocol TranscriptionEngineFailing: Error, Sendable {
    var category: TranscriptionFailureCategory { get }
    var diagnosticMessage: String { get }
    var retryDisposition: RetryDisposition { get }
}

/// The seam a future real transcription engine (e.g. a whisper.cpp-backed
/// adapter) implements. T1 ships only a deterministic test-target fake
/// conformer — this protocol has no production call site yet.
///
/// A conformer must only ever open `audioURL` for reading; T1 does not
/// mechanically enforce this (Swift has no read-only `URL` type), but it is
/// a documented contract obligation for every conformer, present and
/// future.
nonisolated protocol Transcribing: Sendable {
    func transcribe(
        audioURL: URL,
        source: TranscriptionSourceSnapshot
    ) async throws -> TranscriptionEngineOutput
}
