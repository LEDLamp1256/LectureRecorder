import Foundation

/// The lifecycle state of one notes-generation run, as recorded by the
/// orchestration service. Purely advisory metadata — see
/// `NotesGenerationOperationState`'s own doc comment.
nonisolated enum NotesGenerationOperationLifecycle: String, Codable, Equatable, Sendable {
    case running
    case cancelled
    case failed
    case completed
}

/// What stage of a run was in progress (or last in progress) when
/// `NotesGenerationOperationState` was last updated. `nil` on the record
/// itself means "not applicable" (e.g. before any window has started).
nonisolated enum NotesGenerationOperationStage: Equatable, Sendable {
    case analyzingWindow(windowIndex: Int)
    case synthesizing
}

extension NotesGenerationOperationStage: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case windowIndex
    }

    private enum Kind: String, Codable {
        case analyzingWindow
        case synthesizing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .analyzingWindow:
            self = .analyzingWindow(windowIndex: try container.decode(Int.self, forKey: .windowIndex))
        case .synthesizing:
            self = .synthesizing
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .analyzingWindow(let windowIndex):
            try container.encode(Kind.analyzingWindow, forKey: .kind)
            try container.encode(windowIndex, forKey: .windowIndex)
        case .synthesizing:
            try container.encode(Kind.synthesizing, forKey: .kind)
        }
    }
}

/// Advisory, mutable lifecycle metadata for one generation's active or most
/// recent run — the one notes-domain artifact that is overwritten in place
/// rather than committed once (see `LectureNotesOperationStateStoring`).
///
/// This is never canonical truth: `LectureNotesGenerationRecord`, committed
/// `LectureNotesWindowAnalysis` artifacts, and the final
/// `LectureNotesDocument` remain the sole authority for what has actually
/// been durably produced. `NotesGenerationRecoveryClassifier` always
/// evaluates those canonical artifacts first and only ever consults this
/// record to *explain* an otherwise-already-determined incomplete state
/// (why a run stopped, and roughly where) — never to decide whether work is
/// actually done. A malformed or identity-mismatched copy is always
/// rejected by `LectureNotesOperationStateStoring`, never silently repaired
/// or reinterpreted as progress.
nonisolated struct NotesGenerationOperationState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: UUID
    var generationID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    /// Identifies one Generate/Continue/Retry invocation. A fresh value is
    /// minted every time the orchestration service admits a new run for
    /// this generation.
    var activeRunID: UUID
    var runAttemptCount: Int
    var lifecycle: NotesGenerationOperationLifecycle
    var currentStage: NotesGenerationOperationStage?
    var failureDescription: String?
    var updatedDate: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionID: UUID,
        generationID: UUID,
        transcriptFingerprint: TranscriptSourceFingerprint,
        activeRunID: UUID,
        runAttemptCount: Int,
        lifecycle: NotesGenerationOperationLifecycle,
        currentStage: NotesGenerationOperationStage? = nil,
        failureDescription: String? = nil,
        updatedDate: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.generationID = generationID
        self.transcriptFingerprint = transcriptFingerprint
        self.activeRunID = activeRunID
        self.runAttemptCount = runAttemptCount
        self.lifecycle = lifecycle
        self.currentStage = currentStage
        self.failureDescription = failureDescription
        self.updatedDate = updatedDate
    }
}
