
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

Each affected user story must carry the relevant decisions into verifiable acceptance criteria.
Examples include “missing X returns error Y without a default value” and “legacy parser Z is
deleted; no dual path remains.” Do not rely only on the top-level sections because Ralph executes
one story at a time.
