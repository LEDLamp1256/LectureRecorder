#!/bin/bash
set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly TEST_ROOT="$(mktemp -d /tmp/LectureRecorder-T3B-loader-tests.XXXXXX)"
readonly INCLUDE_ROOT="${REPOSITORY_ROOT}/.dependency-work/whisper.cpp/source/include"
readonly GGML_INCLUDE_ROOT="${REPOSITORY_ROOT}/.dependency-work/whisper.cpp/source/ggml/include"
readonly LIBRARY="${REPOSITORY_ROOT}/Generated/WhisperDependency/WhisperC.xcframework/macos-arm64/libWhisperC.a"
trap 'rm -rf "${TEST_ROOT}"' EXIT

[[ -f "${LIBRARY}" ]] || { printf 'error: prepared Whisper library missing\n' >&2; exit 1; }
xcrun clang \
    -mmacosx-version-min=26.5 \
    -DLR_WHISPER_TESTING=1 \
    -I"${INCLUDE_ROOT}" \
    -I"${GGML_INCLUDE_ROOT}" \
    -I"${REPOSITORY_ROOT}/LectureRecorderWhisperWorker" \
    "${REPOSITORY_ROOT}/LectureRecorderWhisperWorker/WhisperBridge.c" \
    "${SCRIPT_DIRECTORY}/WhisperModelLoaderTests.c" \
    "${LIBRARY}" \
    -framework Accelerate \
    -lc++ \
    -o "${TEST_ROOT}/WhisperModelLoaderTests"
mkdir "${TEST_ROOT}/files"
"${TEST_ROOT}/WhisperModelLoaderTests" "${TEST_ROOT}/files"
