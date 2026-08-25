---
name: ralph-run
description: "Run the Ralph autonomous coding loop from Codex CLI. Use when the user wants to execute scripts/ralph/prd.json autonomously, says 'run ralph', 'ralph run', 'ralph 30', 'ralphを回して', '/ralph-run', or wants the Codex equivalent of the Claude ralph-run skill. Requires scripts/ralph/prd.json and scripts/ralph/CLAUDE.md; use ralph-bootstrap first if scripts/ralph is missing."
---

# Ralph Run for Codex

Run Ralph's serial implementation loop using fresh `codex exec` processes instead of
Claude Workflow subagents. This is the Codex equivalent of the local Claude
`ralph-run` skill: each iteration starts with a clean agent context, reads the project's
Ralph instructions and updates `prd.json` and `progress.txt`. The runner independently reviews each
diff for fail-close/clean-break violations, commits only approved work, and stops when every story
is approved or the iteration limit is reached.

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

   The script creates `progress.txt` if missing, then runs one worker and one read-only policy
   reviewer per iteration.

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
- Workers do not commit. The runner verifies that exactly one story changed from `passes: false`
  to `passes: true`, rejects unauthorized PRD edits, and then asks a fresh read-only Codex process
  to inspect the diff.
- The runner stages the complete implementation snapshot (excluding runner logs), runs any
  executable pre-commit hook, restages hook output, and records the resulting Git tree. The
  reviewer inspects that cached diff. The final commit is created from the exact approved tree, so
  no hook or late file change can enter after review.
- The reviewer rejects newly introduced fallback/default behavior, swallowed exceptions,
  speculative compatibility or retained legacy paths, weakened tests, and unmet acceptance
  criteria. Rejected work remains uncommitted and the story returns to `passes: false` for repair
  in the next iteration.
- The runner refuses to start when files outside `scripts/ralph` are already modified or untracked,
  preventing a story commit from absorbing unrelated work.
- A zero child exit with an empty final message is an error, not an incomplete iteration.
  Report the iteration log because authentication or MCP startup may have failed.
- Completion is derived from validated `prd.json` state after the approved commit. It is not trusted
  from a worker's self-reported final message.
- If browser verification appears in acceptance criteria, the child Codex session should
  use available browser tooling in that environment. Do not rewrite the PRD just to rename
  a browser skill unless the user asks.
