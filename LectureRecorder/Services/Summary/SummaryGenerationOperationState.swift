import Foundation

/// The lifecycle state of one Summary-generation run, as recorded by the
/// orchestration service. Purely advisory metadata — see
/// `SummaryGenerationOperationState`'s own doc comment. Mirrors
/// `NotesGenerationOperationLifecycle` exactly; kept as a distinct type so a
/// Summary orchestration bug can never silently read or write Notes'
/// advisory state.
nonisolated enum SummaryGenerationOperationLifecycle: String, Codable, Equatable, Sendable {
    case running
    case cancelled
    case failed
    case completed
}

/// What stage of a run was in progress (or last in progress) when
/// `SummaryGenerationOperationState` was last updated. `nil` on the record
/// itself means "not applicable" (e.g. before any batch has started).
nonisolated enum SummaryGenerationOperationStage: Equatable, Sendable {
    case analyzingBatch(batchIndex: Int)
    case synthesizing
}

extension SummaryGenerationOperationStage: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case batchIndex
    }

    private enum Kind: String, Codable {
        case analyzingBatch
        case synthesizing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .analyzingBatch:
            self = .analyzingBatch(batchIndex: try container.decode(Int.self, forKey: .batchIndex))
        case .synthesizing:
            self = .synthesizing
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .analyzingBatch(let batchIndex):
            try container.encode(Kind.analyzingBatch, forKey: .kind)
            try container.encode(batchIndex, forKey: .batchIndex)
        case .synthesizing:
            try container.encode(Kind.synthesizing, forKey: .kind)
        }
    }
}

/// Advisory, mutable lifecycle metadata for one Summary generation's active
/// or most recent run — the one Summary-domain artifact that is overwritten
/// in place rather than committed once (see `LectureSummaryOperationStateStoring`).
///
/// This is never canonical truth: `LectureSummaryGenerationRecord`, committed
/// `LectureSummaryAnalysis` artifacts, and the final `LectureSummaryDocument`
/// remain the sole authority for what has actually been durably produced.
/// `SummaryGenerationRecoveryClassifier` always evaluates those canonical
/// artifacts first and only ever consults this record to *explain* an
/// otherwise-already-determined incomplete state (why a run stopped, and
/// roughly where) — never to decide whether work is actually done. A
/// malformed or identity-mismatched copy is always rejected by
/// `LectureSummaryOperationStateStoring`, never silently repaired or
/// reinterpreted as progress.
///
/// Unlike `NotesGenerationOperationState`, a Summary generation's identity
/// depends on both the live transcript *and* the specific source Notes
/// document it was built from — `sourceNotesDocumentFingerprint` is carried
/// here too so a loaded record can be rejected as untrustworthy the moment
/// either fingerprint disagrees with its generation, never only one of them.
nonisolated struct SummaryGenerationOperationState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: UUID
    var generationID: UUID
    var sourceNotesGenerationID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    var sourceNotesDocumentFingerprint: NotesDocumentFingerprint
    /// Identifies one Generate/Continue/Retry invocation. A fresh value is
    /// minted every time the orchestration service admits a new run for
    /// this generation.
    var activeRunID: UUID
    var runAttemptCount: Int
    var lifecycle: SummaryGenerationOperationLifecycle
    var currentStage: SummaryGenerationOperationStage?
    var failureDescription: String?
    var updatedDate: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionID: UUID,
        generationID: UUID,
        sourceNotesGenerationID: UUID,
        transcriptFingerprint: TranscriptSourceFingerprint,
        sourceNotesDocumentFingerprint: NotesDocumentFingerprint,
        activeRunID: UUID,
        runAttemptCount: Int,
        lifecycle: SummaryGenerationOperationLifecycle,
        currentStage: SummaryGenerationOperationStage? = nil,
        failureDescription: String? = nil,
        updatedDate: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.generationID = generationID
        self.sourceNotesGenerationID = sourceNotesGenerationID
        self.transcriptFingerprint = transcriptFingerprint
        self.sourceNotesDocumentFingerprint = sourceNotesDocumentFingerprint
        self.activeRunID = activeRunID
        self.runAttemptCount = runAttemptCount
        self.lifecycle = lifecycle
        self.currentStage = currentStage
        self.failureDescription = failureDescription
        self.updatedDate = updatedDate
    }
}
