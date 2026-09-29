#!/bin/bash
set -euo pipefail

# Installs a pre-downloaded copy of one pinned MLX model into the location
# LectureRecorder's MLXModelVerifier expects, after verifying every file
# against this script's own embedded copy of the authoritative expected
# metadata.
#
#   usage: provision-mlx-notes-model.sh <source-directory> [qwen3-8b-4bit|qwen3-14b-4bit]
#
# The optional selection defaults to qwen3-8b-4bit (the production model):
#   qwen3-8b-4bit   mlx-community/Qwen3-8B-4bit  @ 545dc4251c05440727734bcd94334791f6ab0192
#   qwen3-14b-4bit  mlx-community/Qwen3-14B-4bit @ a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4
# (14B is used only by the opt-in MLX-3 real-lecture acceptance harness.)
# Any other selection is refused.
#
# This script never downloads the model itself (no network access, no API
# key) -- the developer must already have a local directory containing
# exactly the files listed below, obtained however they choose (browser
# download, `huggingface-cli download`, an existing local cache, etc.).
#
# IMPORTANT: each table below MUST exactly match its constant in
# LectureRecorder/Services/MLX/MLXPinnedModelManifests.swift
# (`qwen3_8b_4bit_545dc425` / `qwen3_14b_4bit_a4d9b2df`). Anyone bumping the pinned model
# revision must update both together. Both were populated from Hugging
# Face's own revision-pinned file listing/content, never invented -- see
# that Swift file's header comment for exactly how.

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

[[ $# -eq 1 || $# -eq 2 ]] || \
    fail "usage: $0 <source-directory-containing-the-pinned-model-files> [qwen3-8b-4bit|qwen3-14b-4bit]"
readonly MODEL_SELECTION="${2-qwen3-8b-4bit}"

# filename:byteCount:sha256
case "${MODEL_SELECTION}" in
    qwen3-8b-4bit)
        MODEL_IDENTIFIER="mlx-community/Qwen3-8B-4bit"
        MODEL_REVISION="545dc4251c05440727734bcd94334791f6ab0192"
        EXPECTED_FILES=(
            "config.json:939:e5485285fd7e289e76e9cffa112f6dc2e3426519082f7db9b69041589f81a218"
            "tokenizer_config.json:9706:253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"
            "special_tokens_map.json:613:76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"
            "model.safetensors.index.json:64065:3fb25463b4078b1fc27159daa605190029c2e965f533bf0b1b594f96cbfceb8a"
            "tokenizer.json:11422654:aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
            "model.safetensors:4607835174:f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8"
        )
        ;;
    qwen3-14b-4bit)
        MODEL_IDENTIFIER="mlx-community/Qwen3-14B-4bit"
        MODEL_REVISION="a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4"
        EXPECTED_FILES=(
            "config.json:939:a54ec18ffe24f3c909e9556471dc156ed9b3b61b872008831c7cba9d4768b4a5"
            "tokenizer_config.json:9706:253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"
            "special_tokens_map.json:613:76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"
            "model.safetensors.index.json:86266:eb522fa2269e4a958bf625765bccde4a0677895a09eed23cdd8d1760dfc0259c"
            "tokenizer.json:11422654:aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
            "model-00001-of-00002.safetensors:5354381380:5795efcfc7c96fd273e600562e8b111bfcc427415de9001d0a07e70cd99cff19"
            "model-00002-of-00002.safetensors:2953517134:2814562d654fe2d541fd4682804a0ccaa400e79701872c8e9f5998cf9481fdf8"
        )
        ;;
    *)
        fail "unknown model selection '${MODEL_SELECTION}'; expected qwen3-8b-4bit or qwen3-14b-4bit"
        ;;
esac
readonly MODEL_IDENTIFIER MODEL_REVISION EXPECTED_FILES

# LectureRecorder is sandboxed (ENABLE_APP_SANDBOX = YES), so the running
# app's Application Support directory is redirected into its container --
# not the plain ~/Library/Application Support this script would otherwise
# guess. The container path is deterministic from the bundle identifier.
readonly BUNDLE_IDENTIFIER="com.dylanlee.LectureRecorder"
readonly APP_SUPPORT_ROOT="${HOME}/Library/Containers/${BUNDLE_IDENTIFIER}/Data/Library/Application Support"
readonly SANITIZED_IDENTIFIER="${MODEL_IDENTIFIER//\//_}"
readonly DEST_DIR="${APP_SUPPORT_ROOT}/Models/MLX/${SANITIZED_IDENTIFIER}/${MODEL_REVISION}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required tool '$1' is unavailable."
}

for tool in shasum stat mkdir cp; do
    require_command "$tool"
done

readonly SOURCE_DIR="$1"
[[ -d "${SOURCE_DIR}" ]] || fail "source directory does not exist: ${SOURCE_DIR}"
[[ ! -L "${SOURCE_DIR}" ]] || fail "refusing a symbolic-link source directory: ${SOURCE_DIR}"

echo "Verifying ${MODEL_IDENTIFIER} @ ${MODEL_REVISION} against the authoritative pinned manifest..."
for entry in "${EXPECTED_FILES[@]}"; do
    IFS=':' read -r filename expected_size expected_sha256 <<< "${entry}"
    filepath="${SOURCE_DIR}/${filename}"

    [[ -e "${filepath}" ]] || fail "missing required file: ${filename}"
    [[ ! -L "${filepath}" ]] || fail "refusing a symbolic link: ${filename}"
    [[ -f "${filepath}" ]] || fail "not a regular file: ${filename}"

    actual_size="$(stat -f%z "${filepath}" 2>/dev/null || stat -c%s "${filepath}")"
    [[ "${actual_size}" == "${expected_size}" ]] || \
        fail "${filename} size mismatch: expected ${expected_size} bytes, got ${actual_size}"

    actual_sha256="$(shasum -a 256 "${filepath}" | cut -d' ' -f1)"
    [[ "${actual_sha256}" == "${expected_sha256}" ]] || \
        fail "${filename} SHA-256 mismatch against pinned revision ${MODEL_REVISION} -- refusing to install"

    echo "  verified ${filename}"
done

[[ ! -e "${DEST_DIR}" ]] || fail "destination already exists; remove it explicitly first: ${DEST_DIR}"
mkdir -p "${DEST_DIR}"

for entry in "${EXPECTED_FILES[@]}"; do
    IFS=':' read -r filename _ _ <<< "${entry}"
    cp "${SOURCE_DIR}/${filename}" "${DEST_DIR}/${filename}"
done

# Advisory-only installation receipt. MLXModelVerifier never reads or
# trusts this file -- runtime verification always compares against the
# compiled-in MLXPinnedModelManifests, so rewriting this receipt (even
# consistently with replaced files) cannot change what the app expects.
{
    echo "{"
    echo "  \"modelIdentifier\": \"${MODEL_IDENTIFIER}\","
    echo "  \"modelRevision\": \"${MODEL_REVISION}\","
    echo "  \"files\": ["
    first=1
    for entry in "${EXPECTED_FILES[@]}"; do
        IFS=':' read -r filename size sha256 <<< "${entry}"
        [[ ${first} -eq 1 ]] || echo ","
        first=0
        printf '    {"filename": "%s", "byteCount": %s, "sha256": "%s"}' "${filename}" "${size}" "${sha256}"
    done
    echo ""
    echo "  ]"
    echo "}"
} > "${DEST_DIR}/manifest.json"

echo "Installed and verified ${MODEL_IDENTIFIER} @ ${MODEL_REVISION} to:"
echo "  ${DEST_DIR}"
