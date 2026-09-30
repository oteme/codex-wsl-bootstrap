#!/usr/bin/env bash
set -euo pipefail

# Antigravity CLI (agy) entry point for the shared Ralph loop (ralph-loop.sh). The loop owns argument
# handling, the policy gate and the exact-tree commit; this file says only how agy is run.
# agy has no workspace option, so each call runs in a subshell that changes directory first, and the
# prompt must directly follow -p (agy reads the next argument as the prompt). --print-timeout is not
# passed: its expiry would end the run with partial output and exit status 0.
RALPH_RUNNER_NAME="ralph-run-antigravity.sh"
RALPH_SKILL_LABEL="Antigravity ralph-run"
RALPH_AGENT_LOG_PREFIX="antigravity"
RALPH_AGENT_EXEC_LABEL="agy -p"
RALPH_WORKER_RESTRICTION="Do not invoke the ralph-run skill, do not run ralph-run-antigravity.sh or ralph-notify.py, and do not launch another agy -p, agent -p, codex exec, or autonomous loop."
RALPH_REVIEW_EXTRA='Before judging, run "git write-tree" in that worktree and report its exact output as reviewed_tree.'
RALPH_REVIEW_DIFF_COMMAND="git diff --cached HEAD"

ralph_resolve_agent() {
  AGY_BIN="$(python3 "$SCRIPT_DIR/ralph_runtime.py" --expect antigravity)"
  ralph_resolve_models antigravity
  AGY_REVIEW_SCHEMA="$SCRIPT_DIR/../assets/policy-review-reviewed-tree.schema.json"
  if [[ ! -f "$AGY_REVIEW_SCHEMA" ]]; then
    echo "error: Ralph policy gate files are missing; reinstall the $RALPH_SKILL_LABEL skill" >&2
    echo "missing: $AGY_REVIEW_SCHEMA" >&2
    exit 1
  fi
}

ralph_worker() {
  local project_root="$1" prompt="$2" log_file="$3" last_message="$4" status
  local reply="${log_file%.log}-reply.json"
  (cd "$project_root" && RALPH_RUN_ACTIVE=1 exec "$AGY_BIN" --dangerously-skip-permissions \
    --output-format json "${WORKER_MODEL_ARGS[@]}" -p "$prompt") > "$reply" 2> "$log_file" 9>&-
  status=$?
  [[ "$status" -eq 0 ]] || return "$status"
  python3 "$SCRIPT_DIR/antigravity_output.py" worker "$reply" "$log_file" "$last_message" \
    >> "$log_file" 2>&1 9>&-
}

ralph_reviewer() {
  local review_worktree="$1" review_prompt="$2" log_file="$3" review_file="$4" tree="$5" status
  local reply="${review_file%.json}-reply.json" stderr_file="${review_file%.json}-stderr.log"
  (cd "$review_worktree" && RALPH_RUN_ACTIVE=1 exec "$AGY_BIN" --dangerously-skip-permissions \
    --output-format json --json-schema "$AGY_REVIEW_SCHEMA" "${REVIEW_MODEL_ARGS[@]}" \
    -p "$review_prompt") \
    > "$reply" 2> "$stderr_file" 9>&-
  status=$?
  cat "$stderr_file" >> "$log_file"
  [[ "$status" -eq 0 ]] || return "$status"
  python3 "$SCRIPT_DIR/antigravity_output.py" review "$reply" "$stderr_file" "$tree" "$review_file" \
    >> "$log_file" 2>&1 9>&-
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../ralph-run/scripts/ralph-loop.sh
source "$SCRIPT_DIR/ralph-loop.sh"
