import CryptoKit
import Foundation

/// Every way a provisioned MLX model directory can fail verification.
/// Fail-closed: any of these stops loading before the real ~4–5 GB model
/// is ever touched by the MLX runtime.
nonisolated enum MLXModelVerificationError: LocalizedError, Sendable, Equatable {
    case modelDirectoryMissingOrUnsafe
    /// This app carries no independently pinned expected metadata
    /// (`MLXPinnedModelManifests`) for the configured
    /// `MLXModelDescriptor`. Never falls back to trusting anything found
    /// inside the model directory itself for an unrecognized model.
    case noAuthoritativeManifestForDescriptor
    case manifestListsNoFiles
    case manifestMissingRequiredFilename(String)
    case fileMissingOrUnsafe(String)
    case fileSizeMismatch(filename: String, expected: UInt64, actual: UInt64)
    case fileDigestMismatch(filename: String)
    case fileUnreadable(filename: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .modelDirectoryMissingOrUnsafe:
            return "The configured MLX model directory is missing, not a directory, or a symbolic link."
        case .noAuthoritativeManifestForDescriptor:
            return "No authoritative pinned manifest exists for the configured MLX model identifier/revision."
        case .manifestListsNoFiles:
            return "The authoritative MLX model manifest lists no files."
        case .manifestMissingRequiredFilename(let filename):
            return "The authoritative MLX model manifest does not list a required file: \(filename)."
        case .fileMissingOrUnsafe(let filename):
            return "MLX model file '\(filename)' is missing, not a regular file, or a symbolic link."
        case .fileSizeMismatch(let filename, let expected, let actual):
            return "MLX model file '\(filename)' is \(actual) bytes; the authoritative manifest expects \(expected)."
        case .fileDigestMismatch(let filename):
            return "MLX model file '\(filename)' failed SHA-256 verification against the authoritative manifest."
        case .fileUnreadable(let filename, let detail):
            return "MLX model file '\(filename)' could not be read: \(detail)"
        }
    }
}

/// Verifies a local, pinned-revision MLX model directory before the MLX
/// runtime is ever allowed to load it. Adapts the same trust shape as
/// `WhisperModelVerifier` (path safety, then size, then digest) to a model
/// that is a *directory* of files — but, unlike a naive directory
/// verifier, every expected filename/size/SHA-256 comes from the
/// compiled-in `MLXPinnedModelManifests`, never from anything read out of
/// the directory being verified. A `manifest.json` may still exist inside
/// the installed directory as an advisory installation receipt (written
/// by `Scripts/provision-mlx-notes-model.sh`), but this verifier never
/// reads or trusts it: rewriting that local file, even consistently with
/// a replaced shard, cannot change what this verifier expects.
nonisolated enum MLXModelVerifier {
    /// Filenames the authoritative manifest must list, regardless of exact
    /// upstream repository layout — a defensive sanity check, not the
    /// primary trust mechanism (which is the full per-file size+digest
    /// check against `MLXPinnedModelManifests` below).
    static let requiredFilenameSuffixes: [String] = [".safetensors", "config.json", "tokenizer_config.json"]

    static func verify(
        descriptor: MLXModelDescriptor,
        applicationSupportRoot: URL,
        /// Injectable only for tests, which cannot practically reproduce
        /// the real pinned manifest's multi-gigabyte file (matching its
        /// real SHA-256 would require the actual weights). Production
        /// call sites never pass this — the default is
        /// `MLXPinnedModelManifests.manifest(for:)`, the one and only
        /// trust source at runtime.
        authoritativeManifestLookup: (MLXModelDescriptor) -> MLXModelProvisioningManifest? = MLXPinnedModelManifests.manifest(for:)
    ) throws -> URL {
        let modelDirectory = MLXModelCatalog.modelDirectory(
            applicationSupportRoot: applicationSupportRoot, descriptor: descriptor
        )
        guard CompletedSessionPathSafety.checkExistingDirectory(modelDirectory) == .safe else {
            throw MLXModelVerificationError.modelDirectoryMissingOrUnsafe
        }

        guard let authoritative = authoritativeManifestLookup(descriptor) else {
            throw MLXModelVerificationError.noAuthoritativeManifestForDescriptor
        }
        guard !authoritative.files.isEmpty else {
            throw MLXModelVerificationError.manifestListsNoFiles
        }
        for suffix in requiredFilenameSuffixes {
            guard authoritative.files.contains(where: { $0.filename.hasSuffix(suffix) }) else {
                throw MLXModelVerificationError.manifestMissingRequiredFilename(suffix)
            }
        }

        for entry in authoritative.files {
            let fileURL = modelDirectory.appendingPathComponent(entry.filename, isDirectory: false)
            guard CompletedSessionPathSafety.checkExistingRegularFile(fileURL) == .safe else {
                throw MLXModelVerificationError.fileMissingOrUnsafe(entry.filename)
            }
            try verify(fileURL: fileURL, against: entry)
        }

        return modelDirectory
    }

    private static func verify(fileURL: URL, against entry: MLXModelFileEntry) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw MLXModelVerificationError.fileUnreadable(filename: entry.filename, detail: error.localizedDescription)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalBytesRead: UInt64 = 0
        let chunkSize = 4 * 1024 * 1024
        while true {
            let chunk: Data
            do {
                guard let readChunk = try handle.read(upToCount: chunkSize), !readChunk.isEmpty else { break }
                chunk = readChunk
            } catch {
                throw MLXModelVerificationError.fileUnreadable(filename: entry.filename, detail: error.localizedDescription)
            }
            totalBytesRead += UInt64(chunk.count)
            hasher.update(data: chunk)
        }

        guard totalBytesRead == entry.byteCount else {
            throw MLXModelVerificationError.fileSizeMismatch(
                filename: entry.filename, expected: entry.byteCount, actual: totalBytesRead
            )
        }

        let digest = hasher.finalize()
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        guard digestHex == entry.sha256.lowercased() else {
            throw MLXModelVerificationError.fileDigestMismatch(filename: entry.filename)
        }
    }
}
