import Foundation

/// Authoritative, source-controlled expected file metadata for every MLX
/// model revision this app is configured to trust — obtained independently
/// of, and never derived from, whatever happens to be sitting in an
/// installed `Application Support` model directory. `MLXModelVerifier`
/// consults only this compiled-in list; it never reads a co-located
/// `manifest.json` for trust purposes, because a manifest living beside
/// the files it describes can be rewritten by whatever replaced those
/// files.
///
/// `qwen3_8b_4bit_545dc425` was obtained on 2026-09-18 directly from
/// Hugging Face's own revision-specific file listing for exactly this
/// pinned revision:
///
///     https://huggingface.co/api/models/mlx-community/Qwen3-8B-4bit/tree/545dc4251c05440727734bcd94334791f6ab0192
///
/// - `model.safetensors` and `tokenizer.json` are Hugging Face LFS
///   objects; their `lfs.oid` field returned by that API IS the SHA-256 of
///   the file's actual content (LFS objects are content-addressed by
///   SHA-256) — not a git blob hash, and not independently recomputed
///   here, since obtaining it does not require downloading the ~4.3 GB
///   weight file itself.
/// - `config.json`, `tokenizer_config.json`, `special_tokens_map.json`,
///   and `model.safetensors.index.json` are ordinary (non-LFS) files. The
///   tree API's top-level `oid` for those is a git *blob* SHA-1, not a
///   SHA-256 of file content, so each was instead fetched directly —
///
///       https://huggingface.co/mlx-community/Qwen3-8B-4bit/resolve/545dc4251c05440727734bcd94334791f6ab0192/<path>
///
///   — and hashed locally with `shasum -a 256`. Every byte size below was
///   cross-checked against the tree API's own reported `size` for that
///   path, at that exact revision.
///
/// Any future pinned-revision bump must add a new named constant here
/// (never mutate this one in place) and update
/// `Scripts/provision-mlx-notes-model.sh`'s embedded table to match.
nonisolated enum MLXPinnedModelManifests {
    static let qwen3_8b_4bit_545dc425 = MLXModelProvisioningManifest(
        modelIdentifier: "mlx-community/Qwen3-8B-4bit",
        modelRevision: "545dc4251c05440727734bcd94334791f6ab0192",
        files: [
            MLXModelFileEntry(
                filename: "config.json", byteCount: 939,
                sha256: "e5485285fd7e289e76e9cffa112f6dc2e3426519082f7db9b69041589f81a218"
            ),
            MLXModelFileEntry(
                filename: "tokenizer_config.json", byteCount: 9_706,
                sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"
            ),
            MLXModelFileEntry(
                filename: "special_tokens_map.json", byteCount: 613,
                sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"
            ),
            MLXModelFileEntry(
                filename: "model.safetensors.index.json", byteCount: 64_065,
                sha256: "3fb25463b4078b1fc27159daa605190029c2e965f533bf0b1b594f96cbfceb8a"
            ),
            MLXModelFileEntry(
                filename: "tokenizer.json", byteCount: 11_422_654,
                sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
            ),
            MLXModelFileEntry(
                filename: "model.safetensors", byteCount: 4_607_835_174,
                sha256: "f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8"
            ),
        ]
    )

    private static let known: [MLXModelProvisioningManifest] = [qwen3_8b_4bit_545dc425]

    /// The authoritative manifest for `descriptor`, or `nil` when this app
    /// carries no independently pinned expected metadata for that exact
    /// model identifier + revision. `MLXModelVerifier` treats `nil` as a
    /// hard verification failure — it never falls back to trusting
    /// anything found inside the model directory itself.
    static func manifest(for descriptor: MLXModelDescriptor) -> MLXModelProvisioningManifest? {
        known.first {
            $0.modelIdentifier == descriptor.modelIdentifier && $0.modelRevision == descriptor.modelRevision
        }
    }
}
