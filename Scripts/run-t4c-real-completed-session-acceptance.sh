#!/bin/bash
set -euo pipefail

# T4-C real-inference acceptance, modeled on the existing T3B
# run-whisper-real-inference-acceptance.sh: runs the NORMALLY BUILT
# (not xcodebuild `test`-action) LectureRecorderWorkerLaunchHarness
# executable directly as a process.
#
# This does NOT run through XCTest/`xcodebuild test`: Xcode 26.6's test
# action mutates the launched product's inherited sandbox entitlements
# (see WorkerEntitlementTestSupport.xcode26SkipMessage in the test target),
# which makes any inherit-entitled worker process launched from within a
# hosted test crash immediately (observed directly during T4-C development:
# signal 5, no stderr, in well under a second — nowhere near real model
# load/inference time). That is why EmbeddedWhisperWorkerSmokeTests/
# EmbeddedWorkerSmokeTests already self-skip under `xcodebuild test` and
# rely on normal-build verification instead — this script follows the same
# established pattern for T4-C's real-inference acceptance.
readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly DERIVED_DATA="$(mktemp -d /tmp/LectureRecorder-T4C-real-acceptance.XXXXXX)"
readonly PRODUCTS="${DERIVED_DATA}/Build/Products/Debug"
readonly HARNESS="${PRODUCTS}/LectureRecorderWorkerLaunchHarness"

printf 'Prerequisite: the real large-v3-turbo model must already be installed for the\n'
printf 'production app (run %s once if not).\n\n' "${SCRIPT_DIRECTORY}/install-whisper-large-v3-turbo-model.sh"

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

printf '\n--- Scenario A: real end-to-end transcription + cold reopen (items 7, 11) ---\n'
"${HARNESS}" completed-session-real-inference

printf '\n--- Scenario B: real Cancel -> Continue (item 8) ---\n'
"${HARNESS}" completed-session-cancel-continue
