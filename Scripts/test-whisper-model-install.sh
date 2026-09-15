#!/bin/bash
set -euo pipefail
[[ $# == 1 && ( "$1" == install || "$1" == stage ) ]] || exit 2
readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_ROOT="$(mktemp -d /tmp/LectureRecorder-model-helper-tests.XXXXXX)"
printf 'compiled security test product: %s/model-security-tests\n' "${TEST_ROOT}"
xcrun clang -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -mmacosx-version-min=26.5 "${SCRIPT_DIRECTORY}/WhisperModelInstallTests.c" \
    -o "${TEST_ROOT}/model-security-tests"
"${TEST_ROOT}/model-security-tests" "$1"
