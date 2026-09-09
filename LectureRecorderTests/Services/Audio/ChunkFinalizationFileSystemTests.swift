//
//  ChunkFinalizationFileSystemTests.swift
//  LectureRecorder
//


import Synchronization
import XCTest
@testable import LectureRecorder

final class ChunkFinalizationFileSystemTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkFinalizationFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // MARK: - Production adapter: real syscalls on this machine's test volume

    /// Proves the real `fcntl(_:F_FULLFSYNC)` path runs without error under
    /// normal conditions. This proves the syscall returns success on this
    /// machine's volume — not durability itself, and not OS-crash or
    /// power-loss recovery, which no automated test can prove.
    func testSynchronizeFileSucceedsOnRealFile() throws {
        let url = tempDirectory.appendingPathComponent("chunk.caf")
        try write("real-audio-bytes", to: url)

        let sut = DarwinChunkFinalizationFileSystem()
        XCTAssertNoThrow(try sut.synchronizeFile(at: url))
        XCTAssertEqual(try read(url), "real-audio-bytes", "synchronizeFile must not alter file contents")
    }

    func testSynchronizeDirectorySucceedsOnRealDirectory() throws {
        let sut = DarwinChunkFinalizationFileSystem()
        XCTAssertNoThrow(try sut.synchronizeDirectory(at: tempDirectory))
    }

    func testRenameSucceedsWhenDestinationAbsent() throws {
        let source = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        let destination = tempDirectory.appendingPathComponent("chunk_000000.caf")
        try write("source-content", to: source)

        let sut = DarwinChunkFinalizationFileSystem()
        try sut.rename(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try read(destination), "source-content")
    }

    /// Exercises the real `renamex_np(_:_:RENAME_EXCL)` syscall — proves
    /// actual exclusive-rename behavior on this machine's local APFS test
    /// volume, not a simulated one.
    func testRenameThrowsCollisionAndPreservesBothFilesWhenDestinationExists() throws {
        let source = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        let destination = tempDirectory.appendingPathComponent("chunk_000000.caf")
        try write("source-content", to: source)
        try write("pre-existing-canonical-content", to: destination)

        let sut = DarwinChunkFinalizationFileSystem()
        XCTAssertThrowsError(try sut.rename(from: source, to: destination)) { error in
            guard let collision = error as? ChunkRenameCollision else {
                return XCTFail("Expected ChunkRenameCollision, got \(error)")
            }
            XCTAssertEqual(collision.destination, destination)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Source must survive a collision")
        XCTAssertEqual(try read(source), "source-content", "Source content must be untouched by a collision")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "Pre-existing destination must survive")
        XCTAssertEqual(try read(destination), "pre-existing-canonical-content", "Pre-existing destination must never be replaced")
    }

    /// Proves there is no fallback to a plain, replacing rename: even
    /// though a collision was thrown, the pre-existing canonical file's
    /// content is unchanged after the call, not silently overwritten by
    /// any retry path.
    func testRenameFailureIsNeverRetriedAsPlainReplacingRename() throws {
        let source = tempDirectory.appendingPathComponent("chunk_000000.partial.caf")
        let destination = tempDirectory.appendingPathComponent("chunk_000000.caf")
        try write("source-content", to: source)
        try write("must-survive", to: destination)

        let sut = DarwinChunkFinalizationFileSystem()
        _ = try? sut.rename(from: source, to: destination)

        XCTAssertEqual(try read(destination), "must-survive", "No fallback may ever replace an existing canonical chunk")
    }

    /// A rename failure that is NOT a destination collision (source
    /// missing entirely) must map to `ChunkDurabilityFailure`, never to
    /// `ChunkRenameCollision` — the two must stay distinguishable in both
    /// directions.
    func testRenameNonCollisionFailureIsNotMisreportedAsCollision() throws {
        let source = tempDirectory.appendingPathComponent("does-not-exist.partial.caf")
        let destination = tempDirectory.appendingPathComponent("chunk_000000.caf")

        let sut = DarwinChunkFinalizationFileSystem()
        XCTAssertThrowsError(try sut.rename(from: source, to: destination)) { error in
            guard let failure = error as? ChunkDurabilityFailure else {
                return XCTFail("Expected ChunkDurabilityFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .rename)
            XCTAssertNotEqual(failure.primaryErrno, EEXIST)
        }
    }

    // MARK: - Descriptor open failure (real, forced via a nonexistent path)

    func testSynchronizeFileOpenFailureReportsPartialFileOpenStage() throws {
        let missing = tempDirectory.appendingPathComponent("nonexistent.caf")
        let sut = DarwinChunkFinalizationFileSystem()

        XCTAssertThrowsError(try sut.synchronizeFile(at: missing)) { error in
            guard let failure = error as? ChunkDurabilityFailure else {
                return XCTFail("Expected ChunkDurabilityFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .partialFileOpen)
            XCTAssertEqual(failure.primaryErrno, ENOENT)
            XCTAssertNil(failure.secondaryCloseErrno)
        }
    }

    // MARK: - Descriptor close-pairing matrix (deterministic, injected syscalls)
    //
    // These prove the four (syncFailed, closeFailed) combinations without
    // needing to force real POSIX failure conditions on a live descriptor.
    // They do not exercise real Darwin syscalls and prove nothing about
    // real filesystem or power-loss behavior — only that
    // DarwinChunkFinalizationFileSystem's own result-combination logic is
    // correct.

    private func makeSyscalls(
        openResult: (rv: Int32, errno: Int32) = (3, 0),
        fullfsyncResult: (rv: Int32, errno: Int32),
        closeResult: (rv: Int32, errno: Int32)
    ) -> DarwinChunkFinalizationFileSystem.Syscalls {
        DarwinChunkFinalizationFileSystem.Syscalls(
            open: { _, _ in openResult },
            fullfsync: { _ in fullfsyncResult },
            close: { _ in closeResult },
            renameExcl: { _, _ in (0, 0) }
        )
    }

    func testSyncSucceedsCloseSucceedsContinues() {
        let syscalls = makeSyscalls(fullfsyncResult: (0, 0), closeResult: (0, 0))
        let sut = DarwinChunkFinalizationFileSystem(syscalls: syscalls)
        XCTAssertNoThrow(try sut.synchronizeFile(at: tempDirectory.appendingPathComponent("x.caf")))
    }

    func testSyncSucceedsCloseFailsIsTerminalCloseFailure() {
        let syscalls = makeSyscalls(fullfsyncResult: (0, 0), closeResult: (-1, EBADF))
        let sut = DarwinChunkFinalizationFileSystem(syscalls: syscalls)
        XCTAssertThrowsError(try sut.synchronizeFile(at: tempDirectory.appendingPathComponent("x.caf"))) { error in
            guard let failure = error as? ChunkDurabilityFailure else {
                return XCTFail("Expected ChunkDurabilityFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .partialDescriptorClose)
            XCTAssertEqual(failure.primaryErrno, EBADF)
            XCTAssertNil(failure.secondaryCloseErrno, "A close-only failure must not populate a secondary field")
        }
    }

    func testSyncFailsCloseSucceedsIsTerminalSyncFailure() {
        let syscalls = makeSyscalls(fullfsyncResult: (-1, EIO), closeResult: (0, 0))
        let sut = DarwinChunkFinalizationFileSystem(syscalls: syscalls)
        XCTAssertThrowsError(try sut.synchronizeFile(at: tempDirectory.appendingPathComponent("x.caf"))) { error in
            guard let failure = error as? ChunkDurabilityFailure else {
                return XCTFail("Expected ChunkDurabilityFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .partialFileSync)
            XCTAssertEqual(failure.primaryErrno, EIO)
            XCTAssertNil(failure.secondaryCloseErrno)
        }
    }

    func testSyncFailsCloseFailsRetainsSyncAsPrimaryAndCloseAsSecondary() {
        let syscalls = makeSyscalls(fullfsyncResult: (-1, EIO), closeResult: (-1, EBADF))
        let sut = DarwinChunkFinalizationFileSystem(syscalls: syscalls)
        XCTAssertThrowsError(try sut.synchronizeFile(at: tempDirectory.appendingPathComponent("x.caf"))) { error in
            guard let failure = error as? ChunkDurabilityFailure else {
                return XCTFail("Expected ChunkDurabilityFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .partialFileSync, "sync failure must remain primary even when close also fails")
            XCTAssertEqual(failure.primaryErrno, EIO)
            XCTAssertEqual(failure.secondaryCloseErrno, EBADF, "close failure must be retained, not discarded")
            XCTAssertNotNil(failure.secondaryCloseMessage)
        }
    }

    func testOpenFailurePreventsSyncAndCloseFromRunning() {
        final class CallFlags: Sendable {
            let syncCalled = Atomic<Bool>(false)
            let closeCalled = Atomic<Bool>(false)
        }
        let flags = CallFlags()
        let syscalls = DarwinChunkFinalizationFileSystem.Syscalls(
            open: { _, _ in (-1, EACCES) },
            fullfsync: { _ in
                flags.syncCalled.store(true, ordering: .relaxed)
                return (0, 0)
            },
            close: { _ in
                flags.closeCalled.store(true, ordering: .relaxed)
                return (0, 0)
            },
            renameExcl: { _, _ in (0, 0) }
        )
        let sut = DarwinChunkFinalizationFileSystem(syscalls: syscalls)
        XCTAssertThrowsError(try sut.synchronizeFile(at: tempDirectory.appendingPathComponent("x.caf"))) { error in
            guard let failure = error as? ChunkDurabilityFailure else {
                return XCTFail("Expected ChunkDurabilityFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .partialFileOpen)
            XCTAssertEqual(failure.primaryErrno, EACCES)
        }
        XCTAssertFalse(flags.syncCalled.load(ordering: .relaxed), "sync must never run if open failed")
        XCTAssertFalse(flags.closeCalled.load(ordering: .relaxed), "close must never run if open failed")
    }

    func testDirectorySyncFailureMapsToDirectoryStage() {
        let syscalls = makeSyscalls(fullfsyncResult: (-1, EIO), closeResult: (0, 0))
        let sut = DarwinChunkFinalizationFileSystem(syscalls: syscalls)
        XCTAssertThrowsError(try sut.synchronizeDirectory(at: tempDirectory)) { error in
            guard let failure = error as? ChunkDurabilityFailure else {
                return XCTFail("Expected ChunkDurabilityFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .directorySync, "directory sync failures must use directory-specific stages, not the partial-file ones")
        }
    }

    func testDirectoryDescriptorCloseFailureMapsToDirectoryCloseStage() {
        let syscalls = makeSyscalls(fullfsyncResult: (0, 0), closeResult: (-1, EBADF))
        let sut = DarwinChunkFinalizationFileSystem(syscalls: syscalls)
        XCTAssertThrowsError(try sut.synchronizeDirectory(at: tempDirectory)) { error in
            guard let failure = error as? ChunkDurabilityFailure else {
                return XCTFail("Expected ChunkDurabilityFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .directoryDescriptorClose)
        }
    }

    func testDirectoryOpenFailureReportsDirectoryOpenStage() {
        let syscalls = DarwinChunkFinalizationFileSystem.Syscalls(
            open: { _, _ in (-1, ENOENT) },
            fullfsync: { _ in (0, 0) },
            close: { _ in (0, 0) },
            renameExcl: { _, _ in (0, 0) }
        )
        let sut = DarwinChunkFinalizationFileSystem(syscalls: syscalls)
        XCTAssertThrowsError(try sut.synchronizeDirectory(at: tempDirectory)) { error in
            guard let failure = error as? ChunkDurabilityFailure else {
                return XCTFail("Expected ChunkDurabilityFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .directoryOpen)
            XCTAssertEqual(failure.primaryErrno, ENOENT)
        }
    }
}
