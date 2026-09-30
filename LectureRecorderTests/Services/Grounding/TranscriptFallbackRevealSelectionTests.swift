import XCTest
@testable import LectureRecorder

final class TranscriptFallbackRevealSelectionTests: XCTestCase {
    private let sessionID = UUID()

    private var fingerprint: TranscriptSourceFingerprint {
        TranscriptSourceFingerprint.compute(sessionID: sessionID, units: [])
    }

    private func target(_ first: Int, _ last: Int) -> TranscriptRevealTarget {
        TranscriptRevealTarget(
            sessionID: sessionID,
            transcriptFingerprint: fingerprint,
            firstSequenceNumber: first,
            lastSequenceNumber: last
        )
    }

    private var failure: TranscriptionFailure {
        TranscriptionFailure(category: .engineThrew, message: "decode failed", retryDisposition: .retryable, failureDate: Date(), attemptNumber: 1)
    }

    private func completed(_ sequenceNumber: Int, _ text: String? = nil) -> OrderedSegment {
        OrderedSegment(sequenceNumber: sequenceNumber, state: .completed(text: text ?? "chunk \(sequenceNumber)"))
    }

    private func completed(_ sequenceNumbers: ClosedRange<Int>) -> [OrderedSegment] {
        sequenceNumbers.map { completed($0) }
    }

    private func select(_ target: TranscriptRevealTarget, _ segments: [OrderedSegment]) -> TranscriptFallbackRevealSelection? {
        TranscriptFallbackRevealSelectionBuilder.select(target, in: segments)
    }

    // MARK: - Selection

    func testSingleCompletedChunkIsSelectedAndIsTheScrollTarget() throws {
        let selection = try XCTUnwrap(select(target(1, 1), completed(0...2)))

        XCTAssertEqual(selection.scrollTargetSequenceNumber, 1)
        XCTAssertEqual(selection.selectedSequenceNumbers, [1])
    }

    func testContiguousMultiChunkSourceSelectsEveryChunkInTranscriptOrder() throws {
        let selection = try XCTUnwrap(select(target(1, 3), completed(0...4)))

        XCTAssertEqual(selection.scrollTargetSequenceNumber, 1)
        XCTAssertEqual(selection.selectedSequenceNumbers, [1, 2, 3])
    }

    func testRowsOutsideTheSourceRangeAreExcluded() throws {
        // Out-of-range rows may be in any state; they are never consulted.
        let segments = [
            OrderedSegment(sequenceNumber: 0, state: .missing),
            completed(1),
            completed(2),
            OrderedSegment(sequenceNumber: 3, state: .failed(failure)),
        ]

        let selection = try XCTUnwrap(select(target(1, 2), segments))

        XCTAssertEqual(selection.selectedSequenceNumbers, [1, 2])
    }

    func testEmptyCompletedTextIsStillTranscriptEvidence() throws {
        let selection = try XCTUnwrap(select(target(1, 1), [completed(0), completed(1, ""), completed(2)]))

        XCTAssertEqual(selection.selectedSequenceNumbers, [1])
    }

    // MARK: - Fail closed

    func testMissingReferencedChunkRowFailsClosedNeverPartial() {
        // Chunk 2 has no row at all.
        XCTAssertNil(select(target(1, 3), [completed(0), completed(1), completed(3)]))
    }

    func testNonCompletedReferencedRowNeverCountsAsEvidence() {
        let nonCompletedStates: [OrderedSegment.State] = [.failed(failure), .inProgress, .missing]
        for state in nonCompletedStates {
            let segments = [completed(0), completed(1), OrderedSegment(sequenceNumber: 2, state: state), completed(3)]
            XCTAssertNil(select(target(1, 2), segments), "\(state) row inside the range")
            XCTAssertNil(select(target(2, 2), segments), "\(state) row as the whole range")
        }
    }

    func testNonCompletedDuplicateOfACompletedRowStillFailsClosed() {
        // Coverage by the completed row must not hide contradictory state.
        let segments = [completed(0), completed(1), OrderedSegment(sequenceNumber: 1, state: .missing)]

        XCTAssertNil(select(target(1, 1), segments))
    }

    func testNoMatchingRowsFailsClosed() {
        XCTAssertNil(select(target(5, 6), completed(0...2)))
        XCTAssertNil(select(target(0, 0), []))
    }

    func testInvertedRangeFailsClosed() {
        XCTAssertNil(select(target(2, 1), completed(0...3)))
    }

    func testExtremeBoundsNeitherTrapNorIterateTheRange() {
        let segments = completed(0...3)

        // Width overflows `Int`.
        XCTAssertNil(select(target(Int.min, Int.max), segments))
        XCTAssertNil(select(target(-1, Int.max), segments))
        // Width does not overflow but is astronomically larger than the rows.
        XCTAssertNil(select(target(0, Int.max - 1), segments))
        XCTAssertNil(select(target(Int.min, 3), segments))
        // A range at the very top of `Int` is still handled exactly.
        let top = [completed(Int.max - 1), completed(Int.max)]
        XCTAssertEqual(select(target(Int.max - 1, Int.max), top)?.selectedSequenceNumbers, [Int.max - 1, Int.max])
        XCTAssertEqual(select(target(Int.max, Int.max), top)?.selectedSequenceNumbers, [Int.max])
    }

    // MARK: - Order

    func testSelectionFollowsTheDisplayedRowOrder() throws {
        // Rows are revealed where they are displayed; the scroll target is
        // the first selected row shown, not the lowest sequence number.
        let segments = [completed(3), completed(1), completed(2), completed(0)]

        let selection = try XCTUnwrap(select(target(1, 3), segments))

        XCTAssertEqual(selection.selectedSequenceNumbers, [3, 1, 2])
        XCTAssertEqual(selection.scrollTargetSequenceNumber, 3)
    }
}
