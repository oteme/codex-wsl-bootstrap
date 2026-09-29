## Ralph

Ralph skills are installed under `~/.codex/skills`, and Cursor loads them directly.
Use `ralph-bootstrap` to initialize `scripts/ralph` for a new project, `prd` to
create `tasks/prd-[feature-name].md`, then `ralph` to convert it into
`scripts/ralph/prd.json`, then `ralph-run-cursor` to execute the Ralph loop with Cursor CLI.
In Cursor, always use `ralph-run-cursor`: a skill named `ralph-run` belongs to Codex or Claude
and does not run here.
For an engineering plan workflow, a useful sequence is:
`gstack-plan-eng-review` -> `ralph-bootstrap` -> `prd` -> `ralph` -> `ralph-run-cursor`.

