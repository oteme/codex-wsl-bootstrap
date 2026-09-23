#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bootstrap-ralph.sh [ralph-dir]

Defaults:
  ralph-dir: $PWD/scripts/ralph

Creates Ralph scaffold files, but intentionally does not create prd.json.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

RALPH_DIR_INPUT="${1:-"$PWD/scripts/ralph"}"

mkdir -p "$RALPH_DIR_INPUT/archive" "$RALPH_DIR_INPUT/logs"

if command -v realpath >/dev/null 2>&1; then
  RALPH_DIR="$(realpath "$RALPH_DIR_INPUT")"
else
  RALPH_DIR="$(cd "$RALPH_DIR_INPUT" && pwd)"
fi

CLAUDE_FILE="$RALPH_DIR/CLAUDE.md"
PROGRESS_FILE="$RALPH_DIR/progress.txt"
GITIGNORE_FILE="$RALPH_DIR/.gitignore"

if [[ ! -f "$CLAUDE_FILE" ]]; then
  cat > "$CLAUDE_FILE" <<'EOF'
# Ralph project notes

The Ralph worker protocol (how an iteration runs, when a story passes, the fail-close and
clean-break code rules, and the progress format) comes with the `ralph-run` skill, and the runner
gives it to every worker. This file holds only notes that apply to this project across plans. It
does not change the protocol. Plan-specific rules and decisions belong in the PRD and `prd.json`.

## Authorized actions

- Repository changes, local builds, and local tests: allowed.
- External resources this worker may create, deploy to, share, or modify: none listed. Add
  entries here before running stories that need them.
EOF
  echo "created: $CLAUDE_FILE"
else
  echo "exists:  $CLAUDE_FILE"
fi

if [[ ! -f "$PROGRESS_FILE" ]]; then
  {
    echo "# Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
  } > "$PROGRESS_FILE"
  echo "created: $PROGRESS_FILE"
else
  echo "exists:  $PROGRESS_FILE"
fi

if [[ ! -f "$GITIGNORE_FILE" ]]; then
  cat > "$GITIGNORE_FILE" <<'EOF'
logs/
EOF
  echo "created: $GITIGNORE_FILE"
else
  echo "exists:  $GITIGNORE_FILE"
fi

echo "ready:   $RALPH_DIR"

if [[ -f "$RALPH_DIR/prd.json" ]]; then
  echo "notice:  existing prd.json left untouched"
else
  echo "next:    create a PRD with /prd, then convert it with /ralph"
fi

if ! git -C "$(pwd)" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "warning: current directory is not inside a git worktree; Ralph expects git for branches and commits" >&2
fi
