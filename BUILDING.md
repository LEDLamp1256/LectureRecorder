# Building LectureRecorder

## First build from a clean checkout

The native Whisper dependency is intentionally generated locally and is not
stored in Git. Before the first app build in a clean checkout, run:

```sh
./Scripts/prepare-whisper-dependency.sh
```

This dependency-preparation step accesses the network. It fetches the pinned
whisper.cpp `v1.9.2` commit
`306c88f4d1286aec1bf96e544632897886af5501`, builds an arm64 static library,
and publishes `Generated/WhisperDependency/WhisperC.xcframework`. Ordinary app
builds and runtime worker probes are offline and perform no downloads.

## Preparing the T3B large-v3-turbo model

Real transcription additionally requires one explicit developer preparation
step. It is never run by the app, worker, build, or tests:

```sh
./Scripts/install-whisper-large-v3-turbo-model.sh
```

The argument-free installer downloads only the unquantized
`ggml-large-v3-turbo.bin` published by `ggerganov/whisper.cpp` at pinned repository
revision `5359861c739e955e79d9a303bcbc70fb988958b1`. It requires exactly
1,624,555,275 bytes and SHA-256
`1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`
before atomically publishing the file beneath the app's sandbox-resolved
Application Support root. It will not overwrite a conflicting artifact.
Normal inference performs no network access.

## Preparing the normally signed T3B acceptance harness

The normally signed launch harness has its own App Sandbox container identity,
so it cannot and must not read the production app container. After installing
and verifying the production model, stage a byte-identical acceptance-only
mirror in the harness container with:

```sh
./Scripts/stage-whisper-large-v3-turbo-harness-model.sh
```

This argument-free developer command reads only the closed production model
location through one retained descriptor, copies into an anonymous temporary,
verifies that copy's exact size and SHA-256, and atomically publishes it using
descriptor-source `fclonefileat` at the same catalog-relative path beneath the
harness's Application Support root. It never runs during app startup, builds,
tests, or production inference. Production model resolution remains in the
production app-owned Application Support root; the acceptance harness resolves
only its own container, and the inherited worker uses that same harness-owned
artifact during the external acceptance run. No shared-container entitlement
or filesystem exception is used.

Both commands compile the narrow `Scripts/WhisperModelInstall.c` developer
helper using the existing Xcode toolchain (macOS 26.5 deployment target).
They traverse controlled components from `/` with retained no-follow directory
descriptors, including a shared `Library/Containers` anchor. The account home
comes from `getpwuid`, not an environment override. Temporary files use random
128-bit basenames, exclusive/no-follow/close-on-exec creation and mode 0600,
followed immediately by unlink. The retained anonymous descriptor is copied,
hashed, synchronized, and passed directly to `fclonefileat` with no-owner-copy,
no-follow-any and resolve-beneath flags. Existing destinations are never
overwritten. Unsupported cloning (including ENOTSUP or EXDEV) fails closed:
use a clone-capable APFS destination; there is no pathname/copy fallback.
File full-sync and directory sync failures are reported; published entries
are retained on any subsequent error, never deleted as cleanup. Anonymous
temporary cleanup only closes descriptors.

This protects parent/source pathname substitution and ordinary concurrent
invocations. It explicitly does **not** protect against a malicious same-user
process discovering and opening/replacing the unpredictable basename in the
exclusive-create-to-immediate-unlink interval, then retaining writable access.
It also does not promise persistence against authorized post-publication
modification. Worker-side descriptor-backed size/SHA-256 verification remains
authoritative before inference. No privileged helper or new security boundary
is introduced. Standalone deterministic security tests are:

```sh
./Scripts/test-install-whisper-large-v3-turbo-model.sh
./Scripts/test-stage-whisper-large-v3-turbo-harness-model.sh
```

The downloaded GGML artifact is supplied by the pinned upstream repository;
this project does not claim to have converted or produced it locally.
whisper.cpp is distributed under the MIT license retained in the prepared
source and XCFramework. Whisper model use remains subject to the upstream
model's applicable license and terms; see the pinned upstream model provenance
above. Neither the model nor temporary download bytes are tracked by Git.

Run dependency preparation as a single invocation. Concurrent invocations of
`prepare-whisper-dependency.sh` in the same checkout are unsupported because
they intentionally share fixed build, staging, and publication paths.

Dependency preparation requires an arm64 Mac, Xcode command-line tools, Git,
and CMake 3.5 or newer. The verified toolchain is Xcode 26.6 (macOS SDK 26.5)
and CMake 4.4.3. The generated library and app targets use macOS 26.5 as their
deployment target.

## Verified commands

The tracked Debug-build entry point performs a dependency preflight and prints
the exact preparation command if anything is missing:

```sh
./Scripts/build-debug.sh
```

After preparation, the underlying app command is:

```sh
xcodebuild -project LectureRecorder.xcodeproj -scheme LectureRecorder \
  -configuration Debug -destination 'platform=macOS' build
```

Run the full hosted XCTest suite with:

```sh
xcodebuild -project LectureRecorder.xcodeproj -scheme LectureRecorder \
  -configuration Debug -destination 'platform=macOS' test
```

Because Xcode 26.6 mutates inherit-entitled helpers during a hosted test
action, authoritative normally signed process/signing checks use:

```sh
./Scripts/verify-normal-worker-products.sh
```

That ordinary signing/process suite deliberately does not run the 1.6 GB real
model. After staging the acceptance model, run the separate authoritative
real-inference command explicitly:

```sh
./Scripts/run-whisper-real-inference-acceptance.sh
```

It creates and prints a fresh external DerivedData/product root, strictly
verifies the newly built normally signed harness, measures an independent
artifact hash outside harness timing, and then measures the harness command.
The timed route performs only the worker's authoritative descriptor-backed
full-model hash; the app-side preflight and harness do not hash model bytes.

The labels are `model verification (SHA-256 command) wall time` and
`harness-command wall time (includes worker-authoritative verification)`.
The latter includes harness startup, job processing, worker execution and
acceptance assertions; it excludes the fresh build and independent model hash.
Complete acceptance-script wall time is not measured. The previously reported
approximately 28.59 seconds was harness-command time, not complete-script time.
Raw `time -l` reports are retained in the printed acceptance root. Their
child/aggregate accounting has not been validated and they do not establish
isolated worker peak RSS or support worker-RSS improvement comparisons.
The harness JSON's `totalMilliseconds` measures job processing only.

```sh
/bin/bash Scripts/test-whisper-acceptance-reporting.sh
```
