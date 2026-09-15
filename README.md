# LectureRecorder

LectureRecorder is a native macOS (Swift/SwiftUI) application for lecture
recording and local, offline transcription. Recording is explicitly
Start/Stop driven, audio is durably stored in recoverable chunks as it is
captured, and completed recordings can be transcribed locally with Whisper —
no cloud service is involved.

> **Building from a clean checkout:** the pinned native Whisper dependency is
> generated locally. Run `./Scripts/prepare-whisper-dependency.sh` before the
> first app build. See [BUILDING.md](BUILDING.md) for prerequisites, offline
> build behavior, and verified commands.

## What LectureRecorder does

- Records lecture audio from the microphone, starting and stopping only on
  explicit user action. Voice activity detection is never used to decide
  what gets captured.
- Writes audio to disk in recoverable ~30-second chunks as it records, so a
  crash or interruption does not lose an entire session.
- Lists finished recordings in a **Completed Sessions** window, sorted
  newest-first by the session's actual completion time (not filesystem
  order), with a deterministic tie-break so ordering is stable.
- Transcribes a completed session's audio locally and offline using Whisper
  (whisper.cpp, the project's existing large-v3-turbo model configuration).
  Transcription never blocks or paces recording — a session in progress and
  an already-running transcription of a different, already-completed
  session may coexist under an accepted asymmetric admission policy.
- Runs transcription work sequentially, with durable, resumable progress
  persisted to disk as each audio chunk finishes, so an interruption does
  not require starting over from the beginning.
- Offers Continue, Retry, and Cancel for an interrupted, failed, or
  in-progress transcription, where applicable to that session's state.
- Reopens an already-completed transcript without rerunning inference —
  viewing a finished transcript never re-invokes Whisper.
- Enforces a single app-wide transcription owner: only one transcription
  operation runs at a time across the whole app, regardless of how many
  windows are open.
- Automatically refreshes an already-open Completed Sessions window when a
  new recording finishes, with no polling — the window observes the shared
  recording lifecycle state and reloads only on a genuine new completion.
  Each window keeps its own selection across a refresh; a newly-appearing
  session never steals the current selection, and a selection is cleared
  only when the session it points to has actually disappeared.

## Current features

- Native SwiftUI macOS application, App Sandbox with an audio input
  entitlement
- Explicit recording/session state machine, with a single unified shutdown
  path shared by explicit Stop and failure-containment shutdown
- Real `AVAudioEngine` microphone capture, continuous once started
- Sandboxed per-session storage with versioned, atomically-written JSON
  session manifests
- Recoverable ~30-second audio chunks, written via a `.partial` →
  rename-on-finalize pattern
- Completed Sessions browsing: newest-first ordering, live no-polling
  refresh after finalization, window-local selection preserved across
  refresh
- Local, offline Whisper transcription (whisper.cpp, Metal-accelerated with
  a CPU fallback) of completed sessions, run in a separate, normally signed
  worker process — never in-process; a new transcription is not admitted
  while recording is already active, while an already-running transcription
  may continue if recording starts afterward
- Sequential transcription processing with durable, resumable progress and
  Continue / Retry / Cancel
- Single app-wide transcription ownership, with an accepted asymmetric
  policy allowing a recording session and an unrelated already-running
  transcription to coexist
- Reopening a completed transcript without rerunning inference

## Architecture / durability guarantees

- `AudioCaptureService` owns capture preparation, starting, callback
  admission, asynchronous-failure retention, and Stop draining.
- `SessionManager` owns the recording session lifecycle only: integrating
  capture with chunk-writer output, session manifests, and terminal session
  state. It does not own transcription scheduling or Completed Sessions
  catalog access.
- `CompletedSessionCatalog` performs a read-only, path-safety-checked scan
  of durably completed sessions; it never depends on the in-memory
  recording session and never creates or mutates session state.
- `CompletedSessionTranscriptionService` is the single app-wide owner of
  transcription work: it admits at most one active operation at a time,
  persists durable per-chunk progress, and exposes Continue / Retry /
  Cancel.
- Completed Sessions windows are thin, per-window presentation state
  (`CompletedSessionsListPresenter`) that call only the read-only catalog
  and observe the shared recording lifecycle publisher to trigger a
  refresh — they own no persistent background task and no polling timer.
- Source audio preservation and recoverability outrank transcription speed
  or UI convenience in every design tradeoff; recording never blocks on,
  waits for, or is paced by transcription.

### Session storage layout

```text
Sessions/
└── <session-uuid>/
    ├── session.json
    ├── chunks/
    └── logs/
        └── recording.log
```

`session.json` stores the session UUID, creation and end time, status, end
reason, audio format metadata, target chunk duration, per-chunk metadata,
failure information, and whether the session ended cleanly. Completed
transcription artifacts (jobs, per-chunk transcript results, and durable
progress) are persisted alongside each session under its own directory.

## Tech stack

- Swift, SwiftUI, Foundation, Combine
- `AVFoundation` / `AVAudioEngine` for microphone permission and capture
- whisper.cpp (Metal + CPU backends) via a native C bridge, run in a
  separate, normally signed worker process
- XCTest, OSLog, App Sandbox

## Building

The native Whisper dependency and the large-v3-turbo model are prepared
locally and are not stored in Git. See [BUILDING.md](BUILDING.md) for the
full clean-checkout preparation steps, verified build/test commands, and
real-inference acceptance instructions.

```sh
./Scripts/prepare-whisper-dependency.sh   # once, on a clean checkout
./Scripts/build-debug.sh                  # Debug build
```

## Testing

```sh
xcodebuild -project LectureRecorder.xcodeproj -scheme LectureRecorder \
  -configuration Debug -destination 'platform=macOS' test
```

Targeted tests:

```sh
xcodebuild -project LectureRecorder.xcodeproj -scheme LectureRecorder \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:LectureRecorderTests/<ClassName>[/<testMethod>] test
```

Process/signing verification for the normally signed worker products (does
not run real model inference):

```sh
./Scripts/verify-normal-worker-products.sh
```

Real local Whisper inference is opt-in and requires staging the acceptance
model first; see [BUILDING.md](BUILDING.md) for
`run-whisper-real-inference-acceptance.sh` and related scripts.
Hardware-dependent tests (real microphone capture, real Whisper inference)
remain opt-in and are not part of the default build/test commands above.

## Current development status / limitations

LectureRecorder is under active development, pre-1.0. The current milestone
is **v0.4.0 — Completed Session Transcription**, which brings the full
record → durable completed session → browse → local transcription → reopen
transcript flow together end to end. This milestone is being integrated
through the project's normal review process and will be tagged once that
integration lands on `main`.

Recording, durable session storage, Completed Sessions browsing (with
newest-first ordering and live refresh), and local Whisper transcription
(with sequential processing, durable progress, and Continue/Retry/Cancel)
are implemented, with targeted unit-test coverage included in the
repository.

Lecture-note generation and speaker diarization are not yet implemented.

**Known issue:** the `LectureRecorderTests` target can currently fail to
compile in some environments due to a Swift compiler/actor-isolation
interaction unrelated to the app's behavior (traced to a `nonisolated`
diagnostic on a test-only double). This does not affect the built app; it
is a test-target compilation issue under active investigation.
