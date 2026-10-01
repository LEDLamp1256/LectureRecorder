import Foundation

/// One completed-session window's presentation state for Notes: which
/// generation (if any) is currently displayed, and its recovery
/// classification. A thin wrapper around already-existing durable state and
/// `NotesGenerationRecoveryClassification` — never a second Notes state
/// machine. `.loaded`'s `classification` is always produced by
/// `NotesGenerationRecoveryClassifier`, never re-derived here.
nonisolated enum SessionNotesDisplayState: Equatable {
    /// No `refresh(for:)` has completed yet for the currently displayed
    /// session.
    case loading
    /// `listGenerationIDs` returned no generations for this session yet.
    /// `transcriptSourceReady` is `true` only when `NotesTranscriptSourceLoading
    /// .loadCurrentSnapshot` currently succeeds for this session — the exact
    /// same authoritative "transcript is fully completed and valid" check
    /// `LectureNotesGenerationService.generate` itself performs before
    /// admitting a run. `false` while transcription has not started, is
    /// still queued/running, or is otherwise ineligible; T5-D never offers a
    /// fresh Generate until this is `true`.
    case noGeneration(transcriptSourceReady: Bool)
    case loaded(record: LectureNotesGenerationRecord, classification: NotesGenerationRecoveryClassification, advisoryStateIntegrity: NotesAdvisoryStateIntegrity)
    /// A durable read failed (corrupt store, unreadable transcript source,
    /// etc.) — distinct from any `NotesGenerationRecoveryClassification`
    /// case, since the classifier was never reached.
    case loadError(String)
}

/// Whether the advisory `operation-state.json` this generation's
/// classification was computed against could be trusted. Deliberately kept
/// separate from `NotesGenerationRecoveryClassification` itself: canonical
/// artifacts (and therefore `.completed`/`.readyForSynthesis`/`.staleSource`
/// /`.damaged`) are never affected by operation-state problems — operation
/// state is only ever consulted by the classifier to explain a
/// `.resumable` classification's `interruption`, never to determine
/// completeness. `.problem` exists only so the UI can refuse to offer
/// Continue/Retry in exactly the two cases
/// `LectureNotesGenerationService.run()` would itself deterministically
/// refuse before ever reaching classification — see its own
/// `operationStateIdentity` switch and its `loadOperationState` catch
/// block — without ever hiding an otherwise-valid canonical result.
nonisolated enum NotesAdvisoryStateIntegrity: Equatable {
    case normal
    case problem(reason: String)
}

/// Pure, deterministic default-generation selection among every generation
/// T5-A/B/C ever persisted for a session. T5-A intentionally keeps every
/// generation on disk — this policy exists only to pick *which one* T5-D
/// displays by default; it never deletes, hides, or reorders anything in
/// storage, and `LectureNotesStoring.listGenerationIDs` remains UUID-string
/// ordered regardless of this policy.
nonisolated enum SessionNotesGenerationSelection {
    /// Newest `createdDate` first; ties broken by the greater
    /// `generationID.uuidString` so the result is fully deterministic even
    /// when two generations were created within the same persisted
    /// millisecond. `nil` only when `records` is empty.
    static func chooseDefault(records: [LectureNotesGenerationRecord]) -> LectureNotesGenerationRecord? {
        records.sorted { lhs, rhs in
            if lhs.createdDate != rhs.createdDate { return lhs.createdDate > rhs.createdDate }
            return lhs.generationID.uuidString > rhs.generationID.uuidString
        }.first
    }
}

/// Read-only reconstruction of one completed session's Notes state from
/// already-persisted durable artifacts via `LectureNotesStoring`/
/// `LectureNotesOperationStateStoring`/`NotesTranscriptSourceLoading` plus
/// `NotesGenerationRecoveryClassifier`. Shared by `SessionNotesPresenter`
/// (display) and `LectureProcessingWorkflow` (automatic orchestration) so
/// both reach the same classification through one path. Never calls
/// `LectureNotesGenerationService`, never mints a generation ID, never writes
/// any artifact, never performs a network request, and holds no state of its
/// own — staleness guarding is each caller's responsibility.
struct SessionNotesStateLoader {
    let notesStore: any LectureNotesStoring
    let operationStateStore: any LectureNotesOperationStateStoring
    let sourceLoader: any NotesTranscriptSourceLoading

    /// The state of the generation `SessionNotesGenerationSelection` picks by
    /// default, or `.noGeneration` when none exists.
    func loadDefaultState(sessionID: UUID, sessionPaths: SessionPaths) async -> SessionNotesDisplayState {
        let generationIDs: [UUID]
        do {
            generationIDs = try notesStore.listGenerationIDs(sessionPaths: sessionPaths)
        } catch {
            return .loadError(error.localizedDescription)
        }

        guard !generationIDs.isEmpty else {
            // No Notes generation exists yet, so a fresh Generate is the
            // only action in play — gate it on the same authoritative
            // eligibility check `LectureNotesGenerationService.generate`
            // itself relies on, rather than assuming a missing generation
            // always means the transcript is ready.
            let transcriptSourceReady: Bool
            do {
                _ = try await sourceLoader.loadCurrentSnapshot(sessionID: sessionID)
                transcriptSourceReady = true
            } catch {
                transcriptSourceReady = false
            }
            return .noGeneration(transcriptSourceReady: transcriptSourceReady)
        }

        // Fail closed: `listGenerationIDs` already proved every one of
        // these IDs exists on disk, so an unreadable candidate is never
        // silently dropped from consideration before applying the
        // newest-`createdDate` selection policy below — doing so could
        // make an older, readable generation appear to be "the newest"
        // purely because the actual newest one happened to be unreadable.
        var records: [LectureNotesGenerationRecord] = []
        for generationID in generationIDs {
            let candidatePaths: NotesArtifactPaths
            do {
                candidatePaths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
            } catch {
                return .loadError("Notes generation \(generationID.uuidString) could not be validated: \(error.localizedDescription)")
            }
            do {
                guard let record = try notesStore.loadGeneration(paths: candidatePaths) else {
                    // `listGenerationIDs` enumerated this generation's
                    // directory, but no generation record exists inside
                    // it — an explicit, unexpected inconsistency, never
                    // silently treated as "this generation doesn't exist".
                    return .loadError("Notes generation \(generationID.uuidString) is listed but has no generation record.")
                }
                records.append(record)
            } catch {
                return .loadError("Notes generation \(generationID.uuidString) could not be loaded: \(error.localizedDescription)")
            }
        }

        guard let chosen = SessionNotesGenerationSelection.chooseDefault(records: records) else {
            // `generationIDs` was proven non-empty above and every ID
            // loaded successfully in the loop above — unreachable in
            // practice; kept only as a defensive fallback, never as a
            // reordering policy of its own.
            return .loadError("Unable to determine the Notes generation to display for this session.")
        }

        return await classifiedState(of: chosen, sessionID: sessionID, sessionPaths: sessionPaths)
    }

    /// The state of exactly the Notes generation `generationID`. Never falls
    /// back to another generation: a missing, unreadable, or mismatched
    /// record is `.loadError`. Once the record loads, classification is
    /// identical to `loadDefaultState`.
    func loadState(sessionID: UUID, sessionPaths: SessionPaths, generationID: UUID) async -> SessionNotesDisplayState {
        let paths: NotesArtifactPaths
        do {
            paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: generationID)
        } catch {
            return .loadError("Notes generation \(generationID.uuidString) could not be validated: \(error.localizedDescription)")
        }
        let record: LectureNotesGenerationRecord
        do {
            guard let loaded = try notesStore.loadGeneration(paths: paths) else {
                return .loadError("Notes generation \(generationID.uuidString) is unavailable.")
            }
            record = loaded
        } catch {
            return .loadError("Notes generation \(generationID.uuidString) could not be loaded: \(error.localizedDescription)")
        }
        // `loadGeneration` already verifies identity against `paths`; kept
        // so this route can never classify any generation but the one asked for.
        guard record.generationID == generationID, record.sessionID == sessionID else {
            return .loadError("Notes generation \(generationID.uuidString) does not match the requested generation.")
        }

        return await classifiedState(of: record, sessionID: sessionID, sessionPaths: sessionPaths)
    }

    /// Loads `record`'s analyses, document, advisory operation state, and the
    /// current transcript source, and classifies them — the one load/classify
    /// path shared by both load routes.
    private func classifiedState(
        of chosen: LectureNotesGenerationRecord,
        sessionID: UUID,
        sessionPaths: SessionPaths
    ) async -> SessionNotesDisplayState {
        let paths: NotesArtifactPaths
        do {
            paths = try NotesArtifactPaths.validated(sessionPaths: sessionPaths, sessionID: sessionID, generationID: chosen.generationID)
        } catch {
            return .loadError(error.localizedDescription)
        }

        let analysisResults: [NotesArtifactLoadResult<LectureNotesWindowAnalysis>]
        do {
            analysisResults = try notesStore.loadAllWindowAnalyses(paths: paths)
        } catch {
            return .loadError(error.localizedDescription)
        }

        var analyses: [LectureNotesWindowAnalysis] = []
        for result in analysisResults {
            switch result {
            case .success(_, let value):
                analyses.append(value)
            case .failure(let windowIndex, let underlying):
                // Mirrors `LectureNotesGenerationService.run()`'s own
                // handling of this exact case: a corrupt committed analysis
                // is reported as damaged, never silently dropped from
                // coverage.
                return .loaded(
                    record: chosen,
                    classification: .damaged(reason: .corruptOrInvalidAnalysis(windowIndex: windowIndex, underlying: underlying)),
                    advisoryStateIntegrity: .normal
                )
            }
        }

        let document: LectureNotesDocument?
        do {
            document = try notesStore.loadDocument(paths: paths)
        } catch {
            return .loadError(error.localizedDescription)
        }

        // Advisory-only (see `NotesGenerationOperationState`'s own header
        // comment): a problem here — unreadable, or readable but
        // identity-mismatched — must never be treated as equivalent to a
        // canonical read failure, and must never suppress an otherwise-
        // valid canonical classification (`.completed` in particular never
        // consults operation state at all). It is instead folded into
        // `advisoryStateIntegrity`, which `NotesActionAvailabilityCalculator`
        // uses to withhold Continue/Retry in exactly the two situations
        // `LectureNotesGenerationService.run()` would itself deterministically
        // refuse before ever reaching classification — see its own
        // `operationStateIdentity` switch (mismatched fingerprint) and its
        // `loadOperationState` catch block (unreadable) — never a second,
        // independently-invented policy.
        let operationStateForClassification: NotesGenerationOperationState?
        let advisoryStateIntegrity: NotesAdvisoryStateIntegrity
        do {
            if let loadedOperationState = try operationStateStore.loadOperationState(paths: paths) {
                if loadedOperationState.transcriptFingerprint == chosen.transcriptFingerprint {
                    operationStateForClassification = loadedOperationState
                    advisoryStateIntegrity = .normal
                } else {
                    operationStateForClassification = nil
                    advisoryStateIntegrity = .problem(reason: "recovery metadata for this generation does not match its transcript")
                }
            } else {
                operationStateForClassification = nil
                advisoryStateIntegrity = .normal
            }
        } catch {
            operationStateForClassification = nil
            advisoryStateIntegrity = .problem(reason: "recovery metadata could not be read: \(error.localizedDescription)")
        }

        let sourceSnapshot: NotesTranscriptSourceSnapshot
        do {
            sourceSnapshot = try await sourceLoader.loadCurrentSnapshot(sessionID: sessionID)
        } catch {
            return .loadError(error.localizedDescription)
        }

        let classification = NotesGenerationRecoveryClassifier.classify(
            generation: chosen,
            sourceSnapshot: sourceSnapshot,
            analyses: analyses,
            document: document,
            operationState: operationStateForClassification
        )
        return .loaded(record: chosen, classification: classification, advisoryStateIntegrity: advisoryStateIntegrity)
    }
}
