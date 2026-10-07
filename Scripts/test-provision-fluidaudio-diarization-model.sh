#!/bin/bash
set -euo pipefail

# Offline checks for provision-fluidaudio-diarization-model.sh. Never uses the
# network (the `download` mode is only checked for argument handling) and
# never touches the real app container: HOME is redirected to a temporary
# directory. Optionally set LR_DIARIZATION_MODEL_SOURCE_DIR to a local copy of
# the pinned model files to also check a successful offline install; the copy
# is only read.

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROVISION="${SCRIPT_DIRECTORY}/provision-fluidaudio-diarization-model.sh"
readonly SWIFT_TABLE="${SCRIPT_DIRECTORY}/../LectureRecorder/Services/Diarization/FluidAudioDiarizationModel.swift"
readonly SWIFT_DIARIZER="${SCRIPT_DIRECTORY}/../LectureRecorder/Services/Diarization/FluidAudioSpeakerDiarizer.swift"
readonly PROVENANCE="${SCRIPT_DIRECTORY}/../Dependencies/DiarizationRuntime/provenance.json"
readonly RUNTIME_PACKAGE="${SCRIPT_DIRECTORY}/../Dependencies/DiarizationRuntime/Package.swift"
readonly MODEL_REVISION="df2625ac79a7ac6b65ad868fee6d80f320da4232"
readonly FLUIDAUDIO_COMMIT="b811a61569aa02691c99b808d08ee989b630c133"
readonly TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/LectureRecorder-diarization-provision-tests.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT

readonly FAKE_HOME="${TEST_ROOT}/home"
readonly DEST_PARENT="${FAKE_HOME}/Library/Containers/com.dylanlee.LectureRecorder/Data/Library/Application Support/Models/FluidAudio/FluidInference_speaker-diarization-coreml"
readonly DEST_DIR="${DEST_PARENT}/${MODEL_REVISION}"
mkdir -p "${FAKE_HOME}"

failures=0
pass() { printf 'ok: %s\n' "$1"; }
flunk() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

expect_failure() {
    local description="$1" expected_output="$2"
    shift 2
    local output status=0
    output="$(HOME="${FAKE_HOME}" bash "${PROVISION}" "$@" 2>&1)" || status=$?
    if [[ ${status} -eq 0 ]]; then
        flunk "${description} (expected a nonzero exit)"
    elif [[ "${output}" != *"${expected_output}"* ]]; then
        flunk "${description}: expected output containing '${expected_output}', got: ${output}"
    else
        pass "${description}"
    fi
}

nothing_installed() {
    if [[ -e "${DEST_DIR}" ]] || compgen -G "${DEST_PARENT}/.staging.*" >/dev/null; then
        flunk "$1: a failed run left an installed or staging directory behind"
    else
        pass "$1: nothing installed"
    fi
}

# relativePath:byteCount:sha256 entries of the script's table.
table_entries() {
    grep -oE '^    "[^"]+"' "${PROVISION}" | tr -d ' "'
}

# Writes a source tree with every pinned path present: `sized` files are
# zero bytes of exactly the pinned size (so only the digest is wrong);
# `short` files are a short string of the wrong size.
make_fake_source() {
    local directory="$1" mode="$2" entry relative_path rest bytes
    while IFS= read -r entry; do
        relative_path="${entry%%:*}"
        rest="${entry#*:}"
        bytes="${rest%%:*}"
        mkdir -p "${directory}/$(dirname "${relative_path}")"
        if [[ "${mode}" == "sized" ]]; then
            head -c "${bytes}" /dev/zero > "${directory}/${relative_path}"
        else
            printf 'not the model' > "${directory}/${relative_path}"
        fi
    done < <(table_entries)
}

# Arguments.
expect_failure "no arguments is a usage error" "usage:"
expect_failure "unknown mode fails closed" "unknown mode 'fetch'" fetch
expect_failure "install without a source is a usage error" "usage:" install
expect_failure "download takes no extra arguments" "usage:" download extra
expect_failure "install takes exactly one source" "usage:" install a b

# Source directory checks.
expect_failure "missing source directory" "source directory does not exist" install "${TEST_ROOT}/nowhere"
mkdir -p "${TEST_ROOT}/real-dir"
ln -s "${TEST_ROOT}/real-dir" "${TEST_ROOT}/linked-dir"
expect_failure "symlinked source directory is refused" "refusing a symbolic-link source directory" install "${TEST_ROOT}/linked-dir"

# Every file present but the wrong size: refused before anything is installed.
wrong_size_source="${TEST_ROOT}/wrong-size-source"
make_fake_source "${wrong_size_source}" short
expect_failure "wrong file sizes are refused" "size mismatch for Segmentation.mlmodelc/analytics/coremldata.bin" install "${wrong_size_source}"
nothing_installed "wrong file sizes"

# Every file present at its pinned size but with the wrong bytes: the
# digest check refuses it.
wrong_digest_source="${TEST_ROOT}/wrong-digest-source"
make_fake_source "${wrong_digest_source}" sized
expect_failure "modified files of the right size are refused" "SHA-256 mismatch for Segmentation.mlmodelc/analytics/coremldata.bin" install "${wrong_digest_source}"
nothing_installed "modified files"

empty_source="${TEST_ROOT}/empty-source"
mkdir -p "${empty_source}"
expect_failure "missing files are refused" "missing or non-regular file: Segmentation.mlmodelc/analytics/coremldata.bin" install "${empty_source}"
nothing_installed "missing files"

# A symlink in place of a pinned file is refused.
symlink_source="${TEST_ROOT}/symlink-source"
make_fake_source "${symlink_source}" short
rm "${symlink_source}/Segmentation.mlmodelc/analytics/coremldata.bin"
printf 'target' > "${TEST_ROOT}/link-target.bin"
ln -s "${TEST_ROOT}/link-target.bin" "${symlink_source}/Segmentation.mlmodelc/analytics/coremldata.bin"
expect_failure "a symlinked model file is refused" "missing or non-regular file: Segmentation.mlmodelc/analytics/coremldata.bin" install "${symlink_source}"
nothing_installed "symlinked model file"

# An existing destination is never overwritten.
mkdir -p "${DEST_DIR}"
expect_failure "existing destination is refused" "destination already exists" install "${wrong_size_source}"
rmdir "${DEST_DIR}"

# The script's table and the app's Swift table pin exactly the same files.
script_table="$(table_entries | sort)"
swift_table="$(grep -oE 'relativePath: "[^"]+", byteCount: [0-9_]+, sha256: "[0-9a-f]{64}"' "${SWIFT_TABLE}" \
    | sed -E 's/relativePath: "([^"]+)", byteCount: ([0-9_]+), sha256: "([0-9a-f]{64})"/\1:\2:\3/' | tr -d '_' | sort)"
if [[ -n "${script_table}" && "${script_table}" == "${swift_table}" && "$(printf '%s\n' "${script_table}" | wc -l | tr -d ' ')" == "21" ]]; then
    pass "script table matches FluidAudioDiarizationModelManifest.pinned (21 files)"
else
    flunk "script table and FluidAudioDiarizationModelManifest.pinned disagree"
fi

# Script, Swift, and provenance record pin the same model revision, and the
# provenance lists exactly the top-level model entries the table installs.
if grep -q "MODEL_REVISION=\"${MODEL_REVISION}\"" "${PROVISION}" \
    && grep -q "revision: \"${MODEL_REVISION}\"" "${SWIFT_TABLE}" \
    && [[ "$(plutil -extract model.revision raw -o - "${PROVENANCE}")" == "${MODEL_REVISION}" ]]; then
    pass "script, Swift, and provenance pin the same model revision"
else
    flunk "script, Swift, and provenance model revisions disagree"
fi
provenance_entries="$(plutil -extract model.files json -o - "${PROVENANCE}" | tr -d '[]"' | tr ',' '\n' | sort)"
installed_entries="$(table_entries | cut -d : -f 1 | cut -d / -f 1 | sort -u)"
if [[ "${provenance_entries}" == "${installed_entries}" ]]; then
    pass "provenance lists exactly the installed model entries"
else
    flunk "provenance model files (${provenance_entries//$'\n'/ }) differ from the table (${installed_entries//$'\n'/ })"
fi

# The FluidAudio pin agrees across the runtime package, provenance, and the
# diarizer's recorded provenance.
if grep -q "revision: \"${FLUIDAUDIO_COMMIT}\"" "${RUNTIME_PACKAGE}" \
    && [[ "$(plutil -extract commit raw -o - "${PROVENANCE}")" == "${FLUIDAUDIO_COMMIT}" ]] \
    && [[ "$(plutil -extract releaseTag raw -o - "${PROVENANCE}")" == "v0.16.1" ]] \
    && grep -q "FluidAudio 0.16.1 (${FLUIDAUDIO_COMMIT})" "${SWIFT_DIARIZER}"; then
    pass "runtime package, provenance, and diarizer agree on FluidAudio v0.16.1 (${FLUIDAUDIO_COMMIT})"
else
    flunk "the FluidAudio pin disagrees across the runtime package, provenance, and diarizer"
fi

# Optional: a real, offline install from a verified local copy, which must
# copy exactly the pinned files and nothing else from the source.
if [[ -n "${LR_DIARIZATION_MODEL_SOURCE_DIR:-}" ]]; then
    with_extra="${TEST_ROOT}/source-with-extra"
    cp -R "${LR_DIARIZATION_MODEL_SOURCE_DIR}" "${with_extra}"
    printf 'stray' > "${with_extra}/stray.txt"
    printf 'stray' > "${with_extra}/Segmentation.mlmodelc/stray.bin"
    if output="$(HOME="${FAKE_HOME}" bash "${PROVISION}" install "${with_extra}" 2>&1)" \
        && [[ "$(find "${DEST_DIR}" -type f | wc -l | tr -d ' ')" == "21" ]] \
        && [[ "$(find "${DEST_DIR}" ! -type f ! -type d | wc -l | tr -d ' ')" == "0" ]] \
        && [[ ! -e "${DEST_DIR}/stray.txt" && ! -e "${DEST_DIR}/Segmentation.mlmodelc/stray.bin" ]]; then
        pass "offline install copies exactly the 21 pinned files"
    else
        flunk "offline install from LR_DIARIZATION_MODEL_SOURCE_DIR failed: ${output:-}"
    fi
    expect_failure "a second install never replaces the first" "destination already exists" install "${with_extra}"
else
    printf 'skipped: successful install (set LR_DIARIZATION_MODEL_SOURCE_DIR to run it)\n'
fi

if [[ ${failures} -ne 0 ]]; then
    printf '%d provisioning check(s) failed\n' "${failures}"
    exit 1
fi
printf 'all diarization model provisioning checks passed\n'
