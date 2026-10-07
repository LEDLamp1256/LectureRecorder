#!/bin/bash
set -euo pipefail

# Installs the pinned offline speaker-diarization model into the location
# LectureRecorder's FluidAudioDiarizationModelVerifier expects, after
# verifying every file against this script's embedded table.
#
#   usage: provision-fluidaudio-diarization-model.sh download
#          provision-fluidaudio-diarization-model.sh install <source-directory>
#
# `download` is the only networked step: it fetches exactly the pinned files
# from Hugging Face at an immutable revision into a temporary directory, then
# verifies and installs them. `install` does the same from a local copy and
# never touches the network. The app itself never downloads the model.
#
# Model: FluidInference/speaker-diarization-coreml @ df2625ac79a7ac6b65ad868fee6d80f320da4232
# (FluidAudio's offline VBx pipeline assets, the revision FluidAudio v0.16.1
# itself pins). License: CC-BY-4.0 — see
# Dependencies/DiarizationRuntime/provenance.json for the required attribution.
#
# IMPORTANT: the table below MUST exactly match
# `FluidAudioDiarizationModelManifest.pinned` in
# LectureRecorder/Services/Diarization/FluidAudioDiarizationModel.swift.
# A revision bump updates both together.

readonly MODEL_REPOSITORY="FluidInference/speaker-diarization-coreml"
readonly MODEL_REVISION="df2625ac79a7ac6b65ad868fee6d80f320da4232"
readonly BUNDLE_IDENTIFIER="com.dylanlee.LectureRecorder"
readonly APP_SUPPORT_ROOT="${HOME}/Library/Containers/${BUNDLE_IDENTIFIER}/Data/Library/Application Support"
readonly DEST_DIR="${APP_SUPPORT_ROOT}/Models/FluidAudio/${MODEL_REPOSITORY//\//_}/${MODEL_REVISION}"

# relativePath:byteCount:sha256
readonly EXPECTED_FILES=(
    "Segmentation.mlmodelc/analytics/coremldata.bin:243:64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"
    "Segmentation.mlmodelc/coremldata.bin:812:ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"
    "Segmentation.mlmodelc/metadata.json:3410:88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"
    "Segmentation.mlmodelc/model.mil:43063:d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"
    "Segmentation.mlmodelc/weights/weight.bin:5959360:c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"
    "FBank.mlmodelc/analytics/coremldata.bin:243:0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"
    "FBank.mlmodelc/coremldata.bin:853:57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"
    "FBank.mlmodelc/metadata.json:3409:2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"
    "FBank.mlmodelc/model.mil:15667:27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"
    "FBank.mlmodelc/weights/weight.bin:1776896:9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"
    "Embedding.mlmodelc/analytics/coremldata.bin:243:8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"
    "Embedding.mlmodelc/coremldata.bin:704:4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"
    "Embedding.mlmodelc/metadata.json:2818:1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"
    "Embedding.mlmodelc/model.mil:78432:22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"
    "Embedding.mlmodelc/weights/weight.bin:13412288:99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"
    "PldaRho.mlmodelc/analytics/coremldata.bin:243:8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"
    "PldaRho.mlmodelc/coremldata.bin:763:4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"
    "PldaRho.mlmodelc/metadata.json:2749:b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"
    "PldaRho.mlmodelc/model.mil:7613:83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"
    "PldaRho.mlmodelc/weights/weight.bin:200192:80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"
    "plda-parameters.json:89416:38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"
)

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

usage="usage: $0 download | $0 install <source-directory>"
[[ $# -ge 1 ]] || fail "${usage}"
readonly MODE="$1"
case "${MODE}" in
    download) [[ $# -eq 1 ]] || fail "${usage}" ;;
    install) [[ $# -eq 2 ]] || fail "${usage}" ;;
    *) fail "unknown mode '${MODE}'; ${usage}" ;;
esac

for tool in shasum stat mkdir cp mv mktemp; do
    command -v "${tool}" >/dev/null 2>&1 || fail "Required tool '${tool}' is unavailable."
done

[[ ! -e "${DEST_DIR}" ]] || fail "destination already exists; remove it explicitly first: ${DEST_DIR}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lecturerecorder-diarization-model.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

if [[ "${MODE}" == "download" ]]; then
    command -v curl >/dev/null 2>&1 || fail "Required tool 'curl' is unavailable."
    SOURCE_DIR="${WORK_DIR}/download"
    base_url="https://huggingface.co/${MODEL_REPOSITORY}/resolve/${MODEL_REVISION}"
    for entry in "${EXPECTED_FILES[@]}"; do
        relative_path="${entry%%:*}"
        mkdir -p "${SOURCE_DIR}/$(dirname "${relative_path}")"
        curl --fail --silent --show-error --location --proto '=https' --retry 2 \
            "${base_url}/${relative_path}" -o "${SOURCE_DIR}/${relative_path}" \
            || fail "download failed: ${relative_path}"
    done
else
    SOURCE_DIR="$2"
    [[ -d "${SOURCE_DIR}" ]] || fail "source directory does not exist: ${SOURCE_DIR}"
    [[ ! -L "${SOURCE_DIR}" ]] || fail "refusing a symbolic-link source directory: ${SOURCE_DIR}"
fi

# Verify every pinned file before installing anything.
for entry in "${EXPECTED_FILES[@]}"; do
    relative_path="${entry%%:*}"
    rest="${entry#*:}"
    expected_bytes="${rest%%:*}"
    expected_sha="${rest#*:}"
    source_file="${SOURCE_DIR}/${relative_path}"
    [[ -f "${source_file}" && ! -L "${source_file}" ]] || fail "missing or non-regular file: ${relative_path}"
    actual_bytes="$(stat -f %z "${source_file}")"
    [[ "${actual_bytes}" == "${expected_bytes}" ]] || fail "size mismatch for ${relative_path}: expected ${expected_bytes}, got ${actual_bytes}"
    actual_sha="$(shasum -a 256 "${source_file}" | cut -d ' ' -f 1)"
    [[ "${actual_sha}" == "${expected_sha}" ]] || fail "SHA-256 mismatch for ${relative_path}"
done

# Copy exactly the pinned files into a staging directory beside the
# destination, then move it into place with one rename.
parent_dir="$(dirname "${DEST_DIR}")"
mkdir -p "${parent_dir}"
staging_dir="$(mktemp -d "${parent_dir}/.staging.XXXXXX")"
trap 'rm -rf "${WORK_DIR}" "${staging_dir}"' EXIT
for entry in "${EXPECTED_FILES[@]}"; do
    relative_path="${entry%%:*}"
    mkdir -p "${staging_dir}/$(dirname "${relative_path}")"
    cp "${SOURCE_DIR}/${relative_path}" "${staging_dir}/${relative_path}"
done
chmod 755 "${staging_dir}"
mv "${staging_dir}" "${DEST_DIR}"

printf 'Installed %s @ %s (%d files) into:\n  %s\n' "${MODEL_REPOSITORY}" "${MODEL_REVISION}" "${#EXPECTED_FILES[@]}" "${DEST_DIR}"
