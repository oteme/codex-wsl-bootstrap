## Ralph

Ralph skills are installed under `~/.codex/skills` and registered for Antigravity in
`~/.gemini/config/skills.json`, except Codex's `ralph-run`. Antigravity has its own `ralph-run`
at `~/.gemini/antigravity-cli/skills/ralph-run/SKILL.md`, which runs the loop with Antigravity CLI.
If `ralph-run` is not in your skills list, read that `SKILL.md` and follow it; never use the Codex
`ralph-run` under `~/.codex/skills`, which starts Codex workers.
Use `ralph-bootstrap` to initialize `scripts/ralph` for a new project, `prd` to
create `tasks/prd-[feature-name].md`, then `ralph` to convert it into
`scripts/ralph/prd.json`, then `ralph-run` to execute the Ralph loop with Antigravity CLI.
For an engineering plan workflow, a useful sequence is:
`plan-eng-review` -> `ralph-bootstrap` -> `prd` -> `ralph` -> `ralph-run`.

