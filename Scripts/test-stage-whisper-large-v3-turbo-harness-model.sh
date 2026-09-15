#!/bin/bash
set -euo pipefail
readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /bin/bash "${SCRIPT_DIRECTORY}/test-whisper-model-install.sh" stage
