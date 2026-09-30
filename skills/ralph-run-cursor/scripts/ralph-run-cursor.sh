#!/usr/bin/env bash
set -euo pipefail

# Cursor CLI entry point for the shared Ralph loop (ralph-loop.sh). The loop owns argument handling,
# the policy gate and the exact-tree commit; this file says only how Cursor is run.
RALPH_RUNNER_NAME="ralph-run-cursor.sh"
RALPH_SKILL_LABEL="ralph-run-cursor"
RALPH_AGENT_LOG_PREFIX="cursor"
RALPH_AGENT_EXEC_LABEL="agent -p"
RALPH_WORKER_RESTRICTION="Do not invoke the ralph-run or ralph-run-cursor skill, do not run ralph-run-cursor.sh or ralph-notify.py, and do not launch another agent -p, agy -p, codex exec, or autonomous loop."
RALPH_REVIEW_EXTRA=""
# Cursor also runs Claude Code hooks, whose RTK hook cuts a plain git diff to 100 lines per file.
RALPH_REVIEW_DIFF_COMMAND="git diff --cached HEAD | cat"

ralph_resolve_agent() {
  AGENT_BIN="$(python3 "$SCRIPT_DIR/ralph_runtime.py" --expect cursor)"
  ralph_resolve_models cursor
  local review_schema="$SCRIPT_DIR/../assets/policy-review-reviewed-tree.schema.json"
  if [[ ! -f "$review_schema" ]]; then
    echo "error: Ralph policy gate files are missing; reinstall the $RALPH_SKILL_LABEL skill" >&2
    echo "missing: $review_schema" >&2
    exit 1
  fi
  # Cursor has no output schema option, so the reviewer receives the contract in its prompt.
  RALPH_REVIEW_EXTRA="$(python3 "$SCRIPT_DIR/cursor_output.py" review-instructions "$review_schema")"
}

ralph_worker() {
  local project_root="$1" prompt="$2" log_file="$3" last_message="$4" status
  local events="${log_file%.log}-events.jsonl"
  RALPH_RUN_ACTIVE=1 "$AGENT_BIN" -p --force --trust --sandbox disabled \
    --workspace "$project_root" --output-format stream-json "${WORKER_MODEL_ARGS[@]}" \
    "$prompt" > "$events" 2> "$log_file" 9>&-
  status=$?
  [[ "$status" -eq 0 ]] || return "$status"
  python3 "$SCRIPT_DIR/cursor_output.py" worker "$events" "$last_message" >> "$log_file" 2>&1 9>&-
}

ralph_reviewer() {
  local review_worktree="$1" review_prompt="$2" log_file="$3" review_file="$4" tree="$5" status
  local events="${review_file%.json}-events.jsonl"
  RALPH_RUN_ACTIVE=1 "$AGENT_BIN" -p --force --trust --sandbox disabled \
    --workspace "$review_worktree" --output-format stream-json "${REVIEW_MODEL_ARGS[@]}" \
    "$review_prompt" > "$events" 2>> "$log_file" 9>&-
  status=$?
  [[ "$status" -eq 0 ]] || return "$status"
  python3 "$SCRIPT_DIR/cursor_output.py" review "$events" "$tree" "$review_file" >> "$log_file" 2>&1 9>&-
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../ralph-run/scripts/ralph-loop.sh
source "$SCRIPT_DIR/ralph-loop.sh"
