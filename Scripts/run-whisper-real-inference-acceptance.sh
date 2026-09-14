#!/bin/bash
set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIRECTORY}/whisper-acceptance-reporting.sh"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly ACCEPTANCE_ROOT="$(mktemp -d /tmp/LectureRecorder-T3B-real-acceptance.XXXXXX)"
readonly DERIVED_DATA="${ACCEPTANCE_ROOT}/DerivedData"
readonly PRODUCTS="${DERIVED_DATA}/Build/Products/Debug"
readonly HARNESS="${PRODUCTS}/LectureRecorderWorkerLaunchHarness"
readonly EXPECTED_DIGEST="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"

printf 'acceptance root: %s\n' "${ACCEPTANCE_ROOT}"
cd "${REPOSITORY_ROOT}"
xcodebuild \
    -quiet \
    -project LectureRecorder.xcodeproj \
    -scheme LectureRecorderWorkerLaunchHarness \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA}" \
    build

[[ -x "${HARNESS}" && ! -L "${HARNESS}" ]] || {
    printf 'error: fresh normally signed harness product is unavailable\n' >&2
    exit 1
}
codesign --verify --strict "${HARNESS}"
readonly MODEL_PATH="$("${HARNESS}" acceptance-model-path)"
[[ ! -L "${MODEL_PATH}" && "$(stat -f %z "${MODEL_PATH}")" == 1624555275 ]] || {
    printf 'error: model type or exact size mismatch\n' >&2
    exit 1
}
# Independent artifact verification is deliberately outside harness timing.
measure_model_verification "${ACCEPTANCE_ROOT}" shasum -a 256 "${MODEL_PATH}" | tee "${ACCEPTANCE_ROOT}/model.sha256"
[[ "$(awk 'length($1) == 64 {print $1}' "${ACCEPTANCE_ROOT}/model.sha256")" == "${EXPECTED_DIGEST}" ]] || {
    printf 'error: independently verified model digest did not match\n' >&2
    exit 1
}

measure_harness_command "${ACCEPTANCE_ROOT}" "${HARNESS}" real-inference | tee "${ACCEPTANCE_ROOT}/inference.log"
