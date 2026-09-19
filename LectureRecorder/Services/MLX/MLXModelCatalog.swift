import Foundation

/// Where one MLX model's files live on disk — mirrors
/// `WhisperModelCatalog`'s Application-Support-rooted, identity-addressed
/// layout, adapted for a model that is a *directory* of files rather than
/// one `.bin`. No entitlement or sandbox change: this is the same
/// Application Support container Whisper already uses.
nonisolated enum MLXModelCatalog {
    /// `Application Support/Models/MLX/<sanitized modelIdentifier>/<modelRevision>/`.
    /// The revision-tagged leaf directory is expected to contain the files
    /// `MLXPinnedModelManifests` lists for this descriptor.
    static func modelDirectory(
        applicationSupportRoot: URL,
        descriptor: MLXModelDescriptor
    ) -> URL {
        applicationSupportRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("MLX", isDirectory: true)
            .appendingPathComponent(sanitizedDirectoryComponent(for: descriptor.modelIdentifier), isDirectory: true)
            .appendingPathComponent(descriptor.modelRevision, isDirectory: true)
    }

    /// Path to the advisory installation receipt `Scripts/provision-mlx-notes-model.sh`
    /// writes after a successful install. `MLXModelVerifier` never reads or
    /// trusts this file — runtime verification always compares against the
    /// compiled-in `MLXPinnedModelManifests`, never against anything found
    /// beside the files it is verifying.
    static func manifestURL(
        applicationSupportRoot: URL,
        descriptor: MLXModelDescriptor
    ) -> URL {
        modelDirectory(applicationSupportRoot: applicationSupportRoot, descriptor: descriptor)
            .appendingPathComponent(MLXModelProvisioningManifest.manifestFilename, isDirectory: false)
    }

    /// A repository identifier like "mlx-community/Qwen3-8B-4bit" contains
    /// "/", which cannot appear as one path component — replaced with "_"
    /// so the whole identifier still reads as one directory name (never
    /// split into nested directories, which would let an adversarial or
    /// malformed identifier traverse the path structure unexpectedly).
    private static func sanitizedDirectoryComponent(for modelIdentifier: String) -> String {
        modelIdentifier.replacingOccurrences(of: "/", with: "_")
    }
}
