---
name: ralph-run
description: "Run the Ralph autonomous coding loop from Codex CLI. Use when the user wants to execute scripts/ralph/prd.json autonomously, says 'run ralph', 'ralph run', 'ralph 30', 'ralphを回して', '/ralph-run', or wants the Codex equivalent of the Claude ralph-run skill. Requires scripts/ralph/prd.json and scripts/ralph/CLAUDE.md; use ralph-bootstrap first if scripts/ralph is missing."
---

# Ralph Run for Codex

Run Ralph's serial implementation loop using fresh `codex exec` processes instead of
Claude Workflow subagents. This is the Codex equivalent of the local Claude
`ralph-run` skill: each iteration starts with a clean agent context, reads the project's
Ralph instructions and updates `prd.json` and `progress.txt`. The runner independently reviews each
diff for fail-close/clean-break violations, commits only approved work, and by default stays attached
until every story is approved or the runner reaches a concrete blocked condition.

Do not modify `scripts/ralph/prd.json`, `scripts/ralph/CLAUDE.md`, `ralph.sh`, or the
`prd`/`ralph` skills just to run the loop. The runner reads them as-is.

## Inputs

- Max iterations: optional positive integer from the invocation, such as `/ralph-run 30`. With no
  number, the runner continues until all stories pass or a concrete failure/blocked condition stops
  it. `0` also means run until complete.
- Rejection circuit breaker: the same story may be rejected at most 3 consecutive times by default.
  Override only when explicitly needed with `RALPH_MAX_CONSECUTIVE_REJECTIONS`.
- Ralph directory: `<project-root>/scripts/ralph` by default. Run from the project root,
  the same directory where `./scripts/ralph/ralph.sh` would be run.

## Workflow

1. Resolve `RALPH_DIR` as an absolute path. Default: `$PWD/scripts/ralph`.
2. Check that `RALPH_DIR/prd.json` and `RALPH_DIR/CLAUDE.md` both exist. If
   `scripts/ralph` is missing, use `ralph-bootstrap` first. If only `prd.json` is
   missing, tell the user to create a PRD with `/prd`, then convert it with `/ralph`.
3. Start exactly one foreground runner execution:

   ```bash
   bash ~/.codex/skills/ralph-run/scripts/ralph-run-codex.sh [max-iterations]
   ```

   The script creates `progress.txt` if missing, then runs one worker and one independent policy
   reviewer per iteration. Do not append `&`, use `nohup`, or otherwise detach it.

4. Keep the original execution session attached until it returns an exit code:
   - If the execution tool yields a running session ID, retain it and wait on that same session
     using the tool's session wait/stdin operation.
   - Wait in intervals no longer than 60 seconds, without posting intermediate progress unless the
     user asks for it.
   - Do not replace the attached wait with `sleep`, `pgrep`, log-tail polling, another terminal
     command, or a newly launched runner.
   - If the session handle is lost, immediately report that monitoring was lost. Never claim that
     completion notification is still active merely because an OS process remains.

5. Only after that attached session completes, summarize:
   - whether Ralph completed
   - iterations run
   - where `scripts/ralph/progress.txt` is
   - any failed command or nonzero child exit code

## Execution Notes

- The runner uses `codex exec --dangerously-bypass-approvals-and-sandbox` for both the worker and
  reviewer so an autonomous iteration and its test suite do not stall on approval prompts or fail
  on scratch-file permissions. The reviewer runs in a disposable detached Git worktree populated
  from the exact staged review tree, so reviewer-created files cannot dirty the main worktree. This
  is intentionally equivalent to the unattended Ralph loop. Only run it in a trusted repository.
- Iterations are serial by design. Do not parallelize them; Ralph stories depend on
  ordered updates to `prd.json` and `progress.txt`.
- An omitted iteration limit is intentional. Do not invent a 10-iteration default and do not chain
  extra runner invocations after a guessed limit. A user-supplied numeric limit remains authoritative.
- Three consecutive policy rejections for the same story stop the runner as blocked instead of
  consuming unbounded retries. Nonzero child exits and invalid state transitions already fail closed.
- Child agents are instructed to read `RALPH_DIR/CLAUDE.md` in full and follow it as the
  authoritative task specification for that iteration.
- Child agents implement one iteration directly. They must not invoke `ralph-run`, run the
  runner script, launch another `codex exec`, or start another autonomous loop.
- Workers do not commit. The runner verifies that exactly one story changed from `passes: false`
  to `passes: true`, rejects unauthorized PRD edits, and then asks a fresh Codex process to inspect
  the diff. The reviewer performs static diff review in a disposable worktree and must not run
  builds, tests, linters, coverage, or package-manager commands. The runner removes that worktree
  after review and rejects the iteration if the main HEAD, staged tree, tracked files, or untracked
  files change during review.
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
