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
    /// The model files' on-disk identity changed while they were being
    /// hashed, so the digests just computed cannot be attributed to the
    /// files now present. Fail closed; the next check verifies again.
    case modelFilesChangedDuringVerification

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
        case .modelFilesChangedDuringVerification:
            return "The MLX model files changed while they were being verified."
        }
    }
}

/// A cheap, metadata-only identity of exactly the files `MLXModelVerifier`
/// verifies for one descriptor — never a substitute for verification, only
/// the key under which one successful full verification may be reused
/// within the same process (`MLXModelVerificationCache`). Any replacement,
/// rewrite, rename-over, or touch of a verified file changes its inode,
/// size, modification time, or status-change time; a different model
/// directory, descriptor revision, or pinned manifest changes the
/// remaining fields.
nonisolated struct MLXModelFileIdentity: Sendable, Equatable {
    nonisolated struct FileStatus: Sendable, Equatable {
        var device: Int64
        var inode: UInt64
        var byteCount: Int64
        var modificationSeconds: Int
        var modificationNanoseconds: Int
        var statusChangeSeconds: Int
        var statusChangeNanoseconds: Int
    }

    nonisolated struct VerifiedFile: Sendable, Equatable {
        var entry: MLXModelFileEntry
        var status: FileStatus
    }

    var modelIdentifier: String
    var modelRevision: String
    var canonicalDirectoryPath: String
    var directoryStatus: FileStatus
    var files: [VerifiedFile]
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

    /// The current `MLXModelFileIdentity` of the files `verify` would check
    /// for `descriptor`, from file metadata only (no file contents are
    /// read). `nil` whenever that identity cannot be established — missing
    /// or unsafe directory/files, or no authoritative manifest — in which
    /// case nothing may be reused and full verification must run (and
    /// report the real reason).
    static func fileIdentity(
        descriptor: MLXModelDescriptor,
        applicationSupportRoot: URL,
        authoritativeManifestLookup: (MLXModelDescriptor) -> MLXModelProvisioningManifest? = MLXPinnedModelManifests.manifest(for:)
    ) -> MLXModelFileIdentity? {
        let modelDirectory = MLXModelCatalog.modelDirectory(
            applicationSupportRoot: applicationSupportRoot, descriptor: descriptor
        )
        guard CompletedSessionPathSafety.checkExistingDirectory(modelDirectory) == .safe,
              let authoritative = authoritativeManifestLookup(descriptor),
              !authoritative.files.isEmpty,
              let directoryStatus = fileStatus(atPath: modelDirectory.path, expectedType: S_IFDIR)
        else {
            return nil
        }
        var files: [MLXModelFileIdentity.VerifiedFile] = []
        for entry in authoritative.files {
            let fileURL = modelDirectory.appendingPathComponent(entry.filename, isDirectory: false)
            guard let status = fileStatus(atPath: fileURL.path, expectedType: S_IFREG) else { return nil }
            files.append(MLXModelFileIdentity.VerifiedFile(entry: entry, status: status))
        }
        return MLXModelFileIdentity(
            modelIdentifier: descriptor.modelIdentifier,
            modelRevision: descriptor.modelRevision,
            canonicalDirectoryPath: modelDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
            directoryStatus: directoryStatus,
            files: files
        )
    }

    /// `lstat`, so a symbolic link is never followed and never matches
    /// `expectedType`.
    private static func fileStatus(atPath path: String, expectedType: mode_t) -> MLXModelFileIdentity.FileStatus? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == expectedType else { return nil }
        return MLXModelFileIdentity.FileStatus(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            byteCount: Int64(info.st_size),
            modificationSeconds: info.st_mtimespec.tv_sec,
            modificationNanoseconds: info.st_mtimespec.tv_nsec,
            statusChangeSeconds: info.st_ctimespec.tv_sec,
            statusChangeNanoseconds: info.st_ctimespec.tv_nsec
        )
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
