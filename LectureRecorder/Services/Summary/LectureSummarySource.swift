import CryptoKit
import Foundation

/// One Note item frozen in canonical section/item order for Summary work.
/// Original IDs and all grounding/fidelity context are preserved verbatim.
nonisolated struct LectureSummarySourceItem: Codable, Equatable, Sendable {
    var sourceIndex: Int
    var sectionID: UUID
    var sectionHeading: String
    var item: LectureNoteItem
}

nonisolated struct LectureSummarySourceSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: UUID
    var sourceNotesGenerationID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    var sourceNotesDocumentFingerprint: NotesDocumentFingerprint
    var sourceItems: [LectureSummarySourceItem]
}

nonisolated enum LectureSummarySourceError: LocalizedError, Sendable, Equatable {
    case missingGeneration
    case incompleteGeneration
    case notesValidationFailed(String)
    case sourceIdentityMismatch
    case emptyNotesDocument
    case emptySectionHeading
    case emptyItemBody
    case duplicateItemID(UUID)
    case missingUncertaintyExplanation(UUID)
    case fingerprintEncodingFailed(String)
    case sourceLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingGeneration: return "The source Notes generation does not exist."
        case .incompleteGeneration: return "The source Notes generation has no completed document."
        case .notesValidationFailed(let reason): return "The source Notes document failed integrity validation: \(reason)"
        case .sourceIdentityMismatch: return "The source Notes generation, document, and transcript identities do not match."
        case .emptyNotesDocument: return "The source Notes document contains no detailed Note items."
        case .emptySectionHeading: return "A source Notes section has an empty heading."
        case .emptyItemBody: return "A source Note item has empty text."
        case .duplicateItemID(let id): return "The source Notes document repeats Note item ID \(id.uuidString)."
        case .missingUncertaintyExplanation(let id): return "Source Note item \(id.uuidString) requires a nonempty uncertainty explanation."
        case .fingerprintEncodingFailed(let reason): return "The source Notes document could not be fingerprinted: \(reason)"
        case .sourceLoadFailed(let reason): return "The source Notes evidence could not be loaded: \(reason)"
        }
    }
}

nonisolated enum LectureSummarySourceBuilder {
    /// Computes SHA-256 over the sorted-key, ISO-8601 deterministic JSON
    /// encoding used by canonical artifact persistence. This intentionally
    /// fingerprints decoded document semantics, not incidental whitespace or
    /// key ordering in the file that contained them.
    static func fingerprint(document: LectureNotesDocument) throws -> NotesDocumentFingerprint {
        do {
            let data = try AtomicFileWriter.defaultEncoder.encode(document)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return NotesDocumentFingerprint(
                algorithmVersion: NotesDocumentFingerprint.currentAlgorithmVersion,
                digestHex: digest
            )
        } catch {
            throw LectureSummarySourceError.fingerprintEncodingFailed(error.localizedDescription)
        }
    }

    static func build(
        generation: LectureNotesGenerationRecord,
        analyses: [LectureNotesWindowAnalysis],
        document: LectureNotesDocument,
        transcriptSnapshot: NotesTranscriptSourceSnapshot
    ) throws -> LectureSummarySourceSnapshot {
        do {
            try NotesIntegrityValidator.validateCoverage(
                analyses: analyses,
                generation: generation,
                sourceSnapshot: transcriptSnapshot
            )
            try NotesIntegrityValidator.validate(
                document: document,
                generation: generation,
                sourceSnapshot: transcriptSnapshot
            )
        } catch {
            throw LectureSummarySourceError.notesValidationFailed(error.localizedDescription)
        }

        guard
            generation.schemaVersion == LectureNotesGenerationRecord.currentSchemaVersion,
            generation.sessionID == document.sessionID,
            generation.generationID == document.generationID,
            generation.transcriptFingerprint == document.transcriptFingerprint,
            transcriptSnapshot.schemaVersion == NotesTranscriptSourceSnapshot.currentSchemaVersion
        else {
            throw LectureSummarySourceError.sourceIdentityMismatch
        }

        var seenItemIDs: Set<UUID> = []
        var flattened: [LectureSummarySourceItem] = []
        for section in document.sections {
            guard !section.heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LectureSummarySourceError.emptySectionHeading
            }
            for item in section.items {
                guard seenItemIDs.insert(item.id).inserted else {
                    throw LectureSummarySourceError.duplicateItemID(item.id)
                }
                guard !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LectureSummarySourceError.emptyItemBody
                }
                if item.fidelity != .transcriptSupported {
                    guard let note = item.uncertaintyNote,
                          !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw LectureSummarySourceError.missingUncertaintyExplanation(item.id)
                    }
                }
                flattened.append(LectureSummarySourceItem(
                    sourceIndex: flattened.count,
                    sectionID: section.id,
                    sectionHeading: section.heading,
                    item: item
                ))
            }
        }
        guard !flattened.isEmpty else { throw LectureSummarySourceError.emptyNotesDocument }

        return LectureSummarySourceSnapshot(
            schemaVersion: LectureSummarySourceSnapshot.currentSchemaVersion,
            sessionID: generation.sessionID,
            sourceNotesGenerationID: generation.generationID,
            transcriptFingerprint: generation.transcriptFingerprint,
            sourceNotesDocumentFingerprint: try fingerprint(document: document),
            sourceItems: flattened
        )
    }
}

nonisolated protocol LectureSummarySourceLoading: Sendable {
    func loadSourceSnapshot(sessionID: UUID, notesGenerationID: UUID) async throws -> LectureSummarySourceSnapshot
}

/// Whether a thrown `LectureSummarySourceLoading.loadSourceSnapshot` error
/// means the referenced Notes generation is genuinely not a valid/current
/// Summary source (`.sourceInvalid` — every `LectureSummarySourceError` case
/// other than `.sourceLoadFailed`), or is an ordinary operational failure
/// that says nothing about source validity (`.operational` —
/// `.sourceLoadFailed`, or any error a `LectureSummarySourceLoading`
/// implementation did not itself classify). Shared by
/// `LectureSummaryGenerationService` and `SessionSummaryPresenter` so the
/// live orchestration path and the read-only durable-state presenter can
/// never diverge on which failures mean staleness/unavailability versus an
/// ordinary I/O problem.
nonisolated enum SummarySourceLoadFailureClassification: Equatable, Sendable {
    case sourceInvalid(description: String)
    case operational(description: String)

    static func classify(_ error: Error) -> SummarySourceLoadFailureClassification {
        guard let sourceError = error as? LectureSummarySourceError else {
            return .operational(description: error.localizedDescription)
        }
        switch sourceError {
        case .sourceLoadFailed:
            return .operational(description: sourceError.localizedDescription)
        case .missingGeneration, .incompleteGeneration, .notesValidationFailed,
             .sourceIdentityMismatch, .emptyNotesDocument, .emptySectionHeading,
             .emptyItemBody, .duplicateItemID, .missingUncertaintyExplanation,
             .fingerprintEncodingFailed:
            return .sourceInvalid(description: sourceError.localizedDescription)
        }
    }
}

/// Loads only committed Notes artifacts and delegates transcript loading and
/// Notes validation to the established T5-E boundaries.
nonisolated struct LectureSummarySourceLoader: LectureSummarySourceLoading {
    private let notesStore: any LectureNotesStoring
    private let transcriptLoader: any NotesTranscriptSourceLoading
    private let sessionsRootResolver: @Sendable () throws -> URL

    init(
        notesStore: any LectureNotesStoring,
        transcriptLoader: any NotesTranscriptSourceLoading,
        sessionsRootResolver: @escaping @Sendable () throws -> URL = {
            try DefaultFileSystemLocator.resolveSessionsRootPathWithoutCreating()
        }
    ) {
        self.notesStore = notesStore
        self.transcriptLoader = transcriptLoader
        self.sessionsRootResolver = sessionsRootResolver
    }

    func loadSourceSnapshot(sessionID: UUID, notesGenerationID: UUID) async throws -> LectureSummarySourceSnapshot {
        do {
            let root = try sessionsRootResolver()
            guard CompletedSessionPathSafety.checkExistingDirectory(root) == .safe else {
                throw LectureSummarySourceError.sourceLoadFailed("unsafe sessions root")
            }
            let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)
            guard CompletedSessionPathSafety.checkExistingDirectory(sessionPaths.sessionDirectory) == .safe else {
                throw LectureSummarySourceError.sourceLoadFailed("unsafe or missing session directory")
            }
            let paths = try NotesArtifactPaths.validated(
                sessionPaths: sessionPaths,
                sessionID: sessionID,
                generationID: notesGenerationID
            )
            guard let generation = try notesStore.loadGeneration(paths: paths) else {
                throw LectureSummarySourceError.missingGeneration
            }
            guard let document = try notesStore.loadDocument(paths: paths) else {
                throw LectureSummarySourceError.incompleteGeneration
            }
            let transcript = try await transcriptLoader.loadCurrentSnapshot(sessionID: sessionID)
            let loadedAnalyses = try notesStore.loadAllWindowAnalyses(paths: paths)
            var analyses: [LectureNotesWindowAnalysis] = []
            for loaded in loadedAnalyses {
                switch loaded {
                case .success(_, let analysis):
                    analyses.append(analysis)
                case .failure(let windowIndex, let reason):
                    throw LectureSummarySourceError.notesValidationFailed(
                        "Window analysis #\(windowIndex) is corrupt or invalid: \(reason)"
                    )
                }
            }
            return try LectureSummarySourceBuilder.build(
                generation: generation,
                analyses: analyses,
                document: document,
                transcriptSnapshot: transcript
            )
        } catch let error as LectureSummarySourceError {
            throw error
        } catch {
            throw LectureSummarySourceError.sourceLoadFailed(error.localizedDescription)
        }
    }
}
