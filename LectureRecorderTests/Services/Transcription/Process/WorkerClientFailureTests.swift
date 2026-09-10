import XCTest
@testable import LectureRecorder

/// Pure, process-free unit coverage for `WorkerClientFailure`'s identity
/// bounding, exercising `boundedIdentityPreview` directly against a
/// pathological input rather than relying on whatever a real (well-behaved)
/// worker fixture happens to send. Complements
/// `TranscriptionWorkerClientTests.testUnexpectedWorkerIdentityIsRejected`,
/// which proves the case is produced correctly end-to-end but never
/// constructs an `actual` large or multibyte enough to exercise truncation.
final class WorkerClientFailureTests: XCTestCase {
    func testUnexpectedWorkerIdentityWithExtremelyLargeMultibyteActualPreservesTheFullValueButBoundsTheDescription() {
        // Alternating 4-byte astral (🎉) and 3-byte CJK (字) scalars, so the
        // byte-oriented truncation walk in `boundedIdentityPreview` is
        // exercised against genuinely multibyte content, not ASCII.
        let unit = "🎉字"
        let hugeActual = String(repeating: unit, count: 2000) // ~14,000 UTF-8 bytes
        let failure = WorkerClientFailure.unexpectedWorkerIdentity(expected: "LectureRecorderWorkerFixture", actual: hugeActual)

        guard case .unexpectedWorkerIdentity(let expected, let storedActual) = failure else {
            return XCTFail("Expected .unexpectedWorkerIdentity")
        }
        XCTAssertEqual(expected, "LectureRecorderWorkerFixture")
        // The stored associated value is untouched — only the *rendered*
        // errorDescription is bounded, never the value itself.
        XCTAssertEqual(storedActual, hugeActual)
        XCTAssertEqual(storedActual.utf8.count, hugeActual.utf8.count)

        guard let description = failure.errorDescription else {
            return XCTFail("Expected a non-nil errorDescription")
        }

        // Tightly bounded: nowhere near the ~14KB input, regardless of how
        // large `actual` was.
        XCTAssertLessThan(description.utf8.count, 400, "errorDescription must stay tightly bounded regardless of actual's length")

        XCTAssertTrue(description.contains("truncated"), "expected the description to indicate truncation occurred")

        // No split/corrupted Unicode: a replacement character would only
        // appear here if a multibyte sequence had been cut mid-scalar.
        XCTAssertFalse(description.contains("\u{FFFD}"), "expected no replacement characters from a split multibyte sequence")
    }
}
