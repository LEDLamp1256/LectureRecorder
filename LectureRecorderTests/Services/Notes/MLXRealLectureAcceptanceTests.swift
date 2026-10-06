import CryptoKit
import XCTest
@testable import LectureRecorder

/// MLX-3: opt-in, test-only measurement harness for the current MLX Notes
/// and Summary generators against one real, representative completed
/// lecture session's full transcript — never the small synthetic fixtures
/// `MLXRealAcceptanceTests`/`MLXSummaryRealAcceptanceTests` use. Disabled by
/// default and never part of the deterministic suite. Enable with:
///
///     LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE=1
///     LECTURE_RECORDER_ACCEPTANCE_SESSION_ID=<completed session UUID>
///     LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY=<absolute local path>
///
/// Optionally set `LECTURE_RECORDER_ACCEPTANCE_NOTES_WINDOW_INDEX` to one
/// nonnegative production-plan index to analyze and persist only that Notes
/// window, then return before Notes synthesis or Summary.
///
/// Optionally set `LECTURE_RECORDER_ACCEPTANCE_SCOPE` to exactly one of
/// `notes-window` (requires the window index), `notes-full` (every planned
/// Notes window, then return before Notes synthesis or Summary; forbids the
/// window index), `notes-and-summary` (the full run; forbids the window
/// index), or `notes-range` (the inclusive planned-window range given by
/// the required `LECTURE_RECORDER_ACCEPTANCE_NOTES_FIRST_WINDOW_INDEX` and
/// `LECTURE_RECORDER_ACCEPTANCE_NOTES_LAST_WINDOW_INDEX`, then return before
/// Notes synthesis or Summary; forbids the single window index, and the two
/// range indices are forbidden with every other scope). Absent keeps the
/// original routing: `notes-window` when the window index is set, otherwise
/// `notes-and-summary`. Any other value, including empty, fails the run.
/// Every run is a fresh directory; `notes-range` never reads, resumes, or
/// merges an earlier run.
///
/// Every run writes `run-identity.json` (run, session, scope, model,
/// provenance, transcript fingerprint, and planned/requested windows) after
/// configuration and source validation but before the first MLX generation.
///
/// Optionally set `LECTURE_RECORDER_ACCEPTANCE_MLX_MODEL` to exactly
/// `qwen3-8b-4bit` or `qwen3-14b-4bit` to choose between the two pinned,
/// trusted descriptors (absent means `qwen3-8b-4bit`; any other value,
/// including empty, fails the run). The selected descriptor drives the
/// session driver, both generators, both generation provenances, and every
/// model-identity field in the persisted results. Test-only: production
/// always uses `MLXModelDescriptor.qwen3_8b_4bit`.
///
/// Optionally also set `LECTURE_RECORDER_ACCEPTANCE_DIAGNOSTICS=1` (the
/// existing `AcceptanceDiagnosticLogger` gate) for the ordinary structural
/// diagnostics trace, unrelated to this harness's own local artifacts.
///
/// Optionally set `LECTURE_RECORDER_ACCEPTANCE_SESSIONS_ROOT` to the absolute
/// path of an existing directory to load the session from that
/// acceptance-only sessions root (for example a trimmed copy kept outside the
/// app's Sessions catalog) instead of the production Sessions root. Absent
/// keeps the production root; an invalid value fails the run.
///
/// Bypasses `LectureNotesGenerationService`/`LectureSummaryGenerationService`
/// entirely and drives `MLXLectureNotesGenerator`/`MLXLectureSummaryGenerator`
/// directly — exactly as `MLXRealAcceptanceTests`/`MLXSummaryRealAcceptanceTests`
/// already do. This measures generator quality/performance only: because it
/// bypasses both generation services and `AppEnvironment` entirely, it
/// proves nothing about either service's durable-recovery behavior, and
/// nothing about `AppEnvironment`'s production provider routing — that
/// routing is covered separately by `AppEnvironmentTests`.
///
/// Never downloads or reprovisions the pinned model:
/// `RealMLXSessionDriver.availability()` must already report `.available`,
/// exactly like the two existing acceptance tests.
///
/// Once the master gate is `1`, every other configuration/session/model
/// problem is reported as an explicit `XCTFail`, never a silent `XCTSkip` —
/// an intentionally requested acceptance run must never appear to have
/// "passed" by silently skipping.
/// The finite set of pinned models the MLX-3 acceptance harness may select.
/// Never accepts an arbitrary model identifier.
enum MLXAcceptanceModelSelection: String, CaseIterable, Sendable {
    case qwen3_8b_4bit = "qwen3-8b-4bit"
    case qwen3_14b_4bit = "qwen3-14b-4bit"

    static let environmentKey = "LECTURE_RECORDER_ACCEPTANCE_MLX_MODEL"

    struct UnknownSelection: LocalizedError, Equatable {
        var value: String
        var errorDescription: String? {
            "\(MLXAcceptanceModelSelection.environmentKey) '\(value)' is not one of: "
                + MLXAcceptanceModelSelection.allCases.map(\.rawValue).joined(separator: ", ") + "."
        }
    }

    /// Absent selects the production 8B model; any present value must match
    /// an allowlisted name exactly.
    static func resolve(environmentValue: String?) throws -> MLXAcceptanceModelSelection {
        guard let environmentValue else { return .qwen3_8b_4bit }
        guard let selection = MLXAcceptanceModelSelection(rawValue: environmentValue) else {
            throw UnknownSelection(value: environmentValue)
        }
        return selection
    }

    var descriptor: MLXModelDescriptor {
        switch self {
        case .qwen3_8b_4bit: return .qwen3_8b_4bit
        case .qwen3_14b_4bit: return .qwen3_14b_4bit
        }
    }
}

/// The model-identity fields every persisted acceptance result carries,
/// derived only from the selected descriptor.
struct MLXAcceptanceModelIdentity: Encodable, Equatable {
    var mlxModelSelection: String
    var modelIdentifier: String
    var modelRevision: String
    var nativeContextLength: Int
    var operationalContextCeiling: Int

    init(_ selection: MLXAcceptanceModelSelection) {
        mlxModelSelection = selection.rawValue
        modelIdentifier = selection.descriptor.modelIdentifier
        modelRevision = selection.descriptor.modelRevision
        nativeContextLength = selection.descriptor.nativeContextLength
        operationalContextCeiling = selection.descriptor.operationalContextCeiling
    }
}

/// The optional acceptance-only sessions root
/// (`LECTURE_RECORDER_ACCEPTANCE_SESSIONS_ROOT`). Test-only: it selects which
/// directory the production `NotesTranscriptSourceLoader` reads through its
/// existing `sessionsRootResolver` injection point and changes nothing else.
enum MLXAcceptanceSessionsRoot {
    static let environmentKey = "LECTURE_RECORDER_ACCEPTANCE_SESSIONS_ROOT"

    enum ResolutionError: LocalizedError, Equatable {
        case notAbsolute(String)
        case unusable(String)

        var errorDescription: String? {
            switch self {
            case .notAbsolute(let value):
                return "\(MLXAcceptanceSessionsRoot.environmentKey) '\(value)' must be an absolute path."
            case .unusable(let value):
                return "\(MLXAcceptanceSessionsRoot.environmentKey) '\(value)' is missing, a symlink, or not a directory."
            }
        }
    }

    /// `nil` when unset (the production Sessions root). A set value must be
    /// an absolute path to an existing, non-symlink directory.
    static func resolve(environmentValue: String?) throws -> URL? {
        guard let value = environmentValue else { return nil }
        guard value.hasPrefix("/") else { throw ResolutionError.notAbsolute(value) }
        let url = URL(fileURLWithPath: value, isDirectory: true)
        guard CompletedSessionPathSafety.checkExistingDirectory(url) == .safe else {
            throw ResolutionError.unusable(value)
        }
        return url
    }

    /// The production transcript loader, reading `root` when supplied and
    /// the production Sessions root otherwise.
    static func makeTranscriptLoader(root: URL?) -> NotesTranscriptSourceLoader {
        guard let root else { return NotesTranscriptSourceLoader(transcriptionStore: TranscriptionStore()) }
        return NotesTranscriptSourceLoader(transcriptionStore: TranscriptionStore(), sessionsRootResolver: { root })
    }
}

/// How far one acceptance run goes. Resolved once, before any work, from
/// `LECTURE_RECORDER_ACCEPTANCE_SCOPE`,
/// `LECTURE_RECORDER_ACCEPTANCE_NOTES_WINDOW_INDEX`, and (for `notes-range`)
/// `LECTURE_RECORDER_ACCEPTANCE_NOTES_FIRST_WINDOW_INDEX` /
/// `LECTURE_RECORDER_ACCEPTANCE_NOTES_LAST_WINDOW_INDEX`.
enum MLXAcceptanceScope: Equatable, Sendable {
    /// Exactly one planned Notes window; stops before Notes synthesis.
    case notesWindow(index: Int)
    /// The inclusive planned-window range `first...last`; stops before
    /// Notes synthesis. Always a fresh run, never a resume.
    case notesRange(first: Int, last: Int)
    /// Every planned Notes window; stops before Notes synthesis.
    case notesFull
    /// Every planned Notes window, Notes synthesis, then Summary.
    case notesAndSummary

    static let scopeEnvironmentKey = "LECTURE_RECORDER_ACCEPTANCE_SCOPE"
    static let windowIndexEnvironmentKey = "LECTURE_RECORDER_ACCEPTANCE_NOTES_WINDOW_INDEX"
    static let firstWindowIndexEnvironmentKey = "LECTURE_RECORDER_ACCEPTANCE_NOTES_FIRST_WINDOW_INDEX"
    static let lastWindowIndexEnvironmentKey = "LECTURE_RECORDER_ACCEPTANCE_NOTES_LAST_WINDOW_INDEX"
    static let scopeNames = ["notes-window", "notes-full", "notes-and-summary", "notes-range"]

    enum ResolutionError: LocalizedError, Equatable {
        case unknownScope(String)
        case malformedNotesWindowIndex(String)
        case malformedNotesRangeIndex(key: String, value: String)
        case scopeRequiresNotesWindowIndex
        case scopeForbidsNotesWindowIndex(String)
        case notesRangeRequiresBothIndices
        case notesRangeIndicesRequireNotesRangeScope(String)
        case notesRangeFirstAfterLast(first: Int, last: Int)
        case notesWindowIndexOutOfRange(index: Int, plannedWindowCount: Int)
        case notesRangeOutOfRange(first: Int, last: Int, plannedWindowCount: Int)

        var errorDescription: String? {
            switch self {
            case .unknownScope(let value):
                return "\(MLXAcceptanceScope.scopeEnvironmentKey) '\(value)' is not one of: "
                    + MLXAcceptanceScope.scopeNames.joined(separator: ", ") + "."
            case .malformedNotesWindowIndex(let value):
                return "\(MLXAcceptanceScope.windowIndexEnvironmentKey) '\(value)' is not a nonnegative integer."
            case .malformedNotesRangeIndex(let key, let value):
                return "\(key) '\(value)' is not a nonnegative integer."
            case .scopeRequiresNotesWindowIndex:
                return "\(MLXAcceptanceScope.scopeEnvironmentKey)=notes-window requires \(MLXAcceptanceScope.windowIndexEnvironmentKey)."
            case .scopeForbidsNotesWindowIndex(let scope):
                return "\(MLXAcceptanceScope.scopeEnvironmentKey)=\(scope) does not analyze a single window; unset \(MLXAcceptanceScope.windowIndexEnvironmentKey)."
            case .notesRangeRequiresBothIndices:
                return "\(MLXAcceptanceScope.scopeEnvironmentKey)=notes-range requires both \(MLXAcceptanceScope.firstWindowIndexEnvironmentKey) and \(MLXAcceptanceScope.lastWindowIndexEnvironmentKey)."
            case .notesRangeIndicesRequireNotesRangeScope(let scope):
                return "\(MLXAcceptanceScope.firstWindowIndexEnvironmentKey)/\(MLXAcceptanceScope.lastWindowIndexEnvironmentKey) are only valid with \(MLXAcceptanceScope.scopeEnvironmentKey)=notes-range (got \(scope))."
            case .notesRangeFirstAfterLast(let first, let last):
                return "Notes range first window \(first) is after last window \(last)."
            case .notesWindowIndexOutOfRange(let index, let plannedWindowCount):
                return "\(MLXAcceptanceScope.windowIndexEnvironmentKey) \(index) is outside the production Notes plan's 0..<\(plannedWindowCount) range."
            case .notesRangeOutOfRange(let first, let last, let plannedWindowCount):
                return "Notes range \(first)...\(last) is outside the production Notes plan's 0..<\(plannedWindowCount) range."
            }
        }
    }

    static func resolve(
        scopeValue: String?,
        notesWindowIndexValue: String?,
        notesFirstWindowIndexValue: String? = nil,
        notesLastWindowIndexValue: String? = nil
    ) throws -> MLXAcceptanceScope {
        let windowIndex: Int?
        if let notesWindowIndexValue {
            guard let parsed = Int(notesWindowIndexValue), parsed >= 0 else {
                throw ResolutionError.malformedNotesWindowIndex(notesWindowIndexValue)
            }
            windowIndex = parsed
        } else {
            windowIndex = nil
        }
        func parseRangeIndex(_ value: String?, key: String) throws -> Int? {
            guard let value else { return nil }
            guard let parsed = Int(value), parsed >= 0 else {
                throw ResolutionError.malformedNotesRangeIndex(key: key, value: value)
            }
            return parsed
        }
        let first = try parseRangeIndex(notesFirstWindowIndexValue, key: firstWindowIndexEnvironmentKey)
        let last = try parseRangeIndex(notesLastWindowIndexValue, key: lastWindowIndexEnvironmentKey)
        let hasRangeIndex = first != nil || last != nil

        switch scopeValue {
        case "notes-range":
            guard windowIndex == nil else { throw ResolutionError.scopeForbidsNotesWindowIndex("notes-range") }
            guard let first, let last else { throw ResolutionError.notesRangeRequiresBothIndices }
            guard first <= last else { throw ResolutionError.notesRangeFirstAfterLast(first: first, last: last) }
            return .notesRange(first: first, last: last)
        case let other? where !scopeNames.contains(other):
            throw ResolutionError.unknownScope(other)
        default:
            break
        }

        // Every other scope (including the absent default) forbids the
        // range indices.
        guard !hasRangeIndex else {
            throw ResolutionError.notesRangeIndicesRequireNotesRangeScope(scopeValue ?? "<unset>")
        }
        switch scopeValue {
        case nil:
            return windowIndex.map { .notesWindow(index: $0) } ?? .notesAndSummary
        case "notes-window":
            guard let windowIndex else { throw ResolutionError.scopeRequiresNotesWindowIndex }
            return .notesWindow(index: windowIndex)
        case let scope?:
            guard windowIndex == nil else { throw ResolutionError.scopeForbidsNotesWindowIndex(scope) }
            return scope == "notes-full" ? .notesFull : .notesAndSummary
        }
    }

    var name: String {
        switch self {
        case .notesWindow: return "notes-window"
        case .notesRange: return "notes-range"
        case .notesFull: return "notes-full"
        case .notesAndSummary: return "notes-and-summary"
        }
    }

    var notesWindowIndex: Int? {
        if case .notesWindow(let index) = self { return index }
        return nil
    }

    var stopsBeforeNotesSynthesis: Bool { self != .notesAndSummary }

    /// The planned windows this scope analyzes, in source order. Checked
    /// against the current production plan before any output directory or
    /// model call exists.
    func windowsToAnalyze(plannedWindows: [NotesInputWindow]) throws -> [NotesInputWindow] {
        let ordered = plannedWindows.sorted { $0.windowIndex < $1.windowIndex }
        switch self {
        case .notesWindow(let index):
            guard let window = ordered.first(where: { $0.windowIndex == index }) else {
                throw ResolutionError.notesWindowIndexOutOfRange(index: index, plannedWindowCount: ordered.count)
            }
            return [window]
        case .notesRange(let first, let last):
            let selected = ordered.filter { (first...last).contains($0.windowIndex) }
            guard selected.map(\.windowIndex) == Array(first...last) else {
                throw ResolutionError.notesRangeOutOfRange(first: first, last: last, plannedWindowCount: ordered.count)
            }
            return selected
        case .notesFull, .notesAndSummary:
            return ordered
        }
    }
}

/// Immutable structural identity of one acceptance run, written as
/// `run-identity.json` before the first MLX generation so that even a
/// failed run identifies itself. Never contains transcript, prompt,
/// schema, or generated Notes text.
struct MLXAcceptanceRunIdentity: Codable, Equatable {
    var runID: String
    var sessionID: String
    var acceptanceScope: String
    var requestedFirstWindowIndex: Int?
    var requestedLastWindowIndex: Int?
    var requestedWindowIndices: [Int]
    var mlxModelSelection: String
    var modelIdentifier: String
    var modelRevision: String
    var nativeContextLength: Int
    var operationalContextCeiling: Int
    var notesGenerationProvenance: LectureNotesGenerationProvenance
    /// Present only for `notes-and-summary`, the only scope that runs Summary.
    var summaryGenerationProvenance: LectureNotesGenerationProvenance?
    var transcriptFingerprint: TranscriptSourceFingerprint
    var transcriptUnitCount: Int
    var plannedWindowCount: Int
    var plannedWindows: [NotesInputWindow]

    init(
        runID: UUID,
        sessionID: UUID,
        scope: MLXAcceptanceScope,
        selection: MLXAcceptanceModelSelection,
        transcriptFingerprint: TranscriptSourceFingerprint,
        transcriptUnitCount: Int,
        plannedWindows: [NotesInputWindow],
        requestedWindows: [NotesInputWindow]
    ) {
        let model = MLXAcceptanceModelIdentity(selection)
        self.runID = runID.uuidString
        self.sessionID = sessionID.uuidString
        acceptanceScope = scope.name
        if case .notesRange(let first, let last) = scope {
            requestedFirstWindowIndex = first
            requestedLastWindowIndex = last
        }
        requestedWindowIndices = requestedWindows.map(\.windowIndex)
        mlxModelSelection = model.mlxModelSelection
        modelIdentifier = model.modelIdentifier
        modelRevision = model.modelRevision
        nativeContextLength = model.nativeContextLength
        operationalContextCeiling = model.operationalContextCeiling
        notesGenerationProvenance = MLXNotesConfiguration.generationProvenance(for: selection.descriptor)
        summaryGenerationProvenance = scope == .notesAndSummary
            ? MLXSummaryConfiguration.generationProvenance(for: selection.descriptor)
            : nil
        self.transcriptFingerprint = transcriptFingerprint
        self.transcriptUnitCount = transcriptUnitCount
        let orderedPlan = plannedWindows.sorted { $0.windowIndex < $1.windowIndex }
        plannedWindowCount = orderedPlan.count
        self.plannedWindows = orderedPlan
    }
}

/// Which stages of one acceptance run have completed, rewritten as each
/// completes. A run that stops early leaves `status` "incomplete" and names
/// the stages that did finish, next to the per-call `call-records.json`.
struct MLXAcceptanceRunProgress: Codable, Equatable {
    var runID: String
    var status = "incomplete"
    var completedStages: [String] = []

    mutating func complete(_ stage: String, writingTo url: URL) throws {
        completedStages.append(stage)
        try AtomicFileWriter.writeJSON(self, to: url)
    }

    mutating func finish(writingTo url: URL) throws {
        status = "completed"
        try AtomicFileWriter.writeJSON(self, to: url)
    }
}

/// Test-only input for the synthesis replay (`LECTURE_RECORDER_RUN_MLX_SYNTHESIS_REPLAY`):
/// one earlier acceptance run's `run-identity.json` and its complete
/// `notes-window-analyses/`. Everything is validated before any synthesis
/// call, and nothing is ever repaired — any mismatch fails the replay.
enum MLXSynthesisReplaySource {
    static let sourceDirectoryEnvironmentKey = "LECTURE_RECORDER_REPLAY_SOURCE_RUN_DIRECTORY"

    enum ValidationError: LocalizedError, Equatable {
        case unreadable(String)
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Replay source artifact \(name) is missing, unsafe, or unreadable."
            case .mismatch(let detail): return "Replay source failed validation: \(detail)."
            }
        }
    }

    struct Loaded {
        var identity: MLXAcceptanceRunIdentity
        /// Rebuilt from the source identity, carrying the analyses' own
        /// generation ID and provenance.
        var generation: LectureNotesGenerationRecord
        /// In window order.
        var analyses: [LectureNotesWindowAnalysis]
    }

    static func analysisFileName(for windowIndex: Int) -> String {
        "window_\(String(format: "%04d", windowIndex)).json"
    }

    static func load(runDirectory: URL, expectedProvenance: LectureNotesGenerationProvenance) throws -> Loaded {
        func read<T: Decodable>(_ type: T.Type, _ relativePath: String) throws -> T {
            let url = runDirectory.appendingPathComponent(relativePath)
            guard CompletedSessionPathSafety.checkExistingRegularFile(url) == .safe else {
                throw ValidationError.unreadable(relativePath)
            }
            do {
                return try AtomicFileWriter.readJSON(T.self, from: url)
            } catch {
                throw ValidationError.unreadable(relativePath)
            }
        }
        func require(_ condition: Bool, _ detail: String) throws {
            guard condition else { throw ValidationError.mismatch(detail) }
        }

        let identity = try read(MLXAcceptanceRunIdentity.self, "run-identity.json")
        try require(identity.notesGenerationProvenance == expectedProvenance, "Notes provenance differs from the selected model and current recipe")
        let sessionID = try XCTUnwrapReplay(UUID(uuidString: identity.sessionID), "session ID")
        let plan = identity.plannedWindows.sorted { $0.windowIndex < $1.windowIndex }
        try require(!plan.isEmpty && plan.map(\.windowIndex) == Array(0..<plan.count) && plan.count == identity.plannedWindowCount, "planned windows")
        try require(identity.requestedWindowIndices == plan.map(\.windowIndex), "the source run did not analyze every planned window")

        let analysesDirectory = runDirectory.appendingPathComponent("notes-window-analyses", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: analysesDirectory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        try require(names == plan.map { analysisFileName(for: $0.windowIndex) }, "window analysis files do not exactly match the plan")

        var analyses: [LectureNotesWindowAnalysis] = []
        for window in plan {
            let index = window.windowIndex
            let analysis = try read(LectureNotesWindowAnalysis.self, "notes-window-analyses/\(analysisFileName(for: index))")
            try require(analysis.schemaVersion == LectureNotesWindowAnalysis.currentSchemaVersion, "window \(index) schema version")
            try require(analysis.windowIndex == index, "window \(index) is out of order")
            try require(analysis.sessionID == sessionID, "window \(index) session")
            try require(analysis.transcriptFingerprint == identity.transcriptFingerprint, "window \(index) transcript fingerprint")
            try require(
                analysis.ownedRange == NotesSourceReference(
                    sessionID: sessionID, firstSequenceNumber: window.firstSequenceNumber, lastSequenceNumber: window.lastSequenceNumber
                ),
                "window \(index) owned range"
            )
            try require(analysis.generationID == (analyses.first?.generationID ?? analysis.generationID), "window \(index) generation ID")
            for item in analysis.items {
                try require(!item.sourceReferences.isEmpty, "window \(index) item without source references")
                for reference in item.sourceReferences {
                    try require(
                        reference.sessionID == sessionID
                            && window.firstSequenceNumber <= reference.firstSequenceNumber
                            && reference.firstSequenceNumber <= reference.lastSequenceNumber
                            && reference.lastSequenceNumber <= window.lastSequenceNumber,
                        "window \(index) item source reference"
                    )
                }
            }
            analyses.append(analysis)
        }

        var generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: identity.transcriptFingerprint,
            windowPlan: NotesWindowPlan(windows: plan),
            provenance: identity.notesGenerationProvenance
        )
        generation.generationID = analyses[0].generationID
        return Loaded(identity: identity, generation: generation, analyses: analyses)
    }

    private static func XCTUnwrapReplay<T>(_ value: T?, _ detail: String) throws -> T {
        guard let value else { throw ValidationError.mismatch(detail) }
        return value
    }
}

/// Acceptance-only text checks. They report; they never change or reject
/// generated output.
enum MLXAcceptanceTextDiagnostics {
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One unexpected character found in generated English text: a
    /// Han/CJK character (`cjk`), a control character other than a line
    /// feed (`control`), or leftover LaTeX markup (`backslash`, `dollar`).
    struct ScriptAnomaly: Codable, Equatable {
        var kind: String = "cjk"
        var location: String
        var character: String
        var scalarHex: String
        var containingText: String
    }

    static func anomalyKind(_ scalar: Unicode.Scalar) -> String? {
        if isUnexpectedCJK(scalar) { return "cjk" }
        let value = scalar.value
        if (value < 0x20 && value != 0x0A) || (0x7F...0x9F).contains(value) { return "control" }
        if scalar == "\\" { return "backslash" }
        if scalar == "$" { return "dollar" }
        return nil
    }

    /// Han ideographs, CJK symbols/punctuation, kana, Hangul, and
    /// full-width forms — scripts an English study Note should not contain.
    static func isUnexpectedCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
             0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    static func scriptAnomalies(in text: String, location: String) -> [ScriptAnomaly] {
        text.unicodeScalars.compactMap { scalar in
            anomalyKind(scalar).map {
                ScriptAnomaly(
                    kind: $0, location: location, character: String(scalar),
                    scalarHex: String(format: "U+%04X", scalar.value), containingText: text
                )
            }
        }
    }

    static func scriptAnomalies(analyses: [LectureNotesWindowAnalysis]) -> [ScriptAnomaly] {
        analyses.flatMap { analysis in
            analysis.items.enumerated().flatMap { index, item in
                scriptAnomalies(in: item.body, location: "notesWindow:\(analysis.windowIndex)/item:\(index)")
            }
        }
    }

    static func scriptAnomalies(notes document: LectureNotesDocument) -> [ScriptAnomaly] {
        var found = scriptAnomalies(in: document.overview, location: "notesDocument/overview")
        for (sectionIndex, section) in document.sections.enumerated() {
            found += scriptAnomalies(in: section.heading, location: "notesDocument/section:\(sectionIndex)/title")
            for (topicIndex, topic) in section.topics.enumerated() {
                found += scriptAnomalies(in: topic, location: "notesDocument/section:\(sectionIndex)/topic:\(topicIndex)")
            }
        }
        return found
    }

    static func scriptAnomalies(summary document: LectureSummaryDocument) -> [ScriptAnomaly] {
        document.sections.enumerated().flatMap { sectionIndex, section in
            scriptAnomalies(in: section.heading, location: "summaryDocument/section:\(sectionIndex)/heading")
                + section.passages.enumerated().flatMap { passageIndex, passage in
                    scriptAnomalies(in: passage.text, location: "summaryDocument/section:\(sectionIndex)/passage:\(passageIndex)")
                }
        }
    }
}

/// Where one Summary batch's passages drew their support: positions are
/// 1-based within the batch (the model's own `supportIndices`
/// numbering), so a first-N positional cutoff shows up directly as the
/// uncited tail.
struct MLXSummaryBatchCoverage: Codable, Equatable {
    var batchIndex: Int
    var firstSourceItemIndex: Int
    var lastSourceItemIndex: Int
    var itemCount: Int
    var passageCount: Int
    var passageSupportPositions: [[Int]]
    var citedPositions: [Int]
    var uncitedPositions: [Int]
    var uncitedSourceIndices: [Int]

    static func compute(plan: LectureSummaryPlan, analyses: [LectureSummaryAnalysis]) -> [MLXSummaryBatchCoverage] {
        let byBatch = Dictionary(analyses.map { ($0.batchIndex, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.batches.sorted { $0.batchIndex < $1.batchIndex }.compactMap { batch in
            guard let analysis = byBatch[batch.batchIndex] else { return nil }
            let position = Dictionary(batch.sourceItemIDs.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { first, _ in first })
            let support = analysis.passages.map { $0.supportingNoteItemIDs.compactMap { position[$0] } }
            let cited = Set(support.flatMap { $0 })
            let uncited = batch.sourceItemIDs.indices.map { $0 + 1 }.filter { !cited.contains($0) }
            return MLXSummaryBatchCoverage(
                batchIndex: batch.batchIndex,
                firstSourceItemIndex: batch.firstSourceItemIndex,
                lastSourceItemIndex: batch.lastSourceItemIndex,
                itemCount: batch.sourceItemIDs.count,
                passageCount: analysis.passages.count,
                passageSupportPositions: support,
                citedPositions: cited.sorted(),
                uncitedPositions: uncited,
                uncitedSourceIndices: uncited.map { batch.firstSourceItemIndex + $0 - 1 }
            )
        }
    }
}

/// Test-only downstream replay (`LECTURE_RECORDER_RUN_MLX_SYNTHESIS_SUMMARY_REPLAY`):
/// persisted window analyses from an earlier run feed the CURRENT synthesis
/// and Summary without re-running window analysis. The source generation is
/// re-stamped with the current Notes recipe (same generation ID), which is
/// truthful only while the source recipe's window analysis is identical to
/// the current recipe's — `mlx1-notes-v10` → `mlx1-notes-v15` (v11–v15
/// changed synthesis only).
enum MLXDownstreamReplay {
    static let sourceRecipesWithCurrentWindowAnalysis: Set<String> = ["mlx1-notes-v10"]

    struct IncompatibleSourceRecipe: LocalizedError, Equatable {
        var recipe: String
        var errorDescription: String? { "Source recipe \(recipe) does not share the current recipe's window analysis." }
    }

    static func restampedForCurrentSynthesis(
        _ generation: LectureNotesGenerationRecord, descriptor: MLXModelDescriptor
    ) throws -> LectureNotesGenerationRecord {
        guard sourceRecipesWithCurrentWindowAnalysis.contains(generation.provenance.recipeVersion) else {
            throw IncompatibleSourceRecipe(recipe: generation.provenance.recipeVersion)
        }
        var restamped = generation
        restamped.provenance = MLXNotesConfiguration.generationProvenance(for: descriptor)
        return restamped
    }
}

/// Test-only 4+4 coverage experiment (`LECTURE_RECORDER_RUN_MLX_NOTES_SLICE_DIAGNOSTIC`):
/// each selected planned window stays the logical unit, but is analyzed as
/// two contiguous halves through the unchanged production
/// `analyzeWindow`, then merged into one diagnostic parent result. Nothing
/// here is used by production planning, generation, or persistence.
enum MLXNotesSliceDiagnostic {
    static let windowsEnvironmentKey = "LECTURE_RECORDER_ACCEPTANCE_SLICE_WINDOW_INDICES"

    struct Slice: Equatable {
        var label: String
        var window: NotesInputWindow
        var units: [NotesTranscriptSourceUnit]
    }

    enum SliceError: LocalizedError, Equatable {
        case malformedWindowIndices(String)
        case windowNotPlanned(Int)
        case unitsDoNotMatchWindow(Int)

        var errorDescription: String? {
            switch self {
            case .malformedWindowIndices(let value): return "\(MLXNotesSliceDiagnostic.windowsEnvironmentKey) '\(value)' is not a comma-separated list of distinct nonnegative integers."
            case .windowNotPlanned(let index): return "Window \(index) is not in the production Notes plan."
            case .unitsDoNotMatchWindow(let index): return "Window \(index)'s transcript units do not exactly match its planned range."
            }
        }
    }

    static func windowIndices(from value: String?) throws -> [Int] {
        guard let value, !value.isEmpty else { throw SliceError.malformedWindowIndices(value ?? "") }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let indices = parts.compactMap { Int($0) }
        guard indices.count == parts.count, indices.allSatisfy({ $0 >= 0 }), Set(indices).count == indices.count else {
            throw SliceError.malformedWindowIndices(value)
        }
        return indices
    }

    /// Splits `window`'s units (sorted by sequence) into contiguous slice A
    /// (the first ceil(n/2) units) and slice B (the rest); a one-unit window
    /// is a single slice. Each slice keeps the parent's `windowIndex` and
    /// the original sequence numbers.
    static func slices(of window: NotesInputWindow, units: [NotesTranscriptSourceUnit]) throws -> [Slice] {
        let ordered = units.sorted { $0.sequenceNumber < $1.sequenceNumber }
        guard ordered.map(\.sequenceNumber) == Array(window.firstSequenceNumber...window.lastSequenceNumber) else {
            throw SliceError.unitsDoNotMatchWindow(window.windowIndex)
        }
        let split = (ordered.count + 1) / 2
        let halves = [Array(ordered[..<split]), Array(ordered[split...])].filter { !$0.isEmpty }
        return halves.enumerated().map { offset, part in
            Slice(
                label: "\(window.windowIndex)\(offset == 0 ? "A" : "B")",
                window: NotesInputWindow(
                    windowIndex: window.windowIndex,
                    firstSequenceNumber: part[0].sequenceNumber,
                    lastSequenceNumber: part[part.count - 1].sequenceNumber,
                    unitCount: part.count,
                    isOversizedSingleUnit: false
                ),
                units: part
            )
        }
    }

    /// One diagnostic parent result: every slice item, stable-sorted by its
    /// earliest referenced sequence number (ties keep slice, then item,
    /// order). No semantic deduplication; references are kept as mapped.
    static func merge(parent window: NotesInputWindow, sliceAnalyses: [LectureNotesWindowAnalysis]) -> LectureNotesWindowAnalysis {
        let items = sliceAnalyses.flatMap(\.items).enumerated().sorted { lhs, rhs in
            let l = lhs.element.sourceReferences.map(\.firstSequenceNumber).min() ?? Int.max
            let r = rhs.element.sourceReferences.map(\.firstSequenceNumber).min() ?? Int.max
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
        let first = sliceAnalyses[0]
        return LectureNotesWindowAnalysis(
            generationID: first.generationID,
            sessionID: first.sessionID,
            transcriptFingerprint: first.transcriptFingerprint,
            windowIndex: window.windowIndex,
            ownedRange: NotesSourceReference(
                sessionID: first.sessionID,
                firstSequenceNumber: window.firstSequenceNumber,
                lastSequenceNumber: window.lastSequenceNumber
            ),
            items: items
        )
    }
}

/// Test-only input for the Summary replay (`LECTURE_RECORDER_RUN_MLX_SUMMARY_REPLAY`):
/// one earlier complete acceptance run's window analyses (validated exactly
/// as the synthesis replay does, against the source run's own Notes recipe)
/// plus its persisted `notes-document.json`, which must belong to that same
/// generation. Nothing is regenerated or repaired.
enum MLXSummaryReplaySource {
    static let sourceNotesRecipeEnvironmentKey = "LECTURE_RECORDER_REPLAY_SOURCE_NOTES_RECIPE"

    struct Loaded {
        var notes: MLXSynthesisReplaySource.Loaded
        var document: LectureNotesDocument
    }

    static func load(runDirectory: URL, expectedNotesProvenance: LectureNotesGenerationProvenance) throws -> Loaded {
        let notes = try MLXSynthesisReplaySource.load(runDirectory: runDirectory, expectedProvenance: expectedNotesProvenance)
        let url = runDirectory.appendingPathComponent("notes-document.json")
        guard CompletedSessionPathSafety.checkExistingRegularFile(url) == .safe,
              let document = try? AtomicFileWriter.readJSON(LectureNotesDocument.self, from: url)
        else {
            throw MLXSynthesisReplaySource.ValidationError.unreadable("notes-document.json")
        }
        guard document.generationID == notes.generation.generationID,
              document.sessionID == notes.generation.sessionID,
              document.transcriptFingerprint == notes.generation.transcriptFingerprint,
              document.provenance == notes.generation.provenance
        else {
            throw MLXSynthesisReplaySource.ValidationError.mismatch("Notes document does not belong to the source generation")
        }
        return Loaded(notes: notes, document: document)
    }
}

final class MLXRealLectureAcceptanceTests: XCTestCase {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE"] == "1"
    }

    private enum HarnessConfigurationError: LocalizedError {
        case missingSessionID
        case malformedSessionID(String)
        case missingOutputDirectory
        case outputDirectoryUnavailable(String, String)
        case runDirectoryCollision(String)

        var errorDescription: String? {
            switch self {
            case .missingSessionID:
                return "LECTURE_RECORDER_ACCEPTANCE_SESSION_ID is required when LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE=1."
            case .malformedSessionID(let value):
                return "LECTURE_RECORDER_ACCEPTANCE_SESSION_ID '\(value)' is not a valid UUID."
            case .missingOutputDirectory:
                return "LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY is required when LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE=1."
            case .outputDirectoryUnavailable(let path, let reason):
                return "LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY '\(path)' is unusable: \(reason)"
            case .runDirectoryCollision(let path):
                return "Acceptance run directory already exists (unexpected UUID collision): \(path)"
            }
        }
    }

    /// One real MLX call's structural/timing diagnostics — never
    /// `instructions`/`prompt`/`jsonSchema`, and `jsonText` only for
    /// section-summary calls (`sectionSummaryResponseJSON`, lecture-derived
    /// text in this opt-in harness's local output). `kind` distinguishes
    /// a token-count preflight call from a real guided-generation call;
    /// only the latter has generation/memory fields.
    struct CallRecord: Codable, Equatable {
        var callIndex: Int
        var kind: String
        /// The harness stage that issued the call (for example
        /// `notesWindow:6`, `notesSynthesis`, `summaryBatch:0`).
        var stage: String
        /// Which production instruction set issued the call
        /// (`windowAnalysis`, `sectionSummaries`, `windowTopics`, …,
        /// `summaryBatch`, `summaryReduction`, `summaryFinalSection`), and the
        /// sampling it was sent with (nil =
        /// greedy). Absent in records written before these fields existed.
        var instructionStage: String? = nil
        var sampling: MLXGuidedSampling? = nil
        /// The raw response JSON — recorded only for section-summary calls,
        /// so a rejected sentence (for example one cut at a length limit)
        /// stays inspectable.
        var sectionSummaryResponseJSON: String? = nil
        /// The raw response JSON of section-title calls, so a rejected or
        /// cut title stays inspectable.
        var sectionTitleResponseJSON: String? = nil
        var wallClockSeconds: Double
        var promptTokenCount: Int?
        var generatedTokenCount: Int?
        var generationSeconds: Double?
        var activeMemoryBytes: Int?
        var peakMemoryBytes: Int?
    }

    private struct NotesSourceReferenceFailureDiagnostic: Encodable {
        var windowIndex: Int
        var firstSequenceNumber: Int
        var lastSequenceNumber: Int
        var allowedSequenceNumbers: [Int]
    }

    /// Wraps exactly one real `MLXSessionDriving` conformer, recording
    /// per-call structural/timing diagnostics (see `CallRecord`) without
    /// ever touching call content. An `actor` so its own bookkeeping is
    /// safely isolated; this harness only ever awaits one call at a time.
    /// Shared, unmodified, by both the Notes and Summary generators below —
    /// satisfying "exactly one `RealMLXSessionDriver`" while adding
    /// zero-content-exposure diagnostics.
    ///
    /// When `recordsURL` is set, every record is also written there as soon
    /// as its call returns, so the evidence survives a later stage failing
    /// before the run's final result is written.
    actor TimingSessionDriver: MLXSessionDriving {
        private let wrapped: any MLXSessionDriving
        private let recordsURL: URL?
        private(set) var records: [CallRecord] = []
        private(set) var persistenceWarnings: [String] = []
        private var stage = "unspecified"

        nonisolated var nativeContextLength: Int { wrapped.nativeContextLength }
        nonisolated var operationalContextCeiling: Int { wrapped.operationalContextCeiling }
        nonisolated func availability() async -> LectureNotesGenerationAvailability { await wrapped.availability() }

        init(wrapped: any MLXSessionDriving, recordsURL: URL? = nil) {
            self.wrapped = wrapped
            self.recordsURL = recordsURL
        }

        func setStage(_ stage: String) {
            self.stage = stage
        }

        private func append(_ record: CallRecord) {
            records.append(record)
            guard let recordsURL else { return }
            do {
                try AtomicFileWriter.writeJSON(records, to: recordsURL)
            } catch {
                persistenceWarnings.append("Unable to write \(recordsURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        func preparedInputTokenCount(instructions: String, prompt: String) async throws -> Int {
            let start = AcceptanceDiagnosticLogger.startInstant()
            let count = try await wrapped.preparedInputTokenCount(instructions: instructions, prompt: prompt)
            append(CallRecord(
                callIndex: records.count,
                kind: "tokenCount",
                stage: stage,
                instructionStage: SynthesisStageRecordingDriver.stage(for: instructions),
                wallClockSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start),
                promptTokenCount: count,
                generatedTokenCount: nil,
                generationSeconds: nil,
                activeMemoryBytes: nil,
                peakMemoryBytes: nil
            ))
            return count
        }

        func respond(
            instructions: String, prompt: String, jsonSchema: String, maxOutputTokens: Int,
            sampling: MLXGuidedSampling?
        ) async throws -> MLXGuidedGenerationOutcome {
            let start = AcceptanceDiagnosticLogger.startInstant()
            let outcome = try await wrapped.respond(
                instructions: instructions, prompt: prompt, jsonSchema: jsonSchema, maxOutputTokens: maxOutputTokens,
                sampling: sampling
            )
            append(CallRecord(
                callIndex: records.count,
                kind: "respond",
                stage: stage,
                instructionStage: SynthesisStageRecordingDriver.stage(for: instructions),
                sampling: sampling,
                sectionSummaryResponseJSON: SynthesisStageRecordingDriver.stage(for: instructions) == "sectionSummaries" ? outcome.jsonText : nil,
                sectionTitleResponseJSON: SynthesisStageRecordingDriver.stage(for: instructions) == "sectionTitles" ? outcome.jsonText : nil,
                wallClockSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start),
                promptTokenCount: outcome.promptTokenCount,
                generatedTokenCount: outcome.generatedTokenCount,
                generationSeconds: outcome.generationSeconds,
                activeMemoryBytes: outcome.memory?.activeMemoryBytes,
                peakMemoryBytes: outcome.memory?.peakMemoryBytes
            ))
            return outcome
        }
    }

    /// Synthesis-replay driver: records, per real MLX call, which synthesis
    /// stage issued it (identified only by which production instruction set
    /// it used), token counts, timing, and whether it failed. Never records
    /// prompts, schemas, or generated text.
    private actor SynthesisStageRecordingDriver: MLXSessionDriving {
        struct Call: Encodable {
            var callIndex: Int
            var kind: String
            var stage: String
            var wallClockSeconds: Double
            var maxOutputTokens: Int?
            var promptTokenCount: Int?
            var generatedTokenCount: Int?
            var generationSeconds: Double?
            var peakMemoryBytes: Int?
            var failure: String?
            /// Section-summary calls only: how many summaries the model
            /// returned (a count only — never the summaries).
            var summaryCount: Int?
        }

        private let wrapped: any MLXSessionDriving
        private(set) var calls: [Call] = []

        /// Per-window topic progress from the recorded calls alone: each
        /// window's topic request is preflighted exactly once (retries reuse
        /// it), so the `windowTopics` token counts are the windows reached.
        /// On a window-topic failure the last window reached is the failing
        /// one.
        /// The windows whose topic request was sent more than once (the
        /// single retry after an invalid label) — indices only.
        static func retriedWindowTopicIndices(calls: [Call]) -> [Int] {
            var window = -1
            var attempts: [Int: Int] = [:]
            for call in calls where call.stage == "windowTopics" {
                if call.kind == "tokenCount" { window += 1 } else { attempts[window, default: 0] += 1 }
            }
            return attempts.filter { $0.value > 1 }.map(\.key).sorted()
        }

        static func windowTopicProgress(calls: [Call], failed: Bool) -> (completed: Int, failingWindowIndex: Int?) {
            let reached = calls.filter { $0.kind == "tokenCount" && $0.stage == "windowTopics" }.count
            guard failed, calls.last?.stage == "windowTopics", reached > 0 else { return (reached, nil) }
            return (reached - 1, reached - 1)
        }

        /// Just the number of summaries in a section-summary response.
        static func summaryCount(fromSectionSummariesJSON text: String) -> Int? {
            elementCount(of: "sectionSummaries", inJSON: text)
        }

        private static func elementCount(of key: String, inJSON text: String) -> Int? {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let elements = object[key] as? [Any] else { return nil }
            return elements.count
        }

        /// Where synthesis failed, from the recorded calls alone — structural
        /// only. The generator partitions sections before any model call, so
        /// a failure with no call is a section-assembly failure; a failed
        /// call is a preflight or model-call failure at that call's stage;
        /// and a failure after a successful response, or after a
        /// successful token count, is an output-validation or context-budget
        /// failure at that stage.
        static func failureDiagnosis(calls: [Call]) -> (stage: String, phase: String) {
            guard let last = calls.last else { return ("sectionPartition", "sectionAssembly") }
            switch (last.kind, last.failure != nil) {
            case ("tokenCount", true): return (last.stage, "preflightUnavailable")
            case ("tokenCount", false): return (last.stage, "contextBudget")
            case (_, true): return (last.stage, "modelCall")
            default: return (last.stage, "outputValidation")
            }
        }

        /// Each section's inclusive `[first, last]` range over the windows
        /// with notes (the windows the partition divides), recovered from
        /// the sections' item counts; `nil` when a section boundary does not
        /// fall on a window boundary.
        static func sectionWindowRanges(sectionItemCounts: [Int], windowItemCounts: [Int]) -> [[Int]]? {
            let partitionedCounts = windowItemCounts.filter { $0 > 0 }
            var ranges: [[Int]] = []
            var window = 0
            for sectionCount in sectionItemCounts {
                let first = window
                var remaining = sectionCount
                while remaining > 0, window < partitionedCounts.count {
                    remaining -= partitionedCounts[window]
                    window += 1
                }
                guard remaining == 0, window > first else { return nil }
                ranges.append([first, window - 1])
            }
            return window == partitionedCounts.count ? ranges : nil
        }

        nonisolated var nativeContextLength: Int { wrapped.nativeContextLength }
        nonisolated var operationalContextCeiling: Int { wrapped.operationalContextCeiling }
        nonisolated func availability() async -> LectureNotesGenerationAvailability { await wrapped.availability() }

        init(wrapped: any MLXSessionDriving) {
            self.wrapped = wrapped
        }

        static func stage(for instructions: String) -> String {
            switch instructions {
            case MLXLectureNotesGenerator.windowTopicInstructions: return "windowTopics"
            case MLXLectureNotesGenerator.sectionTitleInstructions: return "sectionTitles"
            case MLXLectureNotesGenerator.sectionSummaryInstructions: return "sectionSummaries"
            case MLXLectureNotesGenerator.reductionInstructions: return "reduction"
            case MLXLectureNotesGenerator.analysisInstructions: return "windowAnalysis"
            case MLXLectureSummaryGenerator.batchInstructions: return "summaryBatch"
            case MLXLectureSummaryGenerator.reductionInstructions: return "summaryReduction"
            case MLXLectureSummaryGenerator.finalSectionInstructions: return "summaryFinalSection"
            default: return "unknown"
            }
        }

        func preparedInputTokenCount(instructions: String, prompt: String) async throws -> Int {
            let start = AcceptanceDiagnosticLogger.startInstant()
            let count: Int
            do {
                count = try await wrapped.preparedInputTokenCount(instructions: instructions, prompt: prompt)
            } catch {
                calls.append(Call(
                    callIndex: calls.count, kind: "tokenCount", stage: Self.stage(for: instructions),
                    wallClockSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start),
                    maxOutputTokens: nil, promptTokenCount: nil, generatedTokenCount: nil,
                    generationSeconds: nil, peakMemoryBytes: nil,
                    failure: String(describing: type(of: error)) + "." + Self.caseName(error), summaryCount: nil
                ))
                throw error
            }
            calls.append(Call(
                callIndex: calls.count, kind: "tokenCount", stage: Self.stage(for: instructions),
                wallClockSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start),
                maxOutputTokens: nil, promptTokenCount: count, generatedTokenCount: nil,
                generationSeconds: nil, peakMemoryBytes: nil, failure: nil, summaryCount: nil
            ))
            return count
        }

        func respond(
            instructions: String, prompt: String, jsonSchema: String, maxOutputTokens: Int,
            sampling: MLXGuidedSampling?
        ) async throws -> MLXGuidedGenerationOutcome {
            let start = AcceptanceDiagnosticLogger.startInstant()
            do {
                let outcome = try await wrapped.respond(
                    instructions: instructions, prompt: prompt, jsonSchema: jsonSchema, maxOutputTokens: maxOutputTokens,
                    sampling: sampling
                )
                calls.append(Call(
                    callIndex: calls.count, kind: "respond", stage: Self.stage(for: instructions),
                    wallClockSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start),
                    maxOutputTokens: maxOutputTokens, promptTokenCount: outcome.promptTokenCount,
                    generatedTokenCount: outcome.generatedTokenCount, generationSeconds: outcome.generationSeconds,
                    peakMemoryBytes: outcome.memory?.peakMemoryBytes, failure: nil,
                    summaryCount: Self.stage(for: instructions) == "sectionSummaries"
                        ? Self.summaryCount(fromSectionSummariesJSON: outcome.jsonText) : nil
                ))
                return outcome
            } catch {
                calls.append(Call(
                    callIndex: calls.count, kind: "respond", stage: Self.stage(for: instructions),
                    wallClockSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start),
                    maxOutputTokens: maxOutputTokens, promptTokenCount: nil, generatedTokenCount: nil,
                    generationSeconds: nil, peakMemoryBytes: nil,
                    failure: String(describing: type(of: error)) + "." + Self.caseName(error),
                    summaryCount: nil
                ))
                throw error
            }
        }

        /// The error's case name only (for example `incompleteOutput`), never
        /// its associated detail.
        private static func caseName(_ error: Error) -> String {
            String(String(describing: error).prefix { $0 != "(" })
        }
    }

    private struct SynthesisReplayResult: Encodable {
        var runID: String
        var sourceRunDirectory: String
        var sessionID: String
        var mlxModelSelection: String
        var modelIdentifier: String
        var modelRevision: String
        var notesGenerationProvenance: LectureNotesGenerationProvenance
        var windowCount: Int
        var inputItemCount: Int
        var synthesisSeconds: Double
        var outcome: String
        var failure: String?
        var failingStage: String?
        /// `sectionAssembly`, `preflightUnavailable`, `contextBudget`,
        /// `modelCall`, or `outputValidation` (see `failureDiagnosis`).
        var failurePhase: String?
        /// One topic call per window with notes; how many produced a valid
        /// label; and, if a window's topic failed, that window's index.
        var expectedWindowTopicCalls: Int
        var completedWindowTopicCalls: Int
        var failingWindowTopicIndex: Int?
        var retriedWindowTopicIndices: [Int]
        var sectionCount: Int?
        var sectionItemCounts: [Int]?
        /// Each section's derived inclusive `[first, last]` window range.
        var derivedSectionWindowRanges: [[Int]]?
        /// Each section's derived inclusive `[start, end]` input-item range.
        var derivedSectionRanges: [[Int]]?
        var sectionHeadingLengths: [Int]?
        var overviewCharacterCount: Int?
        var documentItemCount: Int?
        var documentPreservesInputItemsInOrder: Bool?
        var calls: [SynthesisStageRecordingDriver.Call]
    }

    private struct TimedWindow: Encodable {
        var windowIndex: Int
        var seconds: Double
    }

    private struct TimedBatch: Encodable {
        var batchIndex: Int
        var seconds: Double
    }

    /// Structural result for the opt-in single-window path. The successful
    /// analysis itself retains the ordinary `notes-window-analyses` artifact
    /// shape; this companion contains only counts, timing, tokens, and memory.
    private struct WindowOnlyRunResult: Encodable {
        var runID: String
        var startedAt: Date
        var finishedAt: Date
        var sessionID: String
        var mlxModelSelection: String
        var modelIdentifier: String
        var modelRevision: String
        var nativeContextLength: Int
        var operationalContextCeiling: Int
        var transcriptUnitCount: Int
        var notesPlannedWindowCount: Int
        var analyzedWindowIndex: Int
        var analysisSeconds: Double
        var analysisItemCount: Int
        var notesCallRecords: [CallRecord]
        var totalEndToEndSeconds: Double
        var persistenceWarnings: [String]
    }

    /// Structural result for the opt-in `notes-full` path: every planned
    /// window analyzed, stopping before Notes synthesis and Summary. Each
    /// analysis keeps the ordinary `notes-window-analyses` artifact shape.
    private struct NotesFullRunResult: Encodable {
        var runID: String
        var startedAt: Date
        var finishedAt: Date
        var sessionID: String
        var acceptanceScope: String
        var mlxModelSelection: String
        var modelIdentifier: String
        var modelRevision: String
        var nativeContextLength: Int
        var operationalContextCeiling: Int
        var transcriptUnitCount: Int
        var notesPlannedWindowCount: Int
        var analyzedWindowCount: Int
        var notesPerWindowSeconds: [TimedWindow]
        var notesAnalysisTotalSeconds: Double
        /// Retained item count per analyzed window, in window order.
        var analysisItemCounts: [Int]
        var totalAnalysisItemCount: Int
        var notesCallRecords: [CallRecord]
        var totalEndToEndSeconds: Double
        var persistenceWarnings: [String]
    }

    /// Structural result for the opt-in `notes-range` path: exactly the
    /// requested inclusive window range, stopping before Notes synthesis and
    /// Summary. Identity comes only from this run's `MLXAcceptanceRunIdentity`
    /// and analyzed indices only from this run's own analyses — never from
    /// any other run.
    private struct NotesRangeRunResult: Encodable {
        var runID: String
        var startedAt: Date
        var finishedAt: Date
        var sessionID: String
        var acceptanceScope: String
        var mlxModelSelection: String
        var modelIdentifier: String
        var modelRevision: String
        var nativeContextLength: Int
        var operationalContextCeiling: Int
        var notesGenerationProvenance: LectureNotesGenerationProvenance
        var transcriptFingerprint: TranscriptSourceFingerprint
        var transcriptUnitCount: Int
        var plannedWindowCount: Int
        var requestedFirstWindowIndex: Int?
        var requestedLastWindowIndex: Int?
        var firstAnalyzedWindowIndex: Int?
        var lastAnalyzedWindowIndex: Int?
        var analyzedWindowIndices: [Int]
        var notesPerWindowSeconds: [TimedWindow]
        var notesAnalysisTotalSeconds: Double
        /// Retained item count per analyzed window, in window order.
        var analysisItemCounts: [Int]
        var totalAnalysisItemCount: Int
        var notesCallRecords: [CallRecord]
        var totalEndToEndSeconds: Double
        var persistenceWarnings: [String]

        init(
            identity: MLXAcceptanceRunIdentity,
            startedAt: Date,
            finishedAt: Date,
            analyses: [LectureNotesWindowAnalysis],
            notesPerWindowSeconds: [TimedWindow],
            notesCallRecords: [CallRecord],
            totalEndToEndSeconds: Double,
            persistenceWarnings: [String]
        ) {
            runID = identity.runID
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            sessionID = identity.sessionID
            acceptanceScope = identity.acceptanceScope
            mlxModelSelection = identity.mlxModelSelection
            modelIdentifier = identity.modelIdentifier
            modelRevision = identity.modelRevision
            nativeContextLength = identity.nativeContextLength
            operationalContextCeiling = identity.operationalContextCeiling
            notesGenerationProvenance = identity.notesGenerationProvenance
            transcriptFingerprint = identity.transcriptFingerprint
            transcriptUnitCount = identity.transcriptUnitCount
            plannedWindowCount = identity.plannedWindowCount
            requestedFirstWindowIndex = identity.requestedFirstWindowIndex
            requestedLastWindowIndex = identity.requestedLastWindowIndex
            analyzedWindowIndices = analyses.map(\.windowIndex)
            firstAnalyzedWindowIndex = analyzedWindowIndices.first
            lastAnalyzedWindowIndex = analyzedWindowIndices.last
            self.notesPerWindowSeconds = notesPerWindowSeconds
            notesAnalysisTotalSeconds = notesPerWindowSeconds.reduce(0) { $0 + $1.seconds }
            analysisItemCounts = analyses.map(\.items.count)
            totalAnalysisItemCount = analysisItemCounts.reduce(0, +)
            self.notesCallRecords = notesCallRecords
            self.totalEndToEndSeconds = totalEndToEndSeconds
            self.persistenceWarnings = persistenceWarnings
        }
    }

    /// Non-sensitive run result: identifiers, counts, and timings only —
    /// never transcript, prompt, Notes, or Summary text.
    private struct RunResult: Encodable {
        var runID: String
        var startedAt: Date
        var finishedAt: Date
        var sessionID: String
        var transcriptFingerprintDigestHex: String
        var transcriptUnitCount: Int
        var mlxModelSelection: String
        var modelIdentifier: String
        var modelRevision: String
        var backendIdentifier: String
        var nativeContextLength: Int
        var operationalContextCeiling: Int

        var notesPlannedWindowCount: Int
        var notesPerWindowSeconds: [TimedWindow]
        var notesSynthesisSeconds: Double
        var notesTotalSeconds: Double
        var notesSectionCount: Int
        var notesItemCount: Int
        var notesRealCallRecords: [CallRecord]

        var summaryPlannedBatchCount: Int
        var summaryPlanningSeconds: Double
        var summaryPerBatchSeconds: [TimedBatch]
        var summarySynthesisSeconds: Double
        var summaryTotalSeconds: Double
        var summarySectionCount: Int
        var summaryPassageCount: Int
        var summaryRealCallRecords: [CallRecord]
        var summaryIntegrityValidation: String

        var totalEndToEndSeconds: Double
        var persistenceWarnings: [String]
        var retryMeasurementNote: String
        var memoryMeasurementNote: String
    }

    // MARK: - Acceptance scope routing

    func testAcceptanceScopeAbsentKeepsOriginalRouting() throws {
        XCTAssertEqual(try MLXAcceptanceScope.resolve(scopeValue: nil, notesWindowIndexValue: nil), .notesAndSummary)
        XCTAssertEqual(try MLXAcceptanceScope.resolve(scopeValue: nil, notesWindowIndexValue: "2"), .notesWindow(index: 2))
    }

    func testAcceptanceScopeExplicitValuesRoute() throws {
        let window = try MLXAcceptanceScope.resolve(scopeValue: "notes-window", notesWindowIndexValue: "2")
        XCTAssertEqual(window, .notesWindow(index: 2))
        XCTAssertEqual(window.notesWindowIndex, 2)
        XCTAssertTrue(window.stopsBeforeNotesSynthesis)

        let full = try MLXAcceptanceScope.resolve(scopeValue: "notes-full", notesWindowIndexValue: nil)
        XCTAssertEqual(full, .notesFull)
        XCTAssertNil(full.notesWindowIndex, "notes-full analyzes every planned window")
        XCTAssertTrue(full.stopsBeforeNotesSynthesis, "notes-full must stop before Notes synthesis and Summary")

        let everything = try MLXAcceptanceScope.resolve(scopeValue: "notes-and-summary", notesWindowIndexValue: nil)
        XCTAssertEqual(everything, .notesAndSummary)
        XCTAssertNil(everything.notesWindowIndex)
        XCTAssertFalse(everything.stopsBeforeNotesSynthesis)

        let range = try MLXAcceptanceScope.resolve(
            scopeValue: "notes-range", notesWindowIndexValue: nil,
            notesFirstWindowIndexValue: "8", notesLastWindowIndexValue: "20"
        )
        XCTAssertEqual([window, full, everything, range].map(\.name), MLXAcceptanceScope.scopeNames)
    }

    func testAcceptanceScopeRejectsUnknownValues() {
        for value in ["", "notes", "NOTES-FULL", "notes_full", " notes-full", "summary", "notes-and-summary "] {
            XCTAssertThrowsError(try MLXAcceptanceScope.resolve(scopeValue: value, notesWindowIndexValue: nil)) { error in
                XCTAssertEqual(error as? MLXAcceptanceScope.ResolutionError, .unknownScope(value))
                XCTAssertTrue(error.localizedDescription.contains("LECTURE_RECORDER_ACCEPTANCE_SCOPE"))
            }
        }
    }

    func testAcceptanceScopeRejectsConflictingOrMalformedWindowIndex() {
        XCTAssertThrowsError(try MLXAcceptanceScope.resolve(scopeValue: "notes-window", notesWindowIndexValue: nil)) {
            XCTAssertEqual($0 as? MLXAcceptanceScope.ResolutionError, .scopeRequiresNotesWindowIndex)
        }
        for scope in ["notes-full", "notes-and-summary"] {
            XCTAssertThrowsError(try MLXAcceptanceScope.resolve(scopeValue: scope, notesWindowIndexValue: "2")) {
                XCTAssertEqual($0 as? MLXAcceptanceScope.ResolutionError, .scopeForbidsNotesWindowIndex(scope))
            }
        }
        for scope in [nil, "notes-window", "notes-full"] as [String?] {
            for index in ["-1", "two", ""] {
                XCTAssertThrowsError(try MLXAcceptanceScope.resolve(scopeValue: scope, notesWindowIndexValue: index)) {
                    XCTAssertEqual($0 as? MLXAcceptanceScope.ResolutionError, .malformedNotesWindowIndex(index))
                }
            }
        }
    }

    // MARK: - notes-range

    /// The representative lecture's shape: 21 contiguous planned windows.
    private func plannedWindows(count: Int = 21) -> [NotesInputWindow] {
        (0..<count).map { index in
            NotesInputWindow(
                windowIndex: index, firstSequenceNumber: index * 8, lastSequenceNumber: index * 8 + 7,
                unitCount: 8, isOversizedSingleUnit: false
            )
        }
    }

    private func resolveRange(_ first: String?, _ last: String?, windowIndex: String? = nil) throws -> MLXAcceptanceScope {
        try MLXAcceptanceScope.resolve(
            scopeValue: "notes-range", notesWindowIndexValue: windowIndex,
            notesFirstWindowIndexValue: first, notesLastWindowIndexValue: last
        )
    }

    func testNotesRangeRequiresFirstAndLast() {
        for (first, last) in [(nil, nil), ("8", nil), (nil, "20")] as [(String?, String?)] {
            XCTAssertThrowsError(try resolveRange(first, last)) {
                XCTAssertEqual($0 as? MLXAcceptanceScope.ResolutionError, .notesRangeRequiresBothIndices)
            }
        }
    }

    func testNotesRange8Through20SelectsExactlyThoseWindows() throws {
        let scope = try resolveRange("8", "20")
        XCTAssertEqual(scope, .notesRange(first: 8, last: 20))
        XCTAssertEqual(scope.name, "notes-range")
        XCTAssertNil(scope.notesWindowIndex)
        let windows = try scope.windowsToAnalyze(plannedWindows: plannedWindows().shuffled())
        XCTAssertEqual(windows.map(\.windowIndex), Array(8...20))
        XCTAssertEqual(windows.first?.windowIndex, 8, "the first generated window is 8")
    }

    func testNotesRange0Through6SelectsExactlyThoseWindows() throws {
        let windows = try resolveRange("0", "6").windowsToAnalyze(plannedWindows: plannedWindows())
        XCTAssertEqual(windows.map(\.windowIndex), Array(0...6))
        XCTAssertEqual(try resolveRange("7", "7").windowsToAnalyze(plannedWindows: plannedWindows()).map(\.windowIndex), [7])
    }

    func testNotesRangeFirstAfterLastFailsClosed() {
        XCTAssertThrowsError(try resolveRange("9", "8")) {
            XCTAssertEqual($0 as? MLXAcceptanceScope.ResolutionError, .notesRangeFirstAfterLast(first: 9, last: 8))
        }
    }

    func testNotesRangeOutsidePlanFailsClosed() throws {
        for (first, last) in [(21, 21), (8, 21), (0, 99), (25, 30)] {
            let scope = try resolveRange(String(first), String(last))
            XCTAssertThrowsError(try scope.windowsToAnalyze(plannedWindows: plannedWindows())) {
                XCTAssertEqual(
                    $0 as? MLXAcceptanceScope.ResolutionError,
                    .notesRangeOutOfRange(first: first, last: last, plannedWindowCount: 21)
                )
            }
        }
        // A plan with a missing index inside the range also fails closed.
        let gappedPlan = plannedWindows().filter { $0.windowIndex != 12 }
        XCTAssertThrowsError(try resolveRange("8", "20").windowsToAnalyze(plannedWindows: gappedPlan))
    }

    func testNotesRangeMalformedIndicesFailClosed() {
        for value in ["", " 8", "8 ", "-1", "eight", "8.0", "+"] {
            XCTAssertThrowsError(try resolveRange(value, "20")) {
                XCTAssertEqual(
                    $0 as? MLXAcceptanceScope.ResolutionError,
                    .malformedNotesRangeIndex(key: MLXAcceptanceScope.firstWindowIndexEnvironmentKey, value: value)
                )
            }
            XCTAssertThrowsError(try resolveRange("8", value)) {
                XCTAssertEqual(
                    $0 as? MLXAcceptanceScope.ResolutionError,
                    .malformedNotesRangeIndex(key: MLXAcceptanceScope.lastWindowIndexEnvironmentKey, value: value)
                )
            }
        }
    }

    func testNotesRangeConflictsWithSingleWindowIndex() {
        XCTAssertThrowsError(try resolveRange("8", "20", windowIndex: "2")) {
            XCTAssertEqual($0 as? MLXAcceptanceScope.ResolutionError, .scopeForbidsNotesWindowIndex("notes-range"))
        }
    }

    func testRangeIndicesConflictWithEveryOtherScope() {
        for scope in [nil, "notes-window", "notes-full", "notes-and-summary"] as [String?] {
            for (first, last) in [("8", "20"), ("8", nil), (nil, "20")] as [(String?, String?)] {
                XCTAssertThrowsError(try MLXAcceptanceScope.resolve(
                    scopeValue: scope, notesWindowIndexValue: scope == "notes-window" ? "2" : nil,
                    notesFirstWindowIndexValue: first, notesLastWindowIndexValue: last
                )) {
                    XCTAssertEqual(
                        $0 as? MLXAcceptanceScope.ResolutionError,
                        .notesRangeIndicesRequireNotesRangeScope(scope ?? "<unset>")
                    )
                }
            }
        }
        for value in ["notes-range ", "NOTES-RANGE", "notes_range", ""] {
            XCTAssertThrowsError(try MLXAcceptanceScope.resolve(
                scopeValue: value, notesWindowIndexValue: nil,
                notesFirstWindowIndexValue: "8", notesLastWindowIndexValue: "20"
            )) {
                XCTAssertEqual($0 as? MLXAcceptanceScope.ResolutionError, .unknownScope(value))
            }
        }
    }

    func testAbsentRangeSettingsPreserveExistingRoutingAndWindowSelection() throws {
        let plan = plannedWindows()
        let cases: [(String?, String?, MLXAcceptanceScope, [Int])] = [
            (nil, nil, .notesAndSummary, Array(0...20)),
            (nil, "2", .notesWindow(index: 2), [2]),
            ("notes-window", "7", .notesWindow(index: 7), [7]),
            ("notes-full", nil, .notesFull, Array(0...20)),
            ("notes-and-summary", nil, .notesAndSummary, Array(0...20)),
        ]
        for (scopeValue, windowIndex, expected, indices) in cases {
            let scope = try MLXAcceptanceScope.resolve(scopeValue: scopeValue, notesWindowIndexValue: windowIndex)
            XCTAssertEqual(scope, expected)
            XCTAssertEqual(try scope.windowsToAnalyze(plannedWindows: plan).map(\.windowIndex), indices)
        }
        XCTAssertThrowsError(try MLXAcceptanceScope.notesWindow(index: 21).windowsToAnalyze(plannedWindows: plan)) {
            XCTAssertEqual(
                $0 as? MLXAcceptanceScope.ResolutionError,
                .notesWindowIndexOutOfRange(index: 21, plannedWindowCount: 21)
            )
        }
    }

    func testOnlyNotesAndSummaryContinuesPastWindowAnalysis() {
        // The harness guards on this before Notes synthesis; Summary only
        // follows synthesis, so false here means neither can run.
        XCTAssertTrue(MLXAcceptanceScope.notesRange(first: 8, last: 20).stopsBeforeNotesSynthesis)
        XCTAssertTrue(MLXAcceptanceScope.notesRange(first: 0, last: 20).stopsBeforeNotesSynthesis)
        XCTAssertTrue(MLXAcceptanceScope.notesFull.stopsBeforeNotesSynthesis)
        XCTAssertTrue(MLXAcceptanceScope.notesWindow(index: 2).stopsBeforeNotesSynthesis)
        XCTAssertFalse(MLXAcceptanceScope.notesAndSummary.stopsBeforeNotesSynthesis)
    }

    private func sampleFingerprint() -> TranscriptSourceFingerprint {
        TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "ab", count: 32))
    }

    func testRunIdentityRecordsModelProvenanceScopeAndPlannedRange() throws {
        let runID = UUID()
        let sessionID = UUID()
        let plan = plannedWindows()
        let scope = MLXAcceptanceScope.notesRange(first: 8, last: 20)
        let identity = MLXAcceptanceRunIdentity(
            runID: runID, sessionID: sessionID, scope: scope, selection: .qwen3_14b_4bit,
            transcriptFingerprint: sampleFingerprint(), transcriptUnitCount: 164,
            plannedWindows: plan.shuffled(), requestedWindows: try scope.windowsToAnalyze(plannedWindows: plan)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any]
        )

        XCTAssertEqual(object["runID"] as? String, runID.uuidString)
        XCTAssertEqual(object["sessionID"] as? String, sessionID.uuidString)
        XCTAssertEqual(object["acceptanceScope"] as? String, "notes-range")
        XCTAssertEqual(object["requestedFirstWindowIndex"] as? Int, 8)
        XCTAssertEqual(object["requestedLastWindowIndex"] as? Int, 20)
        XCTAssertEqual(object["requestedWindowIndices"] as? [Int], Array(8...20))
        XCTAssertEqual(object["mlxModelSelection"] as? String, "qwen3-14b-4bit")
        XCTAssertEqual(object["modelIdentifier"] as? String, "mlx-community/Qwen3-14B-4bit")
        XCTAssertEqual(object["modelRevision"] as? String, "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4")
        XCTAssertEqual(object["nativeContextLength"] as? Int, 32_768)
        XCTAssertEqual(object["operationalContextCeiling"] as? Int, 24_576)
        let provenance = try XCTUnwrap(object["notesGenerationProvenance"] as? [String: Any])
        XCTAssertEqual(provenance["recipeVersion"] as? String, "mlx1-notes-v15")
        XCTAssertEqual(provenance["generatorIdentifier"] as? String, "mlx-community/Qwen3-14B-4bit")
        XCTAssertEqual(provenance["generatorVersion"] as? String, "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4")
        XCTAssertEqual(provenance["backendIdentifier"] as? String, "mlx")
        XCTAssertNil(object["summaryGenerationProvenance"], "only notes-and-summary runs Summary")
        let fingerprint = try XCTUnwrap(object["transcriptFingerprint"] as? [String: Any])
        XCTAssertEqual(fingerprint["digestHex"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(fingerprint["algorithmVersion"] as? Int, 1)
        XCTAssertEqual(object["transcriptUnitCount"] as? Int, 164)
        XCTAssertEqual(object["plannedWindowCount"] as? Int, 21)
        let windows = try XCTUnwrap(object["plannedWindows"] as? [[String: Any]])
        XCTAssertEqual(windows.map { $0["windowIndex"] as? Int }, (0...20).map { $0 })
        XCTAssertEqual(windows[8]["firstSequenceNumber"] as? Int, 64)
        XCTAssertEqual(windows[8]["lastSequenceNumber"] as? Int, 71)

        let fullIdentity = MLXAcceptanceRunIdentity(
            runID: runID, sessionID: sessionID, scope: .notesAndSummary, selection: .qwen3_8b_4bit,
            transcriptFingerprint: sampleFingerprint(), transcriptUnitCount: 164,
            plannedWindows: plan, requestedWindows: plan
        )
        XCTAssertNil(fullIdentity.requestedFirstWindowIndex)
        XCTAssertEqual(fullIdentity.summaryGenerationProvenance?.generatorIdentifier, "mlx-community/Qwen3-8B-4bit")
    }

    func testRunIdentityContainsOnlyStructuralFields() throws {
        let plan = plannedWindows()
        let identity = MLXAcceptanceRunIdentity(
            runID: UUID(), sessionID: UUID(), scope: .notesRange(first: 8, last: 20), selection: .qwen3_14b_4bit,
            transcriptFingerprint: sampleFingerprint(), transcriptUnitCount: 164,
            plannedWindows: plan, requestedWindows: plan
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "runID", "sessionID", "acceptanceScope", "requestedFirstWindowIndex", "requestedLastWindowIndex",
            "requestedWindowIndices", "mlxModelSelection", "modelIdentifier", "modelRevision",
            "nativeContextLength", "operationalContextCeiling", "notesGenerationProvenance",
            "transcriptFingerprint", "transcriptUnitCount", "plannedWindowCount", "plannedWindows",
        ])
        let window = try XCTUnwrap((object["plannedWindows"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(window.keys), [
            "windowIndex", "firstSequenceNumber", "lastSequenceNumber", "unitCount", "isOversizedSingleUnit",
        ])
        for forbidden in ["prompt", "instructions", "schema", "jsonSchema", "text", "transcriptText", "items", "body"] {
            XCTAssertNil(object[forbidden], forbidden)
        }
    }

    func testNotesRangeResultRecordsExactAnalyzedIndicesAndModelIdentity() throws {
        let sessionID = UUID()
        let plan = plannedWindows()
        let scope = MLXAcceptanceScope.notesRange(first: 8, last: 20)
        let requested = try scope.windowsToAnalyze(plannedWindows: plan)
        let identity = MLXAcceptanceRunIdentity(
            runID: UUID(), sessionID: sessionID, scope: scope, selection: .qwen3_14b_4bit,
            transcriptFingerprint: sampleFingerprint(), transcriptUnitCount: 164,
            plannedWindows: plan, requestedWindows: requested
        )
        let analyses = requested.map { window in
            LectureNotesWindowAnalysis(
                generationID: UUID(), sessionID: sessionID, transcriptFingerprint: sampleFingerprint(),
                windowIndex: window.windowIndex,
                ownedRange: NotesSourceReference(
                    sessionID: sessionID,
                    firstSequenceNumber: window.firstSequenceNumber,
                    lastSequenceNumber: window.lastSequenceNumber
                ),
                items: Array(repeating: LectureNoteItem(
                    kind: .explanation, body: "synthetic", fidelity: .transcriptSupported,
                    sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: window.firstSequenceNumber)]
                ), count: window.windowIndex % 3)
            )
        }
        let result = NotesRangeRunResult(
            identity: identity, startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 10),
            analyses: analyses,
            notesPerWindowSeconds: requested.map { TimedWindow(windowIndex: $0.windowIndex, seconds: 2) },
            notesCallRecords: [],
            totalEndToEndSeconds: 30, persistenceWarnings: []
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        )

        XCTAssertEqual(object["acceptanceScope"] as? String, "notes-range")
        XCTAssertEqual(object["analyzedWindowIndices"] as? [Int], Array(8...20))
        XCTAssertEqual(object["firstAnalyzedWindowIndex"] as? Int, 8)
        XCTAssertEqual(object["lastAnalyzedWindowIndex"] as? Int, 20)
        XCTAssertEqual(object["requestedFirstWindowIndex"] as? Int, 8)
        XCTAssertEqual(object["requestedLastWindowIndex"] as? Int, 20)
        XCTAssertEqual(object["plannedWindowCount"] as? Int, 21)
        XCTAssertEqual(object["mlxModelSelection"] as? String, "qwen3-14b-4bit")
        XCTAssertEqual(object["modelIdentifier"] as? String, "mlx-community/Qwen3-14B-4bit")
        XCTAssertEqual(
            (object["notesGenerationProvenance"] as? [String: Any])?["generatorVersion"] as? String,
            "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4"
        )
        let expectedCounts = (8...20).map { $0 % 3 }
        XCTAssertEqual(object["analysisItemCounts"] as? [Int], expectedCounts)
        XCTAssertEqual(object["totalAnalysisItemCount"] as? Int, expectedCounts.reduce(0, +))
        XCTAssertEqual(object["notesAnalysisTotalSeconds"] as? Double, 26)
        XCTAssertNil(object["notesDocument"])
        XCTAssertNil(object["summaryDocument"])
    }

    // MARK: - Acceptance model selection

    func testAcceptanceModelSelectorAbsentSelects8B() throws {
        XCTAssertEqual(try MLXAcceptanceModelSelection.resolve(environmentValue: nil), .qwen3_8b_4bit)
        XCTAssertEqual(MLXAcceptanceModelSelection.qwen3_8b_4bit.descriptor, .qwen3_8b_4bit)
    }

    func testAcceptanceModelSelectorExplicit8BSelects8B() throws {
        let selection = try MLXAcceptanceModelSelection.resolve(environmentValue: "qwen3-8b-4bit")
        XCTAssertEqual(selection, .qwen3_8b_4bit)
        XCTAssertEqual(selection.descriptor, .qwen3_8b_4bit)
    }

    func testAcceptanceModelSelectorExplicit14BSelectsExact14BDescriptor() throws {
        let selection = try MLXAcceptanceModelSelection.resolve(environmentValue: "qwen3-14b-4bit")
        XCTAssertEqual(selection, .qwen3_14b_4bit)
        XCTAssertEqual(selection.descriptor, .qwen3_14b_4bit)
        XCTAssertEqual(selection.descriptor.modelIdentifier, "mlx-community/Qwen3-14B-4bit")
        XCTAssertEqual(selection.descriptor.modelRevision, "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4")
    }

    func testAcceptanceModelSelectorRejectsUnknownValuesWithTypedError() {
        for value in ["", "qwen3-14b", "QWEN3-14B-4BIT", " qwen3-14b-4bit", "mlx-community/Qwen3-14B-4bit", "main"] {
            XCTAssertThrowsError(try MLXAcceptanceModelSelection.resolve(environmentValue: value)) { error in
                XCTAssertEqual(error as? MLXAcceptanceModelSelection.UnknownSelection, .init(value: value))
                XCTAssertTrue(error.localizedDescription.contains("LECTURE_RECORDER_ACCEPTANCE_MLX_MODEL"))
            }
        }
    }

    func testAcceptanceModelSelectionIsFiniteAndEveryCaseIsPinned() {
        XCTAssertEqual(MLXAcceptanceModelSelection.allCases.map(\.rawValue), ["qwen3-8b-4bit", "qwen3-14b-4bit"])
        for selection in MLXAcceptanceModelSelection.allCases {
            XCTAssertNotNil(MLXPinnedModelManifests.manifest(for: selection.descriptor), selection.rawValue)
        }
    }

    func testAcceptanceIdentityAndProvenanceFollowSelected14BModel() throws {
        let identity = MLXAcceptanceModelIdentity(.qwen3_14b_4bit)
        XCTAssertEqual(identity.mlxModelSelection, "qwen3-14b-4bit")
        XCTAssertEqual(identity.modelIdentifier, "mlx-community/Qwen3-14B-4bit")
        XCTAssertEqual(identity.modelRevision, "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4")
        XCTAssertEqual(identity.nativeContextLength, 32_768)
        XCTAssertEqual(identity.operationalContextCeiling, 24_576)

        let notes14B = MLXNotesConfiguration.generationProvenance(for: .qwen3_14b_4bit)
        let summary14B = MLXSummaryConfiguration.generationProvenance(for: .qwen3_14b_4bit)
        for provenance in [notes14B, summary14B] {
            XCTAssertEqual(provenance.generatorIdentifier, identity.modelIdentifier)
            XCTAssertEqual(provenance.generatorVersion, identity.modelRevision)
            XCTAssertEqual(provenance.backendIdentifier, "mlx")
            XCTAssertNotEqual(provenance.generatorIdentifier, MLXNotesConfiguration.generatorIdentifier)
            XCTAssertNotEqual(provenance.generatorVersion, MLXNotesConfiguration.generatorVersion)
        }
        XCTAssertEqual(notes14B.recipeVersion, "mlx1-notes-v15")
        XCTAssertEqual(summary14B.recipeVersion, MLXSummaryConfiguration.recipeVersion)

        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any]
        )
        XCTAssertEqual(encoded["modelIdentifier"] as? String, "mlx-community/Qwen3-14B-4bit")
        XCTAssertEqual(encoded["mlxModelSelection"] as? String, "qwen3-14b-4bit")
    }

    func testExisting8BIdentityAndProvenanceAreUnchanged() {
        let identity = MLXAcceptanceModelIdentity(.qwen3_8b_4bit)
        XCTAssertEqual(identity.modelIdentifier, "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(identity.modelRevision, "545dc4251c05440727734bcd94334791f6ab0192")
        XCTAssertEqual(
            MLXNotesConfiguration.generationProvenance,
            LectureNotesGenerationProvenance(
                recipeVersion: "mlx1-notes-v15",
                generatorIdentifier: "mlx-community/Qwen3-8B-4bit",
                generatorVersion: "545dc4251c05440727734bcd94334791f6ab0192",
                backendIdentifier: "mlx"
            )
        )
        XCTAssertEqual(MLXNotesConfiguration.generationProvenance, MLXNotesConfiguration.generationProvenance(for: .qwen3_8b_4bit))
        XCTAssertEqual(MLXSummaryConfiguration.generationProvenance, MLXSummaryConfiguration.generationProvenance(for: .qwen3_8b_4bit))
        XCTAssertEqual(MLXSummaryConfiguration.generationProvenance.generatorIdentifier, "mlx-community/Qwen3-8B-4bit")
    }

    func testNotesSourceReferenceFailureDiagnosticPersistsExactPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = NotesSourceReferenceFailureDiagnostic(
            windowIndex: 2,
            firstSequenceNumber: 16,
            lastSequenceNumber: 23,
            allowedSequenceNumbers: [18, 19, 20, 21, 22]
        )
        let url = directory.appendingPathComponent("notes-source-reference-failure.json")
        try AtomicFileWriter.writeJSON(artifact, to: url)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )

        XCTAssertEqual(object["windowIndex"] as? Int, 2)
        XCTAssertEqual(object["firstSequenceNumber"] as? Int, 16)
        XCTAssertEqual(object["lastSequenceNumber"] as? Int, 23)
        XCTAssertEqual(object["allowedSequenceNumbers"] as? [Int], [18, 19, 20, 21, 22])
        XCTAssertNil(object["prompt"])
        XCTAssertNil(object["transcriptText"])
    }

    // MARK: - Evidence durability

    private func scratchDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Every completed call is on disk, tagged with its stage, before a
    /// later stage fails — without waiting for a final result file.
    func testCallRecordsSurviveADownstreamFailure() async throws {
        let directory = try scratchDirectory("CallRecords")
        let recordsURL = directory.appendingPathComponent("call-records.json")
        let fake = FakeMLXSessionDriver()
        fake.enqueueRespond(.success(.stub(jsonText: "{}", promptTokenCount: 1_400, generatedTokenCount: 73)))
        fake.enqueueRespond(.failure(MLXGuidedGenerationRuntimeError.unclassified("boom")))
        let driver = TimingSessionDriver(wrapped: fake, recordsURL: recordsURL)

        await driver.setStage("notesWindow:6")
        _ = try await driver.preparedInputTokenCount(instructions: "i", prompt: "p")
        _ = try await driver.respond(
            instructions: MLXLectureNotesGenerator.analysisInstructions, prompt: "p", jsonSchema: "{}", maxOutputTokens: 4_096,
            sampling: MLXNotesConfiguration.windowAnalysisSampling
        )
        await driver.setStage("summaryDocument")
        do {
            _ = try await driver.respond(instructions: "i", prompt: "p", jsonSchema: "{}", maxOutputTokens: 4_096, sampling: nil)
            XCTFail("expected the downstream call to fail")
        } catch {}

        let persisted = try AtomicFileWriter.readJSON([CallRecord].self, from: recordsURL)
        XCTAssertEqual(persisted.map(\.kind), ["tokenCount", "respond"])
        XCTAssertEqual(persisted.map(\.stage), ["notesWindow:6", "notesWindow:6"])
        XCTAssertEqual(persisted[1].promptTokenCount, 1_400)
        XCTAssertEqual(persisted[1].generatedTokenCount, 73)
        XCTAssertEqual(persisted.map(\.sampling), [nil, MLXNotesConfiguration.windowAnalysisSampling])
        XCTAssertEqual(persisted.map(\.instructionStage), ["unknown", "windowAnalysis"])
        let inMemory = await driver.records
        XCTAssertEqual(persisted, inMemory)
        let warnings = await driver.persistenceWarnings
        XCTAssertTrue(warnings.isEmpty)
    }

    func testRunProgressNamesCompletedStagesAndStaysIncompleteUntilFinished() throws {
        let url = try scratchDirectory("RunProgress").appendingPathComponent("run-progress.json")
        var progress = MLXAcceptanceRunProgress(runID: "run")
        try progress.complete("notesWindow:0", writingTo: url)
        try progress.complete("notesSynthesis", writingTo: url)
        var persisted = try AtomicFileWriter.readJSON(MLXAcceptanceRunProgress.self, from: url)
        XCTAssertEqual(persisted.status, "incomplete")
        XCTAssertEqual(persisted.completedStages, ["notesWindow:0", "notesSynthesis"])
        try progress.finish(writingTo: url)
        persisted = try AtomicFileWriter.readJSON(MLXAcceptanceRunProgress.self, from: url)
        XCTAssertEqual(persisted.status, "completed")
    }

    // MARK: - Summary replay source

    private func writeNotesDocument(
        in directory: URL, analyses: [LectureNotesWindowAnalysis], sessionID: UUID,
        mutate: (inout LectureNotesDocument) -> Void = { _ in }
    ) throws {
        var document = LectureNotesDocument(
            generationID: analyses[0].generationID, sessionID: sessionID,
            transcriptFingerprint: sampleFingerprint(), provenance: currentProvenance,
            overview: "Overview.", sections: [LectureNoteSection(heading: "Section", items: analyses.flatMap(\.items))]
        )
        mutate(&document)
        try AtomicFileWriter.writeJSON(document, to: directory.appendingPathComponent("notes-document.json"))
    }

    func testDownstreamReplayRestampsOnlyV10AnalysesForCurrentSynthesis() throws {
        let directory = try replayDirectory()
        _ = try writeReplaySource(in: directory)
        var v10 = currentProvenance
        v10.recipeVersion = "mlx1-notes-v10"
        let identityURL = directory.appendingPathComponent("run-identity.json")
        var identity = try AtomicFileWriter.readJSON(MLXAcceptanceRunIdentity.self, from: identityURL)
        identity.notesGenerationProvenance = v10
        try AtomicFileWriter.writeJSON(identity, to: identityURL)

        let source = try MLXSynthesisReplaySource.load(runDirectory: directory, expectedProvenance: v10)
        let restamped = try MLXDownstreamReplay.restampedForCurrentSynthesis(source.generation, descriptor: .qwen3_8b_4bit)
        XCTAssertEqual(restamped.generationID, source.generation.generationID, "same generation; only the recipe label moves")
        XCTAssertEqual(restamped.provenance, MLXNotesConfiguration.generationProvenance)
        XCTAssertEqual(restamped.provenance.recipeVersion, "mlx1-notes-v15")
        XCTAssertEqual(restamped.windowPlan, source.generation.windowPlan)
        XCTAssertEqual(restamped.transcriptFingerprint, source.generation.transcriptFingerprint)
        XCTAssertTrue(source.analyses.allSatisfy { $0.generationID == restamped.generationID }, "the analyses still belong to it")

        for recipe in ["mlx1-notes-v8", "mlx1-notes-v9", "mlx1-notes-v11", "mlx1-notes-v12", "mlx1-notes-v13", "mlx1-notes-v14", "mlx1-notes-v15"] {
            var other = source.generation
            other.provenance.recipeVersion = recipe
            XCTAssertThrowsError(try MLXDownstreamReplay.restampedForCurrentSynthesis(other, descriptor: .qwen3_8b_4bit)) {
                XCTAssertEqual($0 as? MLXDownstreamReplay.IncompatibleSourceRecipe, .init(recipe: recipe))
            }
        }
    }

    func testSummaryReplayLoadsTheSourceRunsOwnNotesDocument() throws {
        let directory = try replayDirectory()
        let written = try writeReplaySource(in: directory)
        try writeNotesDocument(in: directory, analyses: written.analyses, sessionID: written.sessionID)
        let loaded = try MLXSummaryReplaySource.load(runDirectory: directory, expectedNotesProvenance: currentProvenance)
        XCTAssertEqual(loaded.document.generationID, loaded.notes.generation.generationID)
        XCTAssertEqual(loaded.notes.analyses.map(\.windowIndex), [0, 1, 2])
    }

    func testSummaryReplayRejectsAMissingOrForeignNotesDocument() throws {
        let missing = try replayDirectory()
        _ = try writeReplaySource(in: missing)
        XCTAssertThrowsError(try MLXSummaryReplaySource.load(runDirectory: missing, expectedNotesProvenance: currentProvenance)) {
            XCTAssertEqual($0 as? MLXSynthesisReplaySource.ValidationError, .unreadable("notes-document.json"))
        }
        let foreign = try replayDirectory()
        let written = try writeReplaySource(in: foreign)
        try writeNotesDocument(in: foreign, analyses: written.analyses, sessionID: written.sessionID) { $0.generationID = UUID() }
        XCTAssertThrowsError(try MLXSummaryReplaySource.load(runDirectory: foreign, expectedNotesProvenance: currentProvenance)) {
            XCTAssertEqual($0 as? MLXSynthesisReplaySource.ValidationError, .mismatch("Notes document does not belong to the source generation"))
        }
    }

    /// Batch coverage is reported in the model's own 1-based batch
    /// positions: a v3-style first-8 cutoff shows as uncited positions 9–12,
    /// and consolidated support counts every cited item.
    func testSummaryBatchCoverageReportsPositionsAndUncitedTail() throws {
        let (source, itemIDs) = try SummaryTestSupport.distinguishableSource(count: 20)
        let plan = try LectureSummaryPlanner.plan(
            source: source, budget: LectureSummaryBatchBudget(maxSerializedBytesPerBatch: 100_000, maxItemsPerBatch: 12)
        )
        XCTAssertEqual(plan.batches.map(\.sourceItemIDs.count), [12, 8])
        func analysis(_ batchIndex: Int, _ support: [[Int]]) -> LectureSummaryAnalysis {
            LectureSummaryAnalysis(
                generationID: UUID(), sessionID: SummaryTestSupport.sessionID,
                sourceNotesGenerationID: SummaryTestSupport.notesGenerationID,
                transcriptFingerprint: source.transcriptFingerprint,
                sourceNotesDocumentFingerprint: source.sourceNotesDocumentFingerprint,
                batchID: plan.batches[batchIndex].batchID, batchIndex: batchIndex,
                passages: support.map { indices in
                    LectureSummaryPassage(
                        id: UUID(), text: "t", supportingNoteItemIDs: indices.map { itemIDs[$0] },
                        sourceReferences: [], fidelity: .transcriptSupported, uncertaintyNote: nil
                    )
                },
                provenance: MLXSummaryConfiguration.generationProvenance
            )
        }
        let coverage = MLXSummaryBatchCoverage.compute(plan: plan, analyses: [
            analysis(0, (0..<8).map { [$0] }),
            analysis(1, [[12, 13, 14], [19]]),
        ])
        XCTAssertEqual(coverage.map(\.batchIndex), [0, 1])
        XCTAssertEqual(coverage[0].passageCount, 8)
        XCTAssertEqual(coverage[0].citedPositions, Array(1...8))
        XCTAssertEqual(coverage[0].uncitedPositions, [9, 10, 11, 12])
        XCTAssertEqual(coverage[0].uncitedSourceIndices, [8, 9, 10, 11])
        XCTAssertEqual(coverage[1].passageSupportPositions, [[1, 2, 3], [8]])
        XCTAssertEqual(coverage[1].uncitedPositions, [4, 5, 6, 7])
        XCTAssertEqual(coverage[1].uncitedSourceIndices, [15, 16, 17, 18])
    }

    // MARK: - v10 contract

    /// v15 keeps v10's window analysis exactly — the restored v8 prompt plus
    /// fixed sampling — and changes only synthesis. Changing any of these
    /// without a new recipe fails here.
    func testV15KeepsV10WindowAnalysisExactly() {
        XCTAssertEqual(MLXNotesConfiguration.recipeVersion, "mlx1-notes-v15")
        XCTAssertEqual(
            MLXNotesConfiguration.windowAnalysisSampling,
            MLXGuidedSampling(temperature: 0.7, topP: 0.8, topK: 20, minP: 0, seed: 20_260_928)
        )
        XCTAssertEqual(String(describing: type(of: MLXNotesConfiguration.windowAnalysisSampling.makeSampler())), "TopPSampler")
        let instructions = MLXLectureNotesGenerator.analysisInstructions
        XCTAssertEqual(MLXAcceptanceTextDiagnostics.sha256Hex(instructions), "f2d481111e09ef078280583867188de2f582ede8c29f2c2d9c4d4f57e231a858")
        XCTAssertEqual(instructions.count, 1_788)
        for v9 in ["Read the whole window", "do not stop after the first valid item", "Consolidate only overlapping"] {
            XCTAssertFalse(instructions.contains(v9), v9)
        }
        XCTAssertEqual(MLXNotesConfiguration.generationProvenance, LectureNotesGenerationProvenance(
            recipeVersion: "mlx1-notes-v15", generatorIdentifier: "mlx-community/Qwen3-8B-4bit",
            generatorVersion: "545dc4251c05440727734bcd94334791f6ab0192", backendIdentifier: "mlx"
        ))
    }

    func testV10KeepsTheWindowSchemaContract() throws {
        let schema = MLXLectureNotesGenerator.windowAnalysisJSONSchema(allowedSequenceNumbers: Array(48...55))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        XCTAssertEqual(root["required"] as? [String], ["items"])
        let items = try XCTUnwrap((root["properties"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(items["maxItems"] as? Int, 12)
        XCTAssertNil(items["minItems"], "no minimum Note count")
        let item = try XCTUnwrap(items["items"] as? [String: Any])
        XCTAssertEqual(item["required"] as? [String], ["kind", "body", "sourceReferences"])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["kind", "body", "sourceReferences"], "no fidelity or other model-chosen field")
        XCTAssertEqual((properties["body"] as? [String: Any])?["maxLength"] as? Int, 600)
        let references = try XCTUnwrap(properties["sourceReferences"] as? [String: Any])
        XCTAssertEqual(references["minItems"] as? Int, 1)
        XCTAssertEqual(references["maxItems"] as? Int, 3)
        let alternatives = try XCTUnwrap((references["items"] as? [String: Any])?["anyOf"] as? [[String: Any]])
        XCTAssertEqual(alternatives.count, 36, "every contiguous range inside the 8-unit window, and nothing outside it")
    }

    func testV10UsesOriginalEightUnitWindows() {
        XCTAssertEqual(MLXNotesConfiguration.maximumUnitsPerWindow, 8)
        let units = (0..<120).map {
            NotesTranscriptSourceUnit(sequenceNumber: $0, chunkFileName: "c\($0)", text: "line \($0)", startOffsetSeconds: Double($0) * 30, durationSeconds: 30)
        }
        let plan = NotesWindowPlanner.plan(units: units, budget: MLXNotesConfiguration.windowBudget)
        XCTAssertEqual(plan.count, 15)
        XCTAssertTrue(plan.allSatisfy { $0.unitCount == 8 })
        XCTAssertEqual(plan.first { $0.windowIndex == 6 }.map { [$0.firstSequenceNumber, $0.lastSequenceNumber] }, [48, 55])
    }

    func testScriptAnomalyScanReportsControlsAndLatexMarkup() {
        let found = MLXAcceptanceTextDiagnostics.scriptAnomalies(in: "$ \u{0C}rac{a}{b} $ and \u{09}ext \\nabla\nnext", location: "summary")
        XCTAssertEqual(found.map(\.kind), ["dollar", "control", "dollar", "control", "backslash"])
        XCTAssertEqual(found.map(\.scalarHex), ["U+0024", "U+000C", "U+0024", "U+0009", "U+005C"])
    }

    func testScriptAnomalyScanReportsOnlyCJKWithItsLocation() {
        let clean = "Voltage φ satisfies dφ = −E · dx; ΔW = F·Δx; Coulomb’s law — “quoted” (10 Ω)."
        XCTAssertTrue(MLXAcceptanceTextDiagnostics.scriptAnomalies(in: clean, location: "x").isEmpty)
        let found = MLXAcceptanceTextDiagnostics.scriptAnomalies(in: "f'(x) = 极2x and 、", location: "notesWindow:4/item:7")
        XCTAssertEqual(found.map(\.character), ["极", "、"])
        XCTAssertEqual(found.map(\.scalarHex), ["U+6781", "U+3001"])
        XCTAssertTrue(found.allSatisfy { $0.location == "notesWindow:4/item:7" && $0.containingText == "f'(x) = 极2x and 、" })
    }

    // MARK: - 4+4 slice diagnostic

    private func sliceUnits(_ range: ClosedRange<Int>) -> [NotesTranscriptSourceUnit] {
        range.map {
            NotesTranscriptSourceUnit(
                sequenceNumber: $0, chunkFileName: "chunk_\($0).caf", text: "line \($0)",
                startOffsetSeconds: Double($0) * 30, durationSeconds: 30
            )
        }
    }

    private func sliceParent(_ index: Int, _ range: ClosedRange<Int>) -> NotesInputWindow {
        NotesInputWindow(windowIndex: index, firstSequenceNumber: range.lowerBound, lastSequenceNumber: range.upperBound,
                         unitCount: range.count, isOversizedSingleUnit: false)
    }

    func testSliceDiagnosticSplitsAnEightUnitWindowIntoContiguousHalves() throws {
        let parent = sliceParent(6, 48...55)
        let slices = try MLXNotesSliceDiagnostic.slices(of: parent, units: sliceUnits(48...55).shuffled())
        XCTAssertEqual(slices.map(\.label), ["6A", "6B"])
        XCTAssertEqual(slices.map { $0.units.map(\.sequenceNumber) }, [Array(48...51), Array(52...55)])
        XCTAssertEqual(slices.map(\.window), [
            NotesInputWindow(windowIndex: 6, firstSequenceNumber: 48, lastSequenceNumber: 51, unitCount: 4, isOversizedSingleUnit: false),
            NotesInputWindow(windowIndex: 6, firstSequenceNumber: 52, lastSequenceNumber: 55, unitCount: 4, isOversizedSingleUnit: false),
        ])
        let all = slices.flatMap(\.units).map(\.sequenceNumber)
        XCTAssertEqual(all, Array(48...55), "every unit exactly once, none lost or duplicated")
        XCTAssertEqual(slices.flatMap(\.units), sliceUnits(48...55), "original unit identity and text survive")
    }

    func testSliceDiagnosticHandlesOddAndSingleUnitWindowsAndRejectsMismatches() throws {
        XCTAssertEqual(try MLXNotesSliceDiagnostic.slices(of: sliceParent(2, 0...4), units: sliceUnits(0...4)).map { $0.units.count }, [3, 2])
        XCTAssertEqual(try MLXNotesSliceDiagnostic.slices(of: sliceParent(3, 9...9), units: sliceUnits(9...9)).map(\.label), ["3A"])
        XCTAssertThrowsError(try MLXNotesSliceDiagnostic.slices(of: sliceParent(1, 8...15), units: sliceUnits(8...14))) {
            XCTAssertEqual($0 as? MLXNotesSliceDiagnostic.SliceError, .unitsDoNotMatchWindow(1))
        }
    }

    func testSliceDiagnosticWindowIndicesParseStrictly() throws {
        XCTAssertEqual(try MLXNotesSliceDiagnostic.windowIndices(from: "6,9,10,11,4,1"), [6, 9, 10, 11, 4, 1])
        for bad in [nil, "", "6,,9", "6,-1", "6,6", "a", " 6"] as [String?] {
            XCTAssertThrowsError(try MLXNotesSliceDiagnostic.windowIndices(from: bad))
        }
    }

    /// Slice analyses run through the unchanged production generator: a
    /// zero-item slice is valid, references keep their original sequence
    /// numbers, and the merge orders items by source position
    /// deterministically — with no minimum and no deduplication.
    func testSliceAnalysesThroughTheProductionGeneratorMergeDeterministically() async throws {
        let parent = sliceParent(9, 72...79)
        let slices = try MLXNotesSliceDiagnostic.slices(of: parent, units: sliceUnits(72...79))
        let fake = FakeMLXSessionDriver()
        let itemJSON: (String, Int) -> String = { body, sequence in
            #"{"kind":"explanation","body":"\#(body)","sourceReferences":[{"firstSequenceNumber":\#(sequence),"lastSequenceNumber":\#(sequence)}]}"#
        }
        fake.enqueueRespond(.success(.stub(jsonText: #"{"items":[\#(itemJSON("late A", 75)),\#(itemJSON("early A", 72)),\#(itemJSON("early A tie", 72))]}"#)))
        fake.enqueueRespond(.success(.stub(jsonText: #"{"items":[\#(itemJSON("B end", 79)),\#(itemJSON("B start", 76))]}"#)))
        fake.enqueueRespond(.success(.stub(jsonText: #"{"items":[\#(itemJSON("only A", 73))]}"#)))
        fake.enqueueRespond(.success(.stub(jsonText: #"{"items":[]}"#)))
        let generator = MLXLectureNotesGenerator(sessionDriver: fake, modelDescriptor: .qwen3_8b_4bit)
        let sessionID = UUID()
        let plan = NotesWindowPlan(windows: [parent])
        let generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID, transcriptFingerprint: sampleFingerprint(), windowPlan: plan,
            provenance: MLXNotesConfiguration.generationProvenance(for: .qwen3_8b_4bit)
        )
        func run() async throws -> [LectureNotesWindowAnalysis] {
            var analyses: [LectureNotesWindowAnalysis] = []
            for slice in slices {
                analyses.append(try await generator.analyzeWindow(units: slice.units, window: slice.window, generation: generation))
            }
            return analyses
        }

        let both = try await run()
        XCTAssertEqual(both.map(\.ownedRange.firstSequenceNumber), [72, 76])
        let merged = MLXNotesSliceDiagnostic.merge(parent: parent, sliceAnalyses: both)
        XCTAssertEqual(merged.items.map(\.body), ["early A", "early A tie", "late A", "B start", "B end"])
        XCTAssertEqual(merged.items.flatMap(\.sourceReferences).map(\.firstSequenceNumber), [72, 72, 75, 76, 79])
        XCTAssertTrue(merged.items.allSatisfy { $0.fidelity == .transcriptSupported })
        XCTAssertEqual(merged.windowIndex, 9)
        XCTAssertEqual(merged.ownedRange, NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 72, lastSequenceNumber: 79))

        let oneEmpty = try await run()
        XCTAssertEqual(oneEmpty.map(\.items.count), [1, 0], "a zero-item slice is valid")
        XCTAssertEqual(MLXNotesSliceDiagnostic.merge(parent: parent, sliceAnalyses: oneEmpty).items.map(\.body), ["only A"])
        XCTAssertEqual(MLXNotesSliceDiagnostic.merge(parent: parent, sliceAnalyses: both).items, merged.items, "merge is deterministic")
    }

    func testSliceReferencesOutsideTheSliceAreRejectedAsBefore() async throws {
        let slices = try MLXNotesSliceDiagnostic.slices(of: sliceParent(9, 72...79), units: sliceUnits(72...79))
        let fake = FakeMLXSessionDriver()
        fake.enqueueRespond(.success(.stub(jsonText: #"{"items":[{"kind":"explanation","body":"x","sourceReferences":[{"firstSequenceNumber":77,"lastSequenceNumber":77}]}]}"#)))
        let generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: UUID(), transcriptFingerprint: sampleFingerprint(), windowPlan: NotesWindowPlan(windows: [sliceParent(9, 72...79)]),
            provenance: MLXNotesConfiguration.generationProvenance(for: .qwen3_8b_4bit)
        )
        do {
            _ = try await MLXLectureNotesGenerator(sessionDriver: fake, modelDescriptor: .qwen3_8b_4bit)
                .analyzeWindow(units: slices[0].units, window: slices[0].window, generation: generation)
            XCTFail("a reference to the other half must be rejected")
        } catch let error as MLXLectureNotesBackendError {
            guard case .invalidSourceReference = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Synthesis replay

    private func writeReplaySource(
        in directory: URL,
        windowCount: Int = 3,
        scope: MLXAcceptanceScope = .notesAndSummary,
        mutate: (inout [LectureNotesWindowAnalysis]) -> Void = { _ in }
    ) throws -> (sessionID: UUID, analyses: [LectureNotesWindowAnalysis]) {
        let sessionID = UUID()
        let plan = plannedWindows(count: windowCount)
        let identity = MLXAcceptanceRunIdentity(
            runID: UUID(), sessionID: sessionID, scope: scope, selection: .qwen3_8b_4bit,
            transcriptFingerprint: sampleFingerprint(), transcriptUnitCount: windowCount * 8,
            plannedWindows: plan, requestedWindows: try scope.windowsToAnalyze(plannedWindows: plan)
        )
        try AtomicFileWriter.writeJSON(identity, to: directory.appendingPathComponent("run-identity.json"))
        let generationID = UUID()
        var analyses = plan.map { window in
            LectureNotesWindowAnalysis(
                generationID: generationID, sessionID: sessionID, transcriptFingerprint: sampleFingerprint(),
                windowIndex: window.windowIndex,
                ownedRange: NotesSourceReference(sessionID: sessionID, firstSequenceNumber: window.firstSequenceNumber, lastSequenceNumber: window.lastSequenceNumber),
                items: [LectureNoteItem(
                    kind: .explanation, body: "synthetic \(window.windowIndex)", fidelity: .transcriptSupported,
                    sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: window.firstSequenceNumber)]
                )]
            )
        }
        mutate(&analyses)
        for (fileIndex, analysis) in analyses.enumerated() {
            try AtomicFileWriter.writeJSON(
                analysis,
                to: directory.appendingPathComponent("notes-window-analyses/\(MLXSynthesisReplaySource.analysisFileName(for: fileIndex))")
            )
        }
        return (sessionID, analyses)
    }

    private func replayDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SynthesisReplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("notes-window-analyses"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private var currentProvenance: LectureNotesGenerationProvenance {
        MLXNotesConfiguration.generationProvenance(for: .qwen3_8b_4bit)
    }

    private func assertReplayRejected(_ directory: URL, _ expected: MLXSynthesisReplaySource.ValidationError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MLXSynthesisReplaySource.load(runDirectory: directory, expectedProvenance: currentProvenance), file: file, line: line) {
            XCTAssertEqual($0 as? MLXSynthesisReplaySource.ValidationError, expected, file: file, line: line)
        }
    }

    func testReplayLoadsACompleteSourceInWindowOrderWithItsGenerationIdentity() throws {
        let directory = try replayDirectory()
        let source = try writeReplaySource(in: directory)
        let loaded = try MLXSynthesisReplaySource.load(runDirectory: directory, expectedProvenance: currentProvenance)
        XCTAssertEqual(loaded.analyses, source.analyses)
        XCTAssertEqual(loaded.generation.generationID, source.analyses[0].generationID)
        XCTAssertEqual(loaded.generation.sessionID, source.sessionID)
        XCTAssertEqual(loaded.generation.provenance, currentProvenance)
        XCTAssertEqual(loaded.generation.windowPlan.windows.map(\.windowIndex), [0, 1, 2])
    }

    func testReplayRejectsAMissingAnalysis() throws {
        let directory = try replayDirectory()
        _ = try writeReplaySource(in: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("notes-window-analyses/window_0001.json"))
        assertReplayRejected(directory, .mismatch("window analysis files do not exactly match the plan"))
    }

    func testReplayRejectsAnExtraAnalysisFile() throws {
        let directory = try replayDirectory()
        _ = try writeReplaySource(in: directory)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("notes-window-analyses/window_0003.json"))
        assertReplayRejected(directory, .mismatch("window analysis files do not exactly match the plan"))
    }

    func testReplayRejectsOutOfOrderAnalyses() throws {
        let directory = try replayDirectory()
        _ = try writeReplaySource(in: directory) { $0.swapAt(1, 2) }
        assertReplayRejected(directory, .mismatch("window 1 is out of order"))
    }

    func testReplayRejectsMalformedAnalysisJSON() throws {
        let directory = try replayDirectory()
        _ = try writeReplaySource(in: directory)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("notes-window-analyses/window_0002.json"))
        assertReplayRejected(directory, .unreadable("notes-window-analyses/window_0002.json"))
    }

    func testReplayRejectsAPartialSourceRun() throws {
        let directory = try replayDirectory()
        _ = try writeReplaySource(in: directory, scope: .notesRange(first: 0, last: 1))
        assertReplayRejected(directory, .mismatch("the source run did not analyze every planned window"))
    }

    func testReplayRejectsAnotherRecipeOrModel() throws {
        let directory = try replayDirectory()
        _ = try writeReplaySource(in: directory)
        XCTAssertThrowsError(try MLXSynthesisReplaySource.load(
            runDirectory: directory, expectedProvenance: MLXNotesConfiguration.generationProvenance(for: .qwen3_14b_4bit)
        )) {
            XCTAssertEqual($0 as? MLXSynthesisReplaySource.ValidationError, .mismatch("Notes provenance differs from the selected model and current recipe"))
        }
    }

    func testReplayRejectsReferencesOutsideTheOwnedWindowAndMixedGenerations() throws {
        let outside = try replayDirectory()
        _ = try writeReplaySource(in: outside) { analyses in
            analyses[1].items[0].sourceReferences = [NotesSourceReference(sessionID: analyses[1].sessionID, sequenceNumber: 0)]
        }
        assertReplayRejected(outside, .mismatch("window 1 item source reference"))

        let mixed = try replayDirectory()
        _ = try writeReplaySource(in: mixed) { $0[2].generationID = UUID() }
        assertReplayRejected(mixed, .mismatch("window 2 generation ID"))
    }

    func testReplayRecordsOnlyTheSummaryCount() {
        XCTAssertEqual(SynthesisStageRecordingDriver.summaryCount(fromSectionSummariesJSON: #"{"sectionSummaries":["A.","B.","C.","D."]}"#), 4)
        XCTAssertNil(SynthesisStageRecordingDriver.summaryCount(fromSectionSummariesJSON: #"{"sentences":["A."]}"#))
    }

    private func replayCall(_ kind: String, _ stage: String, failure: String? = nil) -> SynthesisStageRecordingDriver.Call {
        SynthesisStageRecordingDriver.Call(
            callIndex: 0, kind: kind, stage: stage, wallClockSeconds: 1, maxOutputTokens: nil, promptTokenCount: nil,
            generatedTokenCount: nil, generationSeconds: nil, peakMemoryBytes: nil, failure: failure,
            summaryCount: nil
        )
    }

    func testReplayFailureDiagnosisNamesTheStageAndPhase() {
        let diagnose = SynthesisStageRecordingDriver.failureDiagnosis
        XCTAssertTrue(diagnose([]) == ("sectionPartition", "sectionAssembly"))
        XCTAssertTrue(diagnose([replayCall("tokenCount", "windowTopics", failure: "E.x")]) == ("windowTopics", "preflightUnavailable"))
        XCTAssertTrue(diagnose([replayCall("tokenCount", "windowTopics")]) == ("windowTopics", "contextBudget"))
        XCTAssertTrue(diagnose([replayCall("tokenCount", "windowTopics"), replayCall("respond", "windowTopics", failure: "E.incompleteOutput")])
                      == ("windowTopics", "modelCall"))
        XCTAssertTrue(diagnose([replayCall("tokenCount", "windowTopics"), replayCall("respond", "windowTopics")])
                      == ("windowTopics", "outputValidation"))
        XCTAssertTrue(diagnose([replayCall("tokenCount", "sectionSummaries"), replayCall("respond", "sectionSummaries")])
                      == ("sectionSummaries", "outputValidation"))
        XCTAssertTrue(diagnose([replayCall("tokenCount", "sectionSummaries"), replayCall("respond", "sectionSummaries", failure: "E.x")])
                      == ("sectionSummaries", "modelCall"))
        XCTAssertTrue(diagnose([replayCall("respond", "sectionSummaries"), replayCall("tokenCount", "windowTopics")])
                      == ("windowTopics", "contextBudget"))
    }

    func testReplayWindowTopicProgressIdentifiesTheFailingWindow() {
        let summary = [replayCall("tokenCount", "sectionSummaries"), replayCall("respond", "sectionSummaries")]
        let window = [replayCall("tokenCount", "windowTopics"), replayCall("respond", "windowTopics")]
        let allFifteen = summary + Array((0..<15).map { _ in window }.joined())
        XCTAssertTrue(SynthesisStageRecordingDriver.windowTopicProgress(calls: allFifteen, failed: false) == (15, nil))
        // Windows 0–6 labeled; window 7 answered malformed twice.
        let malformedSeven = summary + Array((0..<7).map { _ in window }.joined())
            + [replayCall("tokenCount", "windowTopics"), replayCall("respond", "windowTopics"), replayCall("respond", "windowTopics")]
        XCTAssertTrue(SynthesisStageRecordingDriver.windowTopicProgress(calls: malformedSeven, failed: true) == (7, 7))
        // Window 3's model call failed.
        let failedThree = summary + Array((0..<3).map { _ in window }.joined())
            + [replayCall("tokenCount", "windowTopics"), replayCall("respond", "windowTopics", failure: "E.incompleteOutput")]
        XCTAssertTrue(SynthesisStageRecordingDriver.windowTopicProgress(calls: failedThree, failed: true) == (3, 3))
        // A section-summary failure reaches no window.
        XCTAssertTrue(SynthesisStageRecordingDriver.windowTopicProgress(calls: summary, failed: true) == (0, nil))
        XCTAssertEqual(SynthesisStageRecordingDriver.retriedWindowTopicIndices(calls: malformedSeven), [7])
        XCTAssertEqual(SynthesisStageRecordingDriver.retriedWindowTopicIndices(calls: allFifteen), [])
    }

    func testReplayCallDiagnosticsAreTextFree() throws {
        let encoded = try JSONEncoder().encode(replayCall("respond", "windowTopics", failure: "MLXGuidedGenerationRuntimeError.incompleteOutput"))
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys)
        XCTAssertEqual(keys, [
            "callIndex", "kind", "stage", "wallClockSeconds", "failure",
        ], "nil structural fields are omitted; there is no field for prompts, headings, or generated text")
        XCTAssertFalse(keys.contains { ["prompt", "heading", "headings", "text", "overview", "jsonText"].contains($0) })
    }

    func testReplayDerivesSectionWindowRangesFromItemCounts() {
        // Windows hold 2, 0 (abstained), 3, 1, 4 items: partitioned windows 0–3.
        XCTAssertEqual(
            SynthesisStageRecordingDriver.sectionWindowRanges(sectionItemCounts: [2, 4, 4], windowItemCounts: [2, 0, 3, 1, 4]),
            [[0, 0], [1, 2], [3, 3]]
        )
        XCTAssertNil(SynthesisStageRecordingDriver.sectionWindowRanges(sectionItemCounts: [3, 7], windowItemCounts: [2, 0, 3, 1, 4]),
                     "a boundary inside a window is not a window range")
        XCTAssertNil(SynthesisStageRecordingDriver.sectionWindowRanges(sectionItemCounts: [2, 4], windowItemCounts: [2, 0, 3, 1, 4]),
                     "sections that leave windows uncovered")
    }

    func testReplayStageLabelsFollowTheProductionInstructionSets() {
        XCTAssertEqual(SynthesisStageRecordingDriver.stage(for: MLXLectureNotesGenerator.windowTopicInstructions), "windowTopics")
        XCTAssertEqual(SynthesisStageRecordingDriver.stage(for: MLXLectureNotesGenerator.sectionTitleInstructions), "sectionTitles")
        XCTAssertEqual(SynthesisStageRecordingDriver.stage(for: MLXLectureNotesGenerator.sectionSummaryInstructions), "sectionSummaries")
        XCTAssertEqual(SynthesisStageRecordingDriver.stage(for: MLXLectureNotesGenerator.reductionInstructions), "reduction")
        XCTAssertEqual(SynthesisStageRecordingDriver.stage(for: MLXLectureSummaryGenerator.batchInstructions), "summaryBatch")
        XCTAssertEqual(SynthesisStageRecordingDriver.stage(for: MLXLectureSummaryGenerator.reductionInstructions), "summaryReduction")
        XCTAssertEqual(SynthesisStageRecordingDriver.stage(for: MLXLectureSummaryGenerator.finalSectionInstructions), "summaryFinalSection")
        XCTAssertEqual(SynthesisStageRecordingDriver.stage(for: "anything else"), "unknown")
    }

    /// Opt-in, real 8B/14B Notes synthesis over one earlier run's persisted
    /// window analyses — no transcript loading and no window-analysis calls.
    /// Enable with `LECTURE_RECORDER_RUN_MLX_SYNTHESIS_REPLAY=1`,
    /// `LECTURE_RECORDER_REPLAY_SOURCE_RUN_DIRECTORY=<earlier run directory>`,
    /// and `LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY`. Writes a fresh
    /// `mlx3-synthesis-replay-<session>-<runID>/`; never modifies the source.
    func testRealMLXNotesSynthesisReplayFromPersistedWindowAnalyses() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["LECTURE_RECORDER_RUN_MLX_SYNTHESIS_REPLAY"] == "1",
            "Set LECTURE_RECORDER_RUN_MLX_SYNTHESIS_REPLAY=1 to replay Notes synthesis."
        )
        let sourceDirectory = URL(fileURLWithPath: try XCTUnwrap(environment[MLXSynthesisReplaySource.sourceDirectoryEnvironmentKey]), isDirectory: true)
        let outputRoot = URL(fileURLWithPath: try XCTUnwrap(environment["LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY"]), isDirectory: true)
        let selection = try MLXAcceptanceModelSelection.resolve(environmentValue: environment[MLXAcceptanceModelSelection.environmentKey])
        let expectedProvenance = MLXNotesConfiguration.generationProvenance(for: selection.descriptor)
        let source = try MLXSynthesisReplaySource.load(runDirectory: sourceDirectory, expectedProvenance: expectedProvenance)
        let inputItems = source.analyses.flatMap(\.items)

        let realDriver = RealMLXSessionDriver(descriptor: selection.descriptor)
        guard case .available = await realDriver.availability() else {
            return XCTFail("Pinned MLX model assets are not provisioned/verified.")
        }
        let driver = SynthesisStageRecordingDriver(wrapped: realDriver)
        let generator = MLXLectureNotesGenerator(sessionDriver: driver, modelDescriptor: selection.descriptor)

        let runID = UUID()
        let runDirectory = outputRoot.appendingPathComponent("mlx3-synthesis-replay-\(source.identity.sessionID)-\(runID.uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        let start = AcceptanceDiagnosticLogger.startInstant()
        var document: LectureNotesDocument?
        var failure: String?
        do {
            document = try await generator.synthesize(analyses: source.analyses, generation: source.generation)
        } catch {
            failure = error.localizedDescription
        }
        let synthesisSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: start)
        let calls = await driver.calls
        let documentItems = document?.sections.flatMap(\.items)

        let model = MLXAcceptanceModelIdentity(selection)
        let result = SynthesisReplayResult(
            runID: runID.uuidString,
            sourceRunDirectory: sourceDirectory.lastPathComponent,
            sessionID: source.identity.sessionID,
            mlxModelSelection: model.mlxModelSelection,
            modelIdentifier: model.modelIdentifier,
            modelRevision: model.modelRevision,
            notesGenerationProvenance: source.generation.provenance,
            windowCount: source.analyses.count,
            inputItemCount: inputItems.count,
            synthesisSeconds: synthesisSeconds,
            outcome: document == nil ? "failed" : "succeeded",
            failure: failure,
            failingStage: failure == nil ? nil : SynthesisStageRecordingDriver.failureDiagnosis(calls: calls).stage,
            failurePhase: failure == nil ? nil : SynthesisStageRecordingDriver.failureDiagnosis(calls: calls).phase,
            expectedWindowTopicCalls: source.analyses.filter { !$0.items.isEmpty }.count,
            completedWindowTopicCalls: SynthesisStageRecordingDriver.windowTopicProgress(calls: calls, failed: failure != nil).completed,
            failingWindowTopicIndex: SynthesisStageRecordingDriver.windowTopicProgress(calls: calls, failed: failure != nil).failingWindowIndex,
            retriedWindowTopicIndices: SynthesisStageRecordingDriver.retriedWindowTopicIndices(calls: calls),
            sectionCount: document?.sections.count,
            sectionItemCounts: document?.sections.map(\.items.count),
            derivedSectionWindowRanges: document.flatMap { document in
                SynthesisStageRecordingDriver.sectionWindowRanges(
                    sectionItemCounts: document.sections.map(\.items.count),
                    windowItemCounts: source.analyses.map(\.items.count)
                )
            },
            derivedSectionRanges: document.map { document in
                var start = 0
                return document.sections.map { section in
                    defer { start += section.items.count }
                    return [start, start + section.items.count - 1]
                }
            },
            sectionHeadingLengths: document?.sections.map(\.heading.count),
            overviewCharacterCount: document?.overview.count,
            documentItemCount: documentItems?.count,
            documentPreservesInputItemsInOrder: documentItems.map { $0 == inputItems },
            calls: calls
        )
        try AtomicFileWriter.writeJSON(result, to: runDirectory.appendingPathComponent("synthesis-replay-result.json"))
        if let document {
            try AtomicFileWriter.writeJSON(document, to: runDirectory.appendingPathComponent("notes-document.json"))
        }

        let synthesized = try XCTUnwrap(document, "Notes synthesis failed at stage \(result.failingStage ?? "unknown"): \(failure ?? "")")
        XCTAssertEqual(documentItems, inputItems, "every input item appears exactly once, in order")
        XCTAssertFalse(synthesized.sections.isEmpty)
        XCTAssertFalse(synthesized.overview.isEmpty)
        XCTAssertTrue(synthesized.sections.count <= MLXLectureNotesGenerator.maximumSectionsPerDocument)
        XCTAssertEqual(synthesized.provenance, expectedProvenance)
    }

    private struct SliceDiagnosticIdentity: Encodable {
        var runID: String
        var sessionID: String
        var notesGenerationProvenance: LectureNotesGenerationProvenance
        var transcriptFingerprint: TranscriptSourceFingerprint
        var transcriptUnitCount: Int
        var plannedWindowCount: Int
        var requestedWindowIndices: [Int]
        var sliceRanges: [String: [Int]]
    }

    private struct SliceDiagnosticResult: Encodable {
        struct SliceRow: Encodable {
            var label: String
            var parentWindowIndex: Int
            var firstSequenceNumber: Int
            var lastSequenceNumber: Int
            var itemCount: Int
            var seconds: Double
        }
        struct ParentRow: Encodable {
            var windowIndex: Int
            var firstSequenceNumber: Int
            var lastSequenceNumber: Int
            var itemCount: Int
        }
        var runID: String
        var outcome: String
        var failure: String?
        var slices: [SliceRow]
        var parents: [ParentRow]
        var totalSeconds: Double
        var calls: [CallRecord]
        var persistenceWarnings: [String]
    }

    /// Opt-in real 4+4 coverage experiment: for each window index in
    /// `LECTURE_RECORDER_ACCEPTANCE_SLICE_WINDOW_INDICES`, analyzes the
    /// production-planned window as two contiguous halves with the
    /// unchanged production generator, and writes each slice's analysis and
    /// the merged parent result. Enable with
    /// `LECTURE_RECORDER_RUN_MLX_NOTES_SLICE_DIAGNOSTIC=1` plus the session
    /// ID, sessions root, output directory, and model variables. Never runs
    /// synthesis or Summary.
    func testRealMLXNotesSliceDiagnostic() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["LECTURE_RECORDER_RUN_MLX_NOTES_SLICE_DIAGNOSTIC"] == "1",
            "Set LECTURE_RECORDER_RUN_MLX_NOTES_SLICE_DIAGNOSTIC=1 to run the 4+4 Notes slice diagnostic."
        )
        let sessionID = try XCTUnwrap(environment["LECTURE_RECORDER_ACCEPTANCE_SESSION_ID"].flatMap(UUID.init(uuidString:)))
        let outputRoot = URL(fileURLWithPath: try XCTUnwrap(environment["LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY"]), isDirectory: true)
        let selection = try MLXAcceptanceModelSelection.resolve(environmentValue: environment[MLXAcceptanceModelSelection.environmentKey])
        let requested = try MLXNotesSliceDiagnostic.windowIndices(from: environment[MLXNotesSliceDiagnostic.windowsEnvironmentKey])
        let sessionsRoot = try MLXAcceptanceSessionsRoot.resolve(environmentValue: environment[MLXAcceptanceSessionsRoot.environmentKey])
        let transcript = try await MLXAcceptanceSessionsRoot.makeTranscriptLoader(root: sessionsRoot).loadCurrentSnapshot(sessionID: sessionID)
        let plan = NotesWindowPlan(windows: NotesWindowPlanner.plan(units: transcript.units, budget: MLXNotesConfiguration.windowBudget))
        try plan.validateCoversExactly(transcript)

        var work: [(parent: NotesInputWindow, slices: [MLXNotesSliceDiagnostic.Slice])] = []
        for index in requested {
            guard let parent = plan.windows.first(where: { $0.windowIndex == index }) else {
                throw MLXNotesSliceDiagnostic.SliceError.windowNotPlanned(index)
            }
            let units = transcript.units.filter { $0.sequenceNumber >= parent.firstSequenceNumber && $0.sequenceNumber <= parent.lastSequenceNumber }
            work.append((parent, try MLXNotesSliceDiagnostic.slices(of: parent, units: units)))
        }

        let realDriver = RealMLXSessionDriver(descriptor: selection.descriptor)
        guard case .available = await realDriver.availability() else {
            return XCTFail("Pinned MLX model assets are not provisioned/verified.")
        }
        let provenance = MLXNotesConfiguration.generationProvenance(for: selection.descriptor)
        let generation = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID, transcriptFingerprint: transcript.fingerprint, windowPlan: plan, provenance: provenance
        )
        let runID = UUID()
        let runDirectory = outputRoot.appendingPathComponent("mlx3-slice-diagnostic-\(sessionID.uuidString)-\(runID.uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try AtomicFileWriter.writeJSON(
            SliceDiagnosticIdentity(
                runID: runID.uuidString, sessionID: sessionID.uuidString, notesGenerationProvenance: provenance,
                transcriptFingerprint: transcript.fingerprint, transcriptUnitCount: transcript.units.count,
                plannedWindowCount: plan.windows.count, requestedWindowIndices: requested,
                sliceRanges: Dictionary(uniqueKeysWithValues: work.flatMap(\.slices).map {
                    ($0.label, [$0.window.firstSequenceNumber, $0.window.lastSequenceNumber])
                })
            ),
            to: runDirectory.appendingPathComponent("run-identity.json")
        )
        let driver = TimingSessionDriver(wrapped: realDriver, recordsURL: runDirectory.appendingPathComponent("call-records.json"))
        let progressURL = runDirectory.appendingPathComponent("run-progress.json")
        var progress = MLXAcceptanceRunProgress(runID: runID.uuidString)
        try progress.complete("runIdentity", writingTo: progressURL)
        let generator = MLXLectureNotesGenerator(sessionDriver: driver, modelDescriptor: selection.descriptor)

        let overallStart = AcceptanceDiagnosticLogger.startInstant()
        var sliceRows: [SliceDiagnosticResult.SliceRow] = []
        var parentRows: [SliceDiagnosticResult.ParentRow] = []
        var failure: String?
        do {
            for (parent, slices) in work {
                var analyses: [LectureNotesWindowAnalysis] = []
                for slice in slices {
                    await driver.setStage("slice:\(slice.label)")
                    let start = AcceptanceDiagnosticLogger.startInstant()
                    let analysis = try await generator.analyzeWindow(units: slice.units, window: slice.window, generation: generation)
                    sliceRows.append(.init(
                        label: slice.label, parentWindowIndex: parent.windowIndex,
                        firstSequenceNumber: slice.window.firstSequenceNumber, lastSequenceNumber: slice.window.lastSequenceNumber,
                        itemCount: analysis.items.count, seconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: start)
                    ))
                    analyses.append(analysis)
                    try AtomicFileWriter.writeJSON(analysis, to: runDirectory.appendingPathComponent("slice-analyses/slice_\(slice.label).json"))
                    try progress.complete("slice:\(slice.label)", writingTo: progressURL)
                }
                let merged = MLXNotesSliceDiagnostic.merge(parent: parent, sliceAnalyses: analyses)
                try AtomicFileWriter.writeJSON(
                    merged, to: runDirectory.appendingPathComponent("merged-parent-analyses/window_\(String(format: "%04d", parent.windowIndex)).json")
                )
                parentRows.append(.init(
                    windowIndex: parent.windowIndex, firstSequenceNumber: parent.firstSequenceNumber,
                    lastSequenceNumber: parent.lastSequenceNumber, itemCount: merged.items.count
                ))
            }
        } catch {
            failure = error.localizedDescription
        }
        let result = SliceDiagnosticResult(
            runID: runID.uuidString, outcome: failure == nil ? "succeeded" : "failed", failure: failure,
            slices: sliceRows, parents: parentRows,
            totalSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: overallStart),
            calls: await driver.records, persistenceWarnings: await driver.persistenceWarnings
        )
        try AtomicFileWriter.writeJSON(result, to: runDirectory.appendingPathComponent("slice-diagnostic-result.json"))
        if failure == nil { try progress.finish(writingTo: progressURL) }
        XCTAssertNil(failure, failure ?? "")
        XCTAssertEqual(parentRows.map(\.windowIndex), requested)
        XCTAssertTrue(result.persistenceWarnings.isEmpty, result.persistenceWarnings.joined(separator: "; "))
    }

    private struct DownstreamReplayIdentity: Encodable {
        var runID: String
        var sourceRunDirectory: String
        var sessionID: String
        var generationID: String
        var sourceAnalysesNotesProvenance: LectureNotesGenerationProvenance
        var synthesisNotesProvenance: LectureNotesGenerationProvenance
        var provenanceRestamped: Bool
        var summaryProvenance: LectureNotesGenerationProvenance
        var windowCount: Int
        var inputItemCount: Int
    }

    private struct DownstreamReplayResult: Encodable {
        var runID: String
        var outcome: String
        var failure: String?
        var sectionSummaryAcceptedMaximum: Int
        var sectionSummaryGrammarCeiling: Int
        var sectionTitleAcceptedMaximum: Int
        var sectionTitleGrammarCeiling: Int
        var sectionTitleLengths: [Int]?
        var summaryBatchCoverage: [MLXSummaryBatchCoverage]?
        var summaryCitedSourceItemCount: Int?
        var summaryUncitedSourceIndices: [Int]?
        var windowAnalysisCalls: Int
        var sectionCount: Int?
        var sectionWindowItemCounts: [[Int]]?
        var sectionHeadings: [String]?
        var overview: String?
        var documentPreservesInputItemsInOrder: Bool?
        var synthesisSeconds: Double?
        var summaryGenerationID: String?
        var summaryPlannedBatchCount: Int?
        var summaryPerBatchSeconds: [TimedBatch]
        var summaryDocumentSeconds: Double?
        var summarySectionCount: Int?
        var summaryPassageCount: Int?
        var textAnomalies: [MLXAcceptanceTextDiagnostics.ScriptAnomaly]
        var totalSeconds: Double
        var calls: [CallRecord]
        var persistenceWarnings: [String]
    }

    /// Opt-in real downstream replay: the persisted window analyses of one
    /// earlier complete run (never re-generated) → current Notes synthesis →
    /// Notes document → current Summary → Summary document, on one shared
    /// real driver, in a fresh `mlx3-synthesis-summary-replay-…` directory.
    /// Enable with `LECTURE_RECORDER_RUN_MLX_SYNTHESIS_SUMMARY_REPLAY=1`,
    /// `LECTURE_RECORDER_REPLAY_SOURCE_RUN_DIRECTORY`,
    /// `LECTURE_RECORDER_REPLAY_SOURCE_NOTES_RECIPE`, the output directory,
    /// the sessions root, and the model variable.
    func testRealMLXNotesSynthesisAndSummaryReplayFromPersistedWindowAnalyses() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["LECTURE_RECORDER_RUN_MLX_SYNTHESIS_SUMMARY_REPLAY"] == "1",
            "Set LECTURE_RECORDER_RUN_MLX_SYNTHESIS_SUMMARY_REPLAY=1 to replay synthesis and Summary from persisted window analyses."
        )
        let sourceDirectory = URL(fileURLWithPath: try XCTUnwrap(environment[MLXSynthesisReplaySource.sourceDirectoryEnvironmentKey]), isDirectory: true)
        let outputRoot = URL(fileURLWithPath: try XCTUnwrap(environment["LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY"]), isDirectory: true)
        let selection = try MLXAcceptanceModelSelection.resolve(environmentValue: environment[MLXAcceptanceModelSelection.environmentKey])
        var sourceProvenance = MLXNotesConfiguration.generationProvenance(for: selection.descriptor)
        sourceProvenance.recipeVersion = try XCTUnwrap(environment[MLXSummaryReplaySource.sourceNotesRecipeEnvironmentKey])
        let source = try MLXSynthesisReplaySource.load(runDirectory: sourceDirectory, expectedProvenance: sourceProvenance)
        let generation = try MLXDownstreamReplay.restampedForCurrentSynthesis(source.generation, descriptor: selection.descriptor)
        let sessionID = generation.sessionID
        let inputItems = source.analyses.flatMap(\.items)
        let sessionsRoot = try MLXAcceptanceSessionsRoot.resolve(environmentValue: environment[MLXAcceptanceSessionsRoot.environmentKey])
        let transcript = try await MLXAcceptanceSessionsRoot.makeTranscriptLoader(root: sessionsRoot).loadCurrentSnapshot(sessionID: sessionID)
        XCTAssertEqual(transcript.fingerprint, generation.transcriptFingerprint, "source transcript changed since the analyses were generated")

        let realDriver = RealMLXSessionDriver(descriptor: selection.descriptor)
        guard case .available = await realDriver.availability() else {
            return XCTFail("Pinned MLX model assets are not provisioned/verified.")
        }
        let runID = UUID()
        let runDirectory = outputRoot.appendingPathComponent("mlx3-synthesis-summary-replay-\(sessionID.uuidString)-\(runID.uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try AtomicFileWriter.writeJSON(
            DownstreamReplayIdentity(
                runID: runID.uuidString, sourceRunDirectory: sourceDirectory.lastPathComponent,
                sessionID: sessionID.uuidString, generationID: generation.generationID.uuidString,
                sourceAnalysesNotesProvenance: source.generation.provenance, synthesisNotesProvenance: generation.provenance,
                provenanceRestamped: source.generation.provenance != generation.provenance,
                summaryProvenance: MLXSummaryConfiguration.generationProvenance(for: selection.descriptor),
                windowCount: source.analyses.count, inputItemCount: inputItems.count
            ),
            to: runDirectory.appendingPathComponent("run-identity.json")
        )
        let driver = TimingSessionDriver(wrapped: realDriver, recordsURL: runDirectory.appendingPathComponent("call-records.json"))
        let progressURL = runDirectory.appendingPathComponent("run-progress.json")
        var progress = MLXAcceptanceRunProgress(runID: runID.uuidString)
        try progress.complete("sourceLoaded", writingTo: progressURL)

        let notesGenerator = MLXLectureNotesGenerator(sessionDriver: driver, modelDescriptor: selection.descriptor)
        let summaryGenerator = MLXLectureSummaryGenerator(sessionDriver: driver, modelDescriptor: selection.descriptor)
        let overallStart = AcceptanceDiagnosticLogger.startInstant()
        var notesDocument: LectureNotesDocument?
        var synthesisSeconds: Double?
        var summaryGeneration: LectureSummaryGenerationRecord?
        var plan: LectureSummaryPlan?
        var summaryAnalyses: [LectureSummaryAnalysis] = []
        var perBatchSeconds: [TimedBatch] = []
        var summaryDocument: LectureSummaryDocument?
        var summaryDocumentSeconds: Double?
        var failure: String?
        do {
            await driver.setStage("notesSynthesis")
            let synthesisStart = AcceptanceDiagnosticLogger.startInstant()
            let document = try await notesGenerator.synthesize(analyses: source.analyses, generation: generation)
            synthesisSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: synthesisStart)
            notesDocument = document
            try AtomicFileWriter.writeJSON(document, to: runDirectory.appendingPathComponent("notes-document.json"))
            try progress.complete("notesSynthesis", writingTo: progressURL)

            let summarySource = try LectureSummarySourceBuilder.build(
                generation: generation, analyses: source.analyses, document: document, transcriptSnapshot: transcript
            )
            await driver.setStage("summaryPlan")
            let madePlan = try await summaryGenerator.makePlan(for: summarySource)
            plan = madePlan
            try AtomicFileWriter.writeJSON(madePlan, to: runDirectory.appendingPathComponent("summary-plan.json"))
            try progress.complete("summaryPlan", writingTo: progressURL)
            let record = LectureSummaryGenerationRecord.newGeneration(
                sessionID: sessionID,
                sourceNotesGenerationID: generation.generationID,
                transcriptFingerprint: transcript.fingerprint,
                sourceNotesDocumentFingerprint: summarySource.sourceNotesDocumentFingerprint,
                batchPlan: madePlan,
                provenance: MLXSummaryConfiguration.generationProvenance(for: selection.descriptor)
            )
            summaryGeneration = record
            for batch in madePlan.batches.sorted(by: { $0.batchIndex < $1.batchIndex }) {
                await driver.setStage("summaryBatch:\(batch.batchIndex)")
                let batchStart = AcceptanceDiagnosticLogger.startInstant()
                let analysis = try await summaryGenerator.generateAnalysis(for: batch, generation: record, source: summarySource)
                try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: record, source: summarySource)
                perBatchSeconds.append(TimedBatch(batchIndex: batch.batchIndex, seconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: batchStart)))
                summaryAnalyses.append(analysis)
                try AtomicFileWriter.writeJSON(analysis, to: runDirectory.appendingPathComponent("summary-batch-analyses/batch_\(String(format: "%04d", batch.batchIndex)).json"))
                try progress.complete("summaryBatch:\(batch.batchIndex)", writingTo: progressURL)
            }
            await driver.setStage("summaryDocument")
            let documentStart = AcceptanceDiagnosticLogger.startInstant()
            let made = try await summaryGenerator.generateDocument(from: summaryAnalyses, generation: record, source: summarySource)
            summaryDocumentSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: documentStart)
            try LectureSummaryIntegrityValidator.validate(document: made, generation: record, source: summarySource)
            summaryDocument = made
            try AtomicFileWriter.writeJSON(made, to: runDirectory.appendingPathComponent("summary-document.json"))
            try progress.complete("summaryDocument", writingTo: progressURL)
        } catch {
            failure = error.localizedDescription
        }

        var anomalies: [MLXAcceptanceTextDiagnostics.ScriptAnomaly] = []
        if let notesDocument { anomalies += MLXAcceptanceTextDiagnostics.scriptAnomalies(notes: notesDocument) }
        for analysis in summaryAnalyses {
            for (index, passage) in analysis.passages.enumerated() {
                anomalies += MLXAcceptanceTextDiagnostics.scriptAnomalies(in: passage.text, location: "summaryBatch:\(analysis.batchIndex)/passage:\(index)")
            }
        }
        if let summaryDocument { anomalies += MLXAcceptanceTextDiagnostics.scriptAnomalies(summary: summaryDocument) }
        try AtomicFileWriter.writeJSON(anomalies, to: runDirectory.appendingPathComponent("script-anomalies.json"))

        let calls = await driver.records
        let windowRanges = notesDocument.map { _ in (try? MLXLectureNotesGenerator.balancedSectionWindowRanges(
            windowCount: source.analyses.filter { !$0.items.isEmpty }.count
        )) ?? [] }
        let nonEmpty = source.analyses.filter { !$0.items.isEmpty }
        let coverage = plan.map { MLXSummaryBatchCoverage.compute(plan: $0, analyses: summaryAnalyses) }
        let result = DownstreamReplayResult(
            runID: runID.uuidString,
            outcome: summaryDocument == nil ? "failed" : "succeeded",
            failure: failure,
            sectionSummaryAcceptedMaximum: MLXLectureNotesGenerator.maximumSectionSummaryLength,
            sectionSummaryGrammarCeiling: MLXLectureNotesGenerator.sectionSummaryGrammarCeiling,
            sectionTitleAcceptedMaximum: MLXLectureNotesGenerator.maximumSectionTitleLength,
            sectionTitleGrammarCeiling: MLXLectureNotesGenerator.sectionTitleGrammarCeiling,
            sectionTitleLengths: notesDocument?.sections.map(\.heading.count),
            summaryBatchCoverage: coverage,
            summaryCitedSourceItemCount: coverage.map { batches in batches.reduce(0) { $0 + $1.citedPositions.count } },
            summaryUncitedSourceIndices: coverage?.flatMap(\.uncitedSourceIndices),
            windowAnalysisCalls: calls.filter { $0.instructionStage == "windowAnalysis" }.count,
            sectionCount: notesDocument?.sections.count,
            sectionWindowItemCounts: windowRanges.map { $0.map { range in range.map { nonEmpty[$0].items.count } } },
            sectionHeadings: notesDocument?.sections.map(\.heading),
            overview: notesDocument?.overview,
            documentPreservesInputItemsInOrder: notesDocument.map { $0.sections.flatMap(\.items) == inputItems },
            synthesisSeconds: synthesisSeconds,
            summaryGenerationID: summaryGeneration?.generationID.uuidString,
            summaryPlannedBatchCount: plan?.batches.count,
            summaryPerBatchSeconds: perBatchSeconds,
            summaryDocumentSeconds: summaryDocumentSeconds,
            summarySectionCount: summaryDocument?.sections.count,
            summaryPassageCount: summaryDocument?.sections.reduce(0) { $0 + $1.passages.count },
            textAnomalies: anomalies,
            totalSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: overallStart),
            calls: calls,
            persistenceWarnings: await driver.persistenceWarnings
        )
        try AtomicFileWriter.writeJSON(result, to: runDirectory.appendingPathComponent("downstream-replay-result.json"))
        if summaryDocument != nil { try progress.finish(writingTo: progressURL) }

        XCTAssertNil(failure, failure ?? "")
        XCTAssertEqual(result.windowAnalysisCalls, 0, "window analysis is never re-run")
        let synthesized = try XCTUnwrap(notesDocument)
        XCTAssertEqual(synthesized.sections.flatMap(\.items), inputItems, "every input item exactly once, in order")
        XCTAssertEqual(calls.filter { $0.kind == "respond" && $0.instructionStage == "sectionSummaries" }.count, synthesized.sections.count,
                       "one section-summary request per section")
        XCTAssertEqual(synthesized.provenance, MLXNotesConfiguration.generationProvenance(for: selection.descriptor))
        let summary = try XCTUnwrap(summaryDocument)
        XCTAssertEqual(summary.provenance, MLXSummaryConfiguration.generationProvenance(for: selection.descriptor))
        XCTAssertEqual(summary.sourceNotesGenerationID, generation.generationID)
        XCTAssertTrue(result.persistenceWarnings.isEmpty, result.persistenceWarnings.joined(separator: "; "))
    }

    private struct SummaryReplayResult: Encodable {
        var runID: String
        var sourceRunDirectory: String
        var sessionID: String
        var sourceNotesGenerationID: String
        var sourceNotesProvenance: LectureNotesGenerationProvenance
        var summaryGenerationID: String
        var summaryProvenance: LectureNotesGenerationProvenance
        var sourceItemCount: Int
        var plannedBatchCount: Int?
        var planningSeconds: Double?
        var perBatchSeconds: [TimedBatch]
        var analysisPassageFidelityCounts: [String: Int]
        var documentSeconds: Double?
        var documentSectionCount: Int?
        var documentPassageCount: Int?
        var documentPassageFidelityCounts: [String: Int]?
        var outcome: String
        var failure: String?
        var totalSeconds: Double
        var calls: [CallRecord]
        var persistenceWarnings: [String]
    }

    /// Opt-in real Summary-only replay over one earlier complete run's
    /// persisted Notes (never regenerated). Enable with
    /// `LECTURE_RECORDER_RUN_MLX_SUMMARY_REPLAY=1`,
    /// `LECTURE_RECORDER_REPLAY_SOURCE_RUN_DIRECTORY`,
    /// `LECTURE_RECORDER_REPLAY_SOURCE_NOTES_RECIPE` (the source run's Notes
    /// recipe), `LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY`, and the
    /// session's `LECTURE_RECORDER_ACCEPTANCE_SESSIONS_ROOT`. Writes a fresh
    /// `mlx3-summary-replay-…` directory with stage progress and call
    /// records persisted as they happen.
    func testRealMLXSummaryReplayFromPersistedNotesDocument() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["LECTURE_RECORDER_RUN_MLX_SUMMARY_REPLAY"] == "1",
            "Set LECTURE_RECORDER_RUN_MLX_SUMMARY_REPLAY=1 to replay Summary from persisted Notes."
        )
        let sourceDirectory = URL(fileURLWithPath: try XCTUnwrap(environment[MLXSynthesisReplaySource.sourceDirectoryEnvironmentKey]), isDirectory: true)
        let outputRoot = URL(fileURLWithPath: try XCTUnwrap(environment["LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY"]), isDirectory: true)
        let selection = try MLXAcceptanceModelSelection.resolve(environmentValue: environment[MLXAcceptanceModelSelection.environmentKey])
        var expectedNotesProvenance = MLXNotesConfiguration.generationProvenance(for: selection.descriptor)
        expectedNotesProvenance.recipeVersion = try XCTUnwrap(environment[MLXSummaryReplaySource.sourceNotesRecipeEnvironmentKey])
        let source = try MLXSummaryReplaySource.load(runDirectory: sourceDirectory, expectedNotesProvenance: expectedNotesProvenance)
        let sessionID = source.notes.generation.sessionID
        let sessionsRoot = try MLXAcceptanceSessionsRoot.resolve(environmentValue: environment[MLXAcceptanceSessionsRoot.environmentKey])
        let transcript = try await MLXAcceptanceSessionsRoot.makeTranscriptLoader(root: sessionsRoot).loadCurrentSnapshot(sessionID: sessionID)
        XCTAssertEqual(transcript.fingerprint, source.notes.generation.transcriptFingerprint, "source transcript changed since the Notes were generated")
        let summarySource = try LectureSummarySourceBuilder.build(
            generation: source.notes.generation, analyses: source.notes.analyses,
            document: source.document, transcriptSnapshot: transcript
        )

        let realDriver = RealMLXSessionDriver(descriptor: selection.descriptor)
        guard case .available = await realDriver.availability() else {
            return XCTFail("Pinned MLX model assets are not provisioned/verified.")
        }
        let runID = UUID()
        let runDirectory = outputRoot.appendingPathComponent("mlx3-summary-replay-\(sessionID.uuidString)-\(runID.uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let driver = TimingSessionDriver(wrapped: realDriver, recordsURL: runDirectory.appendingPathComponent("call-records.json"))
        let progressURL = runDirectory.appendingPathComponent("run-progress.json")
        var progress = MLXAcceptanceRunProgress(runID: runID.uuidString)
        try progress.complete("sourceLoaded", writingTo: progressURL)

        let generator = MLXLectureSummaryGenerator(sessionDriver: driver, modelDescriptor: selection.descriptor)
        let overallStart = AcceptanceDiagnosticLogger.startInstant()
        var plan: LectureSummaryPlan?
        var planningSeconds: Double?
        var analyses: [LectureSummaryAnalysis] = []
        var perBatchSeconds: [TimedBatch] = []
        var document: LectureSummaryDocument?
        var documentSeconds: Double?
        var failure: String?
        var generation: LectureSummaryGenerationRecord?
        do {
            await driver.setStage("summaryPlan")
            let planStart = AcceptanceDiagnosticLogger.startInstant()
            let madePlan = try await generator.makePlan(for: summarySource)
            plan = madePlan
            planningSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: planStart)
            try progress.complete("summaryPlan", writingTo: progressURL)
            let record = LectureSummaryGenerationRecord.newGeneration(
                sessionID: sessionID,
                sourceNotesGenerationID: source.notes.generation.generationID,
                transcriptFingerprint: transcript.fingerprint,
                sourceNotesDocumentFingerprint: summarySource.sourceNotesDocumentFingerprint,
                batchPlan: madePlan,
                provenance: MLXSummaryConfiguration.generationProvenance(for: selection.descriptor)
            )
            generation = record
            for batch in madePlan.batches.sorted(by: { $0.batchIndex < $1.batchIndex }) {
                await driver.setStage("summaryBatch:\(batch.batchIndex)")
                let batchStart = AcceptanceDiagnosticLogger.startInstant()
                let analysis = try await generator.generateAnalysis(for: batch, generation: record, source: summarySource)
                try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: record, source: summarySource)
                perBatchSeconds.append(TimedBatch(batchIndex: batch.batchIndex, seconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: batchStart)))
                analyses.append(analysis)
                try AtomicFileWriter.writeJSON(analysis, to: runDirectory.appendingPathComponent("summary-batch-analyses/batch_\(String(format: "%04d", batch.batchIndex)).json"))
                try progress.complete("summaryBatch:\(batch.batchIndex)", writingTo: progressURL)
            }
            await driver.setStage("summaryDocument")
            let documentStart = AcceptanceDiagnosticLogger.startInstant()
            let made = try await generator.generateDocument(from: analyses, generation: record, source: summarySource)
            documentSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: documentStart)
            try LectureSummaryIntegrityValidator.validate(document: made, generation: record, source: summarySource)
            document = made
            try AtomicFileWriter.writeJSON(made, to: runDirectory.appendingPathComponent("summary-document.json"))
            try progress.complete("summaryDocument", writingTo: progressURL)
        } catch {
            failure = error.localizedDescription
        }

        func fidelityCounts(_ passages: [LectureSummaryPassage]) -> [String: Int] {
            Dictionary(grouping: passages, by: \.fidelity.rawValue).mapValues(\.count)
        }
        let result = SummaryReplayResult(
            runID: runID.uuidString,
            sourceRunDirectory: sourceDirectory.lastPathComponent,
            sessionID: sessionID.uuidString,
            sourceNotesGenerationID: source.notes.generation.generationID.uuidString,
            sourceNotesProvenance: source.notes.generation.provenance,
            summaryGenerationID: generation?.generationID.uuidString ?? "",
            summaryProvenance: generator.provenance,
            sourceItemCount: summarySource.sourceItems.count,
            plannedBatchCount: plan?.batches.count,
            planningSeconds: planningSeconds,
            perBatchSeconds: perBatchSeconds,
            analysisPassageFidelityCounts: fidelityCounts(analyses.flatMap(\.passages)),
            documentSeconds: documentSeconds,
            documentSectionCount: document?.sections.count,
            documentPassageCount: document?.sections.reduce(0) { $0 + $1.passages.count },
            documentPassageFidelityCounts: document.map { fidelityCounts($0.sections.flatMap(\.passages)) },
            outcome: document == nil ? "failed" : "succeeded",
            failure: failure,
            totalSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: overallStart),
            calls: await driver.records,
            persistenceWarnings: await driver.persistenceWarnings
        )
        try AtomicFileWriter.writeJSON(result, to: runDirectory.appendingPathComponent("summary-replay-result.json"))
        if document != nil { try progress.finish(writingTo: progressURL) }

        let completed = try XCTUnwrap(document, "Summary replay failed: \(failure ?? "")")
        XCTAssertFalse(completed.sections.isEmpty)
        XCTAssertEqual(completed.provenance, MLXSummaryConfiguration.generationProvenance(for: selection.descriptor))
        XCTAssertTrue(result.persistenceWarnings.isEmpty, result.persistenceWarnings.joined(separator: "; "))
    }

    /// One Notes section's share of a Summary v5 replay.
    private struct AcceptedNotesSectionReport: Encodable {
        var notesSectionIndex: Int
        var notesHeading: String
        var noteCount: Int
        var firstSourceIndex: Int
        var lastSourceIndex: Int
        var batchIndices: [Int]
        var batchPassageCount: Int
        var summarySectionIndex: Int?
        var summaryHeading: String?
        var finalPassageCount: Int?
        var finalCitedSourceIndices: [Int]?
    }

    private struct AcceptedNotesSummaryReplayResult: Encodable {
        var runID: String
        var outcome: String
        var failure: String?
        var analysesRunDirectory: String
        var notesDocumentRunDirectory: String
        var notesGenerationID: String
        var notesProvenance: LectureNotesGenerationProvenance
        var notesDocumentSHA256Before: String
        var notesDocumentSHA256After: String
        var summaryGenerationID: String?
        var summaryProvenance: LectureNotesGenerationProvenance
        var windowAnalysisCalls: Int
        var notesSynthesisCalls: Int
        var summaryCallsByInstructionStage: [String: Int]
        var plannedBatchCount: Int?
        var batchCoverage: [MLXSummaryBatchCoverage]?
        var batchStageCitedSourceItemCount: Int?
        var batchStageUncitedSourceIndices: [Int]?
        var sections: [AcceptedNotesSectionReport]
        var finalDocumentCitedSourceItemCount: Int?
        var finalDocumentUncitedSourceIndices: [Int]?
        var perBatchSeconds: [TimedBatch]
        var documentSeconds: Double?
        var totalSeconds: Double
        var textAnomalies: [MLXAcceptanceTextDiagnostics.ScriptAnomaly]
        var calls: [CallRecord]
        var persistenceWarnings: [String]
    }

    /// Opt-in real Summary-only replay over an ACCEPTED Notes document from
    /// a downstream replay (for example the v15 document of run C92E76B8),
    /// whose window analyses live in the earlier source run it re-stamped.
    /// Neither window analysis nor Notes synthesis runs: the analyses are
    /// re-stamped exactly as the downstream replay did, the accepted
    /// document must belong to them (same generation, current Notes
    /// provenance, identical items in order), and it is only read — its
    /// bytes are hashed before and after. Enable with
    /// `LECTURE_RECORDER_RUN_MLX_ACCEPTED_NOTES_SUMMARY_REPLAY=1`,
    /// `LECTURE_RECORDER_REPLAY_SOURCE_RUN_DIRECTORY` (the analyses run),
    /// `LECTURE_RECORDER_REPLAY_SOURCE_NOTES_RECIPE` (its recipe),
    /// `LECTURE_RECORDER_REPLAY_NOTES_DOCUMENT_RUN_DIRECTORY` (the accepted
    /// document's run), the output directory, the sessions root, and the
    /// model variable. Writes a fresh `mlx3-summary-v5-replay-…` directory.
    func testRealMLXSummaryReplayFromAcceptedNotesDocument() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["LECTURE_RECORDER_RUN_MLX_ACCEPTED_NOTES_SUMMARY_REPLAY"] == "1",
            "Set LECTURE_RECORDER_RUN_MLX_ACCEPTED_NOTES_SUMMARY_REPLAY=1 to replay Summary from an accepted Notes document."
        )
        let analysesDirectory = URL(fileURLWithPath: try XCTUnwrap(environment[MLXSynthesisReplaySource.sourceDirectoryEnvironmentKey]), isDirectory: true)
        let documentDirectory = URL(fileURLWithPath: try XCTUnwrap(environment["LECTURE_RECORDER_REPLAY_NOTES_DOCUMENT_RUN_DIRECTORY"]), isDirectory: true)
        let outputRoot = URL(fileURLWithPath: try XCTUnwrap(environment["LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY"]), isDirectory: true)
        let selection = try MLXAcceptanceModelSelection.resolve(environmentValue: environment[MLXAcceptanceModelSelection.environmentKey])
        var sourceProvenance = MLXNotesConfiguration.generationProvenance(for: selection.descriptor)
        sourceProvenance.recipeVersion = try XCTUnwrap(environment[MLXSummaryReplaySource.sourceNotesRecipeEnvironmentKey])
        let source = try MLXSynthesisReplaySource.load(runDirectory: analysesDirectory, expectedProvenance: sourceProvenance)
        let notesGeneration = try MLXDownstreamReplay.restampedForCurrentSynthesis(source.generation, descriptor: selection.descriptor)

        let documentURL = documentDirectory.appendingPathComponent("notes-document.json")
        func documentSHA256() throws -> String {
            MLXAcceptanceTextDiagnostics.sha256Hex(String(decoding: try Data(contentsOf: documentURL), as: UTF8.self))
        }
        let documentHashBefore = try documentSHA256()
        let notesDocument = try AtomicFileWriter.readJSON(LectureNotesDocument.self, from: documentURL)
        XCTAssertEqual(notesDocument.generationID, notesGeneration.generationID, "the accepted document belongs to the analyses' generation")
        XCTAssertEqual(notesDocument.provenance, notesGeneration.provenance, "the accepted document was synthesized under the current Notes recipe")
        XCTAssertEqual(notesDocument.transcriptFingerprint, notesGeneration.transcriptFingerprint)
        XCTAssertEqual(notesDocument.sections.flatMap(\.items), source.analyses.flatMap(\.items), "every analysed item exactly once, in order")

        let sessionID = notesGeneration.sessionID
        let sessionsRoot = try MLXAcceptanceSessionsRoot.resolve(environmentValue: environment[MLXAcceptanceSessionsRoot.environmentKey])
        let transcript = try await MLXAcceptanceSessionsRoot.makeTranscriptLoader(root: sessionsRoot).loadCurrentSnapshot(sessionID: sessionID)
        XCTAssertEqual(transcript.fingerprint, notesGeneration.transcriptFingerprint, "source transcript changed since the analyses were generated")
        let summarySource = try LectureSummarySourceBuilder.build(
            generation: notesGeneration, analyses: source.analyses, document: notesDocument, transcriptSnapshot: transcript
        )

        let realDriver = RealMLXSessionDriver(descriptor: selection.descriptor)
        guard case .available = await realDriver.availability() else {
            return XCTFail("Pinned MLX model assets are not provisioned/verified.")
        }
        let runID = UUID()
        let runDirectory = outputRoot.appendingPathComponent("mlx3-summary-v5-replay-\(sessionID.uuidString)-\(runID.uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let summaryProvenance = MLXSummaryConfiguration.generationProvenance(for: selection.descriptor)
        try AtomicFileWriter.writeJSON(
            DownstreamReplayIdentity(
                runID: runID.uuidString, sourceRunDirectory: analysesDirectory.lastPathComponent,
                sessionID: sessionID.uuidString, generationID: notesGeneration.generationID.uuidString,
                sourceAnalysesNotesProvenance: source.generation.provenance, synthesisNotesProvenance: notesDocument.provenance,
                provenanceRestamped: source.generation.provenance != notesGeneration.provenance,
                summaryProvenance: summaryProvenance,
                windowCount: source.analyses.count, inputItemCount: summarySource.sourceItems.count
            ),
            to: runDirectory.appendingPathComponent("run-identity.json")
        )
        let driver = TimingSessionDriver(wrapped: realDriver, recordsURL: runDirectory.appendingPathComponent("call-records.json"))
        let progressURL = runDirectory.appendingPathComponent("run-progress.json")
        var progress = MLXAcceptanceRunProgress(runID: runID.uuidString)
        try progress.complete("sourceLoaded", writingTo: progressURL)

        let generator = MLXLectureSummaryGenerator(sessionDriver: driver, modelDescriptor: selection.descriptor)
        let overallStart = AcceptanceDiagnosticLogger.startInstant()
        var plan: LectureSummaryPlan?
        var generation: LectureSummaryGenerationRecord?
        var analyses: [LectureSummaryAnalysis] = []
        var perBatchSeconds: [TimedBatch] = []
        var document: LectureSummaryDocument?
        var documentSeconds: Double?
        var failure: String?
        do {
            await driver.setStage("summaryPlan")
            let madePlan = try await generator.makePlan(for: summarySource)
            plan = madePlan
            try AtomicFileWriter.writeJSON(madePlan, to: runDirectory.appendingPathComponent("summary-plan.json"))
            try progress.complete("summaryPlan", writingTo: progressURL)
            let record = LectureSummaryGenerationRecord.newGeneration(
                sessionID: sessionID,
                sourceNotesGenerationID: notesGeneration.generationID,
                transcriptFingerprint: transcript.fingerprint,
                sourceNotesDocumentFingerprint: summarySource.sourceNotesDocumentFingerprint,
                batchPlan: madePlan,
                provenance: summaryProvenance
            )
            generation = record
            try AtomicFileWriter.writeJSON(record, to: runDirectory.appendingPathComponent("summary-generation.json"))
            for batch in madePlan.batches.sorted(by: { $0.batchIndex < $1.batchIndex }) {
                await driver.setStage("summaryBatch:\(batch.batchIndex)")
                let batchStart = AcceptanceDiagnosticLogger.startInstant()
                let analysis = try await generator.generateAnalysis(for: batch, generation: record, source: summarySource)
                try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: record, source: summarySource)
                perBatchSeconds.append(TimedBatch(batchIndex: batch.batchIndex, seconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: batchStart)))
                analyses.append(analysis)
                try AtomicFileWriter.writeJSON(analysis, to: runDirectory.appendingPathComponent("summary-batch-analyses/batch_\(String(format: "%04d", batch.batchIndex)).json"))
                try progress.complete("summaryBatch:\(batch.batchIndex)", writingTo: progressURL)
            }
            await driver.setStage("summaryDocument")
            let documentStart = AcceptanceDiagnosticLogger.startInstant()
            let made = try await generator.generateDocument(from: analyses, generation: record, source: summarySource)
            documentSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: documentStart)
            try LectureSummaryIntegrityValidator.validate(document: made, generation: record, source: summarySource)
            document = made
            try AtomicFileWriter.writeJSON(made, to: runDirectory.appendingPathComponent("summary-document.json"))
            try progress.complete("summaryDocument", writingTo: progressURL)
        } catch {
            failure = error.localizedDescription
        }

        // Evidence, computed from the frozen source — not from the model.
        let sourceIndexByID = Dictionary(uniqueKeysWithValues: summarySource.sourceItems.map { ($0.item.id, $0.sourceIndex) })
        let nonEmptySections = notesDocument.sections.enumerated().filter { !$0.element.items.isEmpty }
        var nextIndex = 0
        let sectionRanges: [(index: Int, section: LectureNoteSection, range: ClosedRange<Int>)] = nonEmptySections.map { entry in
            defer { nextIndex += entry.element.items.count }
            return (entry.offset, entry.element, nextIndex...(nextIndex + entry.element.items.count - 1))
        }
        let batchCoverage = plan.map { MLXSummaryBatchCoverage.compute(plan: $0, analyses: analyses) }
        let finalCited = Set(document?.sections.flatMap { $0.passages.flatMap { $0.supportingNoteItemIDs.compactMap { sourceIndexByID[$0] } } } ?? [])
        let sectionReports = sectionRanges.enumerated().map { position, entry -> AcceptedNotesSectionReport in
            let batches = (plan?.batches ?? []).filter { entry.range.contains($0.firstSourceItemIndex) }
            let batchIndices = batches.map(\.batchIndex)
            let summarySection = document.flatMap { position < $0.sections.count ? $0.sections[position] : nil }
            return AcceptedNotesSectionReport(
                notesSectionIndex: entry.index,
                notesHeading: entry.section.heading,
                noteCount: entry.section.items.count,
                firstSourceIndex: entry.range.lowerBound,
                lastSourceIndex: entry.range.upperBound,
                batchIndices: batchIndices,
                batchPassageCount: analyses.filter { batchIndices.contains($0.batchIndex) }.reduce(0) { $0 + $1.passages.count },
                summarySectionIndex: summarySection == nil ? nil : position,
                summaryHeading: summarySection?.heading,
                finalPassageCount: summarySection?.passages.count,
                finalCitedSourceIndices: summarySection.map { Set($0.passages.flatMap { $0.supportingNoteItemIDs.compactMap { sourceIndexByID[$0] } }).sorted() }
            )
        }
        var anomalies: [MLXAcceptanceTextDiagnostics.ScriptAnomaly] = []
        for analysis in analyses {
            for (index, passage) in analysis.passages.enumerated() {
                anomalies += MLXAcceptanceTextDiagnostics.scriptAnomalies(in: passage.text, location: "summaryBatch:\(analysis.batchIndex)/passage:\(index)")
            }
        }
        if let document { anomalies += MLXAcceptanceTextDiagnostics.scriptAnomalies(summary: document) }
        let calls = await driver.records
        let notesSynthesisStages: Set<String> = ["sectionSummaries", "windowTopics", "sectionTitles", "reduction"]
        let result = AcceptedNotesSummaryReplayResult(
            runID: runID.uuidString,
            outcome: document == nil ? "failed" : "succeeded",
            failure: failure,
            analysesRunDirectory: analysesDirectory.lastPathComponent,
            notesDocumentRunDirectory: documentDirectory.lastPathComponent,
            notesGenerationID: notesGeneration.generationID.uuidString,
            notesProvenance: notesDocument.provenance,
            notesDocumentSHA256Before: documentHashBefore,
            notesDocumentSHA256After: try documentSHA256(),
            summaryGenerationID: generation?.generationID.uuidString,
            summaryProvenance: summaryProvenance,
            windowAnalysisCalls: calls.filter { $0.instructionStage == "windowAnalysis" }.count,
            notesSynthesisCalls: calls.filter { notesSynthesisStages.contains($0.instructionStage ?? "") }.count,
            summaryCallsByInstructionStage: Dictionary(grouping: calls.filter { $0.kind == "respond" }, by: { $0.instructionStage ?? "none" }).mapValues(\.count),
            plannedBatchCount: plan?.batches.count,
            batchCoverage: batchCoverage,
            batchStageCitedSourceItemCount: batchCoverage.map { $0.reduce(0) { $0 + $1.citedPositions.count } },
            batchStageUncitedSourceIndices: batchCoverage?.flatMap(\.uncitedSourceIndices),
            sections: sectionReports,
            finalDocumentCitedSourceItemCount: document == nil ? nil : finalCited.count,
            finalDocumentUncitedSourceIndices: document == nil ? nil : summarySource.sourceItems.map(\.sourceIndex).filter { !finalCited.contains($0) },
            perBatchSeconds: perBatchSeconds,
            documentSeconds: documentSeconds,
            totalSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: overallStart),
            textAnomalies: anomalies,
            calls: calls,
            persistenceWarnings: await driver.persistenceWarnings
        )
        try AtomicFileWriter.writeJSON(result, to: runDirectory.appendingPathComponent("summary-v5-replay-result.json"))
        try AtomicFileWriter.writeJSON(anomalies, to: runDirectory.appendingPathComponent("script-anomalies.json"))
        if document != nil { try progress.finish(writingTo: progressURL) }

        XCTAssertNil(failure, failure ?? "")
        XCTAssertEqual(result.windowAnalysisCalls, 0, "window analysis is never re-run")
        XCTAssertEqual(result.notesSynthesisCalls, 0, "Notes synthesis is never re-run")
        XCTAssertEqual(result.notesDocumentSHA256After, result.notesDocumentSHA256Before, "the accepted Notes document is only read")
        let madePlan = try XCTUnwrap(plan)
        for batch in madePlan.batches {
            XCTAssertTrue(sectionRanges.contains { $0.range.contains(batch.firstSourceItemIndex) && $0.range.contains(batch.lastSourceItemIndex) },
                          "batch \(batch.batchIndex) stays inside one Notes section")
        }
        let completed = try XCTUnwrap(document)
        XCTAssertEqual(completed.sections.map(\.heading), sectionRanges.map(\.section.heading), "one Summary section per non-empty Notes section, under its Notes title")
        for (section, entry) in zip(completed.sections, sectionRanges) {
            for passage in section.passages {
                XCTAssertTrue(passage.supportingNoteItemIDs.allSatisfy { sourceIndexByID[$0].map(entry.range.contains) ?? false },
                              "\(section.heading) cites only its own Notes section")
            }
        }
        XCTAssertEqual(completed.provenance, summaryProvenance)
        XCTAssertEqual(completed.sourceNotesGenerationID, notesGeneration.generationID)
        XCTAssertTrue(result.persistenceWarnings.isEmpty, result.persistenceWarnings.joined(separator: "; "))
    }

    // MARK: - Acceptance sessions root

    func testSessionsRootAbsentKeepsTheProductionDefault() throws {
        XCTAssertNil(try MLXAcceptanceSessionsRoot.resolve(environmentValue: nil))
    }

    func testSessionsRootRejectsMalformedOrUnsafeValues() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SessionsRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let linked = base.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: base)
        let file = base.appendingPathComponent("file")
        try Data().write(to: file)

        for value in ["", "relative/sessions"] {
            XCTAssertThrowsError(try MLXAcceptanceSessionsRoot.resolve(environmentValue: value)) {
                XCTAssertEqual($0 as? MLXAcceptanceSessionsRoot.ResolutionError, .notAbsolute(value))
                XCTAssertTrue($0.localizedDescription.contains(MLXAcceptanceSessionsRoot.environmentKey))
            }
        }
        for url in [base.appendingPathComponent("missing"), linked, file] {
            XCTAssertThrowsError(try MLXAcceptanceSessionsRoot.resolve(environmentValue: url.path)) {
                XCTAssertEqual($0 as? MLXAcceptanceSessionsRoot.ResolutionError, .unusable(url.path))
            }
        }
        XCTAssertEqual(try MLXAcceptanceSessionsRoot.resolve(environmentValue: base.path), URL(fileURLWithPath: base.path, isDirectory: true))
    }

    func testSuppliedSessionsRootIsTheOneTheTranscriptLoaderReads() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SessionsRoot-\(UUID().uuidString)", isDirectory: true)
        let acceptanceRoot = base.appendingPathComponent("acceptance", isDirectory: true)
        let emptyRoot = base.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionID = UUID()
        try await writeCompletedTranscribedSession(sessionID: sessionID, root: acceptanceRoot, chunkCount: 3)

        let loader = MLXAcceptanceSessionsRoot.makeTranscriptLoader(
            root: try MLXAcceptanceSessionsRoot.resolve(environmentValue: acceptanceRoot.path)
        )
        let snapshot = try await loader.loadCurrentSnapshot(sessionID: sessionID)
        XCTAssertEqual(snapshot.units.map(\.sequenceNumber), [0, 1, 2])
        XCTAssertEqual(snapshot.units.map(\.startOffsetSeconds), [0, 30, 60])
        XCTAssertEqual(snapshot.units.map(\.text), ["chunk text 0", "chunk text 1", "chunk text 2"])

        let elsewhere = MLXAcceptanceSessionsRoot.makeTranscriptLoader(
            root: try MLXAcceptanceSessionsRoot.resolve(environmentValue: emptyRoot.path)
        )
        do {
            _ = try await elsewhere.loadCurrentSnapshot(sessionID: sessionID)
            XCTFail("a different root must not find the session")
        } catch {}
    }

    /// Writes a completed, transcribed session under `root` through the real
    /// `TranscriptionStore`, the same shape the production loader reads.
    private func writeCompletedTranscribedSession(sessionID: UUID, root: URL, chunkCount: Int) async throws {
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: sessionID)
        var manifest = SessionManifest.newSession(
            id: sessionID,
            audioFormat: AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32"),
            targetChunkDurationSeconds: 30
        )
        manifest.status = .completed
        manifest.endedCleanly = true
        manifest.chunks = (0..<chunkCount).map { seq in
            ChunkMetadata(
                sequenceNumber: seq, fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq) * 30, durationSeconds: 30, frameCount: 1_000, state: .completed
            )
        }
        try AtomicFileWriter.writeJSON(manifest, to: paths.manifestURL)
        let store = TranscriptionStore()
        let artifactPaths = try TranscriptionArtifactPaths.validated(manifest: manifest, sessionPaths: paths)
        try await store.ensureDirectoriesExist(paths: artifactPaths)
        for chunk in manifest.chunks {
            try Data("placeholder".utf8).write(to: paths.chunksDirectory.appendingPathComponent(chunk.fileName))
            let source = TranscriptionSourceSnapshot(
                sessionID: sessionID, chunkSequenceNumber: chunk.sequenceNumber, chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount, startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds, audioFormat: manifest.audioFormat
            )
            var job = TranscriptionJob.newQueued(source: source, now: Date())
            job.state = .completed
            _ = try await store.createJobIfAbsent(job, paths: artifactPaths)
            _ = try await store.commitResult(
                TranscriptResult(
                    schemaVersion: TranscriptResult.legacySchemaVersion, source: source,
                    output: TranscriptionEngineOutput(
                        text: "chunk text \(chunk.sequenceNumber)", engineIdentifier: "fake",
                        modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil
                    ),
                    attemptID: UUID(), completedDate: Date()
                ),
                paths: artifactPaths
            )
        }
    }

    /// Opt-in, inference-free check that an acceptance session loads through
    /// exactly the harness's transcript path and covers a contiguous,
    /// session-relative timeline. Prints structure only, never transcript
    /// text. Enable with `LECTURE_RECORDER_VALIDATE_ACCEPTANCE_SESSION=1`
    /// plus the session ID and (optionally) the sessions root variables.
    func testAcceptanceSessionLoadsThroughTheHarnessPathWithoutInference() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["LECTURE_RECORDER_VALIDATE_ACCEPTANCE_SESSION"] == "1",
            "Set LECTURE_RECORDER_VALIDATE_ACCEPTANCE_SESSION=1 to validate an acceptance session."
        )
        let sessionID = try XCTUnwrap(environment["LECTURE_RECORDER_ACCEPTANCE_SESSION_ID"].flatMap(UUID.init(uuidString:)))
        let root = try MLXAcceptanceSessionsRoot.resolve(environmentValue: environment[MLXAcceptanceSessionsRoot.environmentKey])
        let snapshot = try await MLXAcceptanceSessionsRoot.makeTranscriptLoader(root: root).loadCurrentSnapshot(sessionID: sessionID)

        let units = snapshot.units
        XCTAssertEqual(units.map(\.sequenceNumber), Array(0..<units.count), "no renumbering, no gaps")
        for (previous, next) in zip(units, units.dropFirst()) {
            XCTAssertEqual(previous.startOffsetSeconds + previous.durationSeconds, next.startOffsetSeconds, accuracy: 0.001)
        }
        let plan = NotesWindowPlan(windows: NotesWindowPlanner.plan(units: units, budget: MLXNotesConfiguration.windowBudget))
        XCTAssertNoThrow(try plan.validateCoversExactly(snapshot))
        let end = (units.last.map { $0.startOffsetSeconds + $0.durationSeconds }) ?? 0
        let structure = "sessionsRoot=\(root == nil ? "production" : "override") units=\(units.count) firstSequence=\(units.first?.sequenceNumber ?? -1) lastSequence=\(units.last?.sequenceNumber ?? -1) endSeconds=\(end) nonEmptyUnits=\(units.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) plannedWindows=\(plan.windows.count) fingerprint=\(snapshot.fingerprint.digestHex)"
        print("ACCEPTANCE_SESSION_STRUCTURE \(structure)")
        try Data(structure.utf8).write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("acceptance-session-structure-\(sessionID.uuidString).txt")
        )
    }

    func testRealMLXNotesAndSummaryOnRepresentativeLecture() async throws {
        try XCTSkipUnless(
            Self.isEnabled,
            "Set LECTURE_RECORDER_RUN_MLX_REAL_LECTURE_ACCEPTANCE=1 to run this opt-in MLX-3 real-lecture acceptance test."
        )

        let environment = ProcessInfo.processInfo.environment

        guard let sessionIDString = environment["LECTURE_RECORDER_ACCEPTANCE_SESSION_ID"], !sessionIDString.isEmpty else {
            XCTFail(HarnessConfigurationError.missingSessionID.localizedDescription)
            return
        }
        guard let sessionID = UUID(uuidString: sessionIDString) else {
            XCTFail(HarnessConfigurationError.malformedSessionID(sessionIDString).localizedDescription)
            return
        }
        guard let outputDirectoryPath = environment["LECTURE_RECORDER_ACCEPTANCE_OUTPUT_DIRECTORY"], !outputDirectoryPath.isEmpty else {
            XCTFail(HarnessConfigurationError.missingOutputDirectory.localizedDescription)
            return
        }
        let modelSelection: MLXAcceptanceModelSelection
        do {
            modelSelection = try MLXAcceptanceModelSelection.resolve(
                environmentValue: environment[MLXAcceptanceModelSelection.environmentKey]
            )
        } catch {
            XCTFail(error.localizedDescription)
            return
        }
        let modelDescriptor = modelSelection.descriptor
        let modelIdentity = MLXAcceptanceModelIdentity(modelSelection)
        let acceptanceScope: MLXAcceptanceScope
        do {
            acceptanceScope = try MLXAcceptanceScope.resolve(
                scopeValue: environment[MLXAcceptanceScope.scopeEnvironmentKey],
                notesWindowIndexValue: environment[MLXAcceptanceScope.windowIndexEnvironmentKey],
                notesFirstWindowIndexValue: environment[MLXAcceptanceScope.firstWindowIndexEnvironmentKey],
                notesLastWindowIndexValue: environment[MLXAcceptanceScope.lastWindowIndexEnvironmentKey]
            )
        } catch {
            XCTFail(error.localizedDescription)
            return
        }
        let sessionsRoot: URL?
        do {
            sessionsRoot = try MLXAcceptanceSessionsRoot.resolve(
                environmentValue: environment[MLXAcceptanceSessionsRoot.environmentKey]
            )
        } catch {
            XCTFail(error.localizedDescription)
            return
        }
        let requestedNotesWindowIndex = acceptanceScope.notesWindowIndex
        let outputRootURL = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputRootURL, withIntermediateDirectories: true)
        } catch {
            XCTFail(HarnessConfigurationError.outputDirectoryUnavailable(outputDirectoryPath, error.localizedDescription).localizedDescription)
            return
        }

        // Exactly one real MLX session driver, never downloaded/reprovisioned
        // here — must already be verified in place.
        let realDriver = RealMLXSessionDriver(descriptor: modelDescriptor)
        switch await realDriver.availability() {
        case .available:
            break
        case .unavailable(let description):
            XCTFail("Pinned MLX model assets are not provisioned/verified: \(description)")
            return
        }
        let overallStart = AcceptanceDiagnosticLogger.startInstant()

        // 1/2: load the real transcript through the exact production
        // source-loading path — never a parallel ad hoc loader.
        let transcriptLoader = MLXAcceptanceSessionsRoot.makeTranscriptLoader(root: sessionsRoot)
        let transcriptSnapshot: NotesTranscriptSourceSnapshot
        do {
            transcriptSnapshot = try await transcriptLoader.loadCurrentSnapshot(sessionID: sessionID)
        } catch {
            XCTFail("Unable to load session \(sessionID)'s transcript through the production path: \(error.localizedDescription)")
            return
        }
        guard !transcriptSnapshot.units.isEmpty else {
            XCTFail("Session \(sessionID) has an empty transcript; nothing to measure.")
            return
        }

        // 3: the same planner and MLX budget production uses.
        let windowPlan = NotesWindowPlan(
            windows: NotesWindowPlanner.plan(units: transcriptSnapshot.units, budget: MLXNotesConfiguration.windowBudget)
        )
        do {
            try windowPlan.validateCoversExactly(transcriptSnapshot)
        } catch {
            XCTFail("Computed window plan does not exactly cover the loaded transcript: \(error.localizedDescription)")
            return
        }

        // The exact windows this scope analyzes, validated against the current
        // plan before any run directory or MLX generation exists.
        let orderedWindows = windowPlan.windows.sorted { $0.windowIndex < $1.windowIndex }
        let windowsToAnalyze: [NotesInputWindow]
        do {
            windowsToAnalyze = try acceptanceScope.windowsToAnalyze(plannedWindows: windowPlan.windows)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        // A unique, non-overwriting run subdirectory. Never write into the
        // selected lecture's real session directory.
        let runID = UUID()
        let runStartDate = Date()
        let runDirectory = outputRootURL.appendingPathComponent(
            "mlx3-\(sessionID.uuidString)-\(runID.uuidString)", isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: runDirectory.path) else {
            XCTFail(HarnessConfigurationError.runDirectoryCollision(runDirectory.path).localizedDescription)
            return
        }
        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        } catch {
            XCTFail("Unable to create acceptance run directory: \(error.localizedDescription)")
            return
        }
        let notesWindowAnalysesDirectory = runDirectory.appendingPathComponent("notes-window-analyses", isDirectory: true)
        let runIdentity = MLXAcceptanceRunIdentity(
            runID: runID,
            sessionID: sessionID,
            scope: acceptanceScope,
            selection: modelSelection,
            transcriptFingerprint: transcriptSnapshot.fingerprint,
            transcriptUnitCount: transcriptSnapshot.units.count,
            plannedWindows: windowPlan.windows,
            requestedWindows: windowsToAnalyze
        )
        let summaryBatchAnalysesDirectory = runDirectory.appendingPathComponent("summary-batch-analyses", isDirectory: true)

        var persistenceWarnings: [String] = []
        func persist<T: Encodable>(_ value: T, to url: URL) {
            do {
                try AtomicFileWriter.writeJSON(value, to: url)
            } catch {
                persistenceWarnings.append("Unable to write \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        persist(runIdentity, to: runDirectory.appendingPathComponent("run-identity.json"))

        // Call records and stage progress are written as they happen, so a
        // later failure never loses the evidence gathered so far.
        let timingDriver = TimingSessionDriver(
            wrapped: realDriver, recordsURL: runDirectory.appendingPathComponent("call-records.json")
        )
        let progressURL = runDirectory.appendingPathComponent("run-progress.json")
        var progress = MLXAcceptanceRunProgress(runID: runID.uuidString)
        func completeStage(_ stage: String) {
            do {
                try progress.complete(stage, writingTo: progressURL)
            } catch {
                persistenceWarnings.append("Unable to write run-progress.json: \(error.localizedDescription)")
            }
        }
        completeStage("runIdentity")
        func finishRun() async {
            persistenceWarnings += await timingDriver.persistenceWarnings
            do {
                try progress.finish(writingTo: progressURL)
            } catch {
                persistenceWarnings.append("Unable to write run-progress.json: \(error.localizedDescription)")
            }
        }

        // 4/5: one shared driver, real Notes generator.
        let notesGenerator = MLXLectureNotesGenerator(
            sessionDriver: timingDriver,
            modelDescriptor: modelDescriptor
        )
        let notesGeneration = LectureNotesGenerationRecord.newGeneration(
            sessionID: sessionID,
            transcriptFingerprint: transcriptSnapshot.fingerprint,
            windowPlan: windowPlan,
            provenance: MLXNotesConfiguration.generationProvenance(for: modelDescriptor)
        )

        // 6: analyze the scope's windows in deterministic source order,
        // persisting each successful result as it completes.
        var windowAnalyses: [LectureNotesWindowAnalysis] = []
        var notesPerWindowSeconds: [TimedWindow] = []
        for window in windowsToAnalyze {
            let unitsInWindow = transcriptSnapshot.units.filter {
                $0.sequenceNumber >= window.firstSequenceNumber && $0.sequenceNumber <= window.lastSequenceNumber
            }
            await timingDriver.setStage("notesWindow:\(window.windowIndex)")
            let windowStart = AcceptanceDiagnosticLogger.startInstant()
            let analysis: LectureNotesWindowAnalysis
            do {
                analysis = try await notesGenerator.analyzeWindow(units: unitsInWindow, window: window, generation: notesGeneration)
            } catch {
                if let backendError = error as? MLXLectureNotesBackendError,
                   case .invalidSourceReference(
                    let firstSequenceNumber,
                    let lastSequenceNumber,
                    let allowedSequenceNumbers
                   ) = backendError {
                    persist(
                        NotesSourceReferenceFailureDiagnostic(
                            windowIndex: window.windowIndex,
                            firstSequenceNumber: firstSequenceNumber,
                            lastSequenceNumber: lastSequenceNumber,
                            allowedSequenceNumbers: allowedSequenceNumbers
                        ),
                        to: runDirectory.appendingPathComponent("notes-source-reference-failure.json")
                    )
                }
                XCTFail("Notes window #\(window.windowIndex) analysis failed after \(windowAnalyses.count) prior windows succeeded: \(error.localizedDescription)")
                return
            }
            let seconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: windowStart)
            windowAnalyses.append(analysis)
            notesPerWindowSeconds.append(TimedWindow(windowIndex: window.windowIndex, seconds: seconds))
            persist(
                analysis,
                to: notesWindowAnalysesDirectory.appendingPathComponent("window_\(String(format: "%04d", window.windowIndex)).json")
            )
            completeStage("notesWindow:\(window.windowIndex)")
        }

        if let requestedNotesWindowIndex {
            let result = WindowOnlyRunResult(
                runID: runID.uuidString,
                startedAt: runStartDate,
                finishedAt: Date(),
                sessionID: sessionID.uuidString,
                mlxModelSelection: modelIdentity.mlxModelSelection,
                modelIdentifier: modelIdentity.modelIdentifier,
                modelRevision: modelIdentity.modelRevision,
                nativeContextLength: modelIdentity.nativeContextLength,
                operationalContextCeiling: modelIdentity.operationalContextCeiling,
                transcriptUnitCount: transcriptSnapshot.units.count,
                notesPlannedWindowCount: orderedWindows.count,
                analyzedWindowIndex: requestedNotesWindowIndex,
                analysisSeconds: notesPerWindowSeconds[0].seconds,
                analysisItemCount: windowAnalyses[0].items.count,
                notesCallRecords: await timingDriver.records,
                totalEndToEndSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: overallStart),
                persistenceWarnings: persistenceWarnings
            )
            persist(result, to: runDirectory.appendingPathComponent("notes-window-result.json"))
            await finishRun()
            XCTAssertTrue(
                persistenceWarnings.isEmpty,
                "acceptance artifact persistence warnings: \(persistenceWarnings.joined(separator: "; "))"
            )
            return
        }

        if case .notesRange = acceptanceScope {
            let result = NotesRangeRunResult(
                identity: runIdentity,
                startedAt: runStartDate,
                finishedAt: Date(),
                analyses: windowAnalyses,
                notesPerWindowSeconds: notesPerWindowSeconds,
                notesCallRecords: await timingDriver.records,
                totalEndToEndSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: overallStart),
                persistenceWarnings: persistenceWarnings
            )
            persist(result, to: runDirectory.appendingPathComponent("notes-range-result.json"))
            await finishRun()
            XCTAssertEqual(
                result.analyzedWindowIndices, runIdentity.requestedWindowIndices,
                "notes-range must analyze exactly the requested windows"
            )
            XCTAssertTrue(
                persistenceWarnings.isEmpty,
                "acceptance artifact persistence warnings: \(persistenceWarnings.joined(separator: "; "))"
            )
            return
        }

        if acceptanceScope == .notesFull {
            let itemCounts = windowAnalyses.map(\.items.count)
            let result = NotesFullRunResult(
                runID: runID.uuidString,
                startedAt: runStartDate,
                finishedAt: Date(),
                sessionID: sessionID.uuidString,
                acceptanceScope: acceptanceScope.name,
                mlxModelSelection: modelIdentity.mlxModelSelection,
                modelIdentifier: modelIdentity.modelIdentifier,
                modelRevision: modelIdentity.modelRevision,
                nativeContextLength: modelIdentity.nativeContextLength,
                operationalContextCeiling: modelIdentity.operationalContextCeiling,
                transcriptUnitCount: transcriptSnapshot.units.count,
                notesPlannedWindowCount: orderedWindows.count,
                analyzedWindowCount: windowAnalyses.count,
                notesPerWindowSeconds: notesPerWindowSeconds,
                notesAnalysisTotalSeconds: notesPerWindowSeconds.reduce(0) { $0 + $1.seconds },
                analysisItemCounts: itemCounts,
                totalAnalysisItemCount: itemCounts.reduce(0, +),
                notesCallRecords: await timingDriver.records,
                totalEndToEndSeconds: AcceptanceDiagnosticLogger.elapsedSeconds(since: overallStart),
                persistenceWarnings: persistenceWarnings
            )
            persist(result, to: runDirectory.appendingPathComponent("notes-full-result.json"))
            await finishRun()
            XCTAssertEqual(windowAnalyses.count, orderedWindows.count, "notes-full must analyze every planned window")
            XCTAssertTrue(
                persistenceWarnings.isEmpty,
                "acceptance artifact persistence warnings: \(persistenceWarnings.joined(separator: "; "))"
            )
            return
        }

        // Only notes-and-summary may continue past per-window analysis.
        guard !acceptanceScope.stopsBeforeNotesSynthesis else {
            XCTFail("Acceptance scope \(acceptanceScope.name) must stop before Notes synthesis and Summary.")
            return
        }

        // 7: synthesize the complete Notes document through the existing
        // MLX path — no weakened validation.
        await timingDriver.setStage("notesSynthesis")
        let notesSynthesisStart = AcceptanceDiagnosticLogger.startInstant()
        let notesDocument: LectureNotesDocument
        do {
            notesDocument = try await notesGenerator.synthesize(analyses: windowAnalyses, generation: notesGeneration)
        } catch {
            XCTFail("Notes synthesis failed: \(error.localizedDescription)")
            return
        }
        let notesSynthesisSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: notesSynthesisStart)
        persist(notesDocument, to: runDirectory.appendingPathComponent("notes-document.json"))
        completeStage("notesSynthesis")
        // Report-only: never alters or rejects generated text.
        let notesScriptAnomalies = MLXAcceptanceTextDiagnostics.scriptAnomalies(analyses: windowAnalyses)
            + MLXAcceptanceTextDiagnostics.scriptAnomalies(notes: notesDocument)
        persist(notesScriptAnomalies, to: runDirectory.appendingPathComponent("script-anomalies.json"))

        let notesTotalSeconds = notesPerWindowSeconds.reduce(0) { $0 + $1.seconds } + notesSynthesisSeconds
        let notesRealCallCount = await timingDriver.records.count

        // 8/9: build the in-memory Summary source through the existing
        // Summary contract (the same pure builder `LectureSummarySourceLoader`
        // uses), then generate the dedicated Summary with the same shared
        // driver.
        let sourceSnapshot: LectureSummarySourceSnapshot
        do {
            sourceSnapshot = try LectureSummarySourceBuilder.build(
                generation: notesGeneration, analyses: windowAnalyses, document: notesDocument, transcriptSnapshot: transcriptSnapshot
            )
        } catch {
            XCTFail("Unable to build the in-memory Summary source snapshot from the generated Notes document: \(error.localizedDescription)")
            return
        }

        let summaryGenerator = MLXLectureSummaryGenerator(sessionDriver: timingDriver, modelDescriptor: modelDescriptor)
        await timingDriver.setStage("summaryPlan")
        let summaryPlanStart = AcceptanceDiagnosticLogger.startInstant()
        let summaryPlan: LectureSummaryPlan
        do {
            summaryPlan = try await summaryGenerator.makePlan(for: sourceSnapshot)
        } catch {
            XCTFail("Summary planning failed: \(error.localizedDescription)")
            return
        }
        let summaryPlanningSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: summaryPlanStart)
        completeStage("summaryPlan")

        let summaryGeneration = LectureSummaryGenerationRecord.newGeneration(
            sessionID: sessionID,
            sourceNotesGenerationID: notesGeneration.generationID,
            transcriptFingerprint: transcriptSnapshot.fingerprint,
            sourceNotesDocumentFingerprint: sourceSnapshot.sourceNotesDocumentFingerprint,
            batchPlan: summaryPlan,
            provenance: MLXSummaryConfiguration.generationProvenance(for: modelDescriptor)
        )

        var summaryAnalyses: [LectureSummaryAnalysis] = []
        var summaryPerBatchSeconds: [TimedBatch] = []
        let orderedBatches = summaryPlan.batches.sorted { $0.batchIndex < $1.batchIndex }
        for batch in orderedBatches {
            await timingDriver.setStage("summaryBatch:\(batch.batchIndex)")
            let batchStart = AcceptanceDiagnosticLogger.startInstant()
            let analysis: LectureSummaryAnalysis
            do {
                analysis = try await summaryGenerator.generateAnalysis(for: batch, generation: summaryGeneration, source: sourceSnapshot)
            } catch {
                XCTFail("Summary batch #\(batch.batchIndex) analysis failed after \(summaryAnalyses.count) prior batches succeeded: \(error.localizedDescription)")
                return
            }
            let seconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: batchStart)
            do {
                try LectureSummaryIntegrityValidator.validate(analysis: analysis, generation: summaryGeneration, source: sourceSnapshot)
            } catch {
                XCTFail("Summary batch #\(batch.batchIndex) analysis failed independent integrity validation: \(error.localizedDescription)")
                return
            }
            summaryAnalyses.append(analysis)
            summaryPerBatchSeconds.append(TimedBatch(batchIndex: batch.batchIndex, seconds: seconds))
            persist(
                analysis,
                to: summaryBatchAnalysesDirectory.appendingPathComponent("batch_\(String(format: "%04d", batch.batchIndex)).json")
            )
            completeStage("summaryBatch:\(batch.batchIndex)")
        }

        await timingDriver.setStage("summaryDocument")
        let summarySynthesisStart = AcceptanceDiagnosticLogger.startInstant()
        let summaryDocument: LectureSummaryDocument
        do {
            summaryDocument = try await summaryGenerator.generateDocument(from: summaryAnalyses, generation: summaryGeneration, source: sourceSnapshot)
        } catch {
            XCTFail("Summary synthesis failed: \(error.localizedDescription)")
            return
        }
        let summarySynthesisSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: summarySynthesisStart)
        do {
            try LectureSummaryIntegrityValidator.validate(document: summaryDocument, generation: summaryGeneration, source: sourceSnapshot)
        } catch {
            XCTFail("Summary document failed independent integrity validation: \(error.localizedDescription)")
            return
        }
        persist(summaryDocument, to: runDirectory.appendingPathComponent("summary-document.json"))
        completeStage("summaryDocument")
        persist(
            notesScriptAnomalies + MLXAcceptanceTextDiagnostics.scriptAnomalies(summary: summaryDocument),
            to: runDirectory.appendingPathComponent("script-anomalies.json")
        )

        let summaryTotalSeconds = summaryPlanningSeconds + summaryPerBatchSeconds.reduce(0) { $0 + $1.seconds } + summarySynthesisSeconds
        let totalElapsedSeconds = AcceptanceDiagnosticLogger.elapsedSeconds(since: overallStart)

        // 10: shared-driver reuse evidence — every call, Notes and Summary
        // alike, went through the one `timingDriver`/`realDriver` pair. The
        // call-index boundary below splits its accumulated records into a
        // Notes-phase prefix and a Summary-phase suffix for reporting; a
        // single outlying-duration call at index 0 (model load) followed by
        // much shorter calls throughout both phases is the evidence that
        // exactly one model load served the entire run.
        let allCallRecords = await timingDriver.records
        let notesCallRecords = Array(allCallRecords.prefix(notesRealCallCount))
        let summaryCallRecords = Array(allCallRecords.suffix(from: notesRealCallCount))

        let result = RunResult(
            runID: runID.uuidString,
            startedAt: runStartDate,
            finishedAt: Date(),
            sessionID: sessionID.uuidString,
            transcriptFingerprintDigestHex: transcriptSnapshot.fingerprint.digestHex,
            transcriptUnitCount: transcriptSnapshot.units.count,
            mlxModelSelection: modelIdentity.mlxModelSelection,
            modelIdentifier: modelIdentity.modelIdentifier,
            modelRevision: modelIdentity.modelRevision,
            backendIdentifier: MLXNotesConfiguration.backendIdentifier,
            nativeContextLength: timingDriver.nativeContextLength,
            operationalContextCeiling: timingDriver.operationalContextCeiling,
            notesPlannedWindowCount: windowPlan.windows.count,
            notesPerWindowSeconds: notesPerWindowSeconds,
            notesSynthesisSeconds: notesSynthesisSeconds,
            notesTotalSeconds: notesTotalSeconds,
            notesSectionCount: notesDocument.sections.count,
            notesItemCount: notesDocument.sections.reduce(0) { $0 + $1.items.count },
            notesRealCallRecords: notesCallRecords,
            summaryPlannedBatchCount: summaryPlan.batches.count,
            summaryPlanningSeconds: summaryPlanningSeconds,
            summaryPerBatchSeconds: summaryPerBatchSeconds,
            summarySynthesisSeconds: summarySynthesisSeconds,
            summaryTotalSeconds: summaryTotalSeconds,
            summarySectionCount: summaryDocument.sections.count,
            summaryPassageCount: summaryDocument.sections.reduce(0) { $0 + $1.passages.count },
            summaryRealCallRecords: summaryCallRecords,
            summaryIntegrityValidation: "validated (document + every analysis) via LectureSummaryIntegrityValidator; a failure there would have already failed this run before reaching this point",
            totalEndToEndSeconds: totalElapsedSeconds,
            persistenceWarnings: persistenceWarnings,
            retryMeasurementNote: "withGeneratedOutputRetry is private to each MLX generator and the existing diagnosticRecorder hook only fires for preflight-fit events, never retry attempts — no per-window/per-batch retry count is observable from this generator's public surface. notesRealCallRecords/summaryRealCallRecords (total respond()+tokenCount call counts per phase) are the closest available proxy; they are not a precise retry counter.",
            memoryMeasurementNote: "activeMemoryBytes/peakMemoryBytes above are exactly what RealMLXSessionDriver.respond already reports per call (MLXRuntimeMLX's Memory.activeMemory/Memory.peakMemory) — no separate in-process memory subsystem was added for this harness. No OS-level (RSS/wired) measurement is captured in-process; that would require an external measurement (e.g. wrapping the test invocation) and is out of this patch's scope."
        )
        persist(result, to: runDirectory.appendingPathComponent("result.json"))
        await finishRun()

        XCTAssertFalse(notesDocument.sections.isEmpty, "expected at least one Notes section from the real local model")
        XCTAssertFalse(summaryDocument.sections.isEmpty, "expected at least one Summary section from the real local model")
        XCTAssertTrue(persistenceWarnings.isEmpty, "acceptance artifact persistence warnings: \(persistenceWarnings.joined(separator: "; "))")
    }
}
