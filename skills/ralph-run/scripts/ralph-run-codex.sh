#!/usr/bin/env bash
set -euo pipefail

# Codex entry point for the shared Ralph loop (ralph-loop.sh). The loop owns argument handling,
# the policy gate and the exact-tree commit; this file says only how Codex is run.
RALPH_RUNNER_NAME="ralph-run-codex.sh"
RALPH_SKILL_LABEL="ralph-run"
RALPH_AGENT_LOG_PREFIX="codex"
RALPH_AGENT_EXEC_LABEL="codex exec"
RALPH_WORKER_RESTRICTION="Do not invoke the ralph-run skill, do not run ralph-run-codex.sh, and do not launch another codex exec or autonomous loop."
RALPH_REVIEW_EXTRA=""
RALPH_REVIEW_DIFF_COMMAND="git diff --cached HEAD"

ralph_resolve_agent() {
  CODEX_BIN="$(python3 "$SCRIPT_DIR/ralph_runtime.py")"
  ralph_resolve_models codex
  # Codex takes the reasoning effort as a configuration override.
  [[ -z "$WORKER_EFFORT" ]] || WORKER_MODEL_ARGS+=(-c "model_reasoning_effort=\"$WORKER_EFFORT\"")
  [[ -z "$REVIEW_EFFORT" ]] || REVIEW_MODEL_ARGS+=(-c "model_reasoning_effort=\"$REVIEW_EFFORT\"")
}

ralph_worker() {
  local project_root="$1" prompt="$2" log_file="$3" last_message="$4"
  RALPH_RUN_ACTIVE=1 "$CODEX_BIN" exec \
    --cd "$project_root" \
    --dangerously-bypass-approvals-and-sandbox \
    "${WORKER_MODEL_ARGS[@]}" \
    --output-last-message "$last_message" \
    "$prompt" > "$log_file" 2>&1 9>&-
}

ralph_reviewer() {
  local review_worktree="$1" review_prompt="$2" log_file="$3" review_file="$4"
  RALPH_RUN_ACTIVE=1 "$CODEX_BIN" exec \
    --cd "$review_worktree" \
    --dangerously-bypass-approvals-and-sandbox \
    --ephemeral \
    "${REVIEW_MODEL_ARGS[@]}" \
    --output-schema "$REVIEW_SCHEMA" \
    --output-last-message "$review_file" \
    "$review_prompt" >> "$log_file" 2>&1 9>&-
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ralph-loop.sh
source "$SCRIPT_DIR/ralph-loop.sh"
