#!/bin/bash
set -euo pipefail

# T5-E real on-device Foundation Models Notes acceptance.
#
# Plain `LECTURE_RECORDER_RUN_LOCAL_NOTES_ACCEPTANCE=1 xcodebuild ... test`
# (and the documented `TEST_RUNNER_<VAR>=1` xcodebuild build-setting form)
# were both observed NOT to reach `ProcessInfo.processInfo.environment`
# inside the macOS-hosted XCTest process launched by `xcodebuild test` on
# this toolchain: the opt-in test's own gate saw the variable as absent
# either way and skipped before ever checking model availability.
#
# This script works around that by building for testing once, then
# injecting the environment variable directly into the generated
# `.xctestrun` file's `EnvironmentVariables` dictionary for the
# LectureRecorderTests test target (the documented, supported mechanism for
# `xcodebuild test-without-building -xctestrun`), and running from that.
#
# Unlike T4-C's run-t4c-real-completed-session-acceptance.sh, this does NOT
# need to avoid `xcodebuild test` for entitlement/subprocess-crash reasons
# — FoundationModelsRealAcceptanceTests never launches a worker subprocess,
# it calls SystemLanguageModel directly in the test host process. This is
# a narrower, environment-variable-specific workaround, not a wholesale
# avoidance of the test action.
readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly DERIVED_DATA="$(mktemp -d /tmp/LectureRecorder-T5E-real-acceptance.XXXXXX)"

cd "${REPOSITORY_ROOT}"

printf 'Building for testing...\n'
xcodebuild \
    -quiet \
    -project LectureRecorder.xcodeproj \
    -scheme LectureRecorder \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    build-for-testing

readonly XCTESTRUN="$(find "${DERIVED_DATA}/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
if [[ -z "${XCTESTRUN}" || ! -f "${XCTESTRUN}" ]]; then
    printf 'error: no .xctestrun file was produced by build-for-testing\n' >&2
    exit 1
fi

printf 'Injecting LECTURE_RECORDER_RUN_LOCAL_NOTES_ACCEPTANCE=1 into %s\n' "${XCTESTRUN}"
readonly ENV_KEY="TestConfigurations:0:TestTargets:0:EnvironmentVariables:LECTURE_RECORDER_RUN_LOCAL_NOTES_ACCEPTANCE"
/usr/libexec/PlistBuddy -c "Add :${ENV_KEY} string 1" "${XCTESTRUN}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :${ENV_KEY} 1" "${XCTESTRUN}"

printf '\nRunning the opt-in real Foundation Models acceptance test...\n'
xcodebuild \
    -xctestrun "${XCTESTRUN}" \
    -destination 'platform=macOS' \
    -only-testing:LectureRecorderTests/FoundationModelsRealAcceptanceTests \
    test-without-building
