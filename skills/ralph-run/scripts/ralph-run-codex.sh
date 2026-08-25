#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: ralph-run-codex.sh [max-iterations] [ralph-dir]"
  exit 0
fi

if [[ "${RALPH_RUN_ACTIVE:-0}" == "1" ]]; then
  echo "error: refusing to start a nested Ralph runner" >&2
  exit 1
fi

MAX_ITER="${1:-10}"
RALPH_DIR_INPUT="${2:-"$PWD/scripts/ralph"}"

if ! [[ "$MAX_ITER" =~ ^[0-9]+$ ]] || [[ "$MAX_ITER" -lt 1 ]]; then
  echo "error: max-iterations must be a positive integer" >&2
  exit 2
fi
command -v codex >/dev/null 2>&1 || { echo "error: codex command not found" >&2; exit 127; }

if [[ ! -d "$RALPH_DIR_INPUT" ]]; then
  echo "error: Ralph directory not found: $RALPH_DIR_INPUT" >&2
  echo "Run ralph-bootstrap first." >&2
  exit 1
fi

RALPH_DIR="$(cd "$RALPH_DIR_INPUT" && pwd)"
for required_file in prd.json CLAUDE.md; do
  [[ -f "$RALPH_DIR/$required_file" ]] || {
    echo "error: missing $RALPH_DIR/$required_file" >&2
    exit 1
  }
done

PROGRESS_FILE="$RALPH_DIR/progress.txt"
[[ -f "$PROGRESS_FILE" ]] || printf '# Ralph Progress Log\nStarted: %s\n---\n' "$(date)" > "$PROGRESS_FILE"
PROJECT_ROOT="$(cd "$RALPH_DIR/../.." && pwd)"
LOG_DIR="$RALPH_DIR/logs"
mkdir -p "$LOG_DIR"

completed=0
iterations_run=0
for ((i = 1; i <= MAX_ITER; i++)); do
  iterations_run="$i"
  log_file="$LOG_DIR/codex-iteration-$i.log"
  last_message="$LOG_DIR/codex-iteration-$i-last-message.txt"
  echo "Ralph iteration $i of $MAX_ITER"

  prompt=$(cat <<EOF
You are the implementation worker for exactly one Ralph iteration.

Do the implementation work directly in the project. Do not invoke the ralph-run skill, do not run ralph-run-codex.sh, and do not launch another codex exec or autonomous loop.

Read $RALPH_DIR/CLAUDE.md in full and follow its instructions. The prd.json and progress.txt files are in $RALPH_DIR. Update them as instructed. If all stories are complete, include the exact tag <promise>COMPLETE</promise> in your final response.
EOF
)

  # Prevent a stale message from an earlier run from being treated as this iteration's result.
  : > "$last_message"

  set +e
  RALPH_RUN_ACTIVE=1 codex exec \
    --cd "$PROJECT_ROOT" \
    --dangerously-bypass-approvals-and-sandbox \
    --output-last-message "$last_message" \
    "$prompt" 2>&1 | tee "$log_file"
  status=${PIPESTATUS[0]}
  set -e

  if [[ "$status" -ne 0 ]]; then
    echo "error: iteration $i failed with status $status" >&2
    echo "log: $log_file" >&2
    exit "$status"
  fi

  if [[ ! -s "$last_message" ]] || ! grep -q '[^[:space:]]' "$last_message"; then
    echo "error: codex exec returned no final message in iteration $i" >&2
    echo "This can indicate an authentication or MCP startup failure." >&2
    echo "log: $log_file" >&2
    exit 1
  fi

  if grep -Fxq '<promise>COMPLETE</promise>' "$last_message" 2>/dev/null; then
    completed=1
    break
  fi
done

[[ "$completed" -eq 1 ]] \
  && echo "Ralph completed all tasks." \
  || echo "Ralph reached max iterations without completing all tasks."
echo "completed=$completed"
echo "iterationsRun=$iterations_run"
echo "maxIterations=$MAX_ITER"
echo "progress=$PROGRESS_FILE"
echo "logs=$LOG_DIR"
