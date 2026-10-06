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
used up. The result is then added to the next message sent in this Antigravity conversation.

Do not modify `scripts/ralph/prd.json`, `scripts/ralph/CLAUDE.md`, `ralph.sh`, or the `prd`/`ralph`
skills just to run the loop. The runner reads them as-is.

## Inputs

- Iteration budget: optional positive integer from the invocation, such as `/ralph-run 30`. With no
  number (or `0`), the runner sets the budget to twice the number of pending stories, at least 10,
  and prints it. The run ends when every story passes or the budget is used up; nothing else ends it
  except a hard error (a failed or unsuccessful `agy -p`, a tool auto-denied in headless mode, an
  empty worker reply, a worker commit, a reviewer that cannot run or does not report the staged
  tree). An iteration that completes no story, or whose story the reviewer rejects, leaves
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
   another ID. Setup records its verified agy's absolute path in
   `<skill-dir>/scripts/antigravity-runtime.json`, next to `ralph-notify.py` (not in the project); the
   supervisor, workers and reviewer use that executable. If the record or executable is missing or
   invalid, stop and rerun `Downloads/setup-wsl.cmd`.
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
5. When `started=true` is returned, tell the user that Ralph started, provide the result file, and
   say that the result will come with their next message in this conversation once the run ends (an
   agy session started before the latest setup gets it only after the session is restarted).
   **End the turn.** Do not keep the turn active with waits, sleeps, process checks or log polling.
6. When a `[Ralph result]` message appears after a user message, read that run's `result.json` and
   report its terminal status, iterations, exit code and progress path before answering the user. A
   `[Ralph result]` saying that a result could not be read, or that its delivery cannot be recorded,
   names the file involved; report it as it is. `limit_reached` means the
   budget ran out with stories still pending; the uncommitted work of the current story stays in the
   working tree. Read the latest `progress.txt` entry before deciding whether to run again.
   `failed` and `interrupted` are not success. Do not launch another run automatically.

The durable result separates work status from delivery status. agy has no message queue, so when the
run ends the supervisor leaves the result in `~/.gemini/antigravity-cli/ralph-inbox/<conversation>/`
and records `notification=queued`. The result hook that setup installs (`PreInvocation`) adds it as a
user message at the first model call of this conversation's next turn, whether the conversation is
open in an interactive session or resumed later, and records `notification=delivered` once it has
handed the result to agy. Nothing appears in the conversation before that, and a hook stopped right
after handing a result over can hand it over once more. If asked for status, run
`python3 <skill-dir>/scripts/ralph-notify.py --status <result-file>`; it reports `monitoring_lost`
for a dead supervisor, and `notification=lost` when the supervisor stopped after the run but before
it left the result in the inbox. Never start a second run to recover a notification.

To stop a run, send one SIGTERM to the `supervisor_pid` recorded in the result file; the
supervisor stops the runner and every agent it started, then queues an `interrupted` result.
Never signal `runner_pid` or an agent process directly: the agent would keep changing the working
tree after the repository lock is released.

## Execution Notes

- Workers and the reviewer run as `agy --dangerously-skip-permissions`, the unattended equivalent
  of the Codex loop. The reviewer runs in a disposable detached Git worktree populated from the exact
  staged review tree. Only run it in a trusted repository.
- agy exits 0 even when headless mode auto-denies a tool, so a run whose JSON reply lists
  `denied_actions`, whose stderr reports an auto-denied tool, or whose JSON status is not `SUCCESS`,
  is a hard error.
- Iterations are serial by design. Do not parallelize them.
- Each worker prompt contains the worker protocol from `assets/worker-protocol.md`; where the
  project's `CLAUDE.md`, the PRD or `prd.json` conflicts with it about when to stop, when a story
  passes, or which instruction files a worker may change, the protocol wins. Workers must not
  invoke this skill, run the runner, or start another agent run or loop, and must not commit.
- Workers leave instruction files (`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `GEMINI.md`,
  `.claude/rules/`, `.cursor/rules/`) alone unless the story names the file's path, and propose
  changes in `progress.txt` instead. The runner holds back a story whose staged diff changes one
  it does not name, as the Codex runner does.
- The reviewer's output is constrained with `--json-schema`. It must run `git write-tree` in the
  review worktree and report the result as `reviewed_tree`; a reply without the exact staged tree is
  invalid output, so a reviewer that could not run commands in the review worktree cannot approve
  it.
- The runner keeps only story `passes` and `notes` changes from the worker's `prd.json`, reviews the
  exact staged snapshot, and commits only the approved tree. Completion is derived from validated
  `prd.json` state, never from a worker's self-reported message.
- Uncommitted changes outside `scripts/ralph` do not block a run; they enter the next approved story
  commit.
- Per-iteration details are in `scripts/ralph/logs/antigravity-iteration-N*.{log,json}`.
