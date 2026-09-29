import XCTest
@testable import LectureRecorder

final class TranscriptSourceResolverTests: XCTestCase {
    private func makeUnit(
        _ sequenceNumber: Int,
        start: Double,
        duration: Double,
        fileName: String? = nil
    ) -> NotesTranscriptSourceUnit {
        NotesTranscriptSourceUnit(
            sequenceNumber: sequenceNumber,
            chunkFileName: fileName ?? TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber),
            text: "unit \(sequenceNumber)",
            startOffsetSeconds: start,
            durationSeconds: duration
        )
    }

    private func makeSnapshot(sessionID: UUID = UUID(), units: [NotesTranscriptSourceUnit]) -> NotesTranscriptSourceSnapshot {
        NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        )
    }

    /// Three chunks with deliberately uneven timing, as a real session's
    /// frame-derived offsets would be.
    private func makeSnapshot(sessionID: UUID = UUID()) -> NotesTranscriptSourceSnapshot {
        makeSnapshot(sessionID: sessionID, units: [
            makeUnit(0, start: 0, duration: 30.5),
            makeUnit(1, start: 30.5, duration: 29.75),
            makeUnit(2, start: 60.25, duration: 12.125),
        ])
    }

    private func resolve(
        _ reference: NotesSourceReference,
        in snapshot: NotesTranscriptSourceSnapshot
    ) throws -> ResolvedTranscriptSource {
        try TranscriptSourceResolver.resolve(reference, generatedFrom: snapshot.fingerprint, in: snapshot)
    }

    private func assertResolutionFails(
        _ reference: NotesSourceReference,
        in snapshot: NotesTranscriptSourceSnapshot,
        generatedFrom fingerprint: TranscriptSourceFingerprint? = nil,
        with expected: TranscriptSourceResolutionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try TranscriptSourceResolver.resolve(reference, generatedFrom: fingerprint ?? snapshot.fingerprint, in: snapshot),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? TranscriptSourceResolutionError, expected, file: file, line: line)
        }
    }

    // MARK: - Positive

    func testSingleReferenceResolvesToItsUnitTextAndChunk() throws {
        let snapshot = makeSnapshot()
        let resolved = try resolve(NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: 1), in: snapshot)

        XCTAssertEqual(resolved.sessionID, snapshot.sessionID)
        XCTAssertEqual(resolved.transcriptFingerprint, snapshot.fingerprint)
        XCTAssertEqual(resolved.firstSequenceNumber, 1)
        XCTAssertEqual(resolved.lastSequenceNumber, 1)
        XCTAssertEqual(resolved.units, [
            ResolvedTranscriptSourceUnit(
                sequenceNumber: 1,
                text: "unit 1",
                audioChunk: TranscriptSourceAudioChunk(fileName: "chunk_000001.caf", startOffsetSeconds: 30.5, endOffsetSeconds: 60.25)
            ),
        ])
        XCTAssertEqual(resolved.timing, .chunkBounded(startOffsetSeconds: 30.5, endOffsetSeconds: 60.25))
    }

    func testContiguousRangeResolvesEveryUnitInOrderWithChunkBoundedTiming() throws {
        let snapshot = makeSnapshot()
        let resolved = try resolve(
            NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 0, lastSequenceNumber: 2),
            in: snapshot
        )

        XCTAssertEqual(resolved.units.map(\.sequenceNumber), [0, 1, 2])
        XCTAssertEqual(resolved.units.map(\.text), ["unit 0", "unit 1", "unit 2"])
        XCTAssertEqual(resolved.units.map(\.audioChunk?.fileName), ["chunk_000000.caf", "chunk_000001.caf", "chunk_000002.caf"])
        XCTAssertEqual(resolved.units.map(\.audioChunk?.startOffsetSeconds), [0, 30.5, 60.25])
        XCTAssertEqual(resolved.units.map(\.audioChunk?.endOffsetSeconds), [30.5, 60.25, 72.375])
        XCTAssertEqual(resolved.timing, .chunkBounded(startOffsetSeconds: 0, endOffsetSeconds: 72.375))
    }

    func testResolutionLeavesReferenceAndSnapshotUnchanged() throws {
        let snapshot = makeSnapshot()
        let reference = NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 1, lastSequenceNumber: 2)
        let snapshotBefore = snapshot
        let referenceBefore = reference

        _ = try resolve(reference, in: snapshot)

        XCTAssertEqual(snapshot, snapshotBefore)
        XCTAssertEqual(reference, referenceBefore)
        XCTAssertEqual(snapshot.fingerprint, TranscriptSourceFingerprint.compute(sessionID: snapshot.sessionID, units: snapshot.units))
    }

    // MARK: - Rejection

    func testReferencePastTheEndFails() {
        let snapshot = makeSnapshot()
        assertResolutionFails(
            NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 2, lastSequenceNumber: 3),
            in: snapshot,
            with: .outOfRange(availableRange: 0...2)
        )
        assertResolutionFails(
            NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: -1),
            in: snapshot,
            with: .outOfRange(availableRange: 0...2)
        )
    }

    func testInvertedRangeFails() {
        let snapshot = makeSnapshot()
        assertResolutionFails(
            NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 2, lastSequenceNumber: 0),
            in: snapshot,
            with: .invertedRange(firstSequenceNumber: 2, lastSequenceNumber: 0)
        )
    }

    /// Untrusted persisted bounds spanning the whole `Int` range are
    /// rejected without overflow and without walking the range.
    func testExtremeRangeFailsWithoutOverflow() {
        let snapshot = makeSnapshot()
        assertResolutionFails(
            NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: Int.min, lastSequenceNumber: Int.max),
            in: snapshot,
            with: .outOfRange(availableRange: 0...2)
        )
        assertResolutionFails(
            NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 0, lastSequenceNumber: Int.max),
            in: snapshot,
            with: .outOfRange(availableRange: 0...2)
        )
    }

    /// Built directly to bypass `NotesTranscriptSourceBuilder`'s topology
    /// enforcement: a reference spanning missing transcript material fails
    /// even though both its endpoints exist.
    func testReferenceSpanningMissingTranscriptUnitFails() {
        let snapshot = makeSnapshot(units: [
            makeUnit(0, start: 0, duration: 30),
            makeUnit(2, start: 60, duration: 30),
        ])
        assertResolutionFails(
            NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 0, lastSequenceNumber: 2),
            in: snapshot,
            with: .outOfRange(availableRange: 0...2)
        )
    }

    func testEmptyTranscriptFails() {
        let snapshot = makeSnapshot(units: [])
        assertResolutionFails(
            NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: 0),
            in: snapshot,
            with: .emptySource
        )
    }

    func testDuplicateTranscriptSequenceNumberFails() {
        let snapshot = makeSnapshot(units: [
            makeUnit(0, start: 0, duration: 30),
            makeUnit(0, start: 0, duration: 30),
        ])
        assertResolutionFails(
            NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: 0),
            in: snapshot,
            with: .duplicateSourceSequenceNumber(0)
        )
    }

    func testReferenceFromAnotherSessionFails() {
        let snapshot = makeSnapshot()
        assertResolutionFails(
            NotesSourceReference(sessionID: UUID(), sequenceNumber: 0),
            in: snapshot,
            with: .sessionMismatch
        )
    }

    /// Generated content whose recorded transcript fingerprint differs from
    /// the transcript loaded now is stale: same session, same in-range
    /// sequence numbers, but not resolved.
    func testReferenceFromADifferentTranscriptOfTheSameSessionFails() {
        let snapshot = makeSnapshot()
        var changedUnits = snapshot.units
        changedUnits[1].text = "different wording"
        let otherTranscript = TranscriptSourceFingerprint.compute(sessionID: snapshot.sessionID, units: changedUnits)

        assertResolutionFails(
            NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: 1),
            in: snapshot,
            generatedFrom: otherTranscript,
            with: .transcriptMismatch
        )
    }

    // MARK: - Timing truthfulness

    func testUntrustworthyChunkTimingResolvesTextButClaimsNoTime() throws {
        let cases: [(String, NotesTranscriptSourceUnit)] = [
            ("NaN duration", makeUnit(1, start: 30, duration: .nan)),
            ("infinite start", makeUnit(1, start: .infinity, duration: 30)),
            ("negative start", makeUnit(1, start: -1, duration: 30)),
            ("zero duration", makeUnit(1, start: 30, duration: 0)),
            ("overflowing end", makeUnit(1, start: .greatestFiniteMagnitude, duration: .greatestFiniteMagnitude)),
            ("non-canonical file name", makeUnit(1, start: 30, duration: 30, fileName: "chunk_000007.caf")),
            ("missing file name", makeUnit(1, start: 30, duration: 30, fileName: "")),
        ]
        for (label, badUnit) in cases {
            let snapshot = makeSnapshot(units: [
                makeUnit(0, start: 0, duration: 30),
                badUnit,
                makeUnit(2, start: 60, duration: 30),
            ])

            let resolved = try resolve(
                NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 0, lastSequenceNumber: 2),
                in: snapshot
            )

            XCTAssertEqual(resolved.units.map(\.text), ["unit 0", "unit 1", "unit 2"], label)
            XCTAssertNotNil(resolved.units[0].audioChunk, label)
            XCTAssertNil(resolved.units[1].audioChunk, label)
            XCTAssertNotNil(resolved.units[2].audioChunk, label)
            XCTAssertEqual(resolved.timing, .unavailable, label)

            // A reference that avoids the bad chunk keeps its own time.
            let unaffected = try resolve(NotesSourceReference(sessionID: snapshot.sessionID, sequenceNumber: 2), in: snapshot)
            XCTAssertEqual(unaffected.timing, .chunkBounded(startOffsetSeconds: 60, endOffsetSeconds: 90), label)
        }
    }

    func testChunkStartsOutOfSequenceOrderClaimNoRangeTime() throws {
        let snapshot = makeSnapshot(units: [
            makeUnit(0, start: 60, duration: 30),
            makeUnit(1, start: 0, duration: 30),
        ])
        let resolved = try resolve(
            NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            in: snapshot
        )
        XCTAssertEqual(resolved.units.map(\.audioChunk?.startOffsetSeconds), [60, 0])
        XCTAssertEqual(resolved.timing, .unavailable)
    }

    /// Starts are ordered, but an earlier chunk ends after a later one: the
    /// range must end at the latest chunk end, not the last chunk's end.
    func testRangeEndBoundsEveryChunkWhenAnEarlierChunkEndsLast() throws {
        let snapshot = makeSnapshot(units: [
            makeUnit(0, start: 0, duration: 100),
            makeUnit(1, start: 30, duration: 30),
        ])
        let resolved = try resolve(
            NotesSourceReference(sessionID: snapshot.sessionID, firstSequenceNumber: 0, lastSequenceNumber: 1),
            in: snapshot
        )
        XCTAssertEqual(resolved.units.map(\.audioChunk?.endOffsetSeconds), [100, 60])
        XCTAssertEqual(resolved.timing, .chunkBounded(startOffsetSeconds: 0, endOffsetSeconds: 100))
    }

    // MARK: - Historical documents

    /// A Notes document persisted by an earlier recipe — historical
    /// `reconstructed`/`uncertain` fidelity, no `topics` — resolves every
    /// reference against its matching transcript and re-encodes to exactly
    /// its original JSON afterwards.
    func testHistoricalNotesDocumentReferencesResolveWithoutMutatingIt() throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"))
        let snapshot = makeSnapshot(sessionID: sessionID)
        let legacy = """
        {"createdDate":"2026-05-01T12:00:00.000Z","generationID":"00000000-0000-0000-0000-0000000000A2",\
        "overview":"Legacy overview.","provenance":{"recipeVersion":"t5e-apple-local-notes-v3"},"schemaVersion":1,\
        "sections":[{"heading":"Kinematics","id":"00000000-0000-0000-0000-0000000000B1","items":[\
        {"body":"v = dx/dt","fidelity":"reconstructed","id":"00000000-0000-0000-0000-0000000000C1","kind":"formula",\
        "sourceReferences":[{"firstSequenceNumber":0,"lastSequenceNumber":1,"sessionID":"\(sessionID.uuidString)"}],\
        "uncertaintyNote":"Repaired notation."},\
        {"body":"Possibly a boundary condition.","fidelity":"uncertain","id":"00000000-0000-0000-0000-0000000000C2",\
        "kind":"explanation","sourceReferences":[{"firstSequenceNumber":2,"lastSequenceNumber":2,"sessionID":"\(sessionID.uuidString)"}],\
        "uncertaintyNote":"Garbled wording."}]}],\
        "sessionID":"\(sessionID.uuidString)",\
        "transcriptFingerprint":{"algorithmVersion":\(snapshot.fingerprint.algorithmVersion),"digestHex":"\(snapshot.fingerprint.digestHex)"}}
        """
        let document = try AtomicFileWriter.defaultDecoder.decode(LectureNotesDocument.self, from: Data(legacy.utf8))
        let documentBefore = document

        let resolved = try document.sections.flatMap(\.items).flatMap(\.sourceReferences).map {
            try TranscriptSourceResolver.resolve($0, generatedFrom: document.transcriptFingerprint, in: snapshot)
        }

        XCTAssertEqual(resolved.map { $0.units.map(\.sequenceNumber) }, [[0, 1], [2]])
        XCTAssertEqual(resolved.map(\.timing), [
            .chunkBounded(startOffsetSeconds: 0, endOffsetSeconds: 60.25),
            .chunkBounded(startOffsetSeconds: 60.25, endOffsetSeconds: 72.375),
        ])
        XCTAssertEqual(document, documentBefore)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? NSDictionary)
        let reEncoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: AtomicFileWriter.defaultEncoder.encode(document)) as? NSDictionary
        )
        XCTAssertEqual(reEncoded, original)
    }
}
