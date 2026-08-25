---
name: ralph-run
description: "Run the Ralph autonomous coding loop from Codex CLI. Use when the user wants to execute scripts/ralph/prd.json autonomously, says 'run ralph', 'ralph run', 'ralph 30', 'ralphを回して', '/ralph-run', or wants the Codex equivalent of the Claude ralph-run skill. Requires scripts/ralph/prd.json and scripts/ralph/CLAUDE.md; use ralph-bootstrap first if scripts/ralph is missing."
---

# Ralph Run for Codex

Run Ralph's serial implementation loop using fresh `codex exec` processes instead of
Claude Workflow subagents. This is the Codex equivalent of the local Claude
`ralph-run` skill: each iteration starts with a clean agent context, reads the project's
Ralph instructions, updates `prd.json` and `progress.txt`, and stops when the child agent
emits `<promise>COMPLETE</promise>` or the iteration limit is reached.

Do not modify `scripts/ralph/prd.json`, `scripts/ralph/CLAUDE.md`, `ralph.sh`, or the
`prd`/`ralph` skills just to run the loop. The runner reads them as-is.

## Inputs

- Max iterations: integer from the invocation, such as `/ralph-run 30`. Default is `10`.
- Ralph directory: `<project-root>/scripts/ralph` by default. Run from the project root,
  the same directory where `./scripts/ralph/ralph.sh` would be run.

## Workflow

1. Resolve `RALPH_DIR` as an absolute path. Default: `$PWD/scripts/ralph`.
2. Check that `RALPH_DIR/prd.json` and `RALPH_DIR/CLAUDE.md` both exist. If
   `scripts/ralph` is missing, use `ralph-bootstrap` first. If only `prd.json` is
   missing, tell the user to create a PRD with `/prd`, then convert it with `/ralph`.
3. Run:

   ```bash
   bash ~/.codex/skills/ralph-run/scripts/ralph-run-codex.sh [max-iterations]
   ```

   The script creates `progress.txt` if missing, then runs one `codex exec` child process
   per iteration.

4. After the command completes, summarize:
   - whether Ralph completed
   - iterations run
   - where `scripts/ralph/progress.txt` is
   - any failed command or nonzero child exit code

## Execution Notes

- The runner uses `codex exec --dangerously-bypass-approvals-and-sandbox` so an autonomous
  iteration does not stall on approval prompts. This is intentionally equivalent to the
  unattended Ralph loop. Only run it in a trusted repo/worktree.
- Iterations are serial by design. Do not parallelize them; Ralph stories depend on
  ordered updates to `prd.json` and `progress.txt`.
- Child agents are instructed to read `RALPH_DIR/CLAUDE.md` in full and follow it as the
  authoritative task specification for that iteration.
- Child agents implement one iteration directly. They must not invoke `ralph-run`, run the
  runner script, launch another `codex exec`, or start another autonomous loop.
- A zero child exit with an empty final message is an error, not an incomplete iteration.
  Report the iteration log because authentication or MCP startup may have failed.
- The completion signal is exactly `<promise>COMPLETE</promise>`, matching Ralph's loop
  convention.
- If browser verification appears in acceptance criteria, the child Codex session should
  use available browser tooling in that environment. Do not rewrite the PRD just to rename
  a browser skill unless the user asks.
