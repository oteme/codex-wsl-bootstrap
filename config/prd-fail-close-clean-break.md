
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

## Open implementation choices

- Settle in the PRD every implementation choice the stories need (which runtime, service,
  library, format, or method). Ask the user during clarification with options and a
  recommendation; without an answer, choose the recommended option within the PRD's goals and
  Non-Goals. Record each choice and its reason in the PRD.
- Do not turn an open choice into a spike, a release blocker, a pre-run checklist item, or an open
  question that a story waits for. If no option fits the Non-Goals, leave that work out of the
  stories and list it under Non-Goals or Open Questions.
- A condition for switching something on in production can stay in the PRD as a release step. It
  does not make an implementation story wait.

## Work only a person can do

### Pre-run checklist

- Work that only a person can do (their accounts, devices, one-time external setup, manual
  approvals, live verification on real services) goes here as a checklist to finish before the
  autonomous loop starts.
- It must not appear as user stories or acceptance criteria. Every user story must be completable
  by an unattended worker with repository changes, local builds, and local tests.
- No user story may depend on the result of a checklist item (a decision, record, credential,
  measurement, or verification). Choosing or proving an implementation approach is design work
  for the PRD, not a checklist item.
