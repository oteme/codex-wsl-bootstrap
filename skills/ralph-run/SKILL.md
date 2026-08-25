---
name: ralph-run
description: "Run the Ralph autonomous coding loop from Codex CLI. Use when the user wants to execute scripts/ralph/prd.json autonomously, says 'run ralph', 'ralph run', 'ralph 30', 'ralphを回して', '/ralph-run', or wants the Codex equivalent of the Claude ralph-run skill. Requires scripts/ralph/prd.json and scripts/ralph/CLAUDE.md; use ralph-bootstrap first if scripts/ralph is missing."
---

# Ralph Run for Codex

Run Ralph serially using a fresh `codex exec` process for each iteration. Each child
reads the project's Ralph instructions, updates `prd.json` and `progress.txt`, and stops
when it emits `<promise>COMPLETE</promise>` or reaches the iteration limit.

From the trusted project root, run:

```bash
bash ~/.codex/skills/ralph-run/scripts/ralph-run-codex.sh [max-iterations]
```

The default limit is 10 and the default Ralph directory is `$PWD/scripts/ralph`.
Require both `prd.json` and `CLAUDE.md`. Use `ralph-bootstrap` if the directory or
instructions are missing; use `prd` then `ralph` if only `prd.json` is missing.

Iterations are intentionally serial. The runner bypasses approvals and sandboxing so it
does not stall unattended; only run it inside a trusted repository. After completion,
report the completion state, iteration count, progress file, and any failed child command.
Each child is a direct implementation worker and must not invoke `ralph-run`, launch another
`codex exec`, or start another loop. Treat a successful process exit with an empty final
message as a failure and surface the iteration log; it can indicate an authentication or
MCP startup problem.
