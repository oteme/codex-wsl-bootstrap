## gstack

gstack is installed under `~/.codex/skills`, and Cursor loads those skills directly under their
folder names (`gstack-*`). When a request clearly matches a gstack skill, use the matching
`gstack-*` skill.

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

When a review section produces several findings, present them together in one question to the
user as separate questions, each with its own recommendation and options, and pause once per
section rather than once per finding. Findings whose options depend on an earlier answer are still
asked one at a time.

