---
name: ralph-run-cursor
description: "Run the Ralph autonomous coding loop from Cursor CLI. Use when, in Cursor, the user wants to execute scripts/ralph/prd.json autonomously, says 'run ralph', 'ralph run', 'ralph 30', 'ralphを回して', '/ralph-run', or '/ralph-run-cursor'. Use this skill instead of ralph-run in Cursor: ralph-run belongs to Codex or Claude. Requires scripts/ralph/prd.json and scripts/ralph/CLAUDE.md; use ralph-bootstrap first if scripts/ralph is missing."
---

# Ralph Run for Cursor

Run Ralph's serial implementation loop using fresh headless Cursor CLI runs (`agent -p`). Each
iteration starts with a clean agent context, receives the Ralph worker protocol that ships with this
skill, reads the project's notes in `CLAUDE.md`, and updates `prd.json` and `progress.txt`. The
runner independently reviews each diff for fail-close/clean-break violations, commits only approved
work, and runs under a detached supervisor until every story is approved or the iteration budget is
used up. The supervisor then resumes this Cursor conversation once with the result.

Do not modify `scripts/ralph/prd.json`, `scripts/ralph/CLAUDE.md`, `ralph.sh`, or the `prd`/`ralph`
skills just to run the loop. The runner reads them as-is.

## Inputs

- Iteration budget: optional positive integer from the invocation, such as `/ralph-run-cursor 30`.
  With no number (or `0`), the runner sets the budget to twice the number of pending stories, at
  least 10, and prints it. The run ends when every story passes or the budget is used up; nothing
  else ends it except a hard error (a failed or unsuccessful `agent -p`, an empty worker reply, a
  worker commit, a reviewer that cannot run or does not report the staged tree). An iteration
  that completes no story, or whose story the reviewer rejects, leaves its work in the working tree
  and the next iteration continues from it.
- Ralph directory: `<project-root>/scripts/ralph` by default. Run from the project root.
- Models: optional, separate from the model you use interactively. Saved Ralph defaults live in
  `~/.cursor/ralph.json` as `{"model": "<worker model>", "review_model": "<reviewer model>"}` (both
  keys optional; setup never rewrites this file). When the user names a model for this run, pass
  `--model <name>` for the workers and `--review-model <name>` for the policy reviewer to the
  launcher. Each role uses the run value, then the saved value; the reviewer then falls back to the
  worker's model; with no model anywhere Cursor uses its default model (`agent models` shows it).
  The launcher checks both names against `agent models` and refuses to start with a model Cursor
  does not list. A parameterized name such as `claude-opus-4-8[effort=high]` is not in that list;
  the launcher passes it through, and Cursor rejects an invalid one in the first iteration. When the
  user asks to change the saved Ralph model, edit the settings file with the exact names the CLI
  lists; an invalid file stops every run until fixed. An empty run model is refused.

## Workflow

1. Resolve `RALPH_DIR` as an absolute path. Default: `$PWD/scripts/ralph`.
2. Check that `RALPH_DIR/prd.json` and `RALPH_DIR/CLAUDE.md` both exist. If `scripts/ralph` is
   missing, use `ralph-bootstrap` first. If only `prd.json` is missing, tell the user to create a PRD
   with `/prd`, then convert it with `/ralph`.
3. Require `CURSOR_CONVERSATION_ID` in your shell environment (Cursor sets it for agent commands).
   The ID must be a UUID. If it is missing, stop before starting work; do not substitute another ID.
   The result is delivered by resuming this conversation in the project's git top level, so it
   reaches this conversation only when this Cursor session was started there; otherwise delivery
   records `notification=failed` and the result stays in the result file.
   Setup records its verified Cursor CLI's absolute path in `scripts/cursor-runtime.json`; the
   supervisor, workers, reviewer and result delivery use that executable. If the record or executable
   is missing or invalid, stop and rerun `Downloads/setup-wsl.cmd`.
4. Start exactly one supervisor, using the script alongside this skill:

   ```bash
   python3 <skill-dir>/scripts/ralph-notify.py \
     --conversation "$CURSOR_CONVERSATION_ID" --ralph-dir "$PWD/scripts/ralph" \
     --max-iterations 0
   ```

   Replace 0 only with the user's explicit iteration limit. Add `--model` and `--review-model`
   only when the user named a model for this run. The launcher waits for a short startup
   acknowledgement, returns a run ID and result file, then exits. It detaches the supervisor itself;
   do not add `&` or `nohup`. A repository lock prevents simultaneous runners.
5. When `started=true` is returned, tell the user that Ralph started and provide the result file.
   **End the turn.** Do not keep the turn active with waits, sleeps, process checks or log polling.
6. When a `[Ralph result]` message arrives in this conversation, read that run's `result.json` and
   report its terminal status, iterations, exit code and progress path. `limit_reached` means the
   budget ran out with stories still pending; the uncommitted work of the current story stays in the
   working tree. Read the latest `progress.txt` entry before deciding whether to run again.
   `failed` and `interrupted` are not success. Do not launch another run automatically.

The durable result separates work status from delivery status. Cursor has no message queue, so the
supervisor delivers the result by resuming this conversation once with a headless turn (`agent -p
--resume=<conversation>`, no `--force`), no earlier than a minute after the run started, so that it
cannot collide with the turn that started Ralph. `notification=delivered` means Cursor ran that turn
in this same conversation; if you have this conversation open in an interactive session, the turn
appears when the conversation is reloaded. Cursor silently starts a new conversation for an unknown
ID, so delivery counts only when Cursor reports this conversation back; otherwise the supervisor
records `notification=failed` with `notification_error` and does not retry. If asked for status, run
`python3 <skill-dir>/scripts/ralph-notify.py --status <result-file>`; it reports `monitoring_lost`
for a dead supervisor, and `notification=lost` when the supervisor stopped after the
run but before it delivered the result. Never start a second run to recover a notification.

To stop a run, send one SIGTERM to the `supervisor_pid` recorded in the result file; the
supervisor stops the runner and every agent it started, then delivers an `interrupted` result.
Never signal `runner_pid` or an agent process directly: the agent would keep changing the working
tree after the repository lock is released. A second signal cancels the pending delivery, and
`--status` then reports `notification=lost`.

## Execution Notes

- Workers and the reviewer run as `agent -p --force --trust --sandbox disabled`, the unattended
  equivalent of the Codex loop. The reviewer runs in a disposable detached Git worktree populated
  from the exact staged review tree. Only run it in a trusted repository.
- Iterations are serial by design. Do not parallelize them.
- Each worker prompt contains the worker protocol from `assets/worker-protocol.md`; where the
  project's `CLAUDE.md`, the PRD or `prd.json` conflicts with it about when to stop or when a story
  passes, the protocol wins. Workers must not invoke this skill, run the runner, or start another
  agent run or loop, and must not commit.
- The final message of a worker is the last assistant message of the run, and the run must end with
  a successful `result` event.
- Cursor has no output schema option, so the reviewer receives the review JSON Schema in its prompt
  and must reply with exactly one JSON object (bare, or as the only fenced block). It must also run
  `git write-tree` in the review worktree and report the result as `reviewed_tree`; a reply without
  the exact staged tree is invalid output, so a reviewer that could not run commands in the review
  worktree cannot approve it. The reviewer is told to read the diff as `git diff --cached HEAD |
  cat`, because the Claude Code RTK hook that Cursor also runs cuts a plain `git diff` to 100 lines
  per file.
- The runner keeps only story `passes` and `notes` changes from the worker's `prd.json`, reviews the
  exact staged snapshot, and commits only the approved tree. Completion is derived from validated
  `prd.json` state, never from a worker's self-reported message.
- Uncommitted changes outside `scripts/ralph` do not block a run; they enter the next approved story
  commit.
- Per-iteration details are in `scripts/ralph/logs/cursor-iteration-N*.{log,jsonl}`.
