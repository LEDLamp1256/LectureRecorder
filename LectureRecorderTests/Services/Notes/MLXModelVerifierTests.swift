import XCTest
import CryptoKit
@testable import LectureRecorder

final class MLXModelVerifierTests: XCTestCase {

    private let descriptor = MLXModelDescriptor(
        modelIdentifier: "mlx-community/Test-Model-4bit",
        modelRevision: "deadbeef0000000000000000000000000000dead",
        nativeContextLength: 32_768,
        operationalContextCeiling: 24_576
    )

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The tiny fixture content this test suite uses in place of the real
    /// multi-gigabyte model files, plus a lookup closure that stands in
    /// for `MLXPinnedModelManifests.manifest(for:)` -- verification logic
    /// is identical either way; only the source of "what's authoritative"
    /// differs, via `MLXModelVerifier.verify`'s injectable parameter.
    private func fixtureContents() -> [(String, Data)] {
        [
            ("config.json", Data("{}".utf8)),
            ("tokenizer_config.json", Data("{}".utf8)),
            ("model.safetensors", Data(repeating: 0x42, count: 4_096)),
        ]
    }

    private func authoritativeFixtureManifest() -> MLXModelProvisioningManifest {
        let entries = fixtureContents().map { filename, data in
            MLXModelFileEntry(filename: filename, byteCount: UInt64(data.count), sha256: sha256Hex(of: data))
        }
        return MLXModelProvisioningManifest(
            modelIdentifier: descriptor.modelIdentifier, modelRevision: descriptor.modelRevision, files: entries
        )
    }

    private func lookup(returning manifest: MLXModelProvisioningManifest?) -> (MLXModelDescriptor) -> MLXModelProvisioningManifest? {
        { _ in manifest }
    }

    /// Writes the fixture files (matching `authoritativeFixtureManifest()`)
    /// at the exact path `MLXModelCatalog.modelDirectory` resolves to.
    private func writeValidModelDirectory(root: URL) throws {
        let modelDirectory = MLXModelCatalog.modelDirectory(applicationSupportRoot: root, descriptor: descriptor)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        for (filename, data) in fixtureContents() {
            try data.write(to: modelDirectory.appendingPathComponent(filename, isDirectory: false))
        }
    }

    func testCatalogPathConstructionSanitizesSlashesInIdentifier() {
        let root = URL(fileURLWithPath: "/tmp/AppSupport")
        let directory = MLXModelCatalog.modelDirectory(applicationSupportRoot: root, descriptor: descriptor)
        XCTAssertEqual(
            directory.path,
            "/tmp/AppSupport/Models/MLX/mlx-community_Test-Model-4bit/deadbeef0000000000000000000000000000dead"
        )
    }

    func testVerifySucceedsForACorrectlyProvisionedDirectory() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidModelDirectory(root: root)

        let resolved = try MLXModelVerifier.verify(
            descriptor: descriptor, applicationSupportRoot: root,
            authoritativeManifestLookup: lookup(returning: authoritativeFixtureManifest())
        )
        XCTAssertEqual(resolved, MLXModelCatalog.modelDirectory(applicationSupportRoot: root, descriptor: descriptor))
    }

    func testVerifyFailsWhenModelDirectoryIsMissing() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try MLXModelVerifier.verify(
                descriptor: descriptor, applicationSupportRoot: root,
                authoritativeManifestLookup: lookup(returning: authoritativeFixtureManifest())
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelVerificationError, .modelDirectoryMissingOrUnsafe)
        }
    }

    func testVerifyFailsWhenNoAuthoritativeManifestExistsForDescriptor() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidModelDirectory(root: root)

        // No compiled-in expected metadata for this identifier/revision --
        // must fail closed, never fall back to trusting the directory.
        XCTAssertThrowsError(
            try MLXModelVerifier.verify(
                descriptor: descriptor, applicationSupportRoot: root,
                authoritativeManifestLookup: lookup(returning: nil)
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelVerificationError, .noAuthoritativeManifestForDescriptor)
        }
    }

    func testVerifyFailsWhenAFileSizeDoesNotMatchAuthoritativeMetadata() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidModelDirectory(root: root)

        let modelDirectory = MLXModelCatalog.modelDirectory(applicationSupportRoot: root, descriptor: descriptor)
        try Data(repeating: 0x99, count: 1).write(to: modelDirectory.appendingPathComponent("model.safetensors"))

        XCTAssertThrowsError(
            try MLXModelVerifier.verify(
                descriptor: descriptor, applicationSupportRoot: root,
                authoritativeManifestLookup: lookup(returning: authoritativeFixtureManifest())
            )
        ) { error in
            guard case .fileSizeMismatch = error as? MLXModelVerificationError else {
                return XCTFail("expected fileSizeMismatch, got \(error)")
            }
        }
    }

    func testVerifyFailsWhenAFileDigestDoesNotMatchAuthoritativeMetadataDespiteMatchingSize() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidModelDirectory(root: root)

        // Overwrite with different bytes of the exact same length -- proves
        // digest verification runs independently of the size check.
        let modelDirectory = MLXModelCatalog.modelDirectory(applicationSupportRoot: root, descriptor: descriptor)
        try Data(repeating: 0x24, count: 4_096).write(to: modelDirectory.appendingPathComponent("model.safetensors"))

        XCTAssertThrowsError(
            try MLXModelVerifier.verify(
                descriptor: descriptor, applicationSupportRoot: root,
                authoritativeManifestLookup: lookup(returning: authoritativeFixtureManifest())
            )
        ) { error in
            guard case .fileDigestMismatch = error as? MLXModelVerificationError else {
                return XCTFail("expected fileDigestMismatch, got \(error)")
            }
        }
    }

    func testVerifyFailsWhenARequiredFileIsMissing() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidModelDirectory(root: root)

        let modelDirectory = MLXModelCatalog.modelDirectory(applicationSupportRoot: root, descriptor: descriptor)
        try FileManager.default.removeItem(at: modelDirectory.appendingPathComponent("config.json"))

        XCTAssertThrowsError(
            try MLXModelVerifier.verify(
                descriptor: descriptor, applicationSupportRoot: root,
                authoritativeManifestLookup: lookup(returning: authoritativeFixtureManifest())
            )
        ) { error in
            guard case .fileMissingOrUnsafe = error as? MLXModelVerificationError else {
                return XCTFail("expected fileMissingOrUnsafe, got \(error)")
            }
        }
    }

    /// Proves Correction 4's central invariant: a co-located `manifest.json`
    /// inside the installed directory -- even one an attacker or a buggy
    /// process rewrote to match a replaced shard -- cannot redefine what
    /// this verifier expects, because the verifier never reads it.
    func testLocalManifestJSONTamperingCannotOverrideAuthoritativeDigest() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeValidModelDirectory(root: root)

        // Replace the weights file with different content...
        let modelDirectory = MLXModelCatalog.modelDirectory(applicationSupportRoot: root, descriptor: descriptor)
        let tamperedWeights = Data(repeating: 0xFF, count: 4_096)
        try tamperedWeights.write(to: modelDirectory.appendingPathComponent("model.safetensors"))

        // ...and write a co-located manifest.json whose digest matches the
        // TAMPERED content exactly (what an attacker who controls the
        // directory would do).
        let tamperedReceipt = MLXModelProvisioningManifest(
            modelIdentifier: descriptor.modelIdentifier,
            modelRevision: descriptor.modelRevision,
            files: [
                MLXModelFileEntry(filename: "config.json", byteCount: 2, sha256: sha256Hex(of: Data("{}".utf8))),
                MLXModelFileEntry(filename: "tokenizer_config.json", byteCount: 2, sha256: sha256Hex(of: Data("{}".utf8))),
                MLXModelFileEntry(filename: "model.safetensors", byteCount: UInt64(tamperedWeights.count), sha256: sha256Hex(of: tamperedWeights)),
            ]
        )
        try JSONEncoder().encode(tamperedReceipt).write(
            to: MLXModelCatalog.manifestURL(applicationSupportRoot: root, descriptor: descriptor)
        )

        // Verification still runs against the untouched authoritative
        // fixture manifest (matching the ORIGINAL weights) and must fail,
        // proving the co-located receipt was never consulted.
        XCTAssertThrowsError(
            try MLXModelVerifier.verify(
                descriptor: descriptor, applicationSupportRoot: root,
                authoritativeManifestLookup: lookup(returning: authoritativeFixtureManifest())
            )
        ) { error in
            guard case .fileDigestMismatch(let filename) = error as? MLXModelVerificationError else {
                return XCTFail("expected fileDigestMismatch, got \(error)")
            }
            XCTAssertEqual(filename, "model.safetensors")
        }
    }

    func testVerifyFailsWhenModelDirectoryIsASymlink() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDirectory = root.appendingPathComponent("real-elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)

        let modelDirectory = MLXModelCatalog.modelDirectory(applicationSupportRoot: root, descriptor: descriptor)
        try FileManager.default.createDirectory(
            at: modelDirectory.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: modelDirectory, withDestinationURL: realDirectory)

        XCTAssertThrowsError(
            try MLXModelVerifier.verify(
                descriptor: descriptor, applicationSupportRoot: root,
                authoritativeManifestLookup: lookup(returning: authoritativeFixtureManifest())
            )
        ) { error in
            XCTAssertEqual(error as? MLXModelVerificationError, .modelDirectoryMissingOrUnsafe)
        }
    }

    func testRealPinnedManifestIsRegisteredForTheConfiguredDescriptor() {
        // Does not touch the filesystem -- proves only that the real,
        // production default lookup recognizes the app's own configured
        // model/revision (MLXModelDescriptor.qwen3_8b_4bit), independent
        // of this test suite's injected fixture lookups above.
        XCTAssertNotNil(MLXPinnedModelManifests.manifest(for: .qwen3_8b_4bit))
    }
}
