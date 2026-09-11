# Building LectureRecorder

## First build from a clean checkout

The native Whisper dependency is intentionally generated locally and is not
stored in Git. Before the first app build in a clean checkout, run:

```sh
./Scripts/prepare-whisper-dependency.sh
```

This is the only step that accesses the network. It fetches the pinned
whisper.cpp `v1.9.2` commit
`306c88f4d1286aec1bf96e544632897886af5501`, builds an arm64 static library,
and publishes `Generated/WhisperDependency/WhisperC.xcframework`. Ordinary app
builds and runtime worker probes are offline and perform no downloads.

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
