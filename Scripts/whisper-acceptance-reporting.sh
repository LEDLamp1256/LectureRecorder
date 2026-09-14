# Sourced by the acceptance command and its reporting tests. The commands are
# measured separately; neither interval includes the fresh Xcode build.
measure_model_verification() {
    printf 'model verification (SHA-256 command) wall time:\n'
    /usr/bin/time -l -o "$1/model-verification.time" "${@:2}" || return $?
    cat "$1/model-verification.time"
}

measure_harness_command() {
    printf 'harness-command wall time (includes worker-authoritative verification):\n'
    /usr/bin/time -l -o "$1/harness-command.time" "${@:2}" || return $?
    cat "$1/harness-command.time"
    printf 'complete acceptance-script wall time: not measured\n'
    printf 'resource scope: time -l command accounting; child/aggregate accounting not validated\n'
    printf 'worker-only peak RSS: not measured; no worker-RSS comparison supported\n'
}
