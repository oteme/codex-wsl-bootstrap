<!-- BEGIN codex-workstation-bootstrap -->
Please provide all answers in Japanese

## gstack

gstack is installed for Codex CLI under `~/.codex/skills`.
When a request clearly matches a gstack skill, use the matching `gstack-*` skill.

Common routing:
- Product ideas or brainstorming: `gstack-office-hours`
- Scope or strategy review: `gstack-plan-ceo-review`
- Architecture review: `gstack-plan-eng-review`
- Bugs or root-cause investigation: `gstack-investigate`
- Code review or diff review: `gstack-review`
- Browser QA or site behavior checks: `gstack-qa` or `gstack-qa-only`
- Visual/design review: `gstack-design-review`
- Shipping, PR, or release workflow: `gstack-ship` or `gstack-land-and-deploy`
- Save or restore context: `gstack-context-save` or `gstack-context-restore`
- Spec drafting: `gstack-spec`

## Ralph

Ralph skills are installed for Codex CLI under `~/.codex/skills`.
Use `ralph-bootstrap` to initialize `scripts/ralph` for a new project, `prd` to
create `tasks/prd-[feature-name].md`, then `ralph` to convert it into
`scripts/ralph/prd.json`, then `ralph-run` to execute the Ralph loop with Codex.
For an engineering plan workflow, a useful sequence is:
`gstack-plan-eng-review` -> `ralph-bootstrap` -> `prd` -> `ralph` -> `ralph-run`.

For detailed explanations outside of a Decision Brief / AskUserQuestion, use an HTML artifact.

Explain like I'm someone who knows nothing about this topic, using an HTML artifact with big pictures and few words.

Keep AskUserQuestion as the decision gate. It may contain a compact Decision Brief, but do not duplicate the full detailed explanation there.
The HTML artifact is for understanding; AskUserQuestion is for choosing.
<!-- END codex-workstation-bootstrap -->
