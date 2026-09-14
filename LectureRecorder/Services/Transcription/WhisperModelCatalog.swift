import Foundation

nonisolated struct WhisperModelCatalogEntry: Codable, Equatable, Sendable {
    let identifier: String
    let filename: String
    let format: String
    let sourceRepository: String
    let repositoryRevision: String
    let downloadURL: String
    let byteCount: UInt64
    let sha256: String
    let underlyingModel: String
    let intendedLanguage: String
}

nonisolated enum WhisperModelCatalog {
    static let largeV3Turbo = WhisperModelCatalogEntry(
        identifier: "large-v3-turbo",
        filename: "ggml-large-v3-turbo.bin",
        format: "unquantized-ggml",
        sourceRepository: "ggerganov/whisper.cpp",
        repositoryRevision: "5359861c739e955e79d9a303bcbc70fb988958b1",
        downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin",
        byteCount: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        underlyingModel: "OpenAI Whisper Large v3 Turbo",
        intendedLanguage: "English"
    )

    static func modelURL(applicationSupportRoot: URL, entry: WhisperModelCatalogEntry = largeV3Turbo) -> URL {
        applicationSupportRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Whisper", isDirectory: true)
            .appendingPathComponent(entry.identifier, isDirectory: true)
            .appendingPathComponent(entry.sha256, isDirectory: true)
            .appendingPathComponent(entry.filename, isDirectory: false)
    }
}

nonisolated enum WhisperModelVerificationError: LocalizedError, Sendable, Equatable {
    case missing
    case notRegularFile
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case digestMismatch
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .missing: return "The prepared large-v3-turbo model is missing. Run Scripts/install-whisper-large-v3-turbo-model.sh."
        case .notRegularFile: return "The prepared large-v3-turbo model is not a regular, non-symbolic-link file."
        case .sizeMismatch(let expected, let actual): return "The prepared large-v3-turbo model is \(actual) bytes; expected \(expected)."
        case .digestMismatch: return "The prepared large-v3-turbo model failed SHA-256 verification."
        case .unreadable(let detail): return "The prepared large-v3-turbo model could not be read: \(detail)"
        }
    }
}

nonisolated enum WhisperModelVerifier {
    /// Advisory app-side availability check. Authoritative size and digest
    /// verification occurs in the worker against the descriptor it loads.
    static func preflight(url: URL, entry: WhisperModelCatalogEntry = WhisperModelCatalog.largeV3Turbo) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { throw WhisperModelVerificationError.missing }
            throw WhisperModelVerificationError.unreadable(error.localizedDescription)
        }
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw WhisperModelVerificationError.notRegularFile
        }
        guard let signedSize = values.fileSize, signedSize >= 0 else {
            throw WhisperModelVerificationError.unreadable("File size metadata was unavailable.")
        }
        let actualSize = UInt64(signedSize)
        guard actualSize == entry.byteCount else {
            throw WhisperModelVerificationError.sizeMismatch(expected: entry.byteCount, actual: actualSize)
        }
    }
}
