
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
