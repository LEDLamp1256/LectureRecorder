import CryptoKit
import XCTest
@testable import LectureRecorder

final class FluidAudioDiarizationModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidAudioDiarizationModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    // MARK: - Fixture model

    private let revision = "0123456789abcdef0123456789abcdef01234567"
    private let contents: [(path: String, data: Data)] = [
        ("Segmentation.mlmodelc/coremldata.bin", Data("segmentation".utf8)),
        ("Segmentation.mlmodelc/weights/weight.bin", Data(repeating: 7, count: 64)),
        ("FBank.mlmodelc/coremldata.bin", Data("fbank".utf8)),
        ("plda-parameters.json", Data("{}".utf8)),
    ]

    private var manifest: FluidAudioDiarizationModelManifest {
        FluidAudioDiarizationModelManifest(
            repository: "Example/model",
            revision: revision,
            files: contents.map {
                FluidAudioDiarizationModelFile(
                    relativePath: $0.path,
                    byteCount: UInt64($0.data.count),
                    sha256: SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined()
                )
            }
        )
    }

    private func installFixture() throws -> URL {
        let directory = root.appendingPathComponent(revision, isDirectory: true)
        for (path, data) in contents {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return directory
    }

    private func assertVerificationFails(
        _ directory: URL,
        _ expected: FluidAudioDiarizationModelError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try FluidAudioDiarizationModelVerifier.verify(directory: directory, manifest: manifest), file: file, line: line) {
            XCTAssertEqual($0 as? FluidAudioDiarizationModelError, expected, file: file, line: line)
        }
    }

    // MARK: - Verifier

    func testExactlyTheListedFilesVerify() throws {
        XCTAssertNoThrow(try FluidAudioDiarizationModelVerifier.verify(directory: try installFixture(), manifest: manifest))
    }

    func testMissingOrSymlinkedModelDirectoryIsUnavailable() throws {
        assertVerificationFails(root.appendingPathComponent(revision), .modelDirectoryUnavailable)

        let real = try installFixture()
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let linked = elsewhere.appendingPathComponent(revision)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        assertVerificationFails(linked, .modelDirectoryUnavailable)
    }

    func testDirectoryForAnotherRevisionIsRejected() throws {
        let directory = try installFixture()
        let other = root.appendingPathComponent("fedcba9876543210fedcba9876543210fedcba98", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: other)
        assertVerificationFails(other, .revisionMismatch)
    }

    func testMissingFileIsRejected() throws {
        let directory = try installFixture()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("FBank.mlmodelc/coremldata.bin"))
        assertVerificationFails(directory, .fileMissing("FBank.mlmodelc/coremldata.bin"))
    }

    func testMissingBundleIsRejected() throws {
        let directory = try installFixture()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Segmentation.mlmodelc"))
        assertVerificationFails(directory, .fileMissing("Segmentation.mlmodelc/coremldata.bin"))
    }

    func testModifiedContentOfTheSameSizeFailsTheDigest() throws {
        let directory = try installFixture()
        try Data(repeating: 8, count: 64).write(to: directory.appendingPathComponent("Segmentation.mlmodelc/weights/weight.bin"))
        assertVerificationFails(directory, .digestMismatch("Segmentation.mlmodelc/weights/weight.bin"))
    }

    func testWrongSizeIsRejected() throws {
        let directory = try installFixture()
        try Data("segmentation!".utf8).write(to: directory.appendingPathComponent("Segmentation.mlmodelc/coremldata.bin"))
        assertVerificationFails(directory, .sizeMismatch("Segmentation.mlmodelc/coremldata.bin"))
    }

    func testUnexpectedFilesAndDirectoriesAnywhereAreRejected() throws {
        for extra in ["Segmentation.mlmodelc/extra.bin", "notes.txt", ".DS_Store", "Segmentation.mlmodelc/weights/.hidden"] {
            let directory = try installFixture()
            let url = directory.appendingPathComponent(extra)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            assertVerificationFails(directory, .unexpectedFile(extra))
            try FileManager.default.removeItem(at: directory)
        }

        let directory = try installFixture()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Embedding.mlmodelc"), withIntermediateDirectories: true)
        assertVerificationFails(directory, .unexpectedFile("Embedding.mlmodelc"))
    }

    func testSymlinkInPlaceOfAFileIsRejected() throws {
        let directory = try installFixture()
        let target = root.appendingPathComponent("outside.bin")
        try Data("fbank".utf8).write(to: target)
        let file = directory.appendingPathComponent("FBank.mlmodelc/coremldata.bin")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        assertVerificationFails(directory, .unsafePath("FBank.mlmodelc/coremldata.bin"))
    }

    func testSymlinkedBundleDirectoryIsRejected() throws {
        let directory = try installFixture()
        let bundle = directory.appendingPathComponent("FBank.mlmodelc")
        let moved = root.appendingPathComponent("FBank-elsewhere.mlmodelc")
        try FileManager.default.moveItem(at: bundle, to: moved)
        try FileManager.default.createSymbolicLink(at: bundle, withDestinationURL: moved)
        assertVerificationFails(directory, .unsafePath("FBank.mlmodelc"))
    }

    // MARK: - Pinned manifest

    func testPinnedManifestIsTheAuditedRevisionAndCoversEveryComponent() {
        let pinned = FluidAudioDiarizationModelManifest.pinned
        XCTAssertEqual(pinned.repository, "FluidInference/speaker-diarization-coreml")
        XCTAssertEqual(pinned.revision, "df2625ac79a7ac6b65ad868fee6d80f320da4232")
        XCTAssertEqual(pinned.files.count, 21)
        XCTAssertEqual(Set(pinned.files.map(\.relativePath)).count, pinned.files.count, "no duplicate paths")

        let bundles = FluidAudioDiarizationModelComponent.allCases.map(\.bundleName)
        for file in pinned.files {
            XCTAssertNotNil(file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression), file.relativePath)
            XCTAssertGreaterThan(file.byteCount, 0, file.relativePath)
            XCTAssertFalse(file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains { $0 == ".." || $0 == "." || $0.isEmpty }, file.relativePath)
            XCTAssertTrue(
                file.relativePath == FluidAudioDiarizationModelManifest.pldaParametersFile
                    || bundles.contains { file.relativePath.hasPrefix($0 + "/") },
                file.relativePath
            )
        }
        for bundle in bundles {
            for required in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                XCTAssertTrue(pinned.files.contains { $0.relativePath == "\(bundle)/\(required)" }, "\(bundle)/\(required)")
            }
        }
        XCTAssertTrue(pinned.files.contains { $0.relativePath == FluidAudioDiarizationModelManifest.pldaParametersFile })
    }

    func testModelDirectoryLivesBesideTheMLXModels() {
        let support = URL(fileURLWithPath: "/Support", isDirectory: true)
        XCTAssertEqual(
            FluidAudioDiarizationModelManifest.pinned.modelDirectory(applicationSupportRoot: support).path,
            "/Support/Models/FluidAudio/FluidInference_speaker-diarization-coreml/df2625ac79a7ac6b65ad868fee6d80f320da4232"
        )
    }

    func testOnlyFBankRunsOnTheCPU() {
        XCTAssertEqual(FluidAudioDiarizationModelComponent.allCases.filter(\.runsOnCPUOnly), [.fbank])
    }

    // MARK: - Component loading

    func testComponentsLoadInOrderIntoNamedFields() throws {
        var order: [FluidAudioDiarizationModelComponent] = []
        let components = try FluidAudioDiarizationModelComponents<String>.load { component in
            order.append(component)
            return "loaded:\(component.bundleName)"
        }
        XCTAssertEqual(order, [.segmentation, .fbank, .embedding, .pldaRho])
        XCTAssertEqual(components.segmentation, "loaded:Segmentation.mlmodelc")
        XCTAssertEqual(components.fbank, "loaded:FBank.mlmodelc")
        XCTAssertEqual(components.embedding, "loaded:Embedding.mlmodelc")
        XCTAssertEqual(components.pldaRho, "loaded:PldaRho.mlmodelc")
    }

    func testAComponentThatFailsToLoadIsATypedErrorAndStopsLoading() {
        for failing in FluidAudioDiarizationModelComponent.allCases {
            var attempted: [FluidAudioDiarizationModelComponent] = []
            XCTAssertThrowsError(try FluidAudioDiarizationModelComponents<String>.load { component in
                attempted.append(component)
                if component == failing { throw CocoaError(.fileReadCorruptFile) }
                return component.bundleName
            }) {
                XCTAssertEqual($0 as? FluidAudioDiarizationModelError, .componentLoadFailed(failing.bundleName))
            }
            XCTAssertEqual(attempted.last, failing, "nothing after \(failing) is loaded")
        }
    }

    func testCancellationDuringComponentLoadingPropagatesUnchanged() {
        XCTAssertThrowsError(try FluidAudioDiarizationModelComponents<String>.load { _ in throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
    }

    // MARK: - PLDA parameters

    private func pldaJSON(base64: String) -> Data {
        Data(#"{"tensors":{"psi":{"data_base64":"\#(base64)"}}}"#.utf8)
    }

    private func littleEndianBase64(_ values: [Float]) -> String {
        var bytes: [UInt8] = []
        for value in values {
            let bits = value.bitPattern
            bytes += [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8(bits >> 24)]
        }
        return Data(bytes).base64EncodedString()
    }

    func testPLDAPsiDecodesLittleEndianFloat32() throws {
        let values: [Float] = [1.5, -2.25, 0, 1e-3]
        XCTAssertEqual(try FluidAudioPLDAParameters.psi(from: pldaJSON(base64: littleEndianBase64(values))), values.map(Double.init))
    }

    func testMalformedPLDAParametersAreRejected() {
        let ragged = Data([0, 0, 0x80, 0x3f, 0]).base64EncodedString()
        let cases: [(String, Data)] = [
            ("not JSON", Data("nope".utf8)),
            ("no tensors", Data(#"{"other":{}}"#.utf8)),
            ("no psi", Data(#"{"tensors":{"phi":{"data_base64":"AACAPw=="}}}"#.utf8)),
            ("no data", Data(#"{"tensors":{"psi":{}}}"#.utf8)),
            ("not base64", pldaJSON(base64: "%%%")),
            ("empty", pldaJSON(base64: "")),
            ("ragged", pldaJSON(base64: ragged)),
            ("NaN", pldaJSON(base64: littleEndianBase64([1, .nan]))),
            ("infinity", pldaJSON(base64: littleEndianBase64([.infinity]))),
        ]
        for (name, data) in cases {
            XCTAssertThrowsError(try FluidAudioPLDAParameters.psi(from: data), name) {
                XCTAssertEqual($0 as? FluidAudioDiarizationModelError, .invalidPLDAParameters, name)
            }
        }
    }

    private func pldaEntry(for data: Data) -> FluidAudioDiarizationModelFile {
        FluidAudioDiarizationModelFile(
            relativePath: "plda-parameters.json",
            byteCount: UInt64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    func testPLDAFileIsParsedOnlyFromTheExactPinnedBytes() throws {
        let good = pldaJSON(base64: littleEndianBase64([0.5, -1]))
        let url = root.appendingPathComponent("plda-parameters.json")
        try good.write(to: url)
        XCTAssertEqual(try FluidAudioPLDAParameters.psi(contentsOf: url, expected: pldaEntry(for: good)), [0.5, -1])

        // Replaced after verification with other valid parameters.
        let swapped = pldaJSON(base64: littleEndianBase64([0.25, -1]))
        try swapped.write(to: url)
        XCTAssertThrowsError(try FluidAudioPLDAParameters.psi(contentsOf: url, expected: pldaEntry(for: good))) {
            XCTAssertEqual($0 as? FluidAudioDiarizationModelError, .digestMismatch("plda-parameters.json"))
        }
        try Data(good.dropLast()).write(to: url)
        XCTAssertThrowsError(try FluidAudioPLDAParameters.psi(contentsOf: url, expected: pldaEntry(for: good))) {
            XCTAssertEqual($0 as? FluidAudioDiarizationModelError, .sizeMismatch("plda-parameters.json"))
        }

        let target = root.appendingPathComponent("target.json")
        try good.write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try FluidAudioPLDAParameters.psi(contentsOf: url, expected: pldaEntry(for: good))) {
            XCTAssertEqual($0 as? FluidAudioDiarizationModelError, .unsafePath("plda-parameters.json"))
        }
    }

    func testMissingPLDAFileIsATypedError() {
        let entry = pldaEntry(for: Data("{}".utf8))
        XCTAssertThrowsError(try FluidAudioPLDAParameters.psi(contentsOf: root.appendingPathComponent("missing.json"), expected: entry)) {
            XCTAssertEqual($0 as? FluidAudioDiarizationModelError, .fileMissing("plda-parameters.json"))
        }
    }
}
