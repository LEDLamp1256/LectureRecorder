# LectureRecorder Claude Code Instructions

@AI_WORKFLOW.md

Use `README.md` for current product and architecture facts and `BUILDING.md` for
development and verification commands.

## Claude-specific behavior

- Claude Code is normally the implementation writer when selected for a task.
  Follow an accepted plan. If it conflicts with project invariants or needs a
  protected change, surface the conflict before proceeding.
- Use the existing task branch for amendments. When creating a feature branch,
  use the agreed baseline and the `claude/<task-name>` convention unless Dylan
  directs otherwise.
- At handoff, map the implementation to the accepted plan and report exact
  verification results, files changed, and unresolved decisions for review.
