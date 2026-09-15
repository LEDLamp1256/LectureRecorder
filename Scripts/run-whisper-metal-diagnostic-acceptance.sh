#!/bin/bash
set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIRECTORY}/whisper-acceptance-reporting.sh"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly ACCEPTANCE_ROOT="$(mktemp -d /tmp/LectureRecorder-T3C-metal-diagnostic.XXXXXX)"
readonly DERIVED_DATA="${ACCEPTANCE_ROOT}/DerivedData"
readonly PRODUCTS="${DERIVED_DATA}/Build/Products/Debug"
readonly HARNESS="${PRODUCTS}/LectureRecorderWorkerLaunchHarness"
readonly EXPECTED_DIGEST="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"

# Opt-in only, and read once into a local constant: this script is the only
# place LR_WHISPER_RUNTIME_DIAGNOSTICS or LR_WHISPER_CPU_CONTROL is ever
# translated into a compiled define. Ordinary builds (build-debug.sh,
# prepare-whisper-dependency.sh, the app target itself) never read either
# variable, so an ambient export in the invoking shell cannot silently
# change their behavior -- only an explicit invocation of this script can.
readonly CPU_CONTROL="${LR_WHISPER_CPU_CONTROL:-0}"
case "${CPU_CONTROL}" in
    0|1) ;;
    *)
        printf 'error: LR_WHISPER_CPU_CONTROL must be unset, 0, or 1\n' >&2
        exit 1
        ;;
esac

if [[ "${CPU_CONTROL}" == "1" ]]; then
    readonly MODE='cpu-control'
    readonly DEFINITIONS='$(inherited) LR_WHISPER_RUNTIME_DIAGNOSTICS=1 LR_WHISPER_CPU_CONTROL=1'
else
    readonly MODE='metal'
    readonly DEFINITIONS='$(inherited) LR_WHISPER_RUNTIME_DIAGNOSTICS=1'
fi

printf 'diagnostic mode: %s\n' "${MODE}"
printf 'acceptance root: %s\n' "${ACCEPTANCE_ROOT}"
cd "${REPOSITORY_ROOT}"
xcodebuild \
    -quiet \
    -project LectureRecorder.xcodeproj \
    -scheme LectureRecorderWorkerLaunchHarness \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA}" \
    GCC_PREPROCESSOR_DEFINITIONS="${DEFINITIONS}" \
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

# Unlike the plain real-inference acceptance command, stderr is folded into
# the captured log here: LR_WHISPER_RUNTIME_DIAGNOSTICS makes the worker
# relay whisper.cpp's own init/backend log lines on that stream.
measure_harness_command "${ACCEPTANCE_ROOT}" "${HARNESS}" real-inference 2>&1 | tee "${ACCEPTANCE_ROOT}/diagnostic.log"
