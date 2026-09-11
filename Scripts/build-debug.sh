#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly DEPENDENCY_ROOT="${REPOSITORY_ROOT}/Generated/WhisperDependency/WhisperC.xcframework"

required_files=(
    "${DEPENDENCY_ROOT}/Info.plist"
    "${DEPENDENCY_ROOT}/macos-arm64/libWhisperC.a"
    "${DEPENDENCY_ROOT}/macos-arm64/Headers/WhisperC.h"
    "${DEPENDENCY_ROOT}/macos-arm64/Headers/module.modulemap"
)

for required_file in "${required_files[@]}"; do
    if [[ ! -f "${required_file}" ]]; then
        printf 'error: prepared Whisper dependency is missing or incomplete.\n' >&2
        printf 'Run ./Scripts/prepare-whisper-dependency.sh from the repository root, then retry.\n' >&2
        exit 1
    fi
done

cd "${REPOSITORY_ROOT}"
exec xcodebuild \
    -project LectureRecorder.xcodeproj \
    -scheme LectureRecorder \
    -configuration Debug \
    -destination 'platform=macOS' \
    build
