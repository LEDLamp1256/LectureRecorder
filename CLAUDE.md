# CLAUDE.md

## Project Purpose
LectureRecorder is a native macOS (Swift/SwiftUI) app for lecture recording,
local transcription, and lecture-note generation. Phase 1 (app foundation:
state machine, session manager, sandboxed storage, JSON manifests) is
complete. Phase 2 (real AVAudioEngine microphone capture) is in progress.
Whisper/whisper.cpp transcription is a later, not-yet-authorized phase.

## Non-Negotiable Invariants
These override convenience, performance, or "cleaner code" arguments:

- Recording starts only through explicit user action (Start) and normally
  stops only through explicit user action (Stop). Silence, voice activity
  detection (VAD), elapsed time, transcription, or any other content-based
  or timing-based logic must never automatically start or stop recording.
  The sole exception: a terminal capture or writer failure may trigger
  automatic failure-containment shutdown, so the UI cannot keep claiming
  `.recording` after durable capture has become impossible. That shutdown
  path must use the same unified, result-bearing shutdown owner as an
  explicit user Stop, and it must never automatically restart recording.
- Microphone capture is continuous once started.
- Voice activity detection (VAD) must never gate what gets recorded to
  source audio. VAD, if ever used, may only inform downstream processing —
  never decide what is captured.
- Audio is written in recoverable chunks of ~30 seconds.
- Recording must never block on, wait for, or be paced by transcription.
  Transcription lag can never slow or interrupt capture.
- Source audio preservation and recoverability outrank speed/latency in
  every design tradeoff.
- No transcription or Whisper/whisper.cpp work is to be implemented until
  explicitly authorized in a given task — even if it looks like the
  "obvious next step."

## Roles
- ChatGPT owns architecture, planning, and independent review.
- Claude implements accepted plans and writes code.
- Claude does not silently redesign architecture, change data formats,
  reinterpret invariants, or deviate from an accepted plan. If the plan
  looks wrong, incomplete, or conflicts with the invariants above, Claude
  surfaces the conflict and stops rather than improvising a fix.

## Verified Build & Test Commands
Run from the repo root. All verified working in this environment
(Xcode 26.6, macOS SDK 26.5) — no CI/lint config exists in the repo.

Clean-checkout prerequisite (requires an arm64 Mac, Git, Xcode command-line
tools, and CMake 3.5 or newer; verified with CMake 4.4.3):
    ./Scripts/prepare-whisper-dependency.sh

This publishes the ignored local artifact at
`Generated/WhisperDependency/WhisperC.xcframework`. Preparation is the only
networked step; ordinary builds and runtime worker probes are offline. See
`BUILDING.md` for the complete developer workflow.

Debug build:
    ./Scripts/build-debug.sh

Full unit test suite:
    xcodebuild -project LectureRecorder.xcodeproj -scheme LectureRecorder \
      -configuration Debug -destination 'platform=macOS' test

Targeted tests (class or method):
    xcodebuild -project LectureRecorder.xcodeproj -scheme LectureRecorder \
      -configuration Debug -destination 'platform=macOS' \
      -only-testing:LectureRecorderTests/<ClassName>[/<testMethod>] test

Lint / static analysis: none configured in this repo (no SwiftLint,
no swift-format, no build-phase script). Do not invent or assume one.

Manual verification: open the project in Xcode and Run (Cmd+R), or locate
the Debug build via:
    xcodebuild -project LectureRecorder.xcodeproj -scheme LectureRecorder \
      -configuration Debug -showBuildSettings | grep TARGET_BUILD_DIR
and `open` the resulting `LectureRecorder.app`.

## Branch & Review Workflow
- `dev` is the integration branch; `main` reflects the last reviewed/stable
  state.
- Implementation normally occurs on a `claude/<task-name>` feature branch
  created from the agreed `dev` baseline; amendments continue on that same
  existing task branch.
- Direct implementation on `dev` requires explicit authorization.
- Merging into `dev` or `main` requires Dylan's explicit authorization,
  informed by ChatGPT's architecture/code review.

## Prohibited Changes
- Any transcription/Whisper work not explicitly requested in the current task.
- Any use of VAD to decide what gets captured to source audio.
- Changes to the session manifest / storage format without an accepted plan.
- Silent architecture changes, refactors beyond task scope, or "cleanup"
  not requested.
- Force-pushes, history rewrites, or direct commits/merges to `main`.

## Definition of Done
- Debug build succeeds.
- The full unit test suite command completes successfully (no stored test
  count — verify the current run, not a remembered number); new/changed
  behavior has matching tests.
- No invariant above is violated.
- Implementation matches the accepted plan; any necessary deviation was
  surfaced and approved, not made silently.

## Handoff Format
At the end of implementation work, report:
1. What was implemented, mapped to the accepted plan.
2. Any conflicts, ambiguities, or deviations surfaced (and how resolved).
3. Exact commands run and their exact results (build/test) — never claim
   a check passed that wasn't actually run.
4. Files changed.
5. Open questions or follow-ups for ChatGPT/architecture review.

## Architecture Boundaries
- `AudioCaptureService` (and the `AudioCapturing` protocol it implements)
  owns capture preparation, starting, callback admission, asynchronous-
  failure retention, and Stop draining.
- `SessionManager` owns the higher-level session lifecycle: integrating
  capture with chunk-writer output, session manifests, and terminal
  session state.

## Source Files — Phase 2 Audio Capture Layer
- `AudioCapturing.swift` — protocol defining the idle → prepare() → prepared → start() → running → stop() → idle lifecycle contract
- `AudioCaptureService.swift` — real AVAudioEngine-backed implementation; validates hardware format has no implicit sample-rate/channel conversion before accepting it; `FailureCoordinator` resolves the race between `start()` committing and an async failure landing before/after that commit, tracks the claimed `onFailure` delivery on its own dedicated queue via a `DispatchGroup`, and `stop()` waits for both buffer-gate draining and that delivery to finish before returning
- `MockAudioCaptureService.swift` — hardware-free test double (`#if DEBUG`), same lifecycle/protocol and `FailureCoordinator`-backed draining contract as the real service, with inject-buffer, simulate-failure, and (test-only) stop-transition observation hooks
- `InFlightCallbackGate.swift` — lock-free, single-cycle admission gate (built on `Synchronization.Atomic`) that lets `stop()` wait until every already-admitted buffer callback has actually finished
- `AudioChunkWriter.swift` — consumes buffers off its own serial queue, splits them at chunk boundaries, writes `.caf` files via a `.partial` → rename-on-finalize pattern so a crash mid-chunk leaves a recoverable partial file
- `ChunkBoundaryPlanner.swift` — pure integer arithmetic for splitting a buffer across chunk boundaries, deliberately dependency-free so the boundary math (where off-by-one bugs would drop or duplicate audio) can be exhaustively unit tested
