# Database and Migration Rules

## Persisted-state test

Compatibility is never decided by asking whether a change is "database" or "code." Ask only:

> Does old state, or a consumer we cannot update atomically, outlive this deployment?

- **Yes:** Examples include rows in a shared or production database, files in an already-written
  format, and released APIs used by clients deployed independently. The PRD or acceptance criteria
  must explicitly require the transition and its removal. Use expand -> deploy -> contract when
  needed.
- **No:** Examples include internal signatures, unreleased features, modules whose callers ship in
  the same atomic deployment, and schemas applied only to disposable local or test databases. Use a
  clean break and remove the obsolete path.

Expand/contract is deployment ordering for surviving state, not a preference for old behavior. It
is a time-bounded clean break:

```text
expand schema -> deploy code transition -> contract obsolete schema and code
```

Every expand story must have a paired contract story. Name every temporary dual write,
compatibility read, retained column, converter, feature flag, migration, test, and document that the
contract removes. Define the safe contract condition. If that decision is absent, stop as blocked;
do not invent a compatibility policy.

This section is not precedent for retaining ordinary code paths.

## Migration identity and files

Name paired migrations as:

```text
migrations/
├── 001_create_core_schema.up.sql
├── 001_create_core_schema.down.sql
├── 002_add_users.up.sql
└── 002_add_users.down.sql
```

Use `{sequence}_{description}.{up|down}.sql`. Once a migration has run in a shared environment, its
identifier and contents are immutable. Add a new migration instead of renaming, renumbering, or
editing an applied migration.

Before release, changing an identifier is allowed only after confirming whether any environment
ran the old identifier, whether repeated execution is safe, which references must change, and how
rollback works. Do not assume a migration will see only the development database state.

## Deployment order

- Adding a column or table: apply the additive migration, then deploy code that uses it.
- Removing a column or table: first deploy code that no longer uses it, then apply the contract
  migration.
- Prefer additive expansion only when the persisted-state test requires staged deployment; do not
  preserve an unreleased schema by default.

For a destructive down migration or transformation, explicitly decide whether rollback is
supported. When it is supported and meaningful data would be lost, preserve it before deletion.
Create the backup on the destructive side of the migration and ensure reruns cannot overwrite a
valid backup with already-modified data. A backup or rollback path not required by acceptance
criteria is a specification change, not an automatic fallback.

Test `up` migrations and test `down` migrations where rollback is supported.

## Data migration validation

- Validate the scope immediately before modification.
- Zero matches may be valid for a clean database, test environment, or new tenant; define this from
  the data invariant rather than treating zero as success universally.
- Abort on unsafe scope, such as unexpected duplicates or rows outside the intended tenant or
  predicate.
- Include safe identifiers in internal error output so operators can investigate affected records.
- Never swallow a validation failure or continue with a guessed subset.

When removing a field or type from structured data such as JSON, inspect both stored data and
application conversion logic. Search field names, serialized keys, constants, struct tags,
validators, compatibility converters, fixtures, and tests. Verify the retired field cannot reappear
when legacy records are read and valid fields still produce a valid object. Delete obsolete
conversion code in the contract story.

## Query safety

Always parameterize values:

```go
row := db.QueryRowContext(
    ctx,
    "SELECT id, name FROM users WHERE id = $1",
    userID,
)
```

Never interpolate user-controlled values with string concatenation or `fmt.Sprintf`.

For multi-tenant systems, every read and write of tenant-owned data must include tenant isolation in
the query or in an equivalently enforced database policy:

```sql
SELECT id, title
FROM chats
WHERE id = $1
  AND tenant_id = $2;
```

A resource ID alone is insufficient unless the architecture explicitly proves global isolation.
Test cross-tenant denial.

Handle nullable columns explicitly with `sql.Null*`, pointers, or the repository's established
nullable types. Do not scan a nullable column into a type that assumes a value.

## Transactions

Put all operations that must succeed or fail as a unit in one transaction. Begin with the request
context, return every operation error, roll back on non-commit exits, and return the commit error.

```go
tx, err := db.BeginTx(ctx, nil)
if err != nil {
    return err
}
defer tx.Rollback()

if _, err := tx.ExecContext(ctx, insertChat, chatID); err != nil {
    return err
}
if _, err := tx.ExecContext(ctx, insertMessage, messageID, chatID); err != nil {
    return err
}
return tx.Commit()
```

## Indexes and constraints

Choose indexes from measured or clearly established access patterns. Check filters, ordering,
joins, scan size, composite column order, selectivity, write cost, and storage cost. Tenant and time
columns are common candidates but are not automatic requirements.

Define foreign keys and other constraints where they encode a real invariant. Translate database
constraint failures into stable application errors only when the application needs to distinguish
them. For PostgreSQL, common SQLSTATE values include `23505` (`unique_violation`) and `23503`
(`foreign_key_violation`). Never expose raw database errors to API clients.

## Database change checklist

- Required migrations exist and applied migration identities remain unchanged.
- The persisted-state test and compatibility decision are explicit.
- Every expand step has a named contract step and deletion list.
- Destructive changes have an explicitly required preservation and rollback policy.
- Data migrations validate exact scope and fail closed on unsafe matches.
- Queries are parameterized; multi-tenant access enforces tenant isolation.
- Nullable values and constraint errors are handled intentionally.
- Atomic multi-step operations use a transaction.
- Indexes match actual access patterns and their cost is justified.
- Structured-data migrations remove obsolete converters as well as stored fields.
- Relevant migration, repository, integration, and cross-tenant tests pass.
