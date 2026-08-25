---
name: ralph-bootstrap
description: "Create the minimal scripts/ralph project scaffold for Ralph in a new or existing repo. Use before prd/ralph/ralph-run when scripts/ralph is missing, or when the user asks to initialize/bootstrap Ralph for a project. Does not create prd.json."
---

# Ralph Bootstrap

Initialize Ralph's project-local working directory without creating a task list.

Run this from the project root:

```bash
bash ~/.codex/skills/ralph-bootstrap/scripts/bootstrap-ralph.sh
```

It creates `scripts/ralph/CLAUDE.md`, `progress.txt`, `.gitignore`, `archive/`, and
`logs/`. It must not create or overwrite `prd.json`; the `ralph` skill derives that file
from a real PRD.

Leave existing scaffold files untouched. If the current directory is not a git
worktree, warn after bootstrapping because the Ralph loop expects git branches and
commits.

Afterward, the normal flow is `prd` -> `ralph` -> `ralph-run`. If a PRD already exists,
skip `prd`.
