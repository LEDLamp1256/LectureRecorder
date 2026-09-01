import XCTest
@testable import LectureRecorder

final class FileSystemLocatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemLocatorTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testBuildPathsCreatesSessionChunksAndLogsDirectories() throws {
        let sessionID = UUID()
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)

        var isDirectory: ObjCBool = false

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sessionDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.chunksDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.logsDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        XCTAssertEqual(paths.manifestURL.lastPathComponent, "session.json")
        XCTAssertEqual(paths.logFileURL.lastPathComponent, "recording.log")
        XCTAssertEqual(paths.sessionDirectory.lastPathComponent, sessionID.uuidString)
    }

    func testBuildPathsIsIdempotentWhenCalledTwice() throws {
        let sessionID = UUID()
        _ = try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID)

        XCTAssertNoThrow(try DefaultFileSystemLocator.buildPaths(rootDirectory: tempDirectory, sessionID: sessionID))
    }

    func testEnsureDirectoryExistsThrowsWhenPathIsARegularFile() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let filePath = tempDirectory.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: filePath.path, contents: Data("x".utf8))

        XCTAssertThrowsError(try DefaultFileSystemLocator.ensureDirectoryExists(filePath)) { error in
            guard case FileSystemError.pathExistsButIsNotADirectory = error else {
                XCTFail("Expected pathExistsButIsNotADirectory, got \(error)")
                return
            }
        }
    }
}
