
## Preserve failure and removal semantics

When converting a PRD, preserve its `Failure Behavior` and `Compatibility and Removal` decisions
inside each affected story's acceptance criteria.

- A required failure must name the observable error/stop behavior and forbid silent success,
  default substitution, or swallowed exceptions where relevant.
- A clean break must name the obsolete path, shim, flag, test, or documentation to remove and must
  forbid keeping both implementations when relevant.
- Do not invent fallback, retry, compatibility, migration, or legacy behavior that the PRD does not
  require.
- If the PRD leaves a material failure or compatibility decision unresolved, do not create
  `prd.json`. Report the unresolved decision so the user can update the PRD first.
