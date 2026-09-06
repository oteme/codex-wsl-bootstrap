---
name: ralph-run
description: "Run the Ralph autonomous coding loop from Codex CLI. Use when the user wants to execute scripts/ralph/prd.json autonomously, says 'run ralph', 'ralph run', 'ralph 30', 'ralphを回して', '/ralph-run', or wants the Codex equivalent of the Claude ralph-run skill. Requires scripts/ralph/prd.json and scripts/ralph/CLAUDE.md; use ralph-bootstrap first if scripts/ralph is missing."
---

# Ralph Run for Codex

Run Ralph's serial implementation loop using fresh `codex exec` processes instead of
Claude Workflow subagents. This is the Codex equivalent of the local Claude
`ralph-run` skill: each iteration starts with a clean agent context, reads the project's
Ralph instructions and updates `prd.json` and `progress.txt`. The runner independently reviews each
diff for fail-close/clean-break violations, commits only approved work, and runs under a detached supervisor until every story is approved or the runner reaches a
concrete blocked condition. The supervisor queues one result to the initiating Codex thread.

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
3. Require a valid `CODEX_THREAD_ID` and a Codex CLI with `codex queue --thread` support.
   Use the current session's environment (including `CODEX_HOME`) so the notification targets
   the same server and thread. Do not substitute another thread or home directory. If either
   requirement is missing, stop before starting work. The queue-and-resume route has been verified on the WSL Codex CLI and on the Windows
   App executing in WSL with `CODEX_HOME=/mnt/c/Users/reisu/.codex` (2026-09-07). The full
   supervisor/runner fixture was tested on the WSL CLI; native PowerShell execution is not covered.
4. Start exactly one supervisor, using the script alongside this skill:

   ```bash
   python3 <skill-dir>/scripts/ralph-notify.py \
     --thread "$CODEX_THREAD_ID" --ralph-dir "$PWD/scripts/ralph" \
     --max-iterations 0
   ```

   Replace 0 only with the user's explicit iteration limit. The launcher waits for a short startup
   acknowledgement, returns a run ID and result file, then exits. It detaches the supervisor
   itself; do not add `&` or `nohup`. A repository lock prevents simultaneous runners.
5. When `started=true` is returned, tell the user that Ralph started and provide the result file.
   **End the turn.** Do not keep the parent active using wait/stdin, sleeps, process checks,
   log-tail polling, goals, or another monitoring agent. The program waits for Ralph and uses
   `codex queue` once when it finishes. Detailed worker/reviewer output remains in files.
6. On receipt of `[Ralph result]`, read that run's `result.json` and report its terminal status,
   iterations, exit code and progress path. `limit_reached` is incomplete; `blocked`, `failed`
   and `interrupted` are not success. Do not launch another run automatically. On failure, read
   only the relevant log excerpt needed to explain it, not the entire execution history.

The durable result separates work status from notification status. `notification=queued` means
Codex accepted the message, not that the user read it. If queuing fails or times out, the supervisor
records `notification=failed` and diagnostics in `notification.log`; it does not retry, switch
servers, or claim delivery. If asked for status, run `python3 <skill-dir>/scripts/ralph-notify.py --status <result-file>`;
it checks the recorded process identity and reports `monitoring_lost` for a dead supervisor.
The raw file's `starting`/`running`
is only a last-recorded state, not proof of a live process. An OS/WSL shutdown or forced supervisor
kill can prevent notification entirely. Report monitoring loss if the supervisor has disappeared;
do not infer completion or automatically restart. The run directory is the recovery evidence.

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
  speculative compatibility or retained legacy paths, and weakened tests. It reads acceptance
  criteria only to determine whether those policy-sensitive behaviors are explicitly required or
  allowed; it does not grade general story correctness or completeness. Rejected work remains
  uncommitted and the story returns to `passes: false` for repair in the next iteration.
- The runner refuses to start when files outside `scripts/ralph` are already modified or untracked,
  preventing a story commit from absorbing unrelated work.
- A zero child exit with an empty final message is an error, not an incomplete iteration.
  Report the iteration log because authentication or MCP startup may have failed.
- Completion is derived from validated `prd.json` state after the approved commit. It is not trusted
  from a worker's self-reported final message.
- If browser verification appears in acceptance criteria, the child Codex session should
  use available browser tooling in that environment. Do not rewrite the PRD just to rename
  a browser skill unless the user asks.
