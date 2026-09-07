
## Fail-close and clean-break requirements

Every PRD must make error and compatibility behavior explicit. During clarification, ask only
when the answer cannot be established from the user's request or repository evidence.

Add these sections to the PRD:

### Failure Behavior

- List invalid inputs and invalid states that must return an error or stop processing.
- Identify any intentionally allowed fallback, retry, default substitution, or error suppression.
  If none is required, say that failures must remain visible and must not be converted to success.

### Compatibility and Removal

- Record whether the affected behavior is already released or consumed externally.
- Choose either `clean break` or `compatibility required`; do not leave the choice implicit.
- For a clean break, list obsolete code paths, shims, flags, tests, and documentation to delete.
- For required compatibility, name the supported old behavior, its consumers, and its removal
  condition. Do not add speculative compatibility for unreleased behavior.

### 確定した設計判断

- A table with an ID, the decision, and its reason for every decision settled during review or
  clarification, including the failure and compatibility choices above.
- Implementation follows this table without re-litigating it. When an implementer needs a
  decision the table does not cover, they decide within it and Non-Goals and record the decision;
  they do not stop.

### Pre-run checklist

- Work that only a person can do (their accounts, devices, one-time external setup, manual
  approvals, live verification on real services) goes here as a checklist to finish before the
  autonomous loop starts.
- It must not appear as user stories or acceptance criteria. Every user story must be completable
  by an unattended worker with repository changes, local builds, and local tests.

Keep user stories free of repeated policy text. A story references these sections by ID
(for example `D3`, `FR-5`) instead of restating them; a sentence that would appear in more than
one story belongs in the PRD sections above.
