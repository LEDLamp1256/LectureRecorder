import Foundation

/// The kind of technical/academic content one note item represents. Not
/// exhaustive of every future need, but covers the technical-lecture
/// content classes the notes domain must be able to represent honestly
/// (see contract §5–§6): concepts, definitions, worked examples, and
/// content classes (formula/code) whose exactness must be qualified by
/// `LectureNoteContentFidelity` rather than assumed.
nonisolated enum LectureNoteItemKind: String, Codable, Equatable, Sendable {
    case keyConcept
    case definition
    case explanation
    case example
    case formula
    case algorithmOrCode
    case warning
    case uncertainty
    case other
}

/// What kind of claim `LectureNoteItem.body` actually makes about its own
/// exactness. A reconstructed equation or repaired code snippet must never
/// be represented identically to transcript-supported prose — see contract
/// §6.
nonisolated enum LectureNoteContentFidelity: String, Codable, Equatable, Sendable {
    /// `body` is directly grounded in transcript-supported wording.
    case transcriptSupported
    /// `body` is a reconstructed/normalized representation (e.g. a
    /// reformatted equation or repaired code excerpt) — not verbatim
    /// source material.
    case reconstructed
    /// `body` is a low-confidence reconstruction. `uncertaintyNote` should
    /// explain why whenever this case is used.
    case uncertain
}

/// One structured, grounded note item. `sourceReferences` ties this item
/// back to the transcript source units it was derived from; validation of
/// those references against an actual `NotesTranscriptSourceSnapshot`
/// happens in `NotesIntegrityValidator`, not here — this type is a plain
/// data holder.
nonisolated struct LectureNoteItem: Codable, Equatable, Sendable {
    var id: UUID
    var kind: LectureNoteItemKind
    var title: String?
    var body: String
    var fidelity: LectureNoteContentFidelity
    var sourceReferences: [NotesSourceReference]
    var uncertaintyNote: String?

    init(
        id: UUID = UUID(),
        kind: LectureNoteItemKind,
        title: String? = nil,
        body: String,
        fidelity: LectureNoteContentFidelity,
        sourceReferences: [NotesSourceReference],
        uncertaintyNote: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.fidelity = fidelity
        self.sourceReferences = sourceReferences
        self.uncertaintyNote = uncertaintyNote
    }
}

nonisolated struct LectureNoteSection: Codable, Equatable, Sendable {
    var id: UUID
    var heading: String
    var items: [LectureNoteItem]

    init(id: UUID = UUID(), heading: String, items: [LectureNoteItem]) {
        self.id = id
        self.heading = heading
        self.items = items
    }
}

/// Provenance fields a future real generator/backend may populate.
/// `recipeVersion` identifies the generation *strategy* (prompting/
/// pipeline shape), independent of which concrete backend executed it —
/// T5-A never requires any of these beyond `recipeVersion` to be
/// populated.
nonisolated struct LectureNotesGenerationProvenance: Codable, Equatable, Sendable {
    var recipeVersion: String
    var generatorIdentifier: String?
    var generatorVersion: String?
    var backendIdentifier: String?

    init(
        recipeVersion: String,
        generatorIdentifier: String? = nil,
        generatorVersion: String? = nil,
        backendIdentifier: String? = nil
    ) {
        self.recipeVersion = recipeVersion
        self.generatorIdentifier = generatorIdentifier
        self.generatorVersion = generatorVersion
        self.backendIdentifier = backendIdentifier
    }
}

/// The exact, immutable set of planned input windows belonging to one
/// generation, persisted alongside it. This — not whatever a future app
/// version's planner would compute by default — is the sole authoritative
/// expected coverage for that generation: a cold relaunch resumes against
/// this persisted plan, never a freshly-recomputed one, so a planner
/// change after a generation started can never silently reinterpret which
/// windows that generation owns.
nonisolated struct NotesWindowPlan: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var windows: [NotesInputWindow]

    init(schemaVersion: Int = Self.currentSchemaVersion, windows: [NotesInputWindow]) {
        self.schemaVersion = schemaVersion
        self.windows = windows
    }
}

/// Every deterministic rejection `NotesWindowPlan`'s own validation can
/// throw. A persisted plan is untrusted input — decoding successfully
/// proves only that its JSON shape matched, never that its content is a
/// coherent plan; every case here catches a way it could still be wrong.
nonisolated enum NotesWindowPlanValidationError: LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case duplicateWindowIndex(Int)
    case nonSequentialWindowIndices(indices: [Int])
    case invertedWindowRange(windowIndex: Int, firstSequenceNumber: Int, lastSequenceNumber: Int)
    case nonPositiveUnitCount(windowIndex: Int, unitCount: Int)
    case unitCountMismatch(windowIndex: Int, expected: Int, actual: Int)
    case oversizedFlagInconsistentWithUnitCount(windowIndex: Int, unitCount: Int)
    case overlappingWindows(firstWindowIndex: Int, secondWindowIndex: Int)
    case gapBetweenWindows(afterWindowIndex: Int, expectedNextSequenceNumber: Int, actualNextSequenceNumber: Int)
    case emptyPlanForNonemptySource
    case coverageDoesNotMatchSource
    /// A window's own declared `firstSequenceNumber`/`lastSequenceNumber`/
    /// `unitCount` are individually representable `Int` values, but
    /// computing that window's implied range length, or the sequence
    /// number one past its end, would overflow `Int`. Persisted integers
    /// are untrusted; this is reported as a typed error, never allowed to
    /// trap the process.
    case arithmeticOverflow(windowIndex: Int)
    /// The plan passed `validateStructure()` (every individual window's
    /// own arithmetic is representable), but computing the *aggregate*
    /// first-to-last span across all windows together would overflow
    /// `Int`. Reported as a typed error rather than trapping.
    case coverageRangeOverflow

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Window plan schema version \(version) is not supported."
        case .duplicateWindowIndex(let index):
            return "Window plan contains duplicate windowIndex \(index)."
        case .nonSequentialWindowIndices(let indices):
            return "Window plan indices are not exactly 0..<count: \(indices)."
        case .invertedWindowRange(let windowIndex, let first, let last):
            return "Window #\(windowIndex) has an inverted range: first (\(first)) is greater than last (\(last))."
        case .nonPositiveUnitCount(let windowIndex, let unitCount):
            return "Window #\(windowIndex) has a non-positive unitCount \(unitCount)."
        case .unitCountMismatch(let windowIndex, let expected, let actual):
            return "Window #\(windowIndex) claims unitCount \(actual) but its range implies \(expected)."
        case .oversizedFlagInconsistentWithUnitCount(let windowIndex, let unitCount):
            return "Window #\(windowIndex) is flagged isOversizedSingleUnit but has unitCount \(unitCount), not 1."
        case .overlappingWindows(let first, let second):
            return "Windows #\(first) and #\(second) overlap."
        case .gapBetweenWindows(let afterWindowIndex, let expectedNext, let actualNext):
            return "A gap exists after window #\(afterWindowIndex): expected next sequence number \(expectedNext), got \(actualNext)."
        case .emptyPlanForNonemptySource:
            return "Window plan is empty but the transcript source is not."
        case .coverageDoesNotMatchSource:
            return "Window plan's total coverage does not exactly match the transcript source's sequence coverage."
        case .arithmeticOverflow(let windowIndex):
            return "Window #\(windowIndex) has sequence-number values whose arithmetic overflows Int."
        case .coverageRangeOverflow:
            return "The window plan's aggregate first-to-last sequence span overflows Int."
        }
    }
}

extension NotesWindowPlan {
    /// Validates this plan's own internal structural consistency — no
    /// filesystem or source-snapshot access required. Checks (in order):
    /// supported schema version; unique window indices; indices form
    /// exactly `0..<windows.count` (no missing/non-sequential index); every
    /// window's range is non-inverted with a positive `unitCount` matching
    /// its inclusive range length; `isOversizedSingleUnit` is only ever
    /// `true` when `unitCount == 1`; windows in index order neither overlap
    /// nor leave a gap between consecutive windows' sequence coverage.
    /// Never repairs a malformed plan — only rejects it, and only ever
    /// throws `NotesWindowPlanValidationError`, never traps.
    func validateStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NotesWindowPlanValidationError.unsupportedSchemaVersion(schemaVersion)
        }

        var seenIndices: Set<Int> = []
        for window in windows {
            guard seenIndices.insert(window.windowIndex).inserted else {
                throw NotesWindowPlanValidationError.duplicateWindowIndex(window.windowIndex)
            }
        }

        let sortedIndices = windows.map(\.windowIndex).sorted()
        guard sortedIndices == Array(0..<windows.count) else {
            throw NotesWindowPlanValidationError.nonSequentialWindowIndices(indices: sortedIndices)
        }

        let orderedWindows = windows.sorted { $0.windowIndex < $1.windowIndex }
        var previousWindow: NotesInputWindow?
        for window in orderedWindows {
            guard window.firstSequenceNumber <= window.lastSequenceNumber else {
                throw NotesWindowPlanValidationError.invertedWindowRange(
                    windowIndex: window.windowIndex,
                    firstSequenceNumber: window.firstSequenceNumber,
                    lastSequenceNumber: window.lastSequenceNumber
                )
            }
            guard window.unitCount > 0 else {
                throw NotesWindowPlanValidationError.nonPositiveUnitCount(windowIndex: window.windowIndex, unitCount: window.unitCount)
            }

            // Persisted `firstSequenceNumber`/`lastSequenceNumber` are
            // untrusted integers — computing the range length or the
            // sequence number one past the end must never silently wrap
            // or trap on malformed extreme values (e.g. `Int.max`).
            let (rangeLength, rangeOverflowed) = window.lastSequenceNumber.subtractingReportingOverflow(window.firstSequenceNumber)
            guard !rangeOverflowed else {
                throw NotesWindowPlanValidationError.arithmeticOverflow(windowIndex: window.windowIndex)
            }
            let (expectedUnitCount, unitCountOverflowed) = rangeLength.addingReportingOverflow(1)
            guard !unitCountOverflowed else {
                throw NotesWindowPlanValidationError.arithmeticOverflow(windowIndex: window.windowIndex)
            }
            guard window.unitCount == expectedUnitCount else {
                throw NotesWindowPlanValidationError.unitCountMismatch(
                    windowIndex: window.windowIndex,
                    expected: expectedUnitCount,
                    actual: window.unitCount
                )
            }
            if window.isOversizedSingleUnit {
                guard window.unitCount == 1 else {
                    throw NotesWindowPlanValidationError.oversizedFlagInconsistentWithUnitCount(
                        windowIndex: window.windowIndex,
                        unitCount: window.unitCount
                    )
                }
            }

            // Computed lazily from the *previous* window, and only when a
            // previous window actually exists: the last window in the
            // plan never needs "one past its own end" computed at all, so
            // a last window ending exactly at `Int.max` never overflows
            // this check merely by being last.
            if let previousWindow {
                let (expectedNextSequenceNumber, transitionOverflowed) = previousWindow.lastSequenceNumber.addingReportingOverflow(1)
                guard !transitionOverflowed else {
                    throw NotesWindowPlanValidationError.arithmeticOverflow(windowIndex: previousWindow.windowIndex)
                }
                if window.firstSequenceNumber < expectedNextSequenceNumber {
                    throw NotesWindowPlanValidationError.overlappingWindows(
                        firstWindowIndex: previousWindow.windowIndex,
                        secondWindowIndex: window.windowIndex
                    )
                }
                if window.firstSequenceNumber > expectedNextSequenceNumber {
                    throw NotesWindowPlanValidationError.gapBetweenWindows(
                        afterWindowIndex: previousWindow.windowIndex,
                        expectedNextSequenceNumber: expectedNextSequenceNumber,
                        actualNextSequenceNumber: window.firstSequenceNumber
                    )
                }
            }
            previousWindow = window
        }
    }

    /// Validates structure (see `validateStructure`), then that this
    /// plan's total sequence-number coverage exactly matches `snapshot`'s
    /// actual covered sequence numbers — no more, no less. An empty plan
    /// against a nonempty source is rejected explicitly
    /// (`.emptyPlanForNonemptySource`) even though it would also fail the
    /// general coverage check, for a clearer diagnostic.
    ///
    /// Deliberately never materializes either side's full sequence-number
    /// range as a `Set`: `validateStructure()` already proves this plan's
    /// windows (ordered by `windowIndex`) form one contiguous, gap-free,
    /// non-overlapping span, so the plan's *entire* coverage is provably
    /// exactly `[first window's firstSequenceNumber, last window's
    /// lastSequenceNumber]` — checked here purely via those two bounds
    /// plus a count comparison against the source's actual (deduplicated)
    /// sequence numbers. A source with an internal gap cannot pass this
    /// check even if its min/max happen to match the plan's, because its
    /// unique sequence-number count would then be strictly less than the
    /// span those bounds imply. This keeps cost bounded by the number of
    /// windows and actual source units — never by the numeric magnitude
    /// of a persisted (and therefore untrusted) sequence-number value.
    func validateCoversExactly(_ snapshot: NotesTranscriptSourceSnapshot) throws {
        try validateStructure()

        let sourceSequenceNumbers = Set(snapshot.units.map(\.sequenceNumber))

        guard !windows.isEmpty else {
            guard sourceSequenceNumbers.isEmpty else {
                throw NotesWindowPlanValidationError.emptyPlanForNonemptySource
            }
            return
        }

        guard let sourceMin = sourceSequenceNumbers.min(), let sourceMax = sourceSequenceNumbers.max() else {
            throw NotesWindowPlanValidationError.coverageDoesNotMatchSource
        }

        let orderedWindows = windows.sorted { $0.windowIndex < $1.windowIndex }
        let planMin = orderedWindows[0].firstSequenceNumber
        let planMax = orderedWindows[orderedWindows.count - 1].lastSequenceNumber

        guard planMin == sourceMin, planMax == sourceMax else {
            throw NotesWindowPlanValidationError.coverageDoesNotMatchSource
        }

        let (span, spanOverflowed) = planMax.subtractingReportingOverflow(planMin)
        guard !spanOverflowed else {
            throw NotesWindowPlanValidationError.coverageRangeOverflow
        }
        let (expectedSourceCount, countOverflowed) = span.addingReportingOverflow(1)
        guard !countOverflowed else {
            throw NotesWindowPlanValidationError.coverageRangeOverflow
        }
        guard sourceSequenceNumbers.count == expectedSourceCount else {
            throw NotesWindowPlanValidationError.coverageDoesNotMatchSource
        }
    }
}

/// The durable identity/metadata record for one note generation attempt.
/// Distinct generations for the same session coexist by `generationID` —
/// nothing here is ever mutated in place once persisted (see
/// `LectureNotesStoring`). `windowPlan` is fixed at generation-creation
/// time and is the authoritative expected coverage for every window
/// analysis that generation will ever accept — see `NotesWindowPlan`.
nonisolated struct LectureNotesGenerationRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generationID: UUID
    var sessionID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    var windowPlan: NotesWindowPlan
    var provenance: LectureNotesGenerationProvenance
    var createdDate: Date

    static func newGeneration(
        generationID: UUID = UUID(),
        sessionID: UUID,
        transcriptFingerprint: TranscriptSourceFingerprint,
        windowPlan: NotesWindowPlan,
        provenance: LectureNotesGenerationProvenance,
        now: Date = Date()
    ) -> LectureNotesGenerationRecord {
        LectureNotesGenerationRecord(
            schemaVersion: currentSchemaVersion,
            generationID: generationID,
            sessionID: sessionID,
            transcriptFingerprint: transcriptFingerprint,
            windowPlan: windowPlan,
            provenance: provenance,
            createdDate: now
        )
    }
}

/// A structured, grounded intermediate result for exactly one planned
/// input window of one generation. T5-B's future orchestration will
/// persist one of these per window before synthesis; T5-A defines the
/// shape only — no orchestration state machine.
nonisolated struct LectureNotesWindowAnalysis: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generationID: UUID
    var sessionID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    var windowIndex: Int
    /// The exact range this window was planned to own — an analysis whose
    /// items reference source outside this range is rejected by
    /// `NotesIntegrityValidator`, not silently accepted.
    var ownedRange: NotesSourceReference
    var items: [LectureNoteItem]

    init(
        generationID: UUID,
        sessionID: UUID,
        transcriptFingerprint: TranscriptSourceFingerprint,
        windowIndex: Int,
        ownedRange: NotesSourceReference,
        items: [LectureNoteItem]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generationID = generationID
        self.sessionID = sessionID
        self.transcriptFingerprint = transcriptFingerprint
        self.windowIndex = windowIndex
        self.ownedRange = ownedRange
        self.items = items
    }
}

/// The final, synthesized, structured lecture-notes document for one
/// generation. Canonical persistence format is this typed structure, never
/// a single Markdown/plain-text blob — see contract §5.
nonisolated struct LectureNotesDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generationID: UUID
    var sessionID: UUID
    var transcriptFingerprint: TranscriptSourceFingerprint
    var provenance: LectureNotesGenerationProvenance
    var createdDate: Date
    var overview: String
    var sections: [LectureNoteSection]

    init(
        generationID: UUID,
        sessionID: UUID,
        transcriptFingerprint: TranscriptSourceFingerprint,
        provenance: LectureNotesGenerationProvenance,
        createdDate: Date = Date(),
        overview: String,
        sections: [LectureNoteSection]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generationID = generationID
        self.sessionID = sessionID
        self.transcriptFingerprint = transcriptFingerprint
        self.provenance = provenance
        self.createdDate = createdDate
        self.overview = overview
        self.sections = sections
    }
}
