## gstack

gstack is installed under `~/.codex/skills` and registered for Antigravity in
`~/.gemini/config/skills.json`. Antigravity lists these skills by their own names, without the
`gstack-` prefix of their folders. When a request clearly matches a gstack skill, use it.

Common routing:
- Product ideas or brainstorming: `office-hours`
- Scope or strategy review: `plan-ceo-review`
- Architecture review: `plan-eng-review`
- Bugs or root-cause investigation: `investigate`
- Code review or diff review: `review`
- Browser QA or site behavior checks: `qa` or `qa-only`
- Visual/design review: `design-review`
- Shipping, PR, or release workflow: `ship` or `land-and-deploy`
- Save or restore context: `context-save` or `context-restore`
- Spec drafting: `spec`

When a review section produces several findings, present them in one user-question call
(`ask_question`) as separate questions, each with its own recommendation and options,
and pause once per section rather than once per finding. Findings whose options depend on an
earlier answer are still asked one at a time.

