#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly WHISPER_XCFRAMEWORK="${REPOSITORY_ROOT}/Generated/WhisperDependency/WhisperC.xcframework"

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

for tool in xcodebuild codesign plutil file lipo mktemp shasum; do
    command -v "${tool}" >/dev/null 2>&1 || fail "Required tool '${tool}' is unavailable."
done

[[ -d "${WHISPER_XCFRAMEWORK}" ]] || fail "Prepared Whisper dependency is missing. Run ./Scripts/prepare-whisper-dependency.sh first."

readonly VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/LectureRecorder-T3A-verify.XXXXXX")"
readonly DERIVED_DATA="${VERIFY_ROOT}/DerivedData"
cleanup() {
    [[ -n "${VERIFY_ROOT}" && "${VERIFY_ROOT}" == *LectureRecorder-T3A-verify.* ]] || return
    rm -rf "${VERIFY_ROOT}"
}
trap cleanup EXIT

cd "${REPOSITORY_ROOT}"

xcodebuild \
    -quiet \
    -project LectureRecorder.xcodeproj \
    -scheme LectureRecorder \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA}" \
    build

xcodebuild \
    -quiet \
    -project LectureRecorder.xcodeproj \
    -scheme LectureRecorderWorkerLaunchHarness \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA}" \
    build

readonly PRODUCTS="${DERIVED_DATA}/Build/Products/Debug"
readonly APP="${PRODUCTS}/LectureRecorder.app"
readonly APP_MACOS="${APP}/Contents/MacOS"
readonly HARNESS="${PRODUCTS}/LectureRecorderWorkerLaunchHarness"
readonly FIXTURE_NAME="LectureRecorderWorkerFixture"
readonly WHISPER_NAME="LectureRecorderWhisperWorker"

codesign --verify --deep --strict "${APP}"

entitlements_to_file() {
    local executable="$1"
    local output="$2"
    codesign -d --entitlements - --xml "${executable}" > "${output}" 2>/dev/null
    plutil -lint "${output}" >/dev/null
}

require_boolean_entitlement() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual
    local escaped_key="${key//./\\.}"
    actual="$(plutil -extract "${escaped_key}" raw -o - "${plist}" 2>/dev/null)" || fail "Missing entitlement ${key} in ${plist}."
    [[ "${actual}" == "${expected}" ]] || fail "Expected ${key}=${expected} in ${plist}, got ${actual}."
}

require_exact_child_entitlements() {
    local executable="$1"
    local label="$2"
    local plist="${VERIFY_ROOT}/${label}.entitlements.plist"
    entitlements_to_file "${executable}" "${plist}"
    require_boolean_entitlement "${plist}" com.apple.security.app-sandbox true
    require_boolean_entitlement "${plist}" com.apple.security.inherit true
    local key_count
    key_count="$(grep -o '<key>' "${plist}" | wc -l | tr -d '[:space:]')"
    [[ "${key_count}" == "2" ]] || fail "${label} has unexpected normal-build entitlements: $(plutil -p "${plist}")."
    printf '%s entitlements: app-sandbox=true, inherit=true\n' "${label}"
}

require_exact_source_child_entitlements() {
    local plist="$1"
    local label="$2"
    plutil -lint "${plist}" >/dev/null
    require_boolean_entitlement "${plist}" com.apple.security.app-sandbox true
    require_boolean_entitlement "${plist}" com.apple.security.inherit true
    local key_count
    key_count="$(grep -o '<key>' "${plist}" | wc -l | tr -d '[:space:]')"
    [[ "${key_count}" == "2" ]] || fail "${label} source plist has unexpected entitlements: $(plutil -p "${plist}")."
    printf '%s source entitlements: app-sandbox=true, inherit=true\n' "${label}"
}

require_exact_harness_entitlements() {
    local plist="${VERIFY_ROOT}/harness.entitlements.plist"
    entitlements_to_file "${HARNESS}" "${plist}"
    require_boolean_entitlement "${plist}" com.apple.security.app-sandbox true
    local key_count
    key_count="$(grep -o '<key>' "${plist}" | wc -l | tr -d '[:space:]')"
    [[ "${key_count}" == "1" ]] || fail "Harness has unexpected entitlements: $(plutil -p "${plist}")."
    printf 'harness entitlements: app-sandbox=true\n'
}

codesign_value() {
    local executable="$1"
    local prefix="$2"
    codesign -dvv "${executable}" 2>&1 | sed -n "s/^${prefix}=//p" | head -n 1
}

require_product() {
    local executable="$1"
    local expected_identifier="$2"
    local expected_team="$3"
    [[ -f "${executable}" ]] || fail "Missing regular executable ${executable}."
    [[ ! -L "${executable}" ]] || fail "Executable is a symlink: ${executable}."
    [[ -x "${executable}" ]] || fail "Product is not executable: ${executable}."
    local architecture
    architecture="$(lipo -archs "${executable}")"
    [[ "${architecture}" == "arm64" ]] || fail "Expected arm64 ${executable}, got ${architecture}."
    local identifier
    local team
    identifier="$(codesign_value "${executable}" Identifier)"
    team="$(codesign_value "${executable}" TeamIdentifier)"
    [[ "${identifier}" == "${expected_identifier}" ]] || fail "Expected identifier ${expected_identifier}, got ${identifier}."
    [[ "${team}" == "${expected_team}" ]] || fail "Signing team mismatch for ${executable}: ${team}."
    printf '%s: regular, non-symlink, executable, %s, identifier=%s, team=%s, %s\n' \
        "${executable}" "${architecture}" "${identifier}" "${team}" "$(file "${executable}")"
}

readonly HOST_TEAM="$(codesign_value "${APP}" TeamIdentifier)"
[[ -n "${HOST_TEAM}" ]] || fail "Could not read host signing team."

require_exact_source_child_entitlements \
    "${REPOSITORY_ROOT}/LectureRecorderWorkerFixture/LectureRecorderWorkerFixture.entitlements" \
    fixture
require_exact_source_child_entitlements \
    "${REPOSITORY_ROOT}/LectureRecorderWhisperWorker/LectureRecorderWhisperWorker.entitlements" \
    whisper

require_product "${APP_MACOS}/${FIXTURE_NAME}" "${FIXTURE_NAME}" "${HOST_TEAM}"
require_product "${APP_MACOS}/${WHISPER_NAME}" "${WHISPER_NAME}" "${HOST_TEAM}"
require_exact_child_entitlements "${APP_MACOS}/${FIXTURE_NAME}" app-fixture
require_exact_child_entitlements "${APP_MACOS}/${WHISPER_NAME}" app-whisper

require_product "${HARNESS}" com.dylanlee.LectureRecorder.WorkerLaunchHarness "${HOST_TEAM}"
require_product "${PRODUCTS}/${FIXTURE_NAME}" "${FIXTURE_NAME}" "${HOST_TEAM}"
require_product "${PRODUCTS}/${WHISPER_NAME}" "${WHISPER_NAME}" "${HOST_TEAM}"
require_exact_harness_entitlements
require_exact_child_entitlements "${PRODUCTS}/${FIXTURE_NAME}" adjacent-fixture
require_exact_child_entitlements "${PRODUCTS}/${WHISPER_NAME}" adjacent-whisper

"${HARNESS}" fixture
"${HARNESS}" fixture-read
"${HARNESS}" whisper
"${HARNESS}" process-suite

printf 'normal app deep signature: valid\n'
printf 'normal worker product verification: passed\n'
