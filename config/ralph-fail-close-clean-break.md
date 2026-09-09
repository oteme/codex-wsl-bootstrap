
## Preserve failure and removal semantics

When converting a PRD, keep its `Failure Behavior`, `Compatibility and Removal`, and
`確定した設計判断` sections authoritative without copying them into every story.

- Set `description` to name the PRD file as the source of truth (正本) and state that its
  confirmed design decisions are not re-litigated during implementation. Keep it free of progress
  state such as which stories are done or what is uncommitted; progress lives only in each
  story's `passes` and `notes` and in `progress.txt`, because the runner rejects any later edit
  to `description`.
- Write only story-specific acceptance criteria plus the standard check criteria (typecheck, lint,
  tests, and browser verification for UI stories). Reference PRD decisions by their IDs instead of
  pasting their text; a policy or requirement sentence that would appear in more than one story
  belongs in the PRD.
- Where a story implements a required failure, its criteria name the observable error or stop
  behavior. Where a story removes an obsolete path, its criteria name what is removed.
- Do not invent fallback, retry, compatibility, migration, or legacy behavior that the PRD does
  not require.
- Do not add gating criteria such as "all earlier stories must pass before starting" or "keep
  `passes` false until verified on a real device or account". Order is expressed by `priority`.
- Leave out work that only a person can do (their accounts, devices, one-time external setup,
  manual approvals, live verification on real services); it belongs in the PRD's pre-run
  checklist. Every story must be completable by an unattended worker.
- If the PRD leaves a failure or compatibility decision unresolved, still create `prd.json`,
  record the open item in the affected story's `notes`, and tell the user.
