#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ralph-run-codex.sh [max-iterations] [ralph-dir]

Defaults:
  max-iterations: 10
  ralph-dir:      $PWD/scripts/ralph
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
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

if ! command -v codex >/dev/null 2>&1; then
  echo "error: codex command not found on PATH" >&2
  exit 127
fi

if [[ ! -d "$RALPH_DIR_INPUT" ]]; then
  echo "error: Ralph directory not found: $RALPH_DIR_INPUT" >&2
  echo "Create it first with:" >&2
  echo "  bash ~/.codex/skills/ralph-bootstrap/scripts/bootstrap-ralph.sh" >&2
  echo "Then create a PRD with /prd and convert it with /ralph." >&2
  exit 1
fi

if command -v realpath >/dev/null 2>&1; then
  RALPH_DIR="$(realpath "$RALPH_DIR_INPUT")"
else
  RALPH_DIR="$(cd "$RALPH_DIR_INPUT" && pwd)"
fi

if [[ ! -f "$RALPH_DIR/prd.json" || ! -f "$RALPH_DIR/CLAUDE.md" ]]; then
  echo "error: missing Ralph inputs in $RALPH_DIR" >&2
  [[ -f "$RALPH_DIR/prd.json" ]] || echo "missing: $RALPH_DIR/prd.json" >&2
  [[ -f "$RALPH_DIR/CLAUDE.md" ]] || echo "missing: $RALPH_DIR/CLAUDE.md" >&2
  echo "If CLAUDE.md is missing, run ralph-bootstrap. If prd.json is missing, run /prd then /ralph." >&2
  exit 1
fi

PROGRESS_FILE="$RALPH_DIR/progress.txt"
if [[ ! -f "$PROGRESS_FILE" ]]; then
  {
    echo "# Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
  } > "$PROGRESS_FILE"
  echo "pre-run: created $PROGRESS_FILE"
fi

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

Read the file $RALPH_DIR/CLAUDE.md in full and execute its instructions exactly as written.

That file is your complete and authoritative task specification for this iteration. The prd.json and progress.txt it refers to live in the same directory:
$RALPH_DIR

Run one Ralph iteration only. Update prd.json and progress.txt according to the instructions. If all stories are complete, include the exact tag <promise>COMPLETE</promise> in your final response.
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
    echo "error: codex exec failed in iteration $i with status $status" >&2
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
    echo "Ralph completed all tasks at iteration $i of $MAX_ITER"
    break
  fi

  echo "Iteration $i complete. Continuing..."
done

if [[ "$completed" -eq 0 ]]; then
  echo "Ralph reached max iterations ($MAX_ITER) without completing all tasks."
fi

echo "completed=$completed"
echo "iterationsRun=$iterations_run"
echo "maxIterations=$MAX_ITER"
echo "progress=$PROGRESS_FILE"
echo "logs=$LOG_DIR"
