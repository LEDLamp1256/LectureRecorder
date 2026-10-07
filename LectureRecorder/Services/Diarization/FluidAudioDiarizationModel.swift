import CryptoKit
import Foundation

/// One file of the pinned offline diarization model, relative to the model
/// directory.
nonisolated struct FluidAudioDiarizationModelFile: Sendable, Equatable {
    var relativePath: String
    var byteCount: UInt64
    var sha256: String
}

/// The four compiled Core ML bundles FluidAudio's offline pipeline runs.
nonisolated enum FluidAudioDiarizationModelComponent: String, CaseIterable, Sendable {
    case segmentation = "Segmentation.mlmodelc"
    case fbank = "FBank.mlmodelc"
    case embedding = "Embedding.mlmodelc"
    case pldaRho = "PldaRho.mlmodelc"

    var bundleName: String { rawValue }

    /// FluidAudio's own loader pins FBank to the CPU and runs the others on
    /// all compute units; loading the verified bundles directly keeps that.
    var runsOnCPUOnly: Bool { self == .fbank }
}

/// Every way a provisioned diarization model can fail verification, load,
/// or parse. Fail-closed: nothing is repaired or downloaded.
nonisolated enum FluidAudioDiarizationModelError: LocalizedError, Sendable, Equatable {
    case modelDirectoryUnavailable
    case revisionMismatch
    case fileMissing(String)
    case unsafePath(String)
    case unexpectedFile(String)
    case sizeMismatch(String)
    case digestMismatch(String)
    case unreadable(String)
    case componentLoadFailed(String)
    case invalidPLDAParameters

    var errorDescription: String? {
        switch self {
        case .modelDirectoryUnavailable:
            return "The speaker-diarization model is not provisioned. Run Scripts/provision-fluidaudio-diarization-model.sh."
        case .revisionMismatch:
            return "The speaker-diarization model directory is not the pinned model revision."
        case .fileMissing(let path): return "Speaker-diarization model file \(path) is missing."
        case .unsafePath(let path): return "Speaker-diarization model path \(path) is a symlink or the wrong file type."
        case .unexpectedFile(let path): return "Unexpected file \(path) inside the speaker-diarization model."
        case .sizeMismatch(let path): return "Speaker-diarization model file \(path) has the wrong size."
        case .digestMismatch(let path): return "Speaker-diarization model file \(path) failed its SHA-256 check."
        case .unreadable(let path): return "Speaker-diarization model file \(path) could not be read."
        case .componentLoadFailed(let bundle): return "Speaker-diarization model component \(bundle) could not be loaded."
        case .invalidPLDAParameters: return "The speaker-diarization PLDA parameters could not be read."
        }
    }
}

/// The complete expected content of one model revision: every file, with
/// its pinned size and SHA-256. The compiled-in `pinned` value is the only
/// trust source at runtime; nothing read from the model directory can
/// change what is expected.
nonisolated struct FluidAudioDiarizationModelManifest: Sendable, Equatable {
    static let pldaParametersFile = "plda-parameters.json"

    var repository: String
    var revision: String
    var files: [FluidAudioDiarizationModelFile]

    /// FluidAudio's offline VBx pipeline assets (pyannote Community-1
    /// segmentation, WeSpeaker embedding, BUT PLDA), converted to Core ML by
    /// Fluid Inference, at the immutable Hugging Face revision FluidAudio
    /// v0.16.1 itself pins. Licensed CC-BY-4.0; attribution is recorded in
    /// `Dependencies/DiarizationRuntime/provenance.json`.
    ///
    /// The table must match `Scripts/provision-fluidaudio-diarization-model.sh`
    /// (`Scripts/test-provision-fluidaudio-diarization-model.sh` checks it).
    /// Sizes come from the Hugging Face tree API at `revision`; digests were
    /// computed from files fetched at that revision. A revision bump is a new
    /// pin, never an in-place edit.
    static let pinned = FluidAudioDiarizationModelManifest(
        repository: "FluidInference/speaker-diarization-coreml",
        revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        files: [
            .init(relativePath: "Segmentation.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
            .init(relativePath: "Segmentation.mlmodelc/coremldata.bin", byteCount: 812, sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
            .init(relativePath: "Segmentation.mlmodelc/metadata.json", byteCount: 3_410, sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
            .init(relativePath: "Segmentation.mlmodelc/model.mil", byteCount: 43_063, sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
            .init(relativePath: "Segmentation.mlmodelc/weights/weight.bin", byteCount: 5_959_360, sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
            .init(relativePath: "FBank.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
            .init(relativePath: "FBank.mlmodelc/coremldata.bin", byteCount: 853, sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
            .init(relativePath: "FBank.mlmodelc/metadata.json", byteCount: 3_409, sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
            .init(relativePath: "FBank.mlmodelc/model.mil", byteCount: 15_667, sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
            .init(relativePath: "FBank.mlmodelc/weights/weight.bin", byteCount: 1_776_896, sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
            .init(relativePath: "Embedding.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
            .init(relativePath: "Embedding.mlmodelc/coremldata.bin", byteCount: 704, sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
            .init(relativePath: "Embedding.mlmodelc/metadata.json", byteCount: 2_818, sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
            .init(relativePath: "Embedding.mlmodelc/model.mil", byteCount: 78_432, sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
            .init(relativePath: "Embedding.mlmodelc/weights/weight.bin", byteCount: 13_412_288, sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
            .init(relativePath: "PldaRho.mlmodelc/analytics/coremldata.bin", byteCount: 243, sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
            .init(relativePath: "PldaRho.mlmodelc/coremldata.bin", byteCount: 763, sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
            .init(relativePath: "PldaRho.mlmodelc/metadata.json", byteCount: 2_749, sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
            .init(relativePath: "PldaRho.mlmodelc/model.mil", byteCount: 7_613, sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
            .init(relativePath: "PldaRho.mlmodelc/weights/weight.bin", byteCount: 200_192, sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
            .init(relativePath: "plda-parameters.json", byteCount: 89_416, sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
        ]
    )

    /// `<Application Support>/Models/FluidAudio/<repository with "/" → "_">/<revision>/`,
    /// beside the MLX models (`Models/MLX/...`). Inside the sandbox,
    /// Application Support is the app container's.
    func modelDirectory(applicationSupportRoot: URL) -> URL {
        applicationSupportRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent(repository.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    /// The pinned model's directory in this process's Application Support.
    /// Never creates anything.
    static func defaultModelDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        return pinned.modelDirectory(applicationSupportRoot: root)
    }
}

/// Proves a model directory holds exactly one manifest's files before Core
/// ML is allowed to load anything from it. Reads only; never downloads,
/// repairs, or caches.
nonisolated enum FluidAudioDiarizationModelVerifier {
    /// Checks, in order: the directory is a real directory (not a symlink)
    /// named for the manifest's revision; the whole tree under it contains
    /// no symlink, no special file, and nothing the manifest does not list
    /// (Core ML reads whatever a bundle contains); every listed file is a
    /// regular file of its pinned size; and every listed file has its pinned
    /// SHA-256.
    static func verify(
        directory: URL,
        manifest: FluidAudioDiarizationModelManifest = .pinned
    ) throws {
        guard CompletedSessionPathSafety.checkExistingDirectory(directory) == .safe else {
            throw FluidAudioDiarizationModelError.modelDirectoryUnavailable
        }
        guard directory.lastPathComponent == manifest.revision else {
            throw FluidAudioDiarizationModelError.revisionMismatch
        }
        try verifyTreeContainsOnlyListedFiles(directory, manifest: manifest)
        // Cheap shape checks for every file first, then the digests.
        for file in manifest.files {
            try verifyPresenceAndSize(file, in: directory)
        }
        for file in manifest.files {
            try verifyDigest(file, in: directory)
        }
    }

    private static func verifyTreeContainsOnlyListedFiles(
        _ directory: URL,
        manifest: FluidAudioDiarizationModelManifest
    ) throws {
        let expectedFiles = Set(manifest.files.map(\.relativePath))
        var expectedDirectories: Set<String> = []
        for path in expectedFiles {
            var components = path.split(separator: "/").dropLast()
            while !components.isEmpty {
                expectedDirectories.insert(components.joined(separator: "/"))
                components = components.dropLast()
            }
        }

        // Path-based enumeration yields paths relative to `directory`,
        // includes hidden entries, and never descends into a symlinked
        // directory (which is itself reported and rejected below).
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
            throw FluidAudioDiarizationModelError.modelDirectoryUnavailable
        }
        for case let relative as String in enumerator {
            var info = stat()
            guard lstat(directory.appendingPathComponent(relative).path, &info) == 0 else {
                throw FluidAudioDiarizationModelError.unreadable(relative)
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard expectedDirectories.contains(relative) else {
                    throw FluidAudioDiarizationModelError.unexpectedFile(relative)
                }
            case S_IFREG:
                guard expectedFiles.contains(relative) else {
                    throw FluidAudioDiarizationModelError.unexpectedFile(relative)
                }
            default:
                throw FluidAudioDiarizationModelError.unsafePath(relative)
            }
        }
    }

    private static func verifyPresenceAndSize(_ file: FluidAudioDiarizationModelFile, in directory: URL) throws {
        let url = directory.appendingPathComponent(file.relativePath, isDirectory: false)
        switch CompletedSessionPathSafety.checkExistingRegularFile(url) {
        case .missing: throw FluidAudioDiarizationModelError.fileMissing(file.relativePath)
        case .unsafe: throw FluidAudioDiarizationModelError.unsafePath(file.relativePath)
        case .safe: break
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw FluidAudioDiarizationModelError.unreadable(file.relativePath)
        }
        guard info.st_size >= 0, UInt64(info.st_size) == file.byteCount else {
            throw FluidAudioDiarizationModelError.sizeMismatch(file.relativePath)
        }
    }

    private static func verifyDigest(_ file: FluidAudioDiarizationModelFile, in directory: URL) throws {
        let url = directory.appendingPathComponent(file.relativePath, isDirectory: false)
        guard CompletedSessionPathSafety.checkExistingRegularFile(url) == .safe else {
            throw FluidAudioDiarizationModelError.unsafePath(file.relativePath)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FluidAudioDiarizationModelError.unreadable(file.relativePath)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var total: UInt64 = 0
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 1 << 20), !read.isEmpty else { break }
                chunk = read
            } catch {
                throw FluidAudioDiarizationModelError.unreadable(file.relativePath)
            }
            total += UInt64(chunk.count)
            guard total <= file.byteCount else {
                throw FluidAudioDiarizationModelError.sizeMismatch(file.relativePath)
            }
            hasher.update(data: chunk)
        }
        guard total == file.byteCount else {
            throw FluidAudioDiarizationModelError.sizeMismatch(file.relativePath)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256.lowercased() else {
            throw FluidAudioDiarizationModelError.digestMismatch(file.relativePath)
        }
    }
}

/// One loaded value per required component, held in named fields rather
/// than a lookup table, so a missing component is a load error and never a
/// failed lookup. Generic so the loading order and error mapping are
/// testable without real Core ML models.
nonisolated struct FluidAudioDiarizationModelComponents<Model> {
    var segmentation: Model
    var fbank: Model
    var embedding: Model
    var pldaRho: Model

    /// Loads every component in `FluidAudioDiarizationModelComponent` order,
    /// mapping any failure to `.componentLoadFailed(<bundle>)` (cancellation
    /// propagates unchanged).
    static func load(
        _ loadComponent: (FluidAudioDiarizationModelComponent) throws -> Model
    ) throws -> FluidAudioDiarizationModelComponents<Model> {
        func load(_ component: FluidAudioDiarizationModelComponent) throws -> Model {
            do {
                return try loadComponent(component)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw FluidAudioDiarizationModelError.componentLoadFailed(component.bundleName)
            }
        }
        return FluidAudioDiarizationModelComponents(
            segmentation: try load(.segmentation),
            fbank: try load(.fbank),
            embedding: try load(.embedding),
            pldaRho: try load(.pldaRho)
        )
    }
}

nonisolated enum FluidAudioPLDAParameters {
    /// Reads the PLDA `psi` tensor the way FluidAudio's own loader does —
    /// `tensors.psi.data_base64`, Float32 values — but explicitly
    /// little-endian and rejecting an empty, ragged, or non-finite tensor.
    static func psi(from data: Data) throws -> [Double] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tensors = root["tensors"] as? [String: Any],
            let psi = tensors["psi"] as? [String: Any],
            let base64 = psi["data_base64"] as? String,
            let decoded = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
            !decoded.isEmpty, decoded.count % MemoryLayout<UInt32>.size == 0
        else {
            throw FluidAudioDiarizationModelError.invalidPLDAParameters
        }
        var values: [Double] = []
        values.reserveCapacity(decoded.count / MemoryLayout<UInt32>.size)
        let bytes = [UInt8](decoded)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let bits = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            let value = Float(bitPattern: bits)
            guard value.isFinite else { throw FluidAudioDiarizationModelError.invalidPLDAParameters }
            values.append(Double(value))
        }
        return values
    }

    /// Reads the PLDA file and parses it only if the exact bytes read match
    /// the pinned size and SHA-256, so the parsed values are the verified
    /// ones even if the file changed after directory verification.
    static func psi(contentsOf url: URL, expected: FluidAudioDiarizationModelFile) throws -> [Double] {
        // `lstat` on the path itself: never follows a symlink, and never
        // reuses resource values a `URL` instance may have cached.
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw FluidAudioDiarizationModelError.fileMissing(expected.relativePath)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw FluidAudioDiarizationModelError.unsafePath(expected.relativePath)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FluidAudioDiarizationModelError.unreadable(expected.relativePath)
        }
        guard UInt64(data.count) == expected.byteCount else {
            throw FluidAudioDiarizationModelError.sizeMismatch(expected.relativePath)
        }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected.sha256.lowercased() else {
            throw FluidAudioDiarizationModelError.digestMismatch(expected.relativePath)
        }
        return try psi(from: data)
    }
}
