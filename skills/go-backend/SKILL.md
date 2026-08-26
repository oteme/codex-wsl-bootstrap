---
name: go-backend
description: Apply the repository's Go backend conventions when planning, implementing, or reviewing Go services, HTTP APIs, SQL queries, persistence code, or database migrations. Use for Go backend work; do not apply these stack-specific rules to unrelated languages or frontend-only changes.
---

# Go Backend Rules

Use these rules together with the target repository's instructions. Explicit product requirements
and narrower repository rules remain authoritative. If they conflict in a way that changes
correctness, compatibility, or failure behavior, stop and surface the decision instead of inventing
a fallback.

## Read the relevant rules first

- For every Go backend architecture or implementation task, read
  [references/clean-architecture.md](references/clean-architecture.md).
- When an HTTP API or handler is involved, also read
  [references/api-design.md](references/api-design.md).
- When SQL, persistence, stored formats, or migrations are involved, also read
  [references/database-and-migrations.md](references/database-and-migrations.md).

Do not load an unrelated reference merely because the backend is written in Go.

## Non-negotiable baseline

- Dependencies point inward: `infrastructure -> adapter -> usecase -> domain`. Inner layers never
  import outer layers.
- Domain objects have no framework or persistence concerns. Usecases receive application inputs,
  depend on abstractions, and return domain entities or usecase result types.
- Handlers parse and validate transport input, invoke usecases, map errors, and shape responses.
  They do not contain business logic or directly access persistence.
- Compose concrete dependencies only at the application entry point or composition root.
- Use parameterized SQL. In multi-tenant systems, every access to tenant-owned data must enforce
  tenant isolation. Run writes that must succeed or fail together in one transaction.
- Do not expose internal errors or raw database errors through an API.

## Compatibility boundary

Do not infer a compatibility requirement from the fact that a change touches a database. Apply the
persisted-state test in the database reference. A temporary expand/deploy/contract path is permitted
only when old state or an independently deployed consumer outlives the deployment and the PRD or
acceptance criteria explicitly requires it.

Never use a persisted-state migration as precedent for retaining ordinary code paths. Every
temporary compatibility read, dual write, retained column, converter, flag, or shim must have a
paired contract story that names the exact code, schema, tests, and documentation to delete.

## Completion

Run the target repository's relevant formatter, static analysis, unit tests, integration tests, and
migration tests. Fail closed on invalid state. Do not weaken or skip checks to make the change pass.
