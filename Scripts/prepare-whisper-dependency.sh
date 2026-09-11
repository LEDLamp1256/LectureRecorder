#!/bin/bash

set -euo pipefail

readonly UPSTREAM_URL="https://github.com/ggml-org/whisper.cpp.git"
readonly RELEASE_TAG="v1.9.2"
readonly PINNED_COMMIT="306c88f4d1286aec1bf96e544632897886af5501"
readonly DEPLOYMENT_TARGET="26.5"

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly WORK_ROOT="${REPOSITORY_ROOT}/.dependency-work/whisper.cpp"
readonly SOURCE_DIRECTORY="${WORK_ROOT}/source"
readonly BUILD_DIRECTORY="${WORK_ROOT}/build-macos-arm64"
readonly PACKAGE_DIRECTORY="${WORK_ROOT}/package"
readonly GENERATED_DIRECTORY="${REPOSITORY_ROOT}/Generated/WhisperDependency"
readonly PUBLICATION_STAGE="${REPOSITORY_ROOT}/Generated/.WhisperDependency.publication-stage"
readonly PUBLICATION_BACKUP="${REPOSITORY_ROOT}/Generated/.WhisperDependency.publication-backup"
readonly XCFRAMEWORK_PATH="${PUBLICATION_STAGE}/WhisperC.xcframework"
readonly TRACKED_LICENSE="${REPOSITORY_ROOT}/Dependencies/whisper.cpp/LICENSE"

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

restore_interrupted_publication() {
    local status=$?
    if [[ ! -e "${GENERATED_DIRECTORY}" && -e "${PUBLICATION_BACKUP}" ]]; then
        mv "${PUBLICATION_BACKUP}" "${GENERATED_DIRECTORY}" || \
            printf 'error: could not restore the prior prepared dependency from %s\n' "${PUBLICATION_BACKUP}" >&2
    fi
    exit "${status}"
}

trap restore_interrupted_publication EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required tool '$1' is unavailable. Install it explicitly and rerun this script."
}

for tool in git cmake xcodebuild xcrun shasum file lipo; do
    require_command "${tool}"
done

[[ "$(uname -s)" == "Darwin" ]] || fail "This preparation script requires macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "This preparation script must run on an arm64 Mac."
[[ -f "${TRACKED_LICENSE}" ]] || fail "Tracked upstream license notice is missing at ${TRACKED_LICENSE}."

mkdir -p "${WORK_ROOT}"

if [[ ! -d "${SOURCE_DIRECTORY}/.git" ]]; then
    [[ ! -e "${SOURCE_DIRECTORY}" ]] || fail "Source path exists but is not the expected Git checkout: ${SOURCE_DIRECTORY}"
    git init "${SOURCE_DIRECTORY}"
    git -C "${SOURCE_DIRECTORY}" remote add origin "${UPSTREAM_URL}"
fi

[[ "$(git -C "${SOURCE_DIRECTORY}" remote get-url origin)" == "${UPSTREAM_URL}" ]] || fail "Existing source checkout has an unexpected origin URL. Remove ${WORK_ROOT} explicitly and rerun."

if ! git -C "${SOURCE_DIRECTORY}" rev-parse --verify --quiet "refs/tags/${RELEASE_TAG}^{commit}" >/dev/null; then
    git -C "${SOURCE_DIRECTORY}" fetch --depth 1 origin "refs/tags/${RELEASE_TAG}:refs/tags/${RELEASE_TAG}"
fi

readonly TAG_COMMIT="$(git -C "${SOURCE_DIRECTORY}" rev-parse "refs/tags/${RELEASE_TAG}^{commit}")"
[[ "${TAG_COMMIT}" == "${PINNED_COMMIT}" ]] || fail "Tag ${RELEASE_TAG} resolves to ${TAG_COMMIT}, not ${PINNED_COMMIT}."

if ! git -C "${SOURCE_DIRECTORY}" rev-parse --verify --quiet HEAD >/dev/null; then
    git -C "${SOURCE_DIRECTORY}" checkout --detach "${PINNED_COMMIT}"
fi

readonly CHECKED_OUT_COMMIT="$(git -C "${SOURCE_DIRECTORY}" rev-parse HEAD)"
[[ "${CHECKED_OUT_COMMIT}" == "${PINNED_COMMIT}" ]] || fail "Checked-out commit ${CHECKED_OUT_COMMIT} does not match pin ${PINNED_COMMIT}."
[[ -z "$(git -C "${SOURCE_DIRECTORY}" status --porcelain)" ]] || fail "Pinned source checkout has local or untracked modifications. Remove ${WORK_ROOT} explicitly and rerun."
cmp -s "${SOURCE_DIRECTORY}/LICENSE" "${TRACKED_LICENSE}" || fail "Tracked license notice does not exactly match the pinned upstream LICENSE."

cmake -E remove_directory "${BUILD_DIRECTORY}"
cmake -E remove_directory "${PACKAGE_DIRECTORY}"
cmake -E remove_directory "${PUBLICATION_STAGE}"
mkdir -p "${BUILD_DIRECTORY}" "${PACKAGE_DIRECTORY}/Headers" "${PUBLICATION_STAGE}" "${REPOSITORY_ROOT}/Generated"
[[ ! -e "${PUBLICATION_BACKUP}" ]] || fail "A prior publication backup remains at ${PUBLICATION_BACKUP}; inspect it before rerunning."

readonly CONFIGURE_LOG="${WORK_ROOT}/configure.log"
cmake \
    -S "${SOURCE_DIRECTORY}" \
    -B "${BUILD_DIRECTORY}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_CURL=OFF \
    -DWHISPER_COREML=OFF \
    -DGGML_BUILD_EXAMPLES=OFF \
    -DGGML_BUILD_TESTS=OFF \
    -DGGML_CCACHE=OFF \
    -DGGML_CPU=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_BLAS=OFF \
    -DGGML_METAL=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_NATIVE=OFF \
    2>&1 | tee "${CONFIGURE_LOG}"

if grep -q "Manually-specified variables were not used by the project" "${CONFIGURE_LOG}"; then
    fail "The pinned source did not consume every requested build option; inspect ${CONFIGURE_LOG}."
fi

assert_cache_value() {
    local key="$1"
    local type="$2"
    local expected="$3"
    grep -Fxq "${key}:${type}=${expected}" "${BUILD_DIRECTORY}/CMakeCache.txt" || fail "Expected ${key}:${type}=${expected} in the effective CMake cache."
}

assert_cache_value BUILD_SHARED_LIBS BOOL OFF
assert_cache_value WHISPER_BUILD_EXAMPLES BOOL OFF
assert_cache_value WHISPER_BUILD_TESTS BOOL OFF
assert_cache_value WHISPER_BUILD_SERVER BOOL OFF
assert_cache_value WHISPER_CURL BOOL OFF
assert_cache_value WHISPER_COREML BOOL OFF
assert_cache_value GGML_BUILD_EXAMPLES BOOL OFF
assert_cache_value GGML_BUILD_TESTS BOOL OFF
assert_cache_value GGML_CCACHE BOOL OFF
assert_cache_value GGML_CPU BOOL ON
assert_cache_value GGML_ACCELERATE BOOL ON
assert_cache_value GGML_BLAS BOOL OFF
assert_cache_value GGML_METAL BOOL OFF
assert_cache_value GGML_OPENMP BOOL OFF
assert_cache_value GGML_NATIVE BOOL OFF

cmake --build "${BUILD_DIRECTORY}" --config Release --target whisper --parallel

readonly WHISPER_ARCHIVE="${BUILD_DIRECTORY}/src/libwhisper.a"
readonly GGML_ARCHIVE="${BUILD_DIRECTORY}/ggml/src/libggml.a"
readonly GGML_BASE_ARCHIVE="${BUILD_DIRECTORY}/ggml/src/libggml-base.a"
readonly GGML_CPU_ARCHIVE="${BUILD_DIRECTORY}/ggml/src/libggml-cpu.a"
for archive in "${WHISPER_ARCHIVE}" "${GGML_ARCHIVE}" "${GGML_BASE_ARCHIVE}" "${GGML_CPU_ARCHIVE}"; do
    [[ -f "${archive}" ]] || fail "Expected static archive was not produced: ${archive}"
    [[ "$(lipo -archs "${archive}")" == "arm64" ]] || fail "Archive is not arm64-only: ${archive}"
done

readonly COMBINED_ARCHIVE="${PACKAGE_DIRECTORY}/libWhisperC.a"
xcrun libtool -static -D -o "${COMBINED_ARCHIVE}" \
    "${WHISPER_ARCHIVE}" \
    "${GGML_ARCHIVE}" \
    "${GGML_BASE_ARCHIVE}" \
    "${GGML_CPU_ARCHIVE}"
[[ "$(lipo -archs "${COMBINED_ARCHIVE}")" == "arm64" ]] || fail "Combined archive is not arm64-only."

printf '%s\n' \
    '#ifndef LECTURE_RECORDER_WHISPER_C_H' \
    '#define LECTURE_RECORDER_WHISPER_C_H' \
    '' \
    '#ifdef __cplusplus' \
    'extern "C" {' \
    '#endif' \
    '' \
    'const char * whisper_version(void);' \
    '' \
    '#ifdef __cplusplus' \
    '}' \
    '#endif' \
    '' \
    '#endif' \
    > "${PACKAGE_DIRECTORY}/Headers/WhisperC.h"

printf '%s\n' \
    'module WhisperC {' \
    '    header "WhisperC.h"' \
    '    export *' \
    '}' \
    > "${PACKAGE_DIRECTORY}/Headers/module.modulemap"

xcodebuild -create-xcframework \
    -library "${COMBINED_ARCHIVE}" \
    -headers "${PACKAGE_DIRECTORY}/Headers" \
    -output "${XCFRAMEWORK_PATH}"

[[ -f "${XCFRAMEWORK_PATH}/Info.plist" ]] || fail "Staged XCFramework is missing Info.plist."
[[ -f "${XCFRAMEWORK_PATH}/macos-arm64/Headers/WhisperC.h" ]] || fail "Staged XCFramework is missing WhisperC.h."
[[ -f "${XCFRAMEWORK_PATH}/macos-arm64/Headers/module.modulemap" ]] || fail "Staged XCFramework is missing module.modulemap."
readonly STAGED_ARCHIVE="${XCFRAMEWORK_PATH}/macos-arm64/libWhisperC.a"
[[ -f "${STAGED_ARCHIVE}" ]] || fail "Staged XCFramework is missing libWhisperC.a."
[[ "$(lipo -archs "${STAGED_ARCHIVE}")" == "arm64" ]] || fail "Staged XCFramework archive is not arm64-only."

readonly ARTIFACT_SHA256="$({
    cd "${XCFRAMEWORK_PATH}"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
} | shasum -a 256 | awk '{print $1}')"
readonly COMPILER_VERSION="$(xcrun clang --version | head -n 1)"
readonly XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
readonly CMAKE_VERSION="$(cmake --version | head -n 1)"

printf '%s\n' \
    "upstream=${UPSTREAM_URL}" \
    "tag=${RELEASE_TAG}" \
    "commit=${CHECKED_OUT_COMMIT}" \
    "platform=macOS" \
    "architecture=arm64" \
    "deployment_target=${DEPLOYMENT_TARGET}" \
    "build_shared_libs=OFF" \
    "whisper_build_examples=OFF" \
    "whisper_build_tests=OFF" \
    "whisper_build_server=OFF" \
    "whisper_curl=OFF" \
    "whisper_coreml=OFF" \
    "ggml_build_examples=OFF" \
    "ggml_build_tests=OFF" \
    "ggml_ccache=OFF" \
    "ggml_cpu=ON" \
    "ggml_accelerate=ON" \
    "ggml_blas=OFF" \
    "ggml_metal=OFF" \
    "ggml_openmp=OFF" \
    "ggml_native=OFF" \
    "compiler=${COMPILER_VERSION}" \
    "xcode=${XCODE_VERSION}" \
    "cmake=${CMAKE_VERSION}" \
    "artifact_tree_sha256=${ARTIFACT_SHA256}" \
    > "${PUBLICATION_STAGE}/build-provenance.txt"

# Publish only after the complete staged tree has been built and validated.
# If the final rename fails, restore the previously published dependency.
if [[ -e "${GENERATED_DIRECTORY}" ]]; then
    mv "${GENERATED_DIRECTORY}" "${PUBLICATION_BACKUP}"
fi
if ! mv "${PUBLICATION_STAGE}" "${GENERATED_DIRECTORY}"; then
    if [[ -e "${PUBLICATION_BACKUP}" ]]; then
        mv "${PUBLICATION_BACKUP}" "${GENERATED_DIRECTORY}"
    fi
    fail "Could not publish the prepared dependency; the prior artifact was restored."
fi
cmake -E remove_directory "${PUBLICATION_BACKUP}"

trap - EXIT

printf 'Prepared %s\n' "${GENERATED_DIRECTORY}/WhisperC.xcframework"
printf 'Pinned commit: %s\n' "${CHECKED_OUT_COMMIT}"
printf 'Artifact tree SHA-256: %s\n' "${ARTIFACT_SHA256}"
