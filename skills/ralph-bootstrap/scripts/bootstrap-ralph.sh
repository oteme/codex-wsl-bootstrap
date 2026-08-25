#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: bootstrap-ralph.sh [ralph-dir]"
  exit 0
fi

RALPH_DIR_INPUT="${1:-"$PWD/scripts/ralph"}"
mkdir -p "$RALPH_DIR_INPUT/archive" "$RALPH_DIR_INPUT/logs"
RALPH_DIR="$(cd "$RALPH_DIR_INPUT" && pwd)"

if [[ ! -f "$RALPH_DIR/CLAUDE.md" ]]; then
  cat > "$RALPH_DIR/CLAUDE.md" <<'EOF'
# Ralph Agent Instructions

You are an autonomous coding agent working on a software project.

## Your Task

1. Read `prd.json` and `progress.txt` in this directory.
2. Check out or create the branch named by `branchName` from the PRD.
3. Pick the highest-priority story where `passes` is `false`.
4. Implement that one story and run the project's relevant quality checks.
5. Add only durable, reusable discoveries to nearby AGENTS.md files.
6. When checks pass, commit with `feat: [Story ID] - [Story Title]`.
7. Set that story's `passes` field to `true` and append a report to `progress.txt`.

Append reports in this format:

```text
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- Learnings for future iterations
---
```

Work on exactly one story per iteration. Keep changes focused, follow existing code
patterns, and do not commit broken code. For UI stories, verify in a browser when browser
tools are available and otherwise record that manual verification remains.

When every story has `passes: true`, reply with exactly:

<promise>COMPLETE</promise>
EOF
  echo "created: $RALPH_DIR/CLAUDE.md"
else
  echo "exists:  $RALPH_DIR/CLAUDE.md"
fi

if [[ ! -f "$RALPH_DIR/progress.txt" ]]; then
  printf '# Ralph Progress Log\nStarted: %s\n---\n' "$(date)" > "$RALPH_DIR/progress.txt"
  echo "created: $RALPH_DIR/progress.txt"
else
  echo "exists:  $RALPH_DIR/progress.txt"
fi

if [[ ! -f "$RALPH_DIR/.gitignore" ]]; then
  printf 'logs/\n' > "$RALPH_DIR/.gitignore"
  echo "created: $RALPH_DIR/.gitignore"
else
  echo "exists:  $RALPH_DIR/.gitignore"
fi

echo "ready:   $RALPH_DIR"
[[ -f "$RALPH_DIR/prd.json" ]] \
  && echo "notice:  existing prd.json left untouched" \
  || echo "next:    create a PRD with prd, then convert it with ralph"

if ! git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "warning: current directory is not inside a git worktree" >&2
fi
