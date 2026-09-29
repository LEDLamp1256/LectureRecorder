#!/bin/bash
set -euo pipefail

# Deterministic checks for provision-mlx-notes-model.sh's finite model
# selection. Never downloads or installs a real model: every case either
# fails before installing or runs against tiny fake files, with HOME
# redirected to a temporary directory so no real container is touched.

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROVISION="${SCRIPT_DIRECTORY}/provision-mlx-notes-model.sh"
readonly SWIFT_MANIFESTS="${SCRIPT_DIRECTORY}/../LectureRecorder/Services/MLX/MLXPinnedModelManifests.swift"
readonly TEST_ROOT="$(mktemp -d /tmp/LectureRecorder-mlx-provision-tests.XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

readonly FAKE_HOME="${TEST_ROOT}/home"
readonly EMPTY_SOURCE="${TEST_ROOT}/empty-source"
mkdir -p "${FAKE_HOME}" "${EMPTY_SOURCE}"

failures=0
check() {
    local description="$1" expected_output="$2"
    shift 2
    local output status=0
    output="$(HOME="${FAKE_HOME}" bash "${PROVISION}" "$@" 2>&1)" || status=$?
    if [[ ${status} -eq 0 ]]; then
        printf 'FAIL: %s (expected a nonzero exit)\n' "${description}"
        failures=$((failures + 1))
    elif [[ "${output}" != *"${expected_output}"* ]]; then
        printf 'FAIL: %s\n  expected output containing: %s\n  got: %s\n' "${description}" "${expected_output}" "${output}"
        failures=$((failures + 1))
    else
        printf 'ok: %s\n' "${description}"
    fi
}

check "no arguments is a usage error" "usage:"
check "three arguments is a usage error" "usage:" "${EMPTY_SOURCE}" qwen3-8b-4bit extra
check "unknown selection fails closed" "unknown model selection 'qwen3-14b'" "${EMPTY_SOURCE}" qwen3-14b
check "empty selection fails closed" "unknown model selection ''" "${EMPTY_SOURCE}" ""
check "arbitrary repository id fails closed" "unknown model selection 'mlx-community/Qwen3-14B-4bit'" \
    "${EMPTY_SOURCE}" mlx-community/Qwen3-14B-4bit
check "absent selection defaults to pinned 8B" \
    "Verifying mlx-community/Qwen3-8B-4bit @ 545dc4251c05440727734bcd94334791f6ab0192" "${EMPTY_SOURCE}"
check "explicit 8B selects pinned 8B" \
    "Verifying mlx-community/Qwen3-8B-4bit @ 545dc4251c05440727734bcd94334791f6ab0192" "${EMPTY_SOURCE}" qwen3-8b-4bit
check "explicit 14B selects pinned 14B" \
    "Verifying mlx-community/Qwen3-14B-4bit @ a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4" "${EMPTY_SOURCE}" qwen3-14b-4bit
check "14B requires its files" "missing required file: config.json" "${EMPTY_SOURCE}" qwen3-14b-4bit

# A correctly sized but wrong config.json must fail on the 14B digest.
readonly WRONG_SOURCE="${TEST_ROOT}/wrong-source"
mkdir -p "${WRONG_SOURCE}"
head -c 939 /dev/zero > "${WRONG_SOURCE}/config.json"
check "14B verifies against its own digest" "config.json SHA-256 mismatch against pinned revision a4d9b2df" \
    "${WRONG_SOURCE}" qwen3-14b-4bit

if [[ -e "${FAKE_HOME}/Library" ]]; then
    printf 'FAIL: a failed provisioning attempt created files under HOME\n'
    failures=$((failures + 1))
else
    printf 'ok: no failed attempt installed anything\n'
fi

# Every digest embedded in the script must also be pinned in Swift.
while read -r digest; do
    if ! grep -q "\"${digest}\"" "${SWIFT_MANIFESTS}"; then
        printf 'FAIL: script digest %s is not in MLXPinnedModelManifests.swift\n' "${digest}"
        failures=$((failures + 1))
    fi
done < <(grep -oE ':[0-9a-f]{64}"' "${PROVISION}" | tr -d ':"')
printf 'ok: script digests checked against MLXPinnedModelManifests.swift\n'

if [[ ${failures} -ne 0 ]]; then
    printf '%d failure(s)\n' "${failures}"
    exit 1
fi
printf 'all provisioning selection checks passed\n'
