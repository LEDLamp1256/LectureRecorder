import Darwin
import XCTest
@testable import LectureRecorder

/// Exercises `EmbeddedWorkerLocator.validate(candidate:expectedDirectory:fileManager:)`
/// directly against a temporary directory — independent of `Bundle`, so
/// every rejection rule (symlink, non-regular file, directory escape,
/// executable permission) can be proven deterministically without a real
/// signed app bundle.
final class EmbeddedWorkerLocatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddedWorkerLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeExecutableFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Accepted

    func testRealRegularExecutableIsAccepted() throws {
        let candidate = try makeExecutableFile(named: "helper", in: tempDirectory)
        let result = EmbeddedWorkerLocator.validate(candidate: candidate, expectedDirectory: tempDirectory)
        guard case .success(let resolved) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(resolved.standardizedFileURL.path, candidate.standardizedFileURL.path)
    }

    // MARK: - Rejected

    func testSymlinkToAnInDirectoryExecutableIsRejected() throws {
        let realExecutable = try makeExecutableFile(named: "real-helper", in: tempDirectory)
        let symlinkCandidate = tempDirectory.appendingPathComponent("symlinked-helper")
        try FileManager.default.createSymbolicLink(at: symlinkCandidate, withDestinationURL: realExecutable)

        let result = EmbeddedWorkerLocator.validate(candidate: symlinkCandidate, expectedDirectory: tempDirectory)
        guard case .failure(.helperNotARegularFile) = result else {
            return XCTFail("Expected .helperNotARegularFile for a symlink even to a valid in-directory executable, got \(result)")
        }
    }

    func testSymlinkEscapingTheExpectedDirectoryIsRejected() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddedWorkerLocatorTests-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }

        let outsideExecutable = try makeExecutableFile(named: "outside-helper", in: outsideDirectory)
        let escapingCandidate = tempDirectory.appendingPathComponent("escaping-helper")
        try FileManager.default.createSymbolicLink(at: escapingCandidate, withDestinationURL: outsideExecutable)

        let result = EmbeddedWorkerLocator.validate(candidate: escapingCandidate, expectedDirectory: tempDirectory)
        // A symlink is rejected as non-regular before containment is even
        // evaluated — either failure mode correctly refuses to trust it,
        // but confirm it's specifically not accepted.
        guard case .failure = result else {
            return XCTFail("Expected rejection of a symlink escaping the expected directory, got \(result)")
        }
    }

    func testFIFOWithExecutablePermissionIsRejected() throws {
        let fifoPath = tempDirectory.appendingPathComponent("helper-fifo").path
        let mkfifoResult = mkfifo(fifoPath, 0o755)
        try XCTSkipIf(mkfifoResult != 0, "mkfifo unavailable in this environment")

        let candidate = URL(fileURLWithPath: fifoPath)
        let result = EmbeddedWorkerLocator.validate(candidate: candidate, expectedDirectory: tempDirectory)
        guard case .failure(.helperNotARegularFile) = result else {
            return XCTFail("Expected .helperNotARegularFile for a FIFO, got \(result)")
        }
    }

    func testDirectoryIsRejected() throws {
        let directoryCandidate = tempDirectory.appendingPathComponent("helper-as-directory")
        try FileManager.default.createDirectory(at: directoryCandidate, withIntermediateDirectories: true)

        let result = EmbeddedWorkerLocator.validate(candidate: directoryCandidate, expectedDirectory: tempDirectory)
        guard case .failure(.helperNotARegularFile) = result else {
            return XCTFail("Expected .helperNotARegularFile for a directory, got \(result)")
        }
    }

    func testNonExecutableRegularFileIsRejected() throws {
        let candidate = tempDirectory.appendingPathComponent("helper-not-executable")
        try Data("not executable".utf8).write(to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: candidate.path)

        let result = EmbeddedWorkerLocator.validate(candidate: candidate, expectedDirectory: tempDirectory)
        guard case .failure(.helperNotExecutable) = result else {
            return XCTFail("Expected .helperNotExecutable for a non-executable regular file, got \(result)")
        }
    }

    func testMissingFileIsRejected() throws {
        let candidate = tempDirectory.appendingPathComponent("does-not-exist")
        let result = EmbeddedWorkerLocator.validate(candidate: candidate, expectedDirectory: tempDirectory)
        guard case .failure(.helperMissing) = result else {
            return XCTFail("Expected .helperMissing, got \(result)")
        }
    }
}
