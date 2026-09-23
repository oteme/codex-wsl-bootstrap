---
name: ralph-bootstrap
description: "Create the minimal scripts/ralph project scaffold for Ralph in a new or existing repo. Use before prd/ralph/ralph-run when scripts/ralph is missing, or when the user asks to initialize/bootstrap Ralph for a project. Does not create prd.json."
---

# Ralph Bootstrap

Initialize Ralph's project-local working directory without creating a task list.

Use this when a project does not yet have `scripts/ralph/`, especially before the
workflow:

```text
gstack-plan-eng-review -> prd -> ralph -> ralph-run
```

## What It Creates

Run this from the project root:

```bash
bash ~/.codex/skills/ralph-bootstrap/scripts/bootstrap-ralph.sh
```

The script creates:

- `scripts/ralph/CLAUDE.md` (project notes with an `Authorized actions` list)
- `scripts/ralph/progress.txt`
- `scripts/ralph/archive/`
- `scripts/ralph/logs/`

It also creates `scripts/ralph/.gitignore` for runner logs.

The worker protocol (how an iteration runs, when a story passes, the fail-close/clean-break code
rules, and that workers never commit because `ralph-run` commits only after an independent review)
ships with the `ralph-run` skill, not in `CLAUDE.md`. Keep `CLAUDE.md` for notes that apply to the
project across plans; plan-specific rules belong in the PRD and `prd.json`. An existing
`CLAUDE.md` from an older bootstrap keeps working, and the protocol takes precedence over it about
when to stop or when a story passes.

## Boundaries

- Do not create `scripts/ralph/prd.json`. The `ralph` skill owns that file because it must
  be derived from a real PRD.
- Do not overwrite an existing `CLAUDE.md`, `progress.txt`, `.gitignore`, or `prd.json`
  unless the user explicitly asks for force/repair behavior.
- If `prd.json` already exists, leave it untouched.
- If the current directory is not a git repo, warn the user after bootstrapping. Ralph can
  still be scaffolded, but the loop expects git for branches and commits.

## After Bootstrapping

Tell the user the next normal steps:

```text
/prd -> /ralph -> /ralph-run
```

If they already have a PRD markdown file, they can skip `/prd` and run `ralph` to generate
`scripts/ralph/prd.json`.
