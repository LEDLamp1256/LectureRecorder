import XCTest
@testable import LectureRecorder

final class WhisperTimestampTests: XCTestCase {
    func testConvertsTenMillisecondUnitsExactly() throws {
        XCTAssertEqual(try WhisperTimestamp.milliseconds(fromTenMillisecondUnits: 0), 0)
        XCTAssertEqual(try WhisperTimestamp.milliseconds(fromTenMillisecondUnits: 123), 1_230)
        XCTAssertEqual(try WhisperTimestamp.milliseconds(fromTenMillisecondUnits: Int64.max / 10), (Int64.max / 10) * 10)
    }

    func testRejectsNegativeAndOverflowingValues() {
        XCTAssertThrowsError(try WhisperTimestamp.milliseconds(fromTenMillisecondUnits: -1)) {
            XCTAssertEqual($0 as? WhisperTimestampError, .negative)
        }
        XCTAssertThrowsError(try WhisperTimestamp.milliseconds(fromTenMillisecondUnits: Int64.max / 10 + 1)) {
            XCTAssertEqual($0 as? WhisperTimestampError, .overflow)
        }
    }
}
