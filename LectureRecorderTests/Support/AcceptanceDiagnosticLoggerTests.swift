import XCTest
@testable import LectureRecorder

final class AcceptanceDiagnosticLoggerTests: XCTestCase {
    private var tempDirectory: URL!
    private var logFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcceptanceDiagnosticLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        logFileURL = tempDirectory.appendingPathComponent("acceptance-test.jsonl")
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeLogger(isEnabled: Bool) -> AcceptanceDiagnosticLogger {
        AcceptanceDiagnosticLogger(
            isEnabled: isEnabled,
            fileURLProvider: { [logFileURL] in logFileURL }
        )
    }

    private func readLines() throws -> [String] {
        let data = try Data(contentsOf: logFileURL)
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Disabled

    func testDisabledLoggerProducesNoFile() {
        let logger = makeLogger(isEnabled: false)
        logger.log("summary.started", metadata: ["sessionID": .uuid(UUID())])
        logger.waitUntilAllEventsWritten()

        XCTAssertFalse(FileManager.default.fileExists(atPath: logFileURL.path))
        XCTAssertNil(logger.resolvedFileURLForTesting())
    }

    // MARK: - Enabled: single event

    func testEnabledLoggerProducesValidJSONLine() throws {
        let logger = makeLogger(isEnabled: true)
        let sessionID = UUID()
        logger.log(
            "summary.started",
            metadata: ["sessionID": .uuid(sessionID), "batchCount": .int(3)],
            elapsedSeconds: 1.5
        )
        logger.waitUntilAllEventsWritten()

        let lines = try readLines()
        XCTAssertEqual(lines.count, 1)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "summary.started")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["elapsedSeconds"] as? Double, 1.5)
        XCTAssertNotNil(object["timestamp"] as? String)
        XCTAssertNotNil(object["pid"] as? Int)

        let metadata = try XCTUnwrap(object["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["sessionID"] as? String, sessionID.uuidString)
        XCTAssertEqual(metadata["batchCount"] as? Int, 3)
    }

    // MARK: - Enabled: multiple events

    func testMultipleEventsEachRemainSeparateValidJSONLines() throws {
        let logger = makeLogger(isEnabled: true)
        logger.log("summary.started")
        logger.log("summary.analysis.batch.started", metadata: ["batchIndex": .int(0)])
        logger.log("summary.completed", elapsedSeconds: 4.2)
        logger.waitUntilAllEventsWritten()

        let lines = try readLines()
        XCTAssertEqual(lines.count, 3)

        var events: [String] = []
        for line in lines {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            events.append(try XCTUnwrap(object["event"] as? String))
        }
        XCTAssertEqual(events, ["summary.started", "summary.analysis.batch.started", "summary.completed"])
    }

    // MARK: - Metadata serialization

    func testMetadataSerializesEveryValueCase() throws {
        let logger = makeLogger(isEnabled: true)
        let id = UUID()
        logger.log("test.metadata", metadata: [
            "aString": .string("value"),
            "anInt": .int(7),
            "aDouble": .double(2.5),
            "aBool": .bool(true),
            "aUUID": .uuid(id),
            "aNull": .null,
            "anOptionalPresent": .string("present" as String?),
            "anOptionalAbsent": .string(nil as String?)
        ])
        logger.waitUntilAllEventsWritten()

        let lines = try readLines()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        let metadata = try XCTUnwrap(object["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["aString"] as? String, "value")
        XCTAssertEqual(metadata["anInt"] as? Int, 7)
        XCTAssertEqual(metadata["aDouble"] as? Double, 2.5)
        XCTAssertEqual(metadata["aBool"] as? Bool, true)
        XCTAssertEqual(metadata["aUUID"] as? String, id.uuidString)
        XCTAssertTrue(metadata["aNull"] is NSNull)
        XCTAssertEqual(metadata["anOptionalPresent"] as? String, "present")
        XCTAssertTrue(metadata["anOptionalAbsent"] is NSNull)
    }

    // MARK: - Write failure never propagates

    func testUnresolvableFilePathNeverThrowsOrCrashes() {
        let logger = AcceptanceDiagnosticLogger(isEnabled: true, fileURLProvider: { nil })
        logger.log("summary.started")
        logger.waitUntilAllEventsWritten()
        XCTAssertNil(logger.resolvedFileURLForTesting())
    }

    func testUnwritableDirectoryNeverThrowsOrCrashes() {
        // A path whose parent cannot be created (a regular file standing
        // where a directory is expected) — this must degrade to a silent
        // no-op, never a thrown error or crash.
        let blockingFile = tempDirectory.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: blockingFile.path, contents: Data())
        let unwritableURL = blockingFile.appendingPathComponent("acceptance.jsonl")
        let logger = AcceptanceDiagnosticLogger(isEnabled: true, fileURLProvider: { unwritableURL })

        logger.log("summary.started")
        logger.waitUntilAllEventsWritten()

        XCTAssertNil(logger.resolvedFileURLForTesting())
    }

    // MARK: - Concurrent calls

    func testConcurrentCallsProduceOneCompleteLinePerEvent() throws {
        let logger = makeLogger(isEnabled: true)
        let eventCount = 200
        DispatchQueue.concurrentPerform(iterations: eventCount) { index in
            logger.log("concurrent.event", metadata: ["index": .int(index)])
        }
        logger.waitUntilAllEventsWritten()

        let lines = try readLines()
        XCTAssertEqual(lines.count, eventCount)

        var seenIndices = Set<Int>()
        for line in lines {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            let metadata = try XCTUnwrap(object["metadata"] as? [String: Any])
            seenIndices.insert(try XCTUnwrap(metadata["index"] as? Int))
        }
        XCTAssertEqual(seenIndices, Set(0..<eventCount))
    }

    // MARK: - Timing

    func testElapsedSecondsReflectsOrderedInstantsWithoutSleeping() {
        let start = AcceptanceDiagnosticLogger.startInstant()
        let earlyElapsed = AcceptanceDiagnosticLogger.elapsedSeconds(since: start)
        // A second, later instant must never report a smaller elapsed
        // duration than an earlier one measured from the same start —
        // exercised via ordering rather than a real sleep, so this stays
        // fast and non-flaky.
        let laterElapsed = AcceptanceDiagnosticLogger.elapsedSeconds(since: start)
        XCTAssertGreaterThanOrEqual(earlyElapsed, 0)
        XCTAssertGreaterThanOrEqual(laterElapsed, earlyElapsed)
    }
}
