import XCTest
import CryptoKit
import os
@testable import LectureRecorder

private struct FakeVerificationFailure: Error, Equatable {}

/// Scriptable stand-in for the full SHA-256 verification step: counts every
/// full verification, and can fail, block, or mutate the files' identity
/// while "hashing".
final class FakeFullVerifier: Sendable {
    private struct State {
        var verificationCount = 0
        var failuresRemaining = 0
        var identityAfterNextVerification: MLXModelFileIdentity??
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let identity: OSAllocatedUnfairLock<MLXModelFileIdentity?>
    let directory = URL(fileURLWithPath: "/verified/model", isDirectory: true)

    init(identity: MLXModelFileIdentity?) {
        self.identity = OSAllocatedUnfairLock(initialState: identity)
    }

    var verificationCount: Int { state.withLock { $0.verificationCount } }

    func failNext(_ count: Int) { state.withLock { $0.failuresRemaining = count } }

    func changeIdentityDuringNextVerification(to newIdentity: MLXModelFileIdentity?) {
        state.withLock { $0.identityAfterNextVerification = .some(newIdentity) }
    }

    func verify() throws -> URL {
        let (shouldFail, identityChange) = state.withLock { state -> (Bool, MLXModelFileIdentity??) in
            state.verificationCount += 1
            let change = state.identityAfterNextVerification
            state.identityAfterNextVerification = nil
            if state.failuresRemaining > 0 {
                state.failuresRemaining -= 1
                return (true, change)
            }
            return (false, change)
        }
        if let identityChange { identity.withLock { $0 = identityChange } }
        if shouldFail { throw FakeVerificationFailure() }
        return directory
    }

    func makeCache(beforeVerifying: (@Sendable () -> Void)? = nil) -> MLXModelVerificationCache {
        MLXModelVerificationCache(
            modelIdentifier: "test-model",
            identityProvider: { [identity] _ in identity.withLock { $0 } },
            verifier: { [self] _ in
                beforeVerifying?()
                return try verify()
            }
        )
    }
}

func makeTestModelFileIdentity(inode: UInt64 = 1, modificationSeconds: Int = 100) -> MLXModelFileIdentity {
    let status = MLXModelFileIdentity.FileStatus(
        device: 1, inode: inode, byteCount: 4_096,
        modificationSeconds: modificationSeconds, modificationNanoseconds: 0,
        statusChangeSeconds: modificationSeconds, statusChangeNanoseconds: 0
    )
    return MLXModelFileIdentity(
        modelIdentifier: "test-model",
        modelRevision: "rev",
        canonicalDirectoryPath: "/verified/model",
        directoryStatus: status,
        files: [
            MLXModelFileIdentity.VerifiedFile(
                entry: MLXModelFileEntry(filename: "model.safetensors", byteCount: 4_096, sha256: "00"),
                status: status
            ),
        ]
    )
}

final class MLXModelVerificationCacheTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/app-support", isDirectory: true)

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    // MARK: - Reuse and invalidation

    func testUnchangedIdentityIsFullyVerifiedOnlyOnce() async throws {
        let verifier = FakeFullVerifier(identity: makeTestModelFileIdentity())
        let cache = verifier.makeCache()

        for _ in 0..<3 {
            let directory = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
            XCTAssertEqual(directory, verifier.directory)
        }
        XCTAssertEqual(verifier.verificationCount, 1)
    }

    func testChangedIdentityIsFullyVerifiedAgain() async throws {
        let verifier = FakeFullVerifier(identity: makeTestModelFileIdentity(inode: 1))
        let cache = verifier.makeCache()

        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        verifier.identity.withLock { $0 = makeTestModelFileIdentity(inode: 2) }
        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        XCTAssertEqual(verifier.verificationCount, 2, "a replaced file must be verified again")

        verifier.identity.withLock { $0 = makeTestModelFileIdentity(inode: 2, modificationSeconds: 200) }
        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        XCTAssertEqual(verifier.verificationCount, 3, "a modified file must be verified again")

        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        XCTAssertEqual(verifier.verificationCount, 3)
    }

    func testFailedVerificationIsNeverReusedAsSuccess() async throws {
        let verifier = FakeFullVerifier(identity: makeTestModelFileIdentity())
        verifier.failNext(2)
        let cache = verifier.makeCache()

        for _ in 0..<2 {
            do {
                _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
                XCTFail("expected the verification failure to surface")
            } catch {
                XCTAssertEqual(error as? FakeVerificationFailure, FakeVerificationFailure())
            }
        }
        XCTAssertEqual(verifier.verificationCount, 2, "every check after a failure must verify again")

        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        XCTAssertEqual(verifier.verificationCount, 3, "only the success is reused")
    }

    func testFilesChangingDuringVerificationFailClosedAndAreNotCached() async throws {
        let verifier = FakeFullVerifier(identity: makeTestModelFileIdentity(inode: 1))
        verifier.changeIdentityDuringNextVerification(to: makeTestModelFileIdentity(inode: 2))
        let cache = verifier.makeCache()

        do {
            _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
            XCTFail("expected modelFilesChangedDuringVerification")
        } catch {
            XCTAssertEqual(error as? MLXModelVerificationError, .modelFilesChangedDuringVerification)
        }

        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        XCTAssertEqual(verifier.verificationCount, 2)
    }

    func testUnknownIdentityNeverCachesAndReportsTheVerifierError() async throws {
        let verifier = FakeFullVerifier(identity: nil)
        verifier.failNext(1)
        let cache = verifier.makeCache()

        do {
            _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
            XCTFail("expected the verifier's failure")
        } catch {
            XCTAssertEqual(error as? FakeVerificationFailure, FakeVerificationFailure())
        }
        // A verification that passes while the identity is unknown cannot
        // be attributed to any identity, so it fails closed.
        do {
            _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
            XCTFail("expected modelFilesChangedDuringVerification")
        } catch {
            XCTAssertEqual(error as? MLXModelVerificationError, .modelFilesChangedDuringVerification)
        }
        XCTAssertEqual(verifier.verificationCount, 2)
    }

    func testConcurrentChecksShareOneFullVerification() async throws {
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "verification entered")
        let verifier = FakeFullVerifier(identity: makeTestModelFileIdentity())
        let cache = verifier.makeCache(beforeVerifying: {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
        })

        let checks = (0..<5).map { _ in
            Task { try await cache.verifiedModelDirectory(applicationSupportRoot: root) }
        }
        await fulfillment(of: [entered], timeout: 5)
        await waitUntil { await cache.verificationRequestCountForTesting == 5 }
        release.signal()
        for check in checks { _ = try await check.value }
        XCTAssertEqual(verifier.verificationCount, 1)
    }

    // MARK: - Driver integration

    func testDriverAvailabilityReusesOneSuccessfulVerification() async {
        let verifier = FakeFullVerifier(identity: makeTestModelFileIdentity())
        let driver = RealMLXSessionDriver(
            applicationSupportRootResolver: { [root] in root },
            verificationCache: verifier.makeCache()
        )

        for _ in 0..<3 {
            let availability = await driver.availability()
            XCTAssertEqual(availability, .available)
        }
        XCTAssertEqual(verifier.verificationCount, 1)
    }

    func testDriverAvailabilityReportsVerificationFailureAndRetriesNextTime() async {
        let verifier = FakeFullVerifier(identity: makeTestModelFileIdentity())
        verifier.failNext(1)
        let driver = RealMLXSessionDriver(
            applicationSupportRootResolver: { [root] in root },
            verificationCache: verifier.makeCache()
        )

        let first = await driver.availability()
        guard case .unavailable(let description) = first else {
            return XCTFail("expected unavailable, got \(first)")
        }
        XCTAssertTrue(description.hasPrefix("The local MLX model is not ready:"), description)
        let second = await driver.availability()
        XCTAssertEqual(second, .available)
        XCTAssertEqual(verifier.verificationCount, 2)
    }

    // MARK: - MainActor responsiveness

    /// While full verification is blocked mid-"hash", the main actor must
    /// keep running other work. If verification ran on the main actor, the
    /// probe below could not run until the verifier gave up waiting, and
    /// the verifier would record that timeout.
    @MainActor
    func testAvailabilityVerificationDoesNotBlockTheMainActor() async {
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "verification entered")
        let verifierTimedOut = OSAllocatedUnfairLock(initialState: false)
        let verifier = FakeFullVerifier(identity: makeTestModelFileIdentity())
        let driver = RealMLXSessionDriver(
            applicationSupportRootResolver: { [root] in root },
            verificationCache: verifier.makeCache(beforeVerifying: {
                entered.fulfill()
                if release.wait(timeout: .now() + 10) == .timedOut {
                    verifierTimedOut.withLock { $0 = true }
                }
            })
        )

        let availabilityCheck = Task { @MainActor in await driver.availability() }
        await fulfillment(of: [entered], timeout: 5)

        var probeRan = false
        let probe = Task { @MainActor in probeRan = true }
        await probe.value
        XCTAssertTrue(probeRan)
        XCTAssertFalse(verifierTimedOut.withLock { $0 }, "the main actor probe must run while verification is still blocked")

        release.signal()
        let availability = await availabilityCheck.value
        XCTAssertEqual(availability, .available)
        XCTAssertFalse(verifierTimedOut.withLock { $0 })
    }
}

/// End-to-end with the real `MLXModelVerifier` (SHA-256 and file-identity)
/// on small fixture files in place of the real model.
final class MLXModelVerificationCacheFileSystemTests: XCTestCase {
    private let descriptor = MLXModelDescriptor(
        modelIdentifier: "mlx-community/Test-Model-4bit",
        modelRevision: "deadbeef0000000000000000000000000000dead",
        nativeContextLength: 32_768,
        operationalContextCeiling: 24_576
    )
    private let weights = Data(repeating: 0x42, count: 4_096)
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = modelDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (filename, data) in fixtureContents() {
            try data.write(to: directory.appendingPathComponent(filename))
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private var modelDirectory: URL {
        MLXModelCatalog.modelDirectory(applicationSupportRoot: root, descriptor: descriptor)
    }

    private func fixtureContents() -> [(String, Data)] {
        [
            ("config.json", Data("{}".utf8)),
            ("tokenizer_config.json", Data("{}".utf8)),
            ("model.safetensors", weights),
        ]
    }

    private func manifest() -> MLXModelProvisioningManifest {
        MLXModelProvisioningManifest(
            modelIdentifier: descriptor.modelIdentifier,
            modelRevision: descriptor.modelRevision,
            files: fixtureContents().map { filename, data in
                MLXModelFileEntry(
                    filename: filename,
                    byteCount: UInt64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                )
            }
        )
    }

    private func identity() -> MLXModelFileIdentity? {
        let manifest = manifest()
        return MLXModelVerifier.fileIdentity(
            descriptor: descriptor, applicationSupportRoot: root, authoritativeManifestLookup: { _ in manifest }
        )
    }

    private var weightsURL: URL { modelDirectory.appendingPathComponent("model.safetensors") }

    // MARK: - File identity

    func testIdentityIsStableForUnchangedFiles() throws {
        let first = try XCTUnwrap(identity())
        XCTAssertEqual(identity(), first)
        XCTAssertEqual(first.files.map(\.entry.filename), ["config.json", "tokenizer_config.json", "model.safetensors"])
        XCTAssertEqual(first.canonicalDirectoryPath, modelDirectory.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testIdentityChangesWhenAVerifiedFileIsReplaced() throws {
        let before = try XCTUnwrap(identity())
        try weights.write(to: weightsURL, options: .atomic)
        XCTAssertNotEqual(identity(), before, "a same-content replacement is a different file")
    }

    func testIdentityChangesWhenAVerifiedFileIsRewrittenInPlace() throws {
        let before = try XCTUnwrap(identity())
        let handle = try FileHandle(forWritingTo: weightsURL)
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()
        let after = try XCTUnwrap(identity())
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(
            after.files.last?.status.inode, before.files.last?.status.inode,
            "same inode; the change is visible through modification/status-change time"
        )
    }

    func testIdentityIsUnavailableForAMissingOrSymlinkedFile() throws {
        let target = root.appendingPathComponent("elsewhere.safetensors")
        try weights.write(to: target)
        try FileManager.default.removeItem(at: weightsURL)
        XCTAssertNil(identity())
        try FileManager.default.createSymbolicLink(at: weightsURL, withDestinationURL: target)
        XCTAssertNil(identity())
    }

    // MARK: - Real verification through the cache

    func testRealVerificationIsReusedThenRepeatedAfterReplacementAndNeverCachesFailure() async throws {
        let manifest = manifest()
        let descriptor = descriptor
        let fullVerifications = OSAllocatedUnfairLock(initialState: 0)
        let cache = MLXModelVerificationCache(
            modelIdentifier: descriptor.modelIdentifier,
            identityProvider: { root in
                MLXModelVerifier.fileIdentity(
                    descriptor: descriptor, applicationSupportRoot: root, authoritativeManifestLookup: { _ in manifest }
                )
            },
            verifier: { root in
                fullVerifications.withLock { $0 += 1 }
                return try MLXModelVerifier.verify(
                    descriptor: descriptor, applicationSupportRoot: root, authoritativeManifestLookup: { _ in manifest }
                )
            }
        )

        let directory = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        XCTAssertEqual(directory, modelDirectory)
        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        XCTAssertEqual(fullVerifications.withLock { $0 }, 1)

        // Same size, different content, swapped in atomically.
        try Data(repeating: 0x43, count: weights.count).write(to: weightsURL, options: .atomic)
        do {
            _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
            XCTFail("a corrupted replacement must be verified again and rejected")
        } catch {
            XCTAssertEqual(error as? MLXModelVerificationError, .fileDigestMismatch(filename: "model.safetensors"))
        }
        do {
            _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
            XCTFail("a failed verification must not be cached as success")
        } catch {
            XCTAssertEqual(error as? MLXModelVerificationError, .fileDigestMismatch(filename: "model.safetensors"))
        }
        XCTAssertEqual(fullVerifications.withLock { $0 }, 3)

        try weights.write(to: weightsURL, options: .atomic)
        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        _ = try await cache.verifiedModelDirectory(applicationSupportRoot: root)
        XCTAssertEqual(fullVerifications.withLock { $0 }, 4)
    }
}

/// A `RealMLXSessionDriver` whose full model verification blocks (off the
/// caller's actor, as in production) until `releaseVerification()`, for
/// service-level tests of what happens while a large model is being
/// hashed. If verification ever ran on the main actor, a main-actor test
/// could not proceed until the verifier's own 10-second wait expired, and
/// `verificationTimedOut` would then report it.
final class BlockingVerificationDriverFixture: Sendable {
    let driver: RealMLXSessionDriver
    private let verifier = FakeFullVerifier(identity: makeTestModelFileIdentity())
    private let release = DispatchSemaphore(value: 0)
    private let entered = OSAllocatedUnfairLock(initialState: false)
    private let timedOut = OSAllocatedUnfairLock(initialState: false)

    init() {
        let (release, entered, timedOut) = (release, entered, timedOut)
        driver = RealMLXSessionDriver(
            applicationSupportRootResolver: { URL(fileURLWithPath: "/unused-app-support", isDirectory: true) },
            verificationCache: verifier.makeCache(beforeVerifying: {
                entered.withLock { $0 = true }
                if release.wait(timeout: .now() + 10) == .timedOut {
                    timedOut.withLock { $0 = true }
                }
            })
        )
    }

    var verificationEntered: Bool { entered.withLock { $0 } }
    var verificationTimedOut: Bool { timedOut.withLock { $0 } }
    var fullVerificationCount: Int { verifier.verificationCount }

    func releaseVerification() { release.signal() }
}
