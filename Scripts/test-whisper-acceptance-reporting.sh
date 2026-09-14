#!/bin/bash
set -euo pipefail
readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIRECTORY}/whisper-acceptance-reporting.sh"
readonly TEST_ROOT="$(mktemp -d /tmp/LectureRecorder-reporting-tests.XXXXXX)"
verification="$(measure_model_verification "${TEST_ROOT}" /usr/bin/printf 'verification-control\n')"
harness="$(measure_harness_command "${TEST_ROOT}" /usr/bin/printf 'inference-control\n')"
[[ "$verification" == *'model verification (SHA-256 command) wall time:'* ]]
[[ "$verification" == *verification-control* && "$verification" != *inference-control* ]]
[[ "$harness" == *'harness-command wall time (includes worker-authoritative verification):'* ]]
[[ "$harness" == *inference-control* && "$harness" != *verification-control* ]]
[[ "$harness" == *'complete acceptance-script wall time: not measured'* ]]
[[ "$harness" == *'resource scope: time -l command accounting; child/aggregate accounting not validated'* ]]
[[ "$harness" == *'worker-only peak RSS: not measured; no worker-RSS comparison supported'* ]]
[[ -s "$TEST_ROOT/model-verification.time" && -s "$TEST_ROOT/harness-command.time" ]]
if measure_model_verification "$TEST_ROOT" /usr/bin/false; then exit 1; fi
if measure_harness_command "$TEST_ROOT" /usr/bin/false; then exit 1; fi
printf '%s\n%s\nreporting tests executed=10 passed=10 failed=0 skipped=0\n' "$verification" "$harness"
