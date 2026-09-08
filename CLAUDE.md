# CLAUDE.md

## Project Purpose
LectureRecorder is a native macOS (Swift/SwiftUI) app for lecture recording,
local transcription, and lecture-note generation. Phase 1 (app foundation:
state machine, session manager, sandboxed storage, JSON manifests) is
complete. Phase 2 (real AVAudioEngine microphone capture) is in progress.
Whisper/whisper.cpp transcription is a later, not-yet-authorized phase.

## Non-Negotiable Invariants
These override convenience, performance, or "cleaner code" arguments:

- Recording starts and stops only on explicit user action (Start/Stop).
  No automatic start/stop.
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

Debug build:
    xcodebuild -project LectureRecorder.xcodeproj -scheme LectureRecorder \
      -configuration Debug -destination 'platform=macOS' build

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
- `dev` is the active development branch; `main` reflects the last
  reviewed/stable state.
- Claude works on `dev` (or a feature branch off `dev` when asked) and
  does not merge into `main` or push directly to `main`.
- Changes are subject to review (by the user, relaying ChatGPT's
  architectural review) before merging to `main`.

## Prohibited Changes
- Any transcription/Whisper work not explicitly requested in the current task.
- Any use of VAD to decide what gets captured to source audio.
- Changes to the session manifest / storage format without an accepted plan.
- Silent architecture changes, refactors beyond task scope, or "cleanup"
  not requested.
- Force-pushes, history rewrites, or direct commits/merges to `main`.

## Definition of Done
- Debug build succeeds.
- Full unit test suite passes (currently 73/73); new/changed behavior has
  matching tests.
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
