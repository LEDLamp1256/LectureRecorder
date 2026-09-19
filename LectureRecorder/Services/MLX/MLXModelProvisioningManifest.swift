import Foundation

/// One file this app expects to find inside a provisioned MLX model
/// directory, with the exact size/digest recorded at provisioning time.
/// Digests are never fabricated in source — see
/// `MLXModelProvisioningManifest`'s own header comment.
nonisolated struct MLXModelFileEntry: Codable, Equatable, Sendable {
    var filename: String
    var byteCount: UInt64
    var sha256: String
}

/// Describes exactly which files a correctly-provisioned MLX model
/// directory contains, and what they must hash to. Written once by a
/// developer-provisioning step at the same time the real model files are
/// obtained (never invented here), and read back by `MLXModelVerifier`
/// before every load.
///
/// This is the file `manifest.json`, expected at the root of the model
/// directory `MLXModelCatalog.modelDirectory(...)` resolves to. Its
/// `modelIdentifier`/`modelRevision` must match the configured
/// `MLXModelDescriptor` exactly — a manifest for the wrong model or
/// revision is never treated as valid for a mismatched descriptor.
nonisolated struct MLXModelProvisioningManifest: Codable, Equatable, Sendable {
    static let manifestFilename = "manifest.json"

    var modelIdentifier: String
    var modelRevision: String
    var files: [MLXModelFileEntry]
}
