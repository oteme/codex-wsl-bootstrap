
## Fail-close and clean-break requirements

These sections describe how the product must behave. They are not rules about when work stops
or whether a story is complete.

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

## Work only a person can do

### Pre-run checklist

- Work that only a person can do (their accounts, devices, one-time external setup, manual
  approvals, live verification on real services) goes here as a checklist to finish before the
  autonomous loop starts.
- It must not appear as user stories or acceptance criteria. Every user story must be completable
  by an unattended worker with repository changes, local builds, and local tests.
