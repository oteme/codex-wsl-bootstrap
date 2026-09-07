<!-- BEGIN codex-workstation-bootstrap -->
Please provide all answers in Japanese

## Workstation setup updates

Do not copy skills into either Codex home or run the bootstrap's `install.sh` /
`scripts/install-skill.sh` directly. Workstation changes are applied only by the Windows
`Downloads/setup-wsl.cmd` launcher after the change is merged; the `codex-wsl-bootstrap`
repository's own AGENTS.md has the full procedure.

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

When a review section produces several findings, present them in one user-question call
(`request_user_input`) as separate questions, each with its own recommendation and options,
and pause once per section rather than once per finding. Findings whose options depend on an
earlier answer are still asked one at a time.

## Ralph

Ralph skills are installed for Codex CLI under `~/.codex/skills`.
Use `ralph-bootstrap` to initialize `scripts/ralph` for a new project, `prd` to
create `tasks/prd-[feature-name].md`, then `ralph` to convert it into
`scripts/ralph/prd.json`, then `ralph-run` to execute the Ralph loop with Codex.
For an engineering plan workflow, a useful sequence is:
`gstack-plan-eng-review` -> `ralph-bootstrap` -> `prd` -> `ralph` -> `ralph-run`.

## Go backend

Go is the default backend language. For plans, implementation, or reviews involving Go backend
code, HTTP APIs, SQL, persistence, or database migrations, use the `go-backend` skill and read only
the references it routes to.

Always, even before the skill is loaded:
- Keep dependencies pointing inward; inner layers must not import adapters or infrastructure.
- Use parameterized SQL and enforce tenant isolation for tenant-owned data.
- Keep atomic multi-step writes in one transaction; map errors at the transport boundary and never
  expose internal errors.

## Fail-close and clean-break

For plans, specs, PRDs, implementations, and reviews:

- State which invalid inputs or states must fail, and do not silently substitute defaults,
  swallow errors, or add fallback/retry behavior unless the requirements explicitly call for it.
- State whether compatibility is required. If the replaced behavior has not been released or
  compatibility is not explicitly required, prefer a clean break and remove the obsolete path.
- Name the code, flags, shims, migrations, tests, and documentation that must be deleted.
- Treat new fallback paths, compatibility shims, retained legacy branches, swallowed exceptions,
  and weakened/skipped tests as specification changes that require explicit acceptance criteria.
- If a decision is needed that the requirements do not settle, decide within the PRD's
  confirmed design decisions (確定した設計判断) and Non-Goals, record the decision and its
  basis where the work is tracked (`progress.txt` for Ralph, the plan or PRD otherwise), and
  continue. Do not stop for a missing decision, and do not turn it into a fallback or
  compatibility policy.

For detailed explanations outside of a Decision Brief / AskUserQuestion, use an HTML artifact.

Explain like I'm someone who knows nothing about this topic, using an HTML artifact with big pictures and few words.

Keep AskUserQuestion as the decision gate. It may contain a compact Decision Brief, but do not duplicate the full detailed explanation there.
The HTML artifact is for understanding; AskUserQuestion is for choosing.
<!-- END codex-workstation-bootstrap -->
