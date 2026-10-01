# Shared Engineering Workflow

These agreements apply to whichever coding agent is assigned to LectureRecorder.
Use `README.md` for current product and architecture facts and `BUILDING.md` for
build, test, model preparation, and acceptance procedures.

## Ownership and scope

- Dylan owns product intent and approves merges. ChatGPT may provide architecture,
  sequencing, and independent review guidance when used in the workflow.
- Claude Code is normally the implementation writer. Codex may review independently
  or implement when Dylan selects it. The assigned writer owns the checkout for
  that task; other agents remain read-only unless explicitly reassigned. Use one
  writer per checkout or worktree.
- Follow accepted architecture and task scope. Surface conflicts or needed changes
  to component ownership, public contracts, lifecycle guarantees, or persistence
  before implementing them. Do not silently redesign or start the next stage.
- Keep changes and PRs focused. Preserve unrelated work; avoid unsolicited cleanup.

## Git and approval

- `main` is the stable branch and `dev` is the integration branch. Use an isolated
  feature branch or worktree from the agreed baseline for feature work; amendments
  stay on the existing task branch. PRs target `dev` unless Dylan directs otherwise.
- Do not implement directly on `dev` or `main` without explicit authorization.
  Never merge, push, rewrite history, discard changes, or delete branches or
  worktrees without explicit authorization. Do not commit or open a PR as an
  automatic follow-up to a task. Dylan approves merges.
- Obtain explicit approval for dependency changes, signing, entitlements,
  deployment targets, persisted formats or major storage changes, recording or
  transcription semantics, and other project-wide configuration changes.

## Project invariants

- The normal recording lifecycle is controlled only by explicit user Start and
  Stop. Silence, voice activity detection (VAD), elapsed duration, and
  transcription or other downstream processing state must never automatically
  start or stop recording. The only exceptions are not content-, timing-, or
  processing-driven: a terminal capture or writer failure may stop recording for
  failure containment through the same unified, result-bearing shutdown owner as
  an explicit Stop, and app-termination cleanup remains allowed. Recording must
  never restart automatically.
- Capture is continuous once started. Voice activity detection must never gate
  source audio. Audio is stored in recoverable chunks. Recording must never wait
  for or be paced by transcription. Preserve source audio and recoverability.
- Do not begin unrequested recording, transcription, or inference work merely
  because it is the apparent next stage.

## Verification and reporting

- Choose focused checks first, then deterministic regression checks appropriate
  to the changed behavior. Use real hardware or model inference only when the
  task requires it; Whisper and MLX acceptance runs are opt-in and expensive.
- Do not claim a build or test passed unless it completed successfully. Report
  exact meaningful commands, results, limitations, and files changed. Do not
  substitute remembered test counts for current results.
- Review assignments are read-only unless fixes are explicitly requested.
- Never add AI attribution, generated-by text, session links, model names, or
  `Co-Authored-By` trailers to repository artifacts or Git history.
