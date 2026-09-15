#!/bin/bash -p
# Direct execution uses privileged *shell mode*, not elevated OS privileges:
# Bash ignores startup hooks, imported functions and SHELLOPTS before any code.
# Deliberately overriding this interpreter (e.g. bash script) is outside this
# contract. Repository source, system utilities and /Applications/Xcode.app
# are trusted; arbitrary same-user process/file replacement is not covered.
set -euo pipefail
unset CDPATH
readonly SCRIPT_DIRECTORY="$(builtin cd -P -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && builtin pwd -P)"
# A literal stdin program avoids an environment-controlled re-entry flag or
# startup file. Preserve the source directory and explicit CLI arguments.
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /bin/bash -p -s -- "${SCRIPT_DIRECTORY}" "$@" <<'PREPARATION'
set -euo pipefail
umask 077
readonly SCRIPT_DIRECTORY="$1"
shift
[[ "$#" == 1 && ( "$1" == install || "$1" == stage ) ]] || {
    printf 'error: expected exactly one install or stage operation\n' >&2
    exit 1
}
readonly DEVELOPER_ROOT=/Applications/Xcode.app/Contents/Developer
readonly EXPECTED_COMPILER="${DEVELOPER_ROOT}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
readonly EXPECTED_SDK="${DEVELOPER_ROOT}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
readonly SOURCE="${SCRIPT_DIRECTORY}/WhisperModelInstall.c"
[[ -f "${SOURCE}" && ! -L "${SOURCE}" ]] || { printf 'error: regular helper source unavailable\n' >&2; exit 1; }
COMPILER=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    DEVELOPER_DIR="${DEVELOPER_ROOT}" /usr/bin/xcrun --no-cache --sdk macosx26.5 \
    --toolchain com.apple.dt.toolchain.XcodeDefault --find clang) || {
    printf 'error: Apple default compiler unavailable; install Xcode at /Applications/Xcode.app\n' >&2; exit 1;
}
SDK=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    DEVELOPER_DIR="${DEVELOPER_ROOT}" /usr/bin/xcrun --no-cache --sdk macosx26.5 \
    --toolchain com.apple.dt.toolchain.XcodeDefault --show-sdk-path) || {
    printf 'error: macOS 26.5 SDK unavailable in /Applications/Xcode.app\n' >&2; exit 1;
}
[[ "${COMPILER}" == "${EXPECTED_COMPILER}" && -f "${COMPILER}" && -x "${COMPILER}" &&
   "${SDK}" == "${EXPECTED_SDK}" && -d "${SDK}" ]] || {
    printf 'error: unexpected Apple compiler or SDK resolution\n' >&2; exit 1;
}
readonly COMPILER SDK
HELPER_ROOT=$(/usr/bin/mktemp -d /private/tmp/LectureRecorder-model-helper.XXXXXXXX) || {
    printf 'error: exclusive helper build directory creation failed\n' >&2; exit 1;
}
[[ "${HELPER_ROOT}" == /private/tmp/LectureRecorder-model-helper.* &&
   "${HELPER_ROOT#/private/tmp/LectureRecorder-model-helper.}" != *'/'* && -d "${HELPER_ROOT}" && ! -L "${HELPER_ROOT}" && -O "${HELPER_ROOT}" &&
   "$(/usr/bin/stat -f %Lp "${HELPER_ROOT}")" == 700 ]] || {
    printf 'error: invalid private build directory; no cleanup attempted\n' >&2; exit 1;
}
readonly HELPER_ROOT
readonly HELPER="${HELPER_ROOT}/WhisperModelInstall"
compilation_attempted=false
cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if [[ ${compilation_attempted} == true ]]; then
        /bin/rm -f -- "${HELPER}" || { printf 'error: helper cleanup failed: %s\n' "${HELPER}" >&2; [[ ${result} != 0 ]] || result=1; }
    fi
    /bin/rmdir -- "${HELPER_ROOT}" || { printf 'error: private build directory retained: %s\n' "${HELPER_ROOT}" >&2; [[ ${result} != 0 ]] || result=1; }
    exit "${result}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[[ ! -e "${HELPER}" && ! -L "${HELPER}" ]] || {
    printf 'error: unexpected pre-existing helper output; not executing or removing it\n' >&2; exit 1;
}
compilation_attempted=true
builtin cd -P -- "${HELPER_ROOT}"
if /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    DEVELOPER_DIR="${DEVELOPER_ROOT}" TMPDIR="${HELPER_ROOT}" \
    "${COMPILER}" --no-default-config -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -arch arm64 -isysroot "${SDK}" -mmacosx-version-min=26.5 "${SOURCE}" -o "${HELPER}"; then
    :
else
    result=$?
    printf 'error: helper compilation failed (exit %s); nothing executed\n' "${result}" >&2
    exit "${result}"
fi
[[ -f "${HELPER}" && ! -L "${HELPER}" && -O "${HELPER}" && -x "${HELPER}" && -s "${HELPER}" &&
   "$(/usr/bin/stat -f %l "${HELPER}")" == 1 &&
   "$(/usr/bin/file -b "${HELPER}")" == 'Mach-O 64-bit executable arm64' ]] || {
    printf 'error: compiler output is not the expected owned regular arm64 helper; nothing executed\n' >&2; exit 1;
}
if /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C "${HELPER}" "$@"; then
    exit 0
else
    result=$?
    printf 'error: model helper failed (exit %s)\n' "${result}" >&2
    exit "${result}"
fi
PREPARATION
