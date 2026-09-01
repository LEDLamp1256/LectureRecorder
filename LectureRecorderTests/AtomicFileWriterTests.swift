import XCTest
@testable import LectureRecorder

final class AtomicFileWriterTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private struct Sample: Codable, Equatable {
        let name: String
        let value: Int
    }

    func testWriteAndReadRoundTrip() throws {
        let url = tempDirectory.appendingPathComponent("sample.json")
        let sample = Sample(name: "chunk", value: 42)

        try AtomicFileWriter.writeJSON(sample, to: url)
        let readBack: Sample = try AtomicFileWriter.readJSON(Sample.self, from: url)

        XCTAssertEqual(readBack, sample)
    }

    func testWriteCreatesMissingParentDirectories() throws {
        let nestedURL = tempDirectory
            .appendingPathComponent("nested/deeper")
            .appendingPathComponent("sample.json")
        let sample = Sample(name: "nested", value: 7)

        try AtomicFileWriter.writeJSON(sample, to: nestedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
    }

    func testWriteOverwritesExistingFileAtomically() throws {
        let url = tempDirectory.appendingPathComponent("sample.json")
        try AtomicFileWriter.writeJSON(Sample(name: "first", value: 1), to: url)
        try AtomicFileWriter.writeJSON(Sample(name: "second", value: 2), to: url)

        let readBack: Sample = try AtomicFileWriter.readJSON(Sample.self, from: url)
        XCTAssertEqual(readBack, Sample(name: "second", value: 2))
    }

    func testWriteLeavesNoTemporaryFilesBehindOnSuccess() throws {
        let url = tempDirectory.appendingPathComponent("sample.json")
        try AtomicFileWriter.writeJSON(Sample(name: "first", value: 1), to: url)
        try AtomicFileWriter.writeJSON(Sample(name: "second", value: 2), to: url)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        let temporaryFiles = contents.filter { $0.hasSuffix(".tmp") }

        XCTAssertTrue(temporaryFiles.isEmpty)
        XCTAssertEqual(contents, ["sample.json"])
    }

    /// Forces `FileManager.createFile` to fail by making the parent
    /// directory unwritable, and confirms no temporary file is left
    /// behind. Note: this relies on POSIX permission enforcement, which is
    /// bypassed when tests run as root (e.g. some CI containers) — if this
    /// test unexpectedly passes trivially in such an environment, that is
    /// the reason, not a regression.
    func testWriteCleansUpAndThrowsWhenTemporaryFileCannotBeCreated() throws {
        let restrictedDirectory = tempDirectory.appendingPathComponent("restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: restrictedDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restrictedDirectory.path)
        defer {
            // Restore permissions so tearDown can remove the directory.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restrictedDirectory.path)
        }

        let url = restrictedDirectory.appendingPathComponent("sample.json")
        let sample = Sample(name: "x", value: 1)

        XCTAssertThrowsError(try AtomicFileWriter.writeJSON(sample, to: url))

        let remaining = try FileManager.default.contentsOfDirectory(atPath: restrictedDirectory.path)
        XCTAssertTrue(remaining.isEmpty, "No temporary or destination file should remain after a failed write")
    }
}
