import CryptoKit
import Darwin
import XCTest
@testable import LectureRecorder

final class WhisperModelCatalogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperModelCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testLargeV3TurboCatalogIdentityIsExactAndPathIsDerivedFromRoot() {
        let entry = WhisperModelCatalog.largeV3Turbo
        XCTAssertEqual(entry.identifier, "large-v3-turbo")
        XCTAssertEqual(entry.filename, "ggml-large-v3-turbo.bin")
        XCTAssertEqual(entry.format, "unquantized-ggml")
        XCTAssertEqual(entry.sourceRepository, "ggerganov/whisper.cpp")
        XCTAssertEqual(entry.repositoryRevision, "5359861c739e955e79d9a303bcbc70fb988958b1")
        XCTAssertEqual(entry.downloadURL, "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin")
        XCTAssertEqual(entry.byteCount, 1_624_555_275)
        XCTAssertEqual(entry.sha256, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
        XCTAssertEqual(entry.underlyingModel, "OpenAI Whisper Large v3 Turbo")
        XCTAssertEqual(entry.intendedLanguage, "English")
        XCTAssertEqual(
            WhisperModelCatalog.modelURL(applicationSupportRoot: URL(fileURLWithPath: "/application-support")).path,
            "/application-support/Models/Whisper/large-v3-turbo/1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69/ggml-large-v3-turbo.bin"
        )
    }

    func testProductionPolicyRejectsEveryAlternateModelFact() throws {
        let exact = WhisperT3BPolicy.provenance
        XCTAssertEqual(exact.model.identifier, WhisperModelCatalog.largeV3Turbo.identifier)
        for mutation in [
            { (value: inout TranscriptionProvenance) in value.model.identifier = "large-v3" },
            { (value: inout TranscriptionProvenance) in value.model.filename = "ggml-large-v3.bin" },
            { (value: inout TranscriptionProvenance) in value.model.byteCount = 3_095_033_483 },
            { (value: inout TranscriptionProvenance) in value.model.sha256 = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2" },
            { (value: inout TranscriptionProvenance) in value.engine.version = "1.9.1" },
            { (value: inout TranscriptionProvenance) in value.configuration.identifier = "whisper-large-v3-cpu-greedy-en-v1" },
        ] {
            var changed = exact
            mutation(&changed)
            XCTAssertThrowsError(try WhisperProcessTranscriber.validate(response: output(provenance: changed)))
        }
    }

    func testAdvisoryPreflightChecksTypeAndSizeWithoutReadingOrHashingBytes() throws {
        let bytes = Data("local deterministic model fixture".utf8)
        let entry = localEntry(bytes: bytes)
        let exact = directory.appendingPathComponent("exact.bin")
        try bytes.write(to: exact)
        XCTAssertNoThrow(try WhisperModelVerifier.preflight(url: exact, entry: entry))

        let truncated = directory.appendingPathComponent("truncated.bin")
        try Data(bytes.dropLast()).write(to: truncated)
        XCTAssertThrowsError(try WhisperModelVerifier.preflight(url: truncated, entry: entry)) {
            guard case .sizeMismatch = $0 as? WhisperModelVerificationError else { return XCTFail("\($0)") }
        }

        let oversized = directory.appendingPathComponent("oversized.bin")
        var extra = bytes
        extra.append(0)
        try extra.write(to: oversized)
        XCTAssertThrowsError(try WhisperModelVerifier.preflight(url: oversized, entry: entry))

        let mismatch = directory.appendingPathComponent("mismatch.bin")
        try Data(repeating: 0, count: bytes.count).write(to: mismatch)
        // Same-sized malformed bytes deliberately pass this advisory check;
        // the worker's descriptor-backed digest remains authoritative.
        XCTAssertNoThrow(try WhisperModelVerifier.preflight(url: mismatch, entry: entry))

        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exact)
        XCTAssertThrowsError(try WhisperModelVerifier.preflight(url: link, entry: entry)) {
            XCTAssertEqual($0 as? WhisperModelVerificationError, .notRegularFile)
        }
    }

    func testAdvisoryPreflightDoesNotRequireOpeningModelBytes() throws {
        let bytes = Data("metadata-only preflight".utf8)
        let entry = localEntry(bytes: bytes)
        let url = directory.appendingPathComponent("unreadable-by-mode.bin")
        try bytes.write(to: url)
        XCTAssertEqual(chmod(url.path, 0), 0)
        defer { _ = chmod(url.path, S_IRUSR | S_IWUSR) }
        XCTAssertNoThrow(try WhisperModelVerifier.preflight(url: url, entry: entry))
    }

    func testVerifierRejectsMissingAndConflictingExistingBytesWithoutChangingThem() throws {
        let missing = directory.appendingPathComponent("missing.bin")
        XCTAssertThrowsError(try WhisperModelVerifier.preflight(url: missing, entry: localEntry(bytes: Data()))) {
            XCTAssertEqual($0 as? WhisperModelVerificationError, .missing)
        }

        let existing = directory.appendingPathComponent("existing.bin")
        let conflicting = Data("conflicting".utf8)
        try conflicting.write(to: existing)
        let before = try Data(contentsOf: existing)
        XCTAssertThrowsError(try WhisperModelVerifier.preflight(url: existing, entry: localEntry(bytes: Data("expected".utf8))))
        XCTAssertEqual(try Data(contentsOf: existing), before)
    }

    private func localEntry(bytes: Data) -> WhisperModelCatalogEntry {
        WhisperModelCatalogEntry(
            identifier: "fixture", filename: "fixture.bin", format: "test", sourceRepository: "local",
            repositoryRevision: String(repeating: "a", count: 40), downloadURL: "local-only",
            byteCount: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            underlyingModel: "test", intendedLanguage: "English"
        )
    }

    private func output(provenance: TranscriptionProvenance) -> WhisperInferenceOutput {
        WhisperInferenceOutput(
            schemaVersion: 1, transcript: "", segments: [], decodedDurationMilliseconds: 0,
            decodedSampleCount: 0, provenance: provenance,
            timing: WhisperInferenceTiming(modelInitializationMilliseconds: 0, audioConversionMilliseconds: 0, inferenceMilliseconds: 0)
        )
    }
}
