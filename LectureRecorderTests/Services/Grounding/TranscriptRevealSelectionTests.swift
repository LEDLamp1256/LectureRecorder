import XCTest
@testable import LectureRecorder

final class TranscriptRevealSelectionTests: XCTestCase {
    private let sessionID = UUID()

    private var fingerprint: TranscriptSourceFingerprint {
        TranscriptSourceFingerprint.compute(sessionID: sessionID, units: [])
    }

    private func target(_ first: Int, _ last: Int, sessionID: UUID? = nil) -> TranscriptRevealTarget {
        TranscriptRevealTarget(
            sessionID: sessionID ?? self.sessionID,
            transcriptFingerprint: fingerprint,
            firstSequenceNumber: first,
            lastSequenceNumber: last
        )
    }

    private func chunkStart(_ sequenceNumber: Int) -> TranscriptPlaybackItem {
        TranscriptPlaybackItem(
            chunkSequenceNumber: sequenceNumber,
            target: .chunkStart,
            text: "chunk \(sequenceNumber)",
            startSessionFrame: 0,
            endSessionFrame: 1_000
        )
    }

    /// `count` timed rows for one chunk. Frames are irrelevant to selection.
    private func timedSegments(_ sequenceNumber: Int, count: Int) -> [TranscriptPlaybackItem] {
        (0..<count).map { index in
            TranscriptPlaybackItem(
                chunkSequenceNumber: sequenceNumber,
                target: .timedSegment(index: index),
                text: "chunk \(sequenceNumber) segment \(index)",
                startSessionFrame: Int64(index) * 100,
                endSessionFrame: Int64(index) * 100 + 100
            )
        }
    }

    private func navigation(_ items: [TranscriptPlaybackItem]) -> TranscriptPlaybackNavigation {
        TranscriptPlaybackNavigation(sessionID: sessionID, sampleRate: 16_000, items: items)
    }

    private func timedID(_ sequenceNumber: Int, _ index: Int) -> TranscriptPlaybackItem.ID {
        TranscriptPlaybackItem.ID(chunkSequenceNumber: sequenceNumber, target: .timedSegment(index: index))
    }

    private func chunkStartID(_ sequenceNumber: Int) -> TranscriptPlaybackItem.ID {
        TranscriptPlaybackItem.ID(chunkSequenceNumber: sequenceNumber, target: .chunkStart)
    }

    // MARK: - Selection

    func testSingleChunkStartRowIsSelectedAndIsTheScrollTarget() throws {
        let navigation = navigation([chunkStart(0), chunkStart(1), chunkStart(2)])

        let selection = try XCTUnwrap(TranscriptRevealSelectionBuilder.select(target(1, 1), in: navigation))

        XCTAssertEqual(selection.scrollTargetID, chunkStartID(1))
        XCTAssertEqual(selection.selectedItemIDs, [chunkStartID(1)])
    }

    func testTimedChunkSelectsEverySegmentRowNotJustOne() throws {
        let navigation = navigation(timedSegments(0, count: 2) + timedSegments(1, count: 3) + timedSegments(2, count: 2))

        let selection = try XCTUnwrap(TranscriptRevealSelectionBuilder.select(target(1, 1), in: navigation))

        XCTAssertEqual(selection.scrollTargetID, timedID(1, 0))
        XCTAssertEqual(selection.selectedItemIDs, [timedID(1, 0), timedID(1, 1), timedID(1, 2)])
    }

    func testMultiChunkRangeSelectsEveryRowOfEveryChunkInNavigationOrder() throws {
        let navigation = navigation(
            [chunkStart(0)]
                + timedSegments(1, count: 2)
                + [chunkStart(2)]
                + timedSegments(3, count: 3)
                + [chunkStart(4)]
        )

        let selection = try XCTUnwrap(TranscriptRevealSelectionBuilder.select(target(1, 3), in: navigation))

        XCTAssertEqual(selection.scrollTargetID, timedID(1, 0))
        XCTAssertEqual(selection.selectedItemIDs, [
            timedID(1, 0), timedID(1, 1),
            chunkStartID(2),
            timedID(3, 0), timedID(3, 1), timedID(3, 2),
        ])
    }

    func testRowsOutsideTheRangeAreExcluded() throws {
        let navigation = navigation(timedSegments(0, count: 2) + [chunkStart(1)] + timedSegments(2, count: 2) + [chunkStart(3)])

        let selection = try XCTUnwrap(TranscriptRevealSelectionBuilder.select(target(1, 2), in: navigation))

        XCTAssertEqual(selection.selectedItemIDs, [chunkStartID(1), timedID(2, 0), timedID(2, 1)])
    }

    func testRangeCoveringTheWholeNavigationSelectsEveryRow() throws {
        let items = [chunkStart(0)] + timedSegments(1, count: 2)

        let selection = try XCTUnwrap(TranscriptRevealSelectionBuilder.select(target(0, 1), in: navigation(items)))

        XCTAssertEqual(selection.selectedItemIDs, items.map(\.id))
        XCTAssertEqual(selection.scrollTargetID, chunkStartID(0))
    }

    // MARK: - Fails closed

    func testWrongSessionFailsClosed() {
        let navigation = navigation([chunkStart(0), chunkStart(1)])

        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(0, 1, sessionID: UUID()), in: navigation))
    }

    func testMissingChunkInsideRangeFailsWholeMapping() {
        // Chunk 2 has no row: never a partial selection of chunks 1 and 3.
        let navigation = navigation([chunkStart(0), chunkStart(1)] + timedSegments(3, count: 2) + [chunkStart(4)])

        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(1, 3), in: navigation))
    }

    func testMissingFirstOrLastChunkOfRangeFailsClosed() {
        let navigation = navigation([chunkStart(1), chunkStart(2)])

        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(0, 2), in: navigation))
        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(1, 3), in: navigation))
    }

    func testNoMatchingRowsFailsClosed() {
        let navigation = navigation([chunkStart(0), chunkStart(1)])

        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(5, 6), in: navigation))
        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(-3, -1), in: navigation))
    }

    func testEmptyNavigationFailsClosed() {
        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(0, 0), in: navigation([])))
    }

    func testInvertedRangeFailsClosed() {
        let navigation = navigation([chunkStart(0), chunkStart(1)])

        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(1, 0), in: navigation))
    }

    // MARK: - Untrusted bounds

    /// Each call would effectively never finish if the range were iterated
    /// or materialized; with work bounded by the navigation it returns at
    /// once, and overflowing span/count arithmetic fails closed.
    func testExtremeBoundsNeitherTrapNorIterateTheRange() {
        let navigation = navigation([chunkStart(0)] + timedSegments(1, count: 2) + [chunkStart(2)])

        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(Int.min, Int.max), in: navigation))
        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(0, Int.max), in: navigation))
        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(Int.min, 2), in: navigation))
        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(-1, Int.max - 1), in: navigation))
        XCTAssertNil(TranscriptRevealSelectionBuilder.select(target(Int.max, Int.min), in: navigation))
    }

    func testExtremeSequenceNumbersSelectExactlyWhenFullyCovered() throws {
        let highNavigation = navigation([chunkStart(Int.max - 1)] + timedSegments(Int.max, count: 2))
        let highSelection = try XCTUnwrap(TranscriptRevealSelectionBuilder.select(target(Int.max - 1, Int.max), in: highNavigation))
        XCTAssertEqual(highSelection.selectedItemIDs, [chunkStartID(Int.max - 1), timedID(Int.max, 0), timedID(Int.max, 1)])

        let lowNavigation = navigation([chunkStart(Int.min), chunkStart(Int.min + 1)])
        let lowSelection = try XCTUnwrap(TranscriptRevealSelectionBuilder.select(target(Int.min, Int.min + 1), in: lowNavigation))
        XCTAssertEqual(lowSelection.selectedItemIDs, [chunkStartID(Int.min), chunkStartID(Int.min + 1)])
    }

    // MARK: - Target from T6-A resolution

    func testTargetPreservesResolvedSessionFingerprintAndChunkBounds() throws {
        let units = (0..<4).map { sequenceNumber in
            NotesTranscriptSourceUnit(
                sequenceNumber: sequenceNumber,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber),
                text: "unit \(sequenceNumber)",
                startOffsetSeconds: Double(sequenceNumber) * 30,
                durationSeconds: 30
            )
        }
        let snapshot = NotesTranscriptSourceSnapshot(
            schemaVersion: NotesTranscriptSourceSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            units: units,
            fingerprint: TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        )
        let resolved = try TranscriptSourceResolver.resolve(
            NotesSourceReference(sessionID: sessionID, firstSequenceNumber: 1, lastSequenceNumber: 2),
            generatedFrom: snapshot.fingerprint,
            in: snapshot
        )

        let revealTarget = TranscriptRevealTarget(resolved)

        XCTAssertEqual(revealTarget, TranscriptRevealTarget(
            sessionID: sessionID,
            transcriptFingerprint: snapshot.fingerprint,
            firstSequenceNumber: 1,
            lastSequenceNumber: 2
        ))
        let navigation = navigation([chunkStart(0)] + timedSegments(1, count: 2) + [chunkStart(2), chunkStart(3)])
        let selection = try XCTUnwrap(TranscriptRevealSelectionBuilder.select(revealTarget, in: navigation))
        XCTAssertEqual(selection.selectedItemIDs, [timedID(1, 0), timedID(1, 1), chunkStartID(2)])
    }
}
