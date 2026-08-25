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
# Ralph Agent Instructions

You are an autonomous coding agent working on a software project.

## Your Task

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. Pick the highest priority user story where `passes: false`
5. Implement that single user story
6. Run quality checks (typecheck, lint, test, or whatever this project requires)
7. Update AGENTS.md files if you discover reusable patterns
8. If checks pass, commit all changes with message: `feat: [Story ID] - [Story Title]`
9. Update the PRD to set `passes: true` for the completed story
10. Append your progress to `progress.txt`

## Progress Report Format

Append to progress.txt. Never replace it.

```text
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- Learnings for future iterations:
  - Patterns discovered
  - Gotchas encountered
  - Useful context
---
```

## Codebase Patterns

If you discover reusable knowledge that future iterations need, add it to the
`## Codebase Patterns` section near the top of `progress.txt`. Keep it general and
durable. Do not add story-specific notes there.

## AGENTS.md Updates

Before committing, check whether edited areas have reusable learnings worth preserving
in nearby AGENTS.md files. Add only durable conventions, gotchas, dependencies, or test
requirements that would help future work.

## Quality Requirements

- Work on one story per iteration
- Keep changes focused and minimal
- Follow existing code patterns
- Run the project's relevant checks
- Do not commit broken code

## Browser Testing

For UI stories, verify in a browser when browser tools are available. If no browser tools
are available, note that manual browser verification is still needed.

## Stop Condition

After completing a user story, check if all stories have `passes: true`.

If all stories are complete and passing, reply with:

<promise>COMPLETE</promise>

If any story still has `passes: false`, end normally so the next iteration can continue.
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
