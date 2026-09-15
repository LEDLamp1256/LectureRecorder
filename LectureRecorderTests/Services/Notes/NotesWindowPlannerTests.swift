import XCTest
@testable import LectureRecorder

final class NotesWindowPlannerTests: XCTestCase {
    private func makeUnits(texts: [String]) -> [NotesTranscriptSourceUnit] {
        texts.enumerated().map { index, text in
            NotesTranscriptSourceUnit(
                sequenceNumber: index,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: index),
                text: text,
                startOffsetSeconds: Double(index) * 30,
                durationSeconds: 30
            )
        }
    }

    private func assertFullContiguousCoverage(_ windows: [NotesInputWindow], unitCount: Int) {
        var covered: [Int] = []
        for window in windows {
            covered.append(contentsOf: window.firstSequenceNumber...window.lastSequenceNumber)
        }
        XCTAssertEqual(covered, Array(0..<unitCount))
    }

    func testSmallTranscriptProducesOneWindow() throws {
        let units = makeUnits(texts: ["short one", "short two"])
        let windows = NotesWindowPlanner.plan(units: units, budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 1_000))

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].firstSequenceNumber, 0)
        XCTAssertEqual(windows[0].lastSequenceNumber, 1)
        XCTAssertEqual(windows[0].unitCount, 2)
        XCTAssertFalse(windows[0].isOversizedSingleUnit)
    }

    func testLongTranscriptProducesMultipleOrderedWindowsWithFullCoverageNoGapsNoDuplication() throws {
        let units = makeUnits(texts: (0..<10).map { String(repeating: "word ", count: 20) + "\($0)" })
        let windows = NotesWindowPlanner.plan(units: units, budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 150))

        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertEqual(windows.map(\.windowIndex), Array(0..<windows.count))
        assertFullContiguousCoverage(windows, unitCount: units.count)
    }

    func testDeterministicRepeatedPlanning() throws {
        let units = makeUnits(texts: (0..<8).map { "unit-\($0)-" + String(repeating: "x", count: 40) })
        let budget = try NotesWindowBudget(maxUTF8BytesPerWindow: 100)
        XCTAssertEqual(
            NotesWindowPlanner.plan(units: units, budget: budget),
            NotesWindowPlanner.plan(units: units, budget: budget)
        )
    }

    func testConfigurableBudgetChangesPlanPredictably() throws {
        let units = makeUnits(texts: (0..<6).map { _ in String(repeating: "a", count: 50) })
        let smallBudgetWindows = NotesWindowPlanner.plan(units: units, budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 60))
        let largeBudgetWindows = NotesWindowPlanner.plan(units: units, budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 600))

        XCTAssertGreaterThan(smallBudgetWindows.count, largeBudgetWindows.count)
        XCTAssertEqual(largeBudgetWindows.count, 1)
    }

    func testOversizedSingleUnitIsPlannedExplicitlyAndDeterministically() throws {
        let units = makeUnits(texts: ["short", String(repeating: "z", count: 500), "short again"])
        let windows = NotesWindowPlanner.plan(units: units, budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 100))

        let oversized = windows.filter(\.isOversizedSingleUnit)
        XCTAssertEqual(oversized.count, 1)
        XCTAssertEqual(oversized[0].firstSequenceNumber, 1)
        XCTAssertEqual(oversized[0].lastSequenceNumber, 1)
        assertFullContiguousCoverage(windows, unitCount: units.count)
    }

    func testMaxUnitsPerWindowCapsGrouping() throws {
        let units = makeUnits(texts: (0..<5).map { "u\($0)" })
        let windows = NotesWindowPlanner.plan(
            units: units,
            budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 10_000, maxUnitsPerWindow: 2)
        )
        XCTAssertEqual(windows.map(\.unitCount), [2, 2, 1])
        assertFullContiguousCoverage(windows, unitCount: units.count)
    }

    func testEmptyUnitsProducesNoWindows() throws {
        XCTAssertEqual(NotesWindowPlanner.plan(units: [], budget: try NotesWindowBudget(maxUTF8BytesPerWindow: 100)), [])
    }

    func testNonPositiveByteLimitRejected() {
        XCTAssertThrowsError(try NotesWindowBudget(maxUTF8BytesPerWindow: 0)) { error in
            XCTAssertEqual(error as? NotesWindowBudgetError, .nonPositiveByteLimit(0))
        }
        XCTAssertThrowsError(try NotesWindowBudget(maxUTF8BytesPerWindow: -10)) { error in
            XCTAssertEqual(error as? NotesWindowBudgetError, .nonPositiveByteLimit(-10))
        }
    }

    func testNonPositiveUnitLimitRejected() {
        XCTAssertThrowsError(try NotesWindowBudget(maxUTF8BytesPerWindow: 100, maxUnitsPerWindow: 0)) { error in
            XCTAssertEqual(error as? NotesWindowBudgetError, .nonPositiveUnitLimit(0))
        }
        XCTAssertThrowsError(try NotesWindowBudget(maxUTF8BytesPerWindow: 100, maxUnitsPerWindow: -1)) { error in
            XCTAssertEqual(error as? NotesWindowBudgetError, .nonPositiveUnitLimit(-1))
        }
    }
}
