---
name: ralph-run
description: "Run the Ralph autonomous coding loop from Antigravity CLI (agy). Use when the user wants to execute scripts/ralph/prd.json autonomously, says 'run ralph', 'ralph run', 'ralph 30', 'ralphを回して', or '/ralph-run'. Requires scripts/ralph/prd.json and scripts/ralph/CLAUDE.md; use ralph-bootstrap first if scripts/ralph is missing."
---

# Ralph Run for Antigravity

Run Ralph's serial implementation loop using fresh headless Antigravity CLI runs (`agy -p`). Each
iteration starts with a clean agent context, receives the Ralph worker protocol that ships with this
skill, reads the project's notes in `CLAUDE.md`, and updates `prd.json` and `progress.txt`. The
runner independently reviews each diff for fail-close/clean-break violations, commits only approved
work, and runs under a detached supervisor until every story is approved or the iteration budget is
used up. The supervisor then resumes this Antigravity conversation once with the result.

Do not modify `scripts/ralph/prd.json`, `scripts/ralph/CLAUDE.md`, `ralph.sh`, or the `prd`/`ralph`
skills just to run the loop. The runner reads them as-is.

## Inputs

- Iteration budget: optional positive integer from the invocation, such as `/ralph-run 30`. With no
  number (or `0`), the runner sets the budget to twice the number of pending stories, at least 10,
  and prints it. The run ends when every story passes or the budget is used up; nothing else ends it
  except a hard error (a failed or unsuccessful `agy -p`, a tool auto-denied in headless mode, an
  empty worker reply, a worker commit, a reviewer that cannot run or does not prove it read the
  staged diff). An iteration that completes no story, or whose story the reviewer rejects, leaves
  its work in the working tree and the next iteration continues from it.
- Ralph directory: `<project-root>/scripts/ralph` by default. Run from the project root.
- Models: optional, separate from the model you use interactively. Saved Ralph defaults live in
  `~/.gemini/antigravity-cli/ralph.json` as `{"model": "<worker model>", "review_model": "<reviewer
  model>"}` (both keys optional; setup never rewrites this file). When the user names a model for
  this run, pass `--model <name>` for the workers and `--review-model <name>` for the policy
  reviewer to the launcher. Each role uses the run value, then the saved value; the reviewer then
  falls back to the worker's model; with no model anywhere agy uses its default model. The launcher
  checks both names against `agy models` and refuses to start with a model agy does not list. When
  the user asks to change the saved Ralph model, edit the settings file with the exact names the CLI
  lists; an invalid file stops every run until fixed.

## Workflow

1. Resolve `RALPH_DIR` as an absolute path. Default: `$PWD/scripts/ralph`.
2. Check that `RALPH_DIR/prd.json` and `RALPH_DIR/CLAUDE.md` both exist. If `scripts/ralph` is
   missing, use `ralph-bootstrap` first. If only `prd.json` is missing, tell the user to create a PRD
   with `/prd`, then convert it with `/ralph`.
3. Require `ANTIGRAVITY_CONVERSATION_ID` in your shell environment (agy sets it for commands the
   agent runs). It must be a UUID. If it is missing, stop before starting work; do not substitute
   another ID. Setup records its verified agy's absolute path in `scripts/antigravity-runtime.json`;
   the supervisor, workers, reviewer and result delivery use that executable. If the record or
   executable is missing or invalid, stop and rerun `Downloads/setup-wsl.cmd`.
4. Start exactly one supervisor, using the script alongside this skill:

   ```bash
   python3 <skill-dir>/scripts/ralph-notify.py \
     --conversation "$ANTIGRAVITY_CONVERSATION_ID" --ralph-dir "$PWD/scripts/ralph" \
     --max-iterations 0
   ```

   Replace 0 only with the user's explicit iteration limit. Add `--model` and `--review-model`
   only when the user named a model for this run. The launcher waits for a short startup
   acknowledgement, returns a run ID and result file, then exits. It detaches the supervisor itself;
   do not add `&` or `nohup`, and do not run it as a background task. A repository lock prevents
   simultaneous runners.
5. When `started=true` is returned, tell the user that Ralph started and provide the result file.
   **End the turn.** Do not keep the turn active with waits, sleeps, process checks or log polling.
6. When a `[Ralph result]` message arrives in this conversation, read that run's `result.json` and
   report its terminal status, iterations, exit code and progress path. `limit_reached` means the
   budget ran out with stories still pending; the uncommitted work of the current story stays in the
   working tree. Read the latest `progress.txt` entry before deciding whether to run again.
   `failed` and `interrupted` are not success. Do not launch another run automatically.

The durable result separates work status from delivery status. agy has no message queue, so the
supervisor delivers the result by resuming this conversation once with a headless turn
(`agy --conversation <id> -p ...`, without automatic approvals). `notification=delivered` means agy
ran that turn in this same conversation; if you have this conversation open in an interactive
session, the turn appears when the conversation is reloaded. agy silently starts a new conversation
for an unknown ID, so delivery counts only when agy reports this conversation back; otherwise the
supervisor records `notification=failed` with `notification_error` and does not retry. If asked for
status, run `python3 <skill-dir>/scripts/ralph-notify.py --status <result-file>`; it reports
`monitoring_lost` for a dead supervisor. Never start a second run to recover a notification.

## Execution Notes

- Workers and the reviewer run as `agy --dangerously-skip-permissions`, the unattended equivalent
  of the Codex loop. The reviewer runs in a disposable detached Git worktree populated from the exact
  staged review tree. Only run it in a trusted repository.
- agy exits 0 even when headless mode auto-denies a tool, so a run whose stderr reports an
  auto-denied tool, or whose JSON status is not `SUCCESS`, is a hard error.
- Iterations are serial by design. Do not parallelize them.
- Each worker prompt contains the worker protocol from `assets/worker-protocol.md`; where the
  project's `CLAUDE.md`, the PRD or `prd.json` conflicts with it about when to stop or when a story
  passes, the protocol wins. Workers must not invoke this skill, run the runner, or start another
  agent run or loop, and must not commit.
- The reviewer's output is constrained with `--json-schema`. It must run `git write-tree` in the
  review worktree and report the result as `reviewed_tree`; a reply without the exact staged tree is
  invalid output, so a reviewer that could not read the diff cannot approve it.
- The runner keeps only story `passes` and `notes` changes from the worker's `prd.json`, reviews the
  exact staged snapshot, and commits only the approved tree. Completion is derived from validated
  `prd.json` state, never from a worker's self-reported message.
- Uncommitted changes outside `scripts/ralph` do not block a run; they enter the next approved story
  commit.
- Per-iteration details are in `scripts/ralph/logs/antigravity-iteration-N*.{log,json}`.
