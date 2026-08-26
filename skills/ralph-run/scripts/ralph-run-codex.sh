#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ralph-run-codex.sh [max-iterations] [ralph-dir]

Defaults:
  max-iterations: no global limit; run until complete or blocked
  ralph-dir:      $PWD/scripts/ralph

Environment:
  RALPH_MAX_CONSECUTIVE_REJECTIONS: stop after this many policy rejections for
                                    the same story (default: 3)
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

MAX_ITER="${1:-0}"
RALPH_DIR_INPUT="${2:-"$PWD/scripts/ralph"}"
MAX_CONSECUTIVE_REJECTIONS="${RALPH_MAX_CONSECUTIVE_REJECTIONS:-3}"

if ! [[ "$MAX_ITER" =~ ^[0-9]+$ ]]; then
  echo "error: max-iterations must be a non-negative integer; omit it or use 0 to run until complete" >&2
  exit 2
fi

if ! [[ "$MAX_CONSECUTIVE_REJECTIONS" =~ ^[0-9]+$ ]] \
  || [[ "$MAX_CONSECUTIVE_REJECTIONS" -lt 1 ]]; then
  echo "error: RALPH_MAX_CONSECUTIVE_REJECTIONS must be a positive integer" >&2
  exit 2
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "error: codex command not found on PATH" >&2
  exit 127
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 command not found on PATH" >&2
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

case "$RALPH_DIR" in
  "$PROJECT_ROOT"/*) RALPH_REL="${RALPH_DIR#"$PROJECT_ROOT"/}" ;;
  *) echo "error: Ralph directory must be inside project root: $RALPH_DIR" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_TOOL="$SCRIPT_DIR/ralph-state.py"
REVIEW_SCHEMA="$SCRIPT_DIR/../assets/policy-review.schema.json"

if ! git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: Ralph runner requires a git worktree: $PROJECT_ROOT" >&2
  exit 1
fi

if [[ ! -f "$STATE_TOOL" || ! -f "$REVIEW_SCHEMA" ]]; then
  echo "error: Ralph policy gate files are missing; reinstall the ralph-run skill" >&2
  exit 1
fi

# prd.json/progress.txt are commonly created immediately before the first run. Permit bootstrap
# metadata there, but never absorb unrelated application changes into a Ralph story commit.
outside_changes="$(
  git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all | while IFS= read -r line; do
    path="${line:3}"
    case "$path" in
      scripts/ralph/*) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
)"
if [[ -n "$outside_changes" ]]; then
  echo "error: refusing to start with pre-existing changes outside scripts/ralph" >&2
  printf '%s\n' "$outside_changes" >&2
  echo "Commit, stash, or move those changes before running Ralph." >&2
  exit 1
fi

completed=0
blocked=0
iterations_run=0
retry_story_id=""
rejection_story_id=""
consecutive_rejections=0

for ((i = 1; MAX_ITER == 0 || i <= MAX_ITER; i++)); do
  iterations_run="$i"
  log_file="$LOG_DIR/codex-iteration-$i.log"
  last_message="$LOG_DIR/codex-iteration-$i-last-message.txt"
  before_prd="$LOG_DIR/codex-iteration-$i-prd-before.json"
  review_file="$LOG_DIR/codex-iteration-$i-policy-review.json"
  iteration_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"

  cp "$RALPH_DIR/prd.json" "$before_prd"

  if [[ "$MAX_ITER" -eq 0 ]]; then
    echo "Ralph iteration $i (running until complete)"
  else
    echo "Ralph iteration $i of $MAX_ITER"
  fi

  prompt=$(cat <<EOF
You are the implementation worker for exactly one Ralph iteration.

Do the implementation work directly in the project. Do not invoke the ralph-run skill, do not run ralph-run-codex.sh, and do not launch another codex exec or autonomous loop.

Read the file $RALPH_DIR/CLAUDE.md in full and execute its instructions exactly as written.

That file is your complete and authoritative task specification for this iteration. The prd.json and progress.txt it refers to live in the same directory:
$RALPH_DIR

Run one Ralph iteration only. Update prd.json and progress.txt according to the instructions. Do not commit and do not claim that the whole run is complete; the outer runner owns review, commit, and completion.
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
    cp "$before_prd" "$RALPH_DIR/prd.json"
    echo "error: codex exec failed in iteration $i with status $status" >&2
    echo "log: $log_file" >&2
    exit "$status"
  fi

  if [[ ! -s "$last_message" ]] || ! grep -q '[^[:space:]]' "$last_message"; then
    cp "$before_prd" "$RALPH_DIR/prd.json"
    echo "error: codex exec returned no final message in iteration $i" >&2
    echo "This can indicate an authentication or MCP startup failure." >&2
    echo "log: $log_file" >&2
    exit 1
  fi

  current_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  if [[ "$current_head" != "$iteration_head" ]]; then
    cp "$before_prd" "$RALPH_DIR/prd.json"
    echo "error: worker changed HEAD before policy approval in iteration $i" >&2
    echo "before: $iteration_head" >&2
    echo "after:  $current_head" >&2
    echo "The runner will not rewind commits automatically. Inspect the unapproved commit before continuing." >&2
    exit 1
  fi

  transition_output=""
  if ! transition_output="$(python3 "$STATE_TOOL" validate-transition "$before_prd" "$RALPH_DIR/prd.json")"; then
    cp "$before_prd" "$RALPH_DIR/prd.json"
    echo "error: worker did not produce one valid story transition in iteration $i" >&2
    echo "If the story is blocked, inspect: $PROGRESS_FILE" >&2
    exit 1
  fi

  mapfile -t story_fields <<< "$transition_output"
  STORY_ID="${story_fields[0]:-}"
  STORY_TITLE="${story_fields[1]:-}"

  if [[ -n "$retry_story_id" && "$STORY_ID" != "$retry_story_id" ]]; then
    cp "$before_prd" "$RALPH_DIR/prd.json"
    python3 "$STATE_TOOL" reset "$RALPH_DIR/prd.json" "$PROGRESS_FILE" "$STORY_ID" \
      "Expected repair of rejected story $retry_story_id, but worker completed $STORY_ID instead."
    echo "error: policy rejection repair must stay on $retry_story_id; worker completed $STORY_ID" >&2
    exit 1
  fi

  git -C "$PROJECT_ROOT" add -A
  git -C "$PROJECT_ROOT" reset --quiet -- "$RALPH_REL/logs"

  pre_commit_hook="$(git -C "$PROJECT_ROOT" rev-parse --git-path hooks/pre-commit)"
  if [[ -x "$pre_commit_hook" ]]; then
    set +e
    (cd "$PROJECT_ROOT" && "$pre_commit_hook")
    hook_status=$?
    set -e
    if [[ "$hook_status" -ne 0 ]]; then
      git -C "$PROJECT_ROOT" reset --quiet
      cp "$before_prd" "$RALPH_DIR/prd.json"
      python3 "$STATE_TOOL" reset "$RALPH_DIR/prd.json" "$PROGRESS_FILE" "$STORY_ID" \
        "Pre-commit hook exited with status $hook_status before policy review."
      echo "error: pre-commit hook failed in iteration $i with status $hook_status" >&2
      exit "$hook_status"
    fi
    git -C "$PROJECT_ROOT" add -A
    git -C "$PROJECT_ROOT" reset --quiet -- "$RALPH_REL/logs"
  fi

  unexpected_untracked="$(
    git -C "$PROJECT_ROOT" ls-files --others --exclude-standard | while IFS= read -r path; do
      case "$path" in
        "$RALPH_REL"/logs/*) ;;
        *) printf '%s\n' "$path" ;;
      esac
    done
  )"
  if ! git -C "$PROJECT_ROOT" diff --quiet || [[ -n "$unexpected_untracked" ]]; then
    git -C "$PROJECT_ROOT" reset --quiet
    cp "$before_prd" "$RALPH_DIR/prd.json"
    python3 "$STATE_TOOL" reset "$RALPH_DIR/prd.json" "$PROGRESS_FILE" "$STORY_ID" \
      "Could not create a complete staged snapshot for policy review."
    echo "error: unstaged or untracked changes remain outside Ralph logs" >&2
    [[ -n "$unexpected_untracked" ]] && printf '%s\n' "$unexpected_untracked" >&2
    exit 1
  fi

  review_index_tree="$(git -C "$PROJECT_ROOT" write-tree)"

  review_prompt=$(cat <<EOF
You are the independent fail-close and clean-break policy reviewer for one Ralph iteration.

Do not modify the repository. Inspect the complete staged snapshot using "git diff --cached HEAD" in:
$PROJECT_ROOT

Also run "git status --short" and reject if any implementation change is absent from the staged
snapshot. Files under $RALPH_REL/logs are runner output and must be ignored. Do not rely on plain
"git diff HEAD"; every newly created file must be reviewed from the cached diff.

The story under review is $STORY_ID: $STORY_TITLE. Read its acceptance criteria from:
$RALPH_DIR/prd.json

Ignore bookkeeping-only changes under scripts/ralph except when they alter the story specification
or falsely mark acceptance. Reject only when the diff contains at least one of these concrete
problems:

1. A newly introduced fallback, guessed default, broad retry, swallowed error, or no-op that turns
   a required failure into apparent success without explicit acceptance criteria.
2. A compatibility shim, dual path, retained legacy implementation, migration behavior, or feature
   flag that is not explicitly required by acceptance criteria.
3. Obsolete behavior that acceptance criteria require to be removed but remains reachable.
4. A skipped, weakened, or deleted valid test used to make checks pass.
5. An unmet or contradicted acceptance criterion.

Do not reject for style, optional refactors, or hypothetical improvements. Existing compatibility
and fallback behavior outside the story's change is not a finding. Every finding must cite specific
diff evidence such as a file and symbol or changed behavior. Return JSON matching the provided
schema. Set approved=true with findings=[] only when no listed problem is present.
EOF
)

  : > "$review_file"
  set +e
  RALPH_RUN_ACTIVE=1 codex exec \
    --cd "$PROJECT_ROOT" \
    --dangerously-bypass-approvals-and-sandbox \
    --ephemeral \
    --output-schema "$REVIEW_SCHEMA" \
    --output-last-message "$review_file" \
    "$review_prompt" 2>&1 | tee -a "$log_file"
  review_status=${PIPESTATUS[0]}
  set -e

  if [[ "$review_status" -ne 0 ]]; then
    git -C "$PROJECT_ROOT" reset --quiet
    cp "$before_prd" "$RALPH_DIR/prd.json"
    python3 "$STATE_TOOL" reset "$RALPH_DIR/prd.json" "$PROGRESS_FILE" "$STORY_ID" \
      "Policy reviewer exited with status $review_status; story was not approved."
    echo "error: policy review failed in iteration $i with status $review_status" >&2
    echo "log: $log_file" >&2
    exit "$review_status"
  fi

  review_result=""
  if ! review_result="$(python3 "$STATE_TOOL" review-result "$review_file")"; then
    git -C "$PROJECT_ROOT" reset --quiet
    cp "$before_prd" "$RALPH_DIR/prd.json"
    python3 "$STATE_TOOL" reset "$RALPH_DIR/prd.json" "$PROGRESS_FILE" "$STORY_ID" \
      "Policy reviewer returned invalid structured output; story was not approved."
    echo "error: invalid policy review output in iteration $i" >&2
    echo "review: $review_file" >&2
    exit 1
  fi

  post_review_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  post_review_tree="$(git -C "$PROJECT_ROOT" write-tree)"
  post_review_untracked="$(
    git -C "$PROJECT_ROOT" ls-files --others --exclude-standard | while IFS= read -r path; do
      case "$path" in
        "$RALPH_REL"/logs/*) ;;
        *) printf '%s\n' "$path" ;;
      esac
    done
  )"
  if [[ "$post_review_head" != "$iteration_head" \
    || "$post_review_tree" != "$review_index_tree" \
    || -n "$post_review_untracked" ]] \
    || ! git -C "$PROJECT_ROOT" diff --quiet; then
    git -C "$PROJECT_ROOT" reset --quiet
    cp "$before_prd" "$RALPH_DIR/prd.json"
    python3 "$STATE_TOOL" reset "$RALPH_DIR/prd.json" "$PROGRESS_FILE" "$STORY_ID" \
      "Repository changed after the staged policy snapshot was created."
    echo "error: repository changed during policy review in iteration $i" >&2
    exit 1
  fi

  if [[ "$review_result" == "rejected" ]]; then
    git -C "$PROJECT_ROOT" reset --quiet
    cp "$before_prd" "$RALPH_DIR/prd.json"
    python3 "$STATE_TOOL" reject \
      "$RALPH_DIR/prd.json" "$review_file" "$PROGRESS_FILE" "$STORY_ID"
    if [[ "$rejection_story_id" == "$STORY_ID" ]]; then
      consecutive_rejections=$((consecutive_rejections + 1))
    else
      rejection_story_id="$STORY_ID"
      consecutive_rejections=1
    fi
    if [[ "$consecutive_rejections" -ge "$MAX_CONSECUTIVE_REJECTIONS" ]]; then
      blocked=1
      echo "error: policy review rejected $STORY_ID $consecutive_rejections consecutive times; stopping as blocked" >&2
      echo "Inspect the latest findings in $PROGRESS_FILE and $review_file." >&2
      break
    fi
    retry_story_id="$STORY_ID"
    echo "Policy review rejected $STORY_ID; leaving changes uncommitted for the next repair iteration."
    continue
  fi

  commit_message="feat: $STORY_ID - $STORY_TITLE"
  branch_ref="$(git -C "$PROJECT_ROOT" symbolic-ref -q HEAD || true)"
  commit_oid=""
  if [[ -n "$branch_ref" ]]; then
    commit_oid="$(
      printf '%s\n' "$commit_message" \
        | git -C "$PROJECT_ROOT" commit-tree "$review_index_tree" -p "$iteration_head"
    )"
  fi
  if [[ -z "$branch_ref" || -z "$commit_oid" ]] \
    || ! git -C "$PROJECT_ROOT" update-ref \
      -m "commit: $commit_message" "$branch_ref" "$commit_oid" "$iteration_head"; then
    git -C "$PROJECT_ROOT" reset --quiet
    cp "$before_prd" "$RALPH_DIR/prd.json"
    python3 "$STATE_TOOL" reset "$RALPH_DIR/prd.json" "$PROGRESS_FILE" "$STORY_ID" \
      "Exact-tree commit gate failed; story was not committed."
    echo "error: exact-tree commit gate failed in iteration $i" >&2
    exit 1
  fi
  retry_story_id=""
  rejection_story_id=""
  consecutive_rejections=0

  if [[ "$(python3 "$STATE_TOOL" all-passed "$RALPH_DIR/prd.json")" == "true" ]]; then
    completed=1
    echo "Ralph completed all tasks at iteration $i"
    break
  fi

  echo "Iteration $i approved and committed. Continuing..."
done

if [[ "$blocked" -eq 1 ]]; then
  echo "Ralph stopped because the current story is blocked by repeated policy rejection."
elif [[ "$completed" -eq 0 && "$MAX_ITER" -gt 0 ]]; then
  echo "Ralph reached max iterations ($MAX_ITER) without completing all tasks."
fi

echo "completed=$completed"
echo "iterationsRun=$iterations_run"
echo "maxIterations=$MAX_ITER"
echo "blocked=$blocked"
echo "progress=$PROGRESS_FILE"
echo "logs=$LOG_DIR"

if [[ "$blocked" -eq 1 ]]; then
  exit 1
fi
