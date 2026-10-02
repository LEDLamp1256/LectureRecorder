import XCTest
@testable import LectureRecorder

/// A `LectureSummarySourceLoading` double whose calls either return a
/// scripted result immediately or, for a held Notes generation, suspend
/// until the test resumes that specific call — so completion order is chosen
/// by the test, never by timing.
private actor ControllableSummarySourceLoader: LectureSummarySourceLoading {
    private var immediateResults: [UUID: Result<LectureSummarySourceSnapshot, Error>] = [:]
    private var heldGenerationIDs: Set<UUID> = []
    private var heldCalls: [CheckedContinuation<Result<LectureSummarySourceSnapshot, Error>, Never>?] = []
    private(set) var requests: [(sessionID: UUID, notesGenerationID: UUID)] = []

    func setResult(_ result: Result<LectureSummarySourceSnapshot, Error>, for notesGenerationID: UUID) {
        immediateResults[notesGenerationID] = result
    }

    func hold(_ notesGenerationID: UUID) {
        heldGenerationIDs.insert(notesGenerationID)
    }

    var heldCallCount: Int { heldCalls.count }

    /// Resumes the `index`th held call (in arrival order) with `result`.
    func resumeHeldCall(_ index: Int, with result: Result<LectureSummarySourceSnapshot, Error>) {
        heldCalls[index]?.resume(returning: result)
        heldCalls[index] = nil
    }

    func loadSourceSnapshot(sessionID: UUID, notesGenerationID: UUID) async throws -> LectureSummarySourceSnapshot {
        requests.append((sessionID, notesGenerationID))
        if heldGenerationIDs.contains(notesGenerationID) {
            let result = await withCheckedContinuation { continuation in
                heldCalls.append(continuation)
            }
            return try result.get()
        }
        guard let result = immediateResults[notesGenerationID] else {
            throw LectureSummarySourceError.missingGeneration
        }
        return try result.get()
    }
}

/// One Summary and the exact Notes source it was generated from.
private struct SummaryFixture {
    let sessionID: UUID
    let notesGenerationID: UUID
    let transcriptFingerprint: TranscriptSourceFingerprint
    let notesDocumentFingerprint: NotesDocumentFingerprint
    let noteItems: [LectureNoteItem]
    let notesDocument: LectureNotesDocument
    let summary: LectureSummaryDocument
    let passage: LectureSummaryPassage
    /// A second passage of the same Summary, so same source identity.
    let otherPassage: LectureSummaryPassage

    var target: SummaryNotesRevealTarget {
        SummaryNotesRevealTarget(document: summary, passage: passage)!
    }

    var otherTarget: SummaryNotesRevealTarget {
        SummaryNotesRevealTarget(document: summary, passage: otherPassage)!
    }

    /// The fresh source snapshot, optionally tampered with.
    func snapshot(
        sessionID: UUID? = nil,
        notesGenerationID: UUID? = nil,
        transcriptFingerprint: TranscriptSourceFingerprint? = nil,
        notesDocumentFingerprint: NotesDocumentFingerprint? = nil,
        items: [LectureNoteItem]? = nil
    ) -> LectureSummarySourceSnapshot {
        let sectionID = UUID()
        return LectureSummarySourceSnapshot(
            schemaVersion: LectureSummarySourceSnapshot.currentSchemaVersion,
            sessionID: sessionID ?? self.sessionID,
            sourceNotesGenerationID: notesGenerationID ?? self.notesGenerationID,
            transcriptFingerprint: transcriptFingerprint ?? self.transcriptFingerprint,
            sourceNotesDocumentFingerprint: notesDocumentFingerprint ?? self.notesDocumentFingerprint,
            sourceItems: (items ?? noteItems).enumerated().map { index, item in
                LectureSummarySourceItem(sourceIndex: index, sectionID: sectionID, sectionHeading: "Section", item: item)
            }
        )
    }

    /// `supportIndices` pick which of `itemCount` Note items the passage
    /// cites (`otherSupportIndices` for `otherPassage`); the items are split
    /// across two Notes sections.
    static func make(
        sessionID: UUID,
        notesGenerationID: UUID = UUID(),
        itemCount: Int = 4,
        supportIndices: [Int] = [1, 2],
        otherSupportIndices: [Int] = [0],
        notesDocumentDigest: Character = "b"
    ) -> SummaryFixture {
        let transcriptFingerprint = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "a", count: 64))
        let notesDocumentFingerprint = NotesDocumentFingerprint(algorithmVersion: 1, digestHex: String(repeating: notesDocumentDigest, count: 64))
        let items = (0..<itemCount).map { index in
            LectureNoteItem(
                kind: .explanation,
                body: "note \(index)",
                fidelity: .transcriptSupported,
                sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: index)]
            )
        }
        let notesDocument = LectureNotesDocument(
            generationID: notesGenerationID,
            sessionID: sessionID,
            transcriptFingerprint: transcriptFingerprint,
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            overview: "overview",
            sections: [
                LectureNoteSection(heading: "A", items: Array(items.prefix(itemCount / 2))),
                LectureNoteSection(heading: "B", items: Array(items.dropFirst(itemCount / 2))),
            ]
        )
        let passage = LectureSummaryPassage(
            text: "passage",
            supportingNoteItemIDs: supportIndices.map { items[$0].id },
            sourceReferences: supportIndices.map { NotesSourceReference(sessionID: sessionID, sequenceNumber: $0) },
            fidelity: .transcriptSupported
        )
        let otherPassage = LectureSummaryPassage(
            text: "other passage",
            supportingNoteItemIDs: otherSupportIndices.map { items[$0].id },
            sourceReferences: otherSupportIndices.map { NotesSourceReference(sessionID: sessionID, sequenceNumber: $0) },
            fidelity: .transcriptSupported
        )
        let summary = LectureSummaryDocument(
            generationID: UUID(),
            sessionID: sessionID,
            sourceNotesGenerationID: notesGenerationID,
            transcriptFingerprint: transcriptFingerprint,
            sourceNotesDocumentFingerprint: notesDocumentFingerprint,
            provenance: LectureNotesGenerationProvenance(recipeVersion: "test-recipe-v1"),
            sections: [LectureSummarySection(heading: "Summary", passages: [passage, otherPassage])]
        )
        return SummaryFixture(
            sessionID: sessionID,
            notesGenerationID: notesGenerationID,
            transcriptFingerprint: transcriptFingerprint,
            notesDocumentFingerprint: notesDocumentFingerprint,
            noteItems: items,
            notesDocument: notesDocument,
            summary: summary,
            passage: passage,
            otherPassage: otherPassage
        )
    }
}

@MainActor
final class SessionSummaryNotesRevealPresenterTests: XCTestCase {
    // MARK: - Fixtures

    private func makeEntry(sessionID: UUID = UUID()) -> CompletedSessionEntry {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionSummaryNotesRevealPresenterTests-\(UUID().uuidString)")
        let sessionPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)
        var manifest = SessionManifest.newSession(
            id: sessionID,
            audioFormat: AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32"),
            targetChunkDurationSeconds: 30
        )
        manifest.status = .completed
        return CompletedSessionEntry(manifest: manifest, sessionPaths: sessionPaths)
    }

    private func waitForHeldCalls(_ count: Int, in loader: ControllableSummarySourceLoader, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, await loader.heldCallCount < count {
            await Task.yield()
        }
        let heldCallCount = await loader.heldCallCount
        XCTAssertEqual(heldCallCount, count, "held loader calls", file: file, line: line)
    }

    /// A presenter whose request for `fixture` has already succeeded.
    private func readyPresenter(
        _ fixture: SummaryFixture,
        entry: CompletedSessionEntry
    ) async -> (SessionSummaryNotesRevealPresenter, ControllableSummarySourceLoader) {
        let loader = ControllableSummarySourceLoader()
        await loader.setResult(.success(fixture.snapshot()), for: fixture.notesGenerationID)
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)
        await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry)
        XCTAssertEqual(presenter.state, .ready(fixture.target))
        return (presenter, loader)
    }

    /// A presenter after one request whose fresh source is `snapshot`.
    private func request(
        _ fixture: SummaryFixture,
        snapshot: LectureSummarySourceSnapshot,
        entry: CompletedSessionEntry
    ) async -> SessionSummaryNotesRevealPresenter {
        let loader = ControllableSummarySourceLoader()
        await loader.setResult(.success(snapshot), for: fixture.notesGenerationID)
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)
        await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry)
        return presenter
    }

    private func revalidated(
        _ presenter: SessionSummaryNotesRevealPresenter,
        for entry: CompletedSessionEntry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SummaryNotesRevealApplication {
        let application = await presenter.revalidateReadyTarget(for: entry)
        return try XCTUnwrap(application, file: file, line: line)
    }

    private func assertFailedWithoutPin(
        _ presenter: SessionSummaryNotesRevealPresenter,
        _ failure: SummaryNotesRevealFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(presenter.state, .failed(failure), file: file, line: line)
        XCTAssertNil(presenter.pendingTarget, file: file, line: line)
        XCTAssertNil(presenter.pinnedNotesGenerationID, file: file, line: line)
    }

    // MARK: - Initial request

    func testInitialStateIsIdleAndUnpinned() {
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: ControllableSummarySourceLoader())
        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.sessionID)
        XCTAssertNil(presenter.pendingTarget)
        XCTAssertNil(presenter.pinnedNotesGenerationID)
    }

    func testValidRequestLoadsExactSummarySourceAndBecomesReadyAndPinned() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)

        let (presenter, loader) = await readyPresenter(fixture, entry: entry)

        let requests = await loader.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sessionID, fixture.sessionID)
        XCTAssertEqual(requests.first?.notesGenerationID, fixture.notesGenerationID)
        XCTAssertEqual(presenter.sessionID, fixture.sessionID)
        XCTAssertEqual(presenter.pendingTarget, fixture.target)
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
        XCTAssertEqual(presenter.pinnedNotesGenerationID(forSessionID: fixture.sessionID), fixture.notesGenerationID)
        XCTAssertNil(presenter.pinnedNotesGenerationID(forSessionID: UUID()))
    }

    func testSourceSessionMismatchFailsWithoutPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let presenter = await request(fixture, snapshot: fixture.snapshot(sessionID: UUID()), entry: entry)
        assertFailedWithoutPin(presenter, .sourceUnavailable)
    }

    func testSourceNotesGenerationMismatchFailsWithoutPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let presenter = await request(fixture, snapshot: fixture.snapshot(notesGenerationID: UUID()), entry: entry)
        assertFailedWithoutPin(presenter, .sourceUnavailable)
    }

    func testNotesDocumentFingerprintMismatchFailsWithoutPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let changed = NotesDocumentFingerprint(algorithmVersion: 1, digestHex: String(repeating: "c", count: 64))
        let presenter = await request(fixture, snapshot: fixture.snapshot(notesDocumentFingerprint: changed), entry: entry)
        assertFailedWithoutPin(presenter, .sourceChanged)
    }

    func testTranscriptFingerprintMismatchFailsWithoutPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let changed = TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "d", count: 64))
        let presenter = await request(fixture, snapshot: fixture.snapshot(transcriptFingerprint: changed), entry: entry)
        assertFailedWithoutPin(presenter, .sourceChanged)
    }

    func testMissingSupportingNoteFailsClosed() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID, supportIndices: [1, 2])
        let withoutSecondSupport = fixture.noteItems.filter { $0.id != fixture.noteItems[2].id }
        let presenter = await request(fixture, snapshot: fixture.snapshot(items: withoutSecondSupport), entry: entry)
        assertFailedWithoutPin(presenter, .locationUnavailable)
    }

    func testDuplicateSupportOccurrenceInMalformedSourceFailsClosed() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID, supportIndices: [1])
        let duplicated = fixture.noteItems + [fixture.noteItems[1]]
        let presenter = await request(fixture, snapshot: fixture.snapshot(items: duplicated), entry: entry)
        assertFailedWithoutPin(presenter, .locationUnavailable)
    }

    func testSourceLoadErrorFailsWithoutPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let loader = ControllableSummarySourceLoader()
        await loader.setResult(.failure(LectureSummarySourceError.incompleteGeneration), for: fixture.notesGenerationID)
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)

        await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry)

        assertFailedWithoutPin(presenter, .sourceUnavailable)
    }

    func testPassageFromAnotherSummaryFailsWithoutLoading() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let other = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let loader = ControllableSummarySourceLoader()
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)

        await presenter.requestReveal(document: fixture.summary, passage: other.passage, for: entry)

        assertFailedWithoutPin(presenter, .locationUnavailable)
        let requests = await loader.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSummaryForAnotherSessionFailsWithoutLoading() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: UUID())
        let loader = ControllableSummarySourceLoader()
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)

        await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry)

        assertFailedWithoutPin(presenter, .sourceUnavailable)
        let requests = await loader.requests
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Supersession

    func testDifferentSourceRequestClearsOldTargetAndPinImmediately() async {
        let entry = makeEntry()
        let first = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let second = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(first, entry: entry)
        await loader.hold(second.notesGenerationID)

        let task = Task { await presenter.requestReveal(document: second.summary, passage: second.passage, for: entry) }
        await waitForHeldCalls(1, in: loader)

        XCTAssertEqual(presenter.state, .resolving)
        XCTAssertNil(presenter.pendingTarget)
        XCTAssertNil(presenter.pinnedNotesGenerationID)

        await loader.resumeHeldCall(0, with: .success(second.snapshot()))
        await task.value
        XCTAssertEqual(presenter.state, .ready(second.target))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, second.notesGenerationID)
    }

    /// A starts, B starts, B finishes, A finishes: only B publishes and pins.
    func testOutOfOrderRequestsOnlyNewestPublishesAndPins() async {
        let entry = makeEntry()
        let a = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let b = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let loader = ControllableSummarySourceLoader()
        await loader.hold(a.notesGenerationID)
        await loader.hold(b.notesGenerationID)
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)

        let taskA = Task { await presenter.requestReveal(document: a.summary, passage: a.passage, for: entry) }
        await waitForHeldCalls(1, in: loader)
        let taskB = Task { await presenter.requestReveal(document: b.summary, passage: b.passage, for: entry) }
        await waitForHeldCalls(2, in: loader)

        await loader.resumeHeldCall(1, with: .success(b.snapshot()))
        await taskB.value
        await loader.resumeHeldCall(0, with: .success(a.snapshot()))
        await taskA.value

        XCTAssertEqual(presenter.state, .ready(b.target))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, b.notesGenerationID)
    }

    func testFailedDifferentSourceRequestLeavesNeitherPreviousTargetNorPin() async {
        let entry = makeEntry()
        let first = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let second = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(first, entry: entry)
        await loader.setResult(.failure(LectureSummarySourceError.missingGeneration), for: second.notesGenerationID)

        await presenter.requestReveal(document: second.summary, passage: second.passage, for: entry)

        assertFailedWithoutPin(presenter, .sourceUnavailable)
    }

    // MARK: - Same-source replacement

    func testSameSourceRequestPreservesPinWhileResolvingAndSucceedsWithSamePin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        let pinned = presenter.pinnedSource
        await loader.hold(fixture.notesGenerationID)

        let task = Task { await presenter.requestReveal(document: fixture.summary, passage: fixture.otherPassage, for: entry) }
        await waitForHeldCalls(1, in: loader)

        XCTAssertEqual(presenter.state, .resolving)
        XCTAssertNil(presenter.pendingTarget, "the previous pending reveal is superseded")
        XCTAssertEqual(presenter.pinnedSource, pinned, "no fallback to the newest Notes while resolving")
        XCTAssertEqual(presenter.pinnedNotesGenerationID(forSessionID: fixture.sessionID), fixture.notesGenerationID)

        await loader.resumeHeldCall(0, with: .success(fixture.snapshot()))
        await task.value
        XCTAssertEqual(presenter.state, .ready(fixture.otherTarget))
        XCTAssertEqual(presenter.pinnedSource, pinned)
    }

    func testSameSourceOperationalFailureKeepsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        await loader.setResult(.failure(LectureSummarySourceError.sourceLoadFailed("transient")), for: fixture.notesGenerationID)

        await presenter.requestReveal(document: fixture.summary, passage: fixture.otherPassage, for: entry)

        XCTAssertEqual(presenter.state, .failed(.sourceUnavailable))
        XCTAssertNil(presenter.pendingTarget)
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    func testSameSourceUnavailableLocationKeepsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID, supportIndices: [1], otherSupportIndices: [3])
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        let withoutOtherSupport = fixture.noteItems.filter { $0.id != fixture.noteItems[3].id }
        await loader.setResult(.success(fixture.snapshot(items: withoutOtherSupport)), for: fixture.notesGenerationID)

        await presenter.requestReveal(document: fixture.summary, passage: fixture.otherPassage, for: entry)

        XCTAssertEqual(presenter.state, .failed(.locationUnavailable))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    func testSameSourceRequestFindingChangedSourceDropsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        let changed = NotesDocumentFingerprint(algorithmVersion: 1, digestHex: String(repeating: "f", count: 64))
        await loader.setResult(.success(fixture.snapshot(notesDocumentFingerprint: changed)), for: fixture.notesGenerationID)

        await presenter.requestReveal(document: fixture.summary, passage: fixture.otherPassage, for: entry)

        assertFailedWithoutPin(presenter, .sourceChanged)
    }

    func testCancelledSameSourceRequestKeepsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        await loader.setResult(.failure(CancellationError()), for: fixture.notesGenerationID)

        await presenter.requestReveal(document: fixture.summary, passage: fixture.otherPassage, for: entry)

        XCTAssertEqual(presenter.state, .idle, "cancellation is not a failure")
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    /// The Notes pane clears the old highlight on every new request; the
    /// signal must fire even when a same-source pin does not change.
    func testEveryRequestSignalsHighlightReplacementEvenWhenPinIsKept() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        let countAfterFirst = presenter.revealRequestCount
        await loader.hold(fixture.notesGenerationID)

        let task = Task { await presenter.requestReveal(document: fixture.summary, passage: fixture.otherPassage, for: entry) }
        await waitForHeldCalls(1, in: loader)

        XCTAssertEqual(presenter.revealRequestCount, countAfterFirst + 1)
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
        await loader.resumeHeldCall(0, with: .success(fixture.snapshot()))
        await task.value
    }

    /// Same generation ID, different Notes document fingerprint: a different
    /// source, so the pin must drop immediately.
    func testSameGenerationWithDifferentFingerprintIsADifferentSource() async {
        let entry = makeEntry()
        let generationID = UUID()
        let original = SummaryFixture.make(sessionID: entry.manifest.sessionID, notesGenerationID: generationID)
        let regenerated = SummaryFixture.make(sessionID: entry.manifest.sessionID, notesGenerationID: generationID, notesDocumentDigest: "c")
        let (presenter, loader) = await readyPresenter(original, entry: entry)
        await loader.hold(generationID)

        let task = Task { await presenter.requestReveal(document: regenerated.summary, passage: regenerated.passage, for: entry) }
        await waitForHeldCalls(1, in: loader)
        XCTAssertNil(presenter.pinnedSource)

        await loader.resumeHeldCall(0, with: .success(regenerated.snapshot()))
        await task.value
        XCTAssertEqual(presenter.pinnedSource, SummaryNotesSourceIdentity(document: regenerated.summary))
    }

    /// Same-source A starts, B starts, B succeeds, A completes against a
    /// changed source: A's result must not touch B's target or the pin.
    func testStaleSameSourceCompletionCannotMutateNewerTargetOrPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        await loader.hold(fixture.notesGenerationID)

        let taskA = Task { await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry) }
        await waitForHeldCalls(1, in: loader)
        let taskB = Task { await presenter.requestReveal(document: fixture.summary, passage: fixture.otherPassage, for: entry) }
        await waitForHeldCalls(2, in: loader)

        await loader.resumeHeldCall(1, with: .success(fixture.snapshot()))
        await taskB.value
        let changed = NotesDocumentFingerprint(algorithmVersion: 1, digestHex: String(repeating: "f", count: 64))
        await loader.resumeHeldCall(0, with: .success(fixture.snapshot(notesDocumentFingerprint: changed)))
        await taskA.value

        XCTAssertEqual(presenter.state, .ready(fixture.otherTarget))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    // MARK: - Application-time revalidation

    func testRevalidationSucceedsForExactIdentity() async throws {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)

        let application = try await revalidated(presenter, for: entry)

        XCTAssertEqual(application.target, fixture.target)
        XCTAssertEqual(presenter.state, .ready(fixture.target))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
        let requestCount = await loader.requests.count
        XCTAssertEqual(requestCount, 2, "revalidation must load a second fresh source")
    }

    func testRevalidationRejectsNotesFingerprintChangeAndDropsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        let changed = NotesDocumentFingerprint(algorithmVersion: 1, digestHex: String(repeating: "e", count: 64))
        await loader.setResult(.success(fixture.snapshot(notesDocumentFingerprint: changed)), for: fixture.notesGenerationID)

        let application = await presenter.revalidateReadyTarget(for: entry)

        XCTAssertNil(application)
        assertFailedWithoutPin(presenter, .sourceChanged)
    }

    /// An unshowable location is about this passage, not the source: the
    /// still-valid pin stays.
    func testRevalidationLocationUnavailableRejectsRevealButKeepsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        await loader.setResult(.success(fixture.snapshot(items: [fixture.noteItems[0]])), for: fixture.notesGenerationID)

        let application = await presenter.revalidateReadyTarget(for: entry)

        XCTAssertNil(application)
        XCTAssertEqual(presenter.state, .failed(.locationUnavailable))
        XCTAssertNil(presenter.pendingTarget)
        XCTAssertEqual(presenter.pinnedSource, SummaryNotesSourceIdentity(document: fixture.summary))
    }

    func testRevalidationRejectsLostSourceAndDropsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        await loader.setResult(.failure(LectureSummarySourceError.missingGeneration), for: fixture.notesGenerationID)

        let application = await presenter.revalidateReadyTarget(for: entry)

        XCTAssertNil(application)
        assertFailedWithoutPin(presenter, .sourceUnavailable)
    }

    func testStaleRevalidationCannotAlterNewerRequest() async {
        let entry = makeEntry()
        let first = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let second = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(first, entry: entry)
        await loader.setResult(.success(second.snapshot()), for: second.notesGenerationID)
        await loader.hold(first.notesGenerationID)

        let staleRevalidation = Task { await presenter.revalidateReadyTarget(for: entry) }
        await waitForHeldCalls(1, in: loader)
        await presenter.requestReveal(document: second.summary, passage: second.passage, for: entry)
        // Even a failing stale result must not touch the newer request.
        await loader.resumeHeldCall(0, with: .failure(LectureSummarySourceError.missingGeneration))
        let staleApplication = await staleRevalidation.value

        XCTAssertNil(staleApplication)
        XCTAssertEqual(presenter.state, .ready(second.target))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, second.notesGenerationID)
    }

    func testCancelledRevalidationLeavesTargetAndPinInPlace() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        await loader.setResult(.failure(CancellationError()), for: fixture.notesGenerationID)

        let application = await presenter.revalidateReadyTarget(for: entry)

        XCTAssertNil(application)
        XCTAssertEqual(presenter.state, .ready(fixture.target))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    func testRevalidationForAnotherSessionsEntryFailsAndDropsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)

        let application = await presenter.revalidateReadyTarget(for: makeEntry())

        XCTAssertNil(application)
        assertFailedWithoutPin(presenter, .sourceUnavailable)
        let requestCount = await loader.requests.count
        XCTAssertEqual(requestCount, 1, "no source load for another session's entry")
    }

    /// An older request whose load fails late must not replace a newer
    /// request's ready target or pin with its failure.
    func testStaleFailingRequestCannotAlterNewerRequest() async {
        let entry = makeEntry()
        let old = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let new = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let loader = ControllableSummarySourceLoader()
        await loader.hold(old.notesGenerationID)
        await loader.setResult(.success(new.snapshot()), for: new.notesGenerationID)
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)

        let staleTask = Task { await presenter.requestReveal(document: old.summary, passage: old.passage, for: entry) }
        await waitForHeldCalls(1, in: loader)
        await presenter.requestReveal(document: new.summary, passage: new.passage, for: entry)
        await loader.resumeHeldCall(0, with: .failure(LectureSummarySourceError.missingGeneration))
        await staleTask.value

        XCTAssertEqual(presenter.state, .ready(new.target))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, new.notesGenerationID)
    }

    func testRevalidationWithoutReadyTargetReturnsNil() async {
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: ControllableSummarySourceLoader())
        let application = await presenter.revalidateReadyTarget(for: makeEntry())
        XCTAssertNil(application)
        XCTAssertEqual(presenter.state, .idle)
    }

    // MARK: - Consume / reject / clear

    func testConsumeClearsReadyTargetButPreservesPin() async throws {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(fixture, entry: entry)
        let application = try await revalidated(presenter, for: entry)

        presenter.consume(application)

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.pendingTarget, "a remounted Notes pane has nothing to reapply")
        XCTAssertEqual(presenter.sessionID, fixture.sessionID)
        XCTAssertEqual(presenter.pinnedNotesGenerationID(forSessionID: fixture.sessionID), fixture.notesGenerationID)
    }

    func testOldTokenCannotConsumeOrRejectNewerEqualTarget() async throws {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(fixture, entry: entry)
        let oldApplication = try await revalidated(presenter, for: entry)

        await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry)
        XCTAssertEqual(presenter.state, .ready(fixture.target))

        presenter.consume(oldApplication)
        XCTAssertEqual(presenter.state, .ready(fixture.target))
        presenter.reject(oldApplication, with: .locationUnavailable)
        XCTAssertEqual(presenter.state, .ready(fixture.target))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    func testRejectForUnavailableSourceDropsPin() async throws {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(fixture, entry: entry)
        let application = try await revalidated(presenter, for: entry)

        presenter.reject(application, with: .sourceUnavailable)

        assertFailedWithoutPin(presenter, .sourceUnavailable)
    }

    func testRejectForUnavailableLocationKeepsPin() async throws {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(fixture, entry: entry)
        let application = try await revalidated(presenter, for: entry)

        presenter.reject(application, with: .locationUnavailable)

        XCTAssertEqual(presenter.state, .failed(.locationUnavailable))
        XCTAssertNil(presenter.pendingTarget)
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    func testClearPinRemovesPinAndPendingTargetAndInvalidatesApplication() async throws {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(fixture, entry: entry)
        let application = try await revalidated(presenter, for: entry)

        presenter.clearPin()

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.pendingTarget)
        XCTAssertNil(presenter.pinnedNotesGenerationID)
        presenter.reject(application, with: .locationUnavailable)
        XCTAssertEqual(presenter.state, .idle, "a cleared application cannot publish")
    }

    func testClearPinMakesInFlightRequestHarmless() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let loader = ControllableSummarySourceLoader()
        await loader.hold(fixture.notesGenerationID)
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)

        let task = Task { await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry) }
        await waitForHeldCalls(1, in: loader)
        presenter.clearPin()
        await loader.resumeHeldCall(0, with: .success(fixture.snapshot()))
        await task.value

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.pinnedNotesGenerationID)
    }

    func testInvalidateMakesLateCompletionsHarmless() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        await loader.hold(fixture.notesGenerationID)

        let revalidation = Task { await presenter.revalidateReadyTarget(for: entry) }
        await waitForHeldCalls(1, in: loader)
        let request = Task { await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry) }
        await waitForHeldCalls(2, in: loader)
        presenter.invalidate()
        await loader.resumeHeldCall(1, with: .success(fixture.snapshot()))
        await loader.resumeHeldCall(0, with: .success(fixture.snapshot()))
        await request.value
        let lateApplication = await revalidation.value

        XCTAssertNil(lateApplication)
        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.sessionID)
        XCTAssertNil(presenter.pinnedNotesGenerationID)
    }

    func testSamePassageActivatedAgainAfterConsumeRevealsAgain() async throws {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(fixture, entry: entry)
        let firstApplication = try await revalidated(presenter, for: entry)
        presenter.consume(firstApplication)

        await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry)
        XCTAssertEqual(presenter.pendingTarget, fixture.target)
        let secondApplication = try await revalidated(presenter, for: entry)
        XCTAssertNotEqual(firstApplication, secondApplication, "a fresh request yields a fresh token")
        presenter.consume(secondApplication)

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    // MARK: - Displayed-Summary reconciliation

    /// A different Summary generation from the same exact source keeps the
    /// pin and the pending reveal.
    func testDisplayedSummaryFromSameSourceKeepsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(fixture, entry: entry)
        let regeneratedFromSameSource = LectureSummaryDocument(
            generationID: UUID(),
            sessionID: fixture.summary.sessionID,
            sourceNotesGenerationID: fixture.summary.sourceNotesGenerationID,
            transcriptFingerprint: fixture.summary.transcriptFingerprint,
            sourceNotesDocumentFingerprint: fixture.summary.sourceNotesDocumentFingerprint,
            provenance: fixture.summary.provenance,
            sections: []
        )

        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: regeneratedFromSameSource))

        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
        XCTAssertEqual(presenter.state, .ready(fixture.target))
        XCTAssertEqual(presenter.displayedSummarySource, SummaryNotesSourceIdentity(document: fixture.summary))
    }

    func testDisplayedSummaryFromDifferentSourceClearsPinAndPendingReveal() async {
        let entry = makeEntry()
        let pinned = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let displayed = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(pinned, entry: entry)

        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: displayed.summary))

        XCTAssertNil(presenter.pinnedSource)
        XCTAssertNil(presenter.pendingTarget)
        XCTAssertEqual(presenter.state, .idle)
        XCTAssertEqual(presenter.displayedSummarySource, SummaryNotesSourceIdentity(document: displayed.summary))
    }

    /// The race: A's request is still loading (no pin yet) when Summary B
    /// from a different source becomes displayed. A is superseded at once,
    /// shows no failure, and its late success can never publish or pin.
    func testDifferentDisplayedSourceSupersedesInFlightRequestBeforeItPins() async {
        let entry = makeEntry()
        let a = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let b = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let loader = ControllableSummarySourceLoader()
        await loader.hold(a.notesGenerationID)
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)
        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: a.summary))

        let requestA = Task { await presenter.requestReveal(document: a.summary, passage: a.passage, for: entry) }
        await waitForHeldCalls(1, in: loader)
        XCTAssertEqual(presenter.state, .resolving)
        XCTAssertNil(presenter.pinnedSource)

        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: b.summary))
        XCTAssertEqual(presenter.state, .idle, "superseded without a failure")
        XCTAssertNil(presenter.pinnedSource)

        await loader.resumeHeldCall(0, with: .success(a.snapshot()))
        await requestA.value

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertNil(presenter.pendingTarget)
        XCTAssertNil(presenter.pinnedSource, "A's late completion never pins")
        XCTAssertEqual(presenter.displayedSummarySource, SummaryNotesSourceIdentity(document: b.summary))
    }

    /// Another Summary generation from exactly A's source does not disturb
    /// A's in-flight request.
    func testSameDisplayedSourceLetsInFlightRequestCompleteAndPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let loader = ControllableSummarySourceLoader()
        await loader.hold(fixture.notesGenerationID)
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)
        let regeneratedFromSameSource = LectureSummaryDocument(
            generationID: UUID(),
            sessionID: fixture.summary.sessionID,
            sourceNotesGenerationID: fixture.summary.sourceNotesGenerationID,
            transcriptFingerprint: fixture.summary.transcriptFingerprint,
            sourceNotesDocumentFingerprint: fixture.summary.sourceNotesDocumentFingerprint,
            provenance: fixture.summary.provenance,
            sections: []
        )

        let request = Task { await presenter.requestReveal(document: fixture.summary, passage: fixture.passage, for: entry) }
        await waitForHeldCalls(1, in: loader)
        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: regeneratedFromSameSource))
        XCTAssertEqual(presenter.state, .resolving)

        await loader.resumeHeldCall(0, with: .success(fixture.snapshot()))
        await request.value

        XCTAssertEqual(presenter.state, .ready(fixture.target))
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    /// After B supersedes A, a request from B pins B; A's late completion
    /// cannot alter B's target, pin, or the displayed source.
    func testStaleSupersededCompletionCannotMutateNewerDisplayedSourceOrPin() async {
        let entry = makeEntry()
        let a = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let b = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let loader = ControllableSummarySourceLoader()
        await loader.hold(a.notesGenerationID)
        await loader.setResult(.success(b.snapshot()), for: b.notesGenerationID)
        let presenter = SessionSummaryNotesRevealPresenter(sourceLoader: loader)
        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: a.summary))

        let requestA = Task { await presenter.requestReveal(document: a.summary, passage: a.passage, for: entry) }
        await waitForHeldCalls(1, in: loader)
        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: b.summary))
        await presenter.requestReveal(document: b.summary, passage: b.passage, for: entry)
        XCTAssertEqual(presenter.state, .ready(b.target))

        await loader.resumeHeldCall(0, with: .success(a.snapshot()))
        await requestA.value

        XCTAssertEqual(presenter.state, .ready(b.target))
        XCTAssertEqual(presenter.pinnedSource, SummaryNotesSourceIdentity(document: b.summary))
        XCTAssertEqual(presenter.displayedSummarySource, SummaryNotesSourceIdentity(document: b.summary))
    }

    func testInvalidateClearsDisplayedSource() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(fixture, entry: entry)
        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: fixture.summary))

        presenter.invalidate()

        XCTAssertNil(presenter.displayedSummarySource)
        XCTAssertNil(presenter.pinnedSource)
    }

    func testClearPinAndDismissFailureKeepDisplayedSource() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, _) = await readyPresenter(fixture, entry: entry)
        let displayed = SummaryNotesSourceIdentity(document: fixture.summary)
        presenter.reconcilePin(withDisplayedSummarySource: displayed)

        presenter.dismissFailure()
        XCTAssertEqual(presenter.displayedSummarySource, displayed)
        presenter.clearPin()
        XCTAssertEqual(presenter.displayedSummarySource, displayed)
        XCTAssertNil(presenter.pinnedSource)
    }

    /// Same generation ID but a different Notes document fingerprint is a
    /// different source.
    func testDisplayedSummaryWithSameGenerationButDifferentFingerprintClearsPin() async {
        let entry = makeEntry()
        let generationID = UUID()
        let pinned = SummaryFixture.make(sessionID: entry.manifest.sessionID, notesGenerationID: generationID)
        let displayed = SummaryFixture.make(sessionID: entry.manifest.sessionID, notesGenerationID: generationID, notesDocumentDigest: "c")
        let (presenter, _) = await readyPresenter(pinned, entry: entry)

        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: displayed.summary))

        XCTAssertNil(presenter.pinnedSource)
    }

    func testReconcileWithoutPinIsANoOp() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let presenter = await request(fixture, snapshot: fixture.snapshot(notesDocumentFingerprint: NotesDocumentFingerprint(algorithmVersion: 1, digestHex: String(repeating: "c", count: 64))), entry: entry)
        XCTAssertEqual(presenter.state, .failed(.sourceChanged))
        XCTAssertNil(presenter.pinnedSource)

        presenter.reconcilePin(withDisplayedSummarySource: SummaryNotesSourceIdentity(document: SummaryFixture.make(sessionID: entry.manifest.sessionID).summary))

        XCTAssertEqual(presenter.state, .failed(.sourceChanged))
        XCTAssertEqual(presenter.sessionID, entry.manifest.sessionID)
    }

    // MARK: - Failure dismissal

    func testDismissFailureClearsOnlyTheFailureAndKeepsPin() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID, supportIndices: [1], otherSupportIndices: [3])
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)
        let withoutOtherSupport = fixture.noteItems.filter { $0.id != fixture.noteItems[3].id }
        await loader.setResult(.success(fixture.snapshot(items: withoutOtherSupport)), for: fixture.notesGenerationID)
        await presenter.requestReveal(document: fixture.summary, passage: fixture.otherPassage, for: entry)
        XCTAssertEqual(presenter.state, .failed(.locationUnavailable))

        presenter.dismissFailure()

        XCTAssertEqual(presenter.state, .idle)
        XCTAssertEqual(presenter.pinnedNotesGenerationID, fixture.notesGenerationID)
    }

    func testDismissFailureLeavesReadyAndResolvingRequestsAlone() async {
        let entry = makeEntry()
        let fixture = SummaryFixture.make(sessionID: entry.manifest.sessionID)
        let (presenter, loader) = await readyPresenter(fixture, entry: entry)

        presenter.dismissFailure()
        XCTAssertEqual(presenter.state, .ready(fixture.target))

        await loader.hold(fixture.notesGenerationID)
        let task = Task { await presenter.requestReveal(document: fixture.summary, passage: fixture.otherPassage, for: entry) }
        await waitForHeldCalls(1, in: loader)
        presenter.dismissFailure()
        XCTAssertEqual(presenter.state, .resolving)

        await loader.resumeHeldCall(0, with: .success(fixture.snapshot()))
        await task.value
        XCTAssertEqual(presenter.state, .ready(fixture.otherTarget))
    }

    // MARK: - Messages

    func testFailureMessagesAreDistinctAndPresentationSafe() {
        let messages = [
            SummaryNotesRevealFailureMessage.message(for: .sourceUnavailable),
            SummaryNotesRevealFailureMessage.message(for: .sourceChanged),
            SummaryNotesRevealFailureMessage.message(for: .locationUnavailable),
        ]
        XCTAssertEqual(Set(messages).count, 3)
        for message in messages {
            XCTAssertFalse(message.contains("/"))
        }
    }
}

final class SummaryNotesRevealApplicationPlannerTests: XCTestCase {
    private func outcome(
        _ fixture: SummaryFixture,
        sessionID: UUID? = nil,
        pinned: UUID?? = nil,
        notes: SummaryNotesRevealDisplayedNotes? = nil
    ) -> SummaryNotesRevealApplicationOutcome {
        SummaryNotesRevealApplicationPlanner.outcome(
            for: fixture.target,
            sessionID: sessionID ?? fixture.sessionID,
            pinnedNotesGenerationID: pinned ?? fixture.notesGenerationID,
            notes: notes ?? .completed(fixture.notesDocument)
        )
    }

    func testSingleSupportingNoteIsHighlightedAndScrolledTo() {
        let fixture = SummaryFixture.make(sessionID: UUID(), supportIndices: [2])
        XCTAssertEqual(outcome(fixture), .apply(SummaryNotesRevealSelection(
            scrollTargetItemID: fixture.noteItems[2].id,
            selectedItemIDs: [fixture.noteItems[2].id]
        )))
    }

    func testMultipleSupportingNotesAreAllHighlightedAndFirstIsOnlyTheScrollTarget() {
        // Support crosses sections and is cited out of document order.
        let fixture = SummaryFixture.make(sessionID: UUID(), itemCount: 6, supportIndices: [4, 1, 3])
        guard case .apply(let selection) = outcome(fixture) else {
            return XCTFail("expected a selection")
        }
        let expected = [1, 3, 4].map { fixture.noteItems[$0].id }
        XCTAssertEqual(selection.selectedItemIDs, expected, "every supporting Note is highlighted")
        XCTAssertEqual(selection.scrollTargetItemID, expected[0], "the first Note in document order is the scroll target")
        let unrelated = [0, 2, 5].map { fixture.noteItems[$0].id }
        XCTAssertTrue(Set(selection.selectedItemIDs).isDisjoint(with: unrelated), "unrelated Notes are not highlighted")
    }

    func testSelectionFailureProducesNoPartialHighlight() {
        let fixture = SummaryFixture.make(sessionID: UUID(), supportIndices: [1, 2])
        var document = fixture.notesDocument
        document.sections[1].items.removeAll { $0.id == fixture.noteItems[2].id }
        XCTAssertEqual(outcome(fixture, notes: .completed(document)), .unavailable(.locationUnavailable))
    }

    func testWrongDisplayedNotesGenerationCannotApply() {
        let fixture = SummaryFixture.make(sessionID: UUID())
        // Pinned to another generation, or not pinned: wait, never apply.
        XCTAssertEqual(outcome(fixture, pinned: .some(UUID())), .notApplicable)
        XCTAssertEqual(outcome(fixture, pinned: .some(nil)), .notApplicable)
        // A displayed document of another generation never yields a selection.
        var otherGeneration = fixture.notesDocument
        otherGeneration.generationID = UUID()
        XCTAssertEqual(outcome(fixture, notes: .completed(otherGeneration)), .unavailable(.locationUnavailable))
    }

    func testOtherSessionOrLoadingWaits() {
        let fixture = SummaryFixture.make(sessionID: UUID())
        XCTAssertEqual(outcome(fixture, sessionID: UUID()), .notApplicable)
        XCTAssertEqual(outcome(fixture, notes: .loading), .notApplicable)
    }

    func testUnavailablePinnedNotesRejectAsSourceUnavailable() {
        let fixture = SummaryFixture.make(sessionID: UUID())
        XCTAssertEqual(outcome(fixture, notes: .unavailable), .unavailable(.sourceUnavailable))
    }
}
