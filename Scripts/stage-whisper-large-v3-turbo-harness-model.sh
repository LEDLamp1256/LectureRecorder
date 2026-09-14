#!/bin/bash -p
set -euo pipefail
[[ "$#" == 0 ]] || { printf 'error: this closed model preparation command accepts no arguments\n' >&2; exit 1; }
unset CDPATH
readonly SCRIPT_DIRECTORY="$(builtin cd -P -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && builtin pwd -P)"
exec /bin/bash -p "${SCRIPT_DIRECTORY}/run-whisper-model-preparation.sh" stage
