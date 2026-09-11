# LectureRecorder

LectureRecorder is a native macOS application for lecture recording, transcription, and automated lecture note generation.

> **Building from a clean checkout:** the pinned native Whisper dependency is
> generated locally. Run `./Scripts/prepare-whisper-dependency.sh` before the
> first app build. See [BUILDING.md](BUILDING.md) for prerequisites, offline
> build behavior, and verified commands.

The project is being built with Swift and SwiftUI, with an emphasis on recoverability and accurate transcription of technical lectures.

## Current Status

Implemented so far:

- Native SwiftUI macOS application
- Explicit recording/session state machine
- Microphone permission handling
- App Sandbox configuration with audio input entitlement
- Sandboxed per-session storage
- Versioned session manifests
- JSON persistence

Real microphone audio capture has **not** been implemented yet.

## Goals

LectureRecorder is intended to eventually:

- Continuously capture microphone audio after the user explicitly presses Start
- Never use voice activation or VAD to decide what gets recorded
- Save recoverable audio chunks of approximately 30 seconds
- Continue recording even if transcription falls behind
- Perform transcription locally where practical
- Use Whisper / whisper.cpp for speech-to-text
- Generate structured lecture notes from transcripts
- Prioritize transcription accuracy over real-time speed
- Support technical lectures such as computer science, mathematics, and physics
- Potentially support speaker diarization and conversation recording in later versions

## Architecture

The application is intentionally designed so that recording does not depend on transcription performance.

The planned pipeline is:

```text
Microphone
    ↓
Audio Capture
    ↓
Recoverable Audio Chunks
    ↓
Transcription Queue
    ↓
Whisper / whisper.cpp
    ↓
Persisted Transcript
    ↓
Lecture Note Generation
The native macOS application owns:
	•	Recording lifecycle
	•	Session state
	•	Audio files
	•	Session metadata
	•	Persistence
	•	User interface
Transcription will later run as a separate local worker/service.
This separation ensures that slow transcription cannot interrupt or block audio capture.
Tech Stack
Current:
	•	Swift
	•	SwiftUI
	•	Foundation
	•	AVFoundation for microphone permission handling
	•	XCTest
	•	OSLog
	•	App Sandbox
Planned:
	•	AVAudioEngine / AVFAudio
	•	whisper.cpp
	•	Local transcription queue
	•	Transcript persistence
	•	Lecture note generation pipeline
Session Storage
Each recording session receives a UUID and its own directory.
Current layout:
Sessions/
└── <session-uuid>/
    ├── session.json
    ├── chunks/
    └── logs/
        └── recording.log
session.json
The session manifest stores information such as:
	•	Session UUID
	•	Creation time
	•	End time
	•	Session status
	•	End reason
	•	Audio format metadata
	•	Target chunk duration
	•	Chunk metadata
	•	Failure information
	•	Whether the session ended cleanly
chunks/
This directory will contain recoverable audio chunks once real microphone capture is implemented in Phase 2.
It is intentionally empty in the current Phase 1 implementation.
logs/
Each session contains a recording.log file for lifecycle and persistence events.
Development Phases
Phase 1 — Application Foundation
Status: Complete
Implemented:
	•	Recording state machine
	•	Microphone authorization flow
	•	Session manager
	•	Filesystem abstraction
	•	Session storage
	•	Atomic manifest writes
	•	Session logging
	•	Failure and retry handling
	•	SwiftUI interface
	•	Unit tests
Current milestone:
26 / 26 tests passing
Phase 2 — Real Audio Capture
Status: Next
Planned work:
	•	AVAudioEngine-based microphone capture
	•	Continuous recording
	•	No VAD-based recording decisions
	•	Approximately 30-second recoverable chunks
	•	Safe chunk rotation
	•	Final partial-chunk handling
	•	Manifest updates for completed chunks
	•	Audio interruption handling
	•	Input-device change handling
	•	Crash-recovery considerations
The first Phase 2 milestone will focus only on reliable recording and playback of saved audio.
Whisper integration will not be added until the recording pipeline is stable.
Later Phases
Planned future work includes:
	•	Local Whisper / whisper.cpp integration
	•	Background transcription queue
	•	Recording while previous chunks are transcribed
	•	Transcript persistence
	•	Post-processing for technical lectures
	•	Lecture note generation
	•	Speaker diarization
	•	Conversation recording support
	•	In-app session management and deletion
	•	Safe cleanup rules that prevent source audio from being deleted before transcription and note generation are complete
Design Principles
Recording reliability comes first
The recorder must continue capturing audio regardless of transcription throughput.
Accuracy over latency
LectureRecorder is intended for situations where transcription quality is more important than immediate results.
Transcription may continue after a lecture has ended if additional processing improves accuracy.
Recoverability
Sessions are persisted incrementally so that a crash or interruption should not destroy an entire lecture recording.
Local-first processing
Where practical, speech recognition and processing will run locally on the Mac rather than requiring continuous cloud services.
Separation of concerns
Recording, persistence, transcription, and note generation are being designed as separate components so that each can evolve independently.
Testing
The Phase 1 test suite currently covers:
	•	Atomic JSON writing and replacement
	•	Temporary-file cleanup
	•	Filesystem directory creation
	•	Session manifest encoding and decoding
	•	Recording lifecycle transitions
	•	Permission-denied behavior
	•	Repeated session creation
	•	Session preparation failures
	•	Manifest persistence failures
	•	Retry behavior
	•	Stop-finalization failures
	•	Recovery abandonment behavior
Current result:
Currently developed and tested for macOS using Xcode.
Project Status
LectureRecorder is under active development.
The current codebase represents the completed application foundation. Real microphone audio capture and transcription are still under development.
