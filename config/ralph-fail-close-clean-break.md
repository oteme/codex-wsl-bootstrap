
## Preserve failure and removal semantics

The PRD's `Failure Behavior` and `Compatibility and Removal` sections describe how the code must
behave. Carry them into acceptance criteria only where a story implements them.

- Where a story implements a required failure, its criteria name the observable error or stop
  behavior. Where a story removes an obsolete path, its criteria name what is removed.
- Do not invent fallback, retry, compatibility, migration, or legacy behavior that the PRD does
  not require.

## Runner constraints

- Set `description` to name the PRD file as the source of truth (正本). Keep it free of progress
  state such as which stories are done or what is uncommitted; progress lives only in each
  story's `passes` and `notes` and in `progress.txt`, because the runner discards any later edit
  to `description`.
- Leave out work that only a person can do (their accounts, devices, one-time external setup,
  manual approvals, live verification on real services); it belongs in the PRD's pre-run
  checklist. Every story must be completable by an unattended worker.
- Do not write acceptance criteria, notes, or instructions that keep `passes` false until an
  outside decision, record, approval, credential, measurement, or live verification exists, and
  do not add ordering gates such as "all earlier stories must pass before starting". Order is
  expressed by `priority`. A criterion may still require the code to return an error when such an
  input is missing.
- If a story needs an implementation choice the PRD leaves open, settle it before writing
  `prd.json`: ask the user with options and a recommendation, or choose the recommended option
  within the PRD's goals and Non-Goals, and record the choice in the PRD. If no option fits, leave
  the story out and tell the user.
- Do not replace, archive, or rewrite `scripts/ralph/CLAUDE.md` when converting a PRD. It holds
  project notes such as `Authorized actions`; the worker protocol comes with the `ralph-run`
  skill, and plan-specific rules belong in the PRD and `prd.json`. Archive only `prd.json` and
  `progress.txt`.
