import XCTest
@testable import LectureRecorder

final class CompletedSessionWorkspaceLayoutTests: XCTestCase {
    private typealias Layout = CompletedSessionWorkspaceLayout

    func testBreakpointFitsEveryPaneMinimumPlusDividers() {
        let paneMinimums = Layout.transcriptMinimumWidth + Layout.notesMinimumWidth + Layout.summaryMinimumWidth
        XCTAssertGreaterThan(Layout.dividerAllowance, 0)
        XCTAssertEqual(Layout.sideBySideMinimumWidth, paneMinimums + Layout.dividerAllowance)
    }

    func testSideBySideOnlyAtOrAboveBreakpoint() {
        XCTAssertFalse(Layout.usesSideBySide(availableWidth: Layout.sideBySideMinimumWidth - 1))
        XCTAssertTrue(Layout.usesSideBySide(availableWidth: Layout.sideBySideMinimumWidth))
        XCTAssertTrue(Layout.usesSideBySide(availableWidth: Layout.sideBySideMinimumWidth + 400))
        XCTAssertFalse(Layout.usesSideBySide(availableWidth: 0))
    }

    /// Transcript's widest fixed row is the playback bar: Play and Reset
    /// (~80pt each), the slider's 160pt minimum, an elapsed / total label as
    /// long as `9:59:59 / 9:59:59` (~106pt), three 12pt gaps, and 20pt
    /// padding per side — ~502pt. Below that, the oversized content is
    /// centered and its leading edge slides under the sidebar.
    func testTranscriptMinimumCoversPlaybackBar() {
        let playbackBar: CGFloat = 80 + 80 + 160 + 106 + 3 * 12 + 2 * 20
        XCTAssertGreaterThanOrEqual(Layout.transcriptMinimumWidth, playbackBar)
    }

    /// Notes and Summary rows (Generate / Continue / Cancel) measured 288pt
    /// and 309pt, plus 20pt padding per side.
    func testNotesAndSummaryMinimumsCoverTheirActionRows() {
        XCTAssertGreaterThanOrEqual(Layout.notesMinimumWidth, 288 + 2 * 20)
        XCTAssertGreaterThanOrEqual(Layout.summaryMinimumWidth, 309 + 2 * 20)
    }
}
