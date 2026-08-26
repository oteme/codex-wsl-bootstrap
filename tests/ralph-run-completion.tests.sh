#!/usr/bin/env bash
set -euo pipefail

RUNNER="${RUNNER:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/ralph-run/scripts/ralph-run-codex.sh"}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mktemp() {
  if [[ "${MOCK_MKTEMP_FAILURE:-0}" == "1" ]]; then
    return 70
  fi
  command mktemp "$@"
}

git() {
  if [[ "${MOCK_GIT_FAILURE:-}" == "worktree-add" && "$*" == *"worktree add"* ]]; then
    return 71
  fi
  command git "$@"
}

export -f mktemp git

[[ "$(grep -Fc -- '--dangerously-bypass-approvals-and-sandbox' "$RUNNER")" -eq 2 ]]
if grep -Fq -- '--sandbox read-only' "$RUNNER"; then
  echo 'reviewer must not use the read-only sandbox' >&2
  exit 1
fi

codex() {
  local last_message=""
  local codex_cwd=""
  local prompt="${*: -1}"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --cd)
        codex_cwd="$2"
        shift 2
        ;;
      --output-last-message)
        last_message="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  printf '%s\n' "$prompt" >> "$MOCK_PROMPTS_FILE"

  if [[ "$prompt" == *"independent fail-close and clean-break policy reviewer"* ]]; then
    printf 'review\n' >> "$MOCK_CALLS_FILE"
    printf '%s\n' "$codex_cwd" >> "$MOCK_REVIEW_CWDS_FILE"
    if [[ "$codex_cwd" == "$PWD" ]]; then
      return 8
    fi
    if ! git -C "$codex_cwd" diff --cached --name-only | grep -Fxq 'app.txt'; then
      return 8
    fi
    if [[ "$MOCK_MODE" == "hook-mutates" ]] \
      && ! git -C "$codex_cwd" diff --cached --name-only | grep -Fxq 'hook-added.txt'; then
      return 8
    fi
    if [[ "$MOCK_MODE" == "review-artifact" ]]; then
      mkdir -p "$codex_cwd/coverage"
      printf 'reviewer output\n' > "$codex_cwd/coverage/report.txt"
    fi
    if [[ "$MOCK_MODE" == "review-main-artifact" \
      || "$MOCK_MODE" == "review-error-after-main-artifact" ]]; then
      printf 'escaped reviewer output\n' > "$MOCK_MAIN_WORKTREE/reviewer-escaped.txt"
    fi
    if [[ "$MOCK_MODE" == "review-main-tracked-and-staged" ]]; then
      printf 'escaped staged change\n' > "$MOCK_MAIN_WORKTREE/app.txt"
      git -C "$MOCK_MAIN_WORKTREE" add app.txt
      printf 'escaped tracked change\n' >> "$MOCK_MAIN_WORKTREE/app.txt"
    fi
    if [[ "$MOCK_MODE" == "review-main-head" ]]; then
      git -C "$MOCK_MAIN_WORKTREE" commit --no-verify -qm 'escaped reviewer commit'
    fi
    if [[ "$MOCK_MODE" == "review-error" \
      || "$MOCK_MODE" == "review-error-after-main-artifact" ]]; then
      return 7
    fi
    local review_count
    review_count="$(grep -c '^review$' "$MOCK_CALLS_FILE" || true)"
    if [[ "$MOCK_MODE" == "reject-always" \
      || ( "$MOCK_MODE" == "reject-once" && "$review_count" -eq 1 ) \
      || ( "$MOCK_MODE" == "wrong-retry" && "$review_count" -eq 1 ) ]]; then
      printf '%s\n' \
        '{"approved":false,"findings":[{"category":"fallback","message":"unexpected fallback","evidence":"app.txt"}]}' \
        > "$last_message"
    else
      printf '%s\n' '{"approved":true,"findings":[]}' > "$last_message"
    fi
    return 0
  fi

  printf 'worker\n' >> "$MOCK_CALLS_FILE"
  if [[ "$MOCK_MODE" == "empty" ]]; then
    : > "$last_message"
    return 0
  fi

  if [[ "$MOCK_MODE" != "blocked" ]]; then
    local worker_count story_index
    worker_count="$(grep -c '^worker$' "$MOCK_CALLS_FILE")"
    story_index=-1
    if [[ "$MOCK_MODE" == "wrong-retry" && "$worker_count" -gt 1 ]]; then
      story_index=1
    fi
    python3 - "$codex_cwd/scripts/ralph/prd.json" "$story_index" <<'PY'
import json
import sys

path = sys.argv[1]
story_index = int(sys.argv[2])
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
if story_index < 0:
    story_index = next(
        index for index, story in enumerate(document["userStories"])
        if not story["passes"]
    )
document["userStories"][story_index]["passes"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
    printf 'implementation attempt\n' >> "$codex_cwd/app.txt"
    if [[ "$MOCK_MODE" == "worker-commit" ]]; then
      git -C "$codex_cwd" add -A
      git -C "$codex_cwd" commit -qm 'unauthorized worker commit'
    fi
  fi
  if [[ "$MOCK_MODE" == "worker-error" ]]; then
    return 6
  fi
  if [[ "$MOCK_MODE" == "empty-after-mutate" ]]; then
    : > "$last_message"
    return 0
  fi
  printf 'worker finished\n' > "$last_message"
}

add_second_story() {
  local fixture_root="$1"
  python3 - "$fixture_root/scripts/ralph/prd.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
document["userStories"].append({
    "id": "US-002",
    "title": "Second story",
    "description": "Must not bypass a rejected story",
    "acceptanceCriteria": ["Tests pass"],
    "priority": 2,
    "passes": False,
    "notes": "",
})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
  git -C "$fixture_root" add scripts/ralph/prd.json
  git -C "$fixture_root" commit -qm 'add second fixture story'
}

add_pending_stories() {
  local fixture_root="$1"
  local total="$2"
  python3 - "$fixture_root/scripts/ralph/prd.json" "$total" <<'PY'
import json
import sys

path = sys.argv[1]
total = int(sys.argv[2])
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
for number in range(2, total + 1):
    document["userStories"].append({
        "id": f"US-{number:03d}",
        "title": f"Story {number}",
        "description": "Exercise until-complete mode",
        "acceptanceCriteria": ["Tests pass"],
        "priority": number,
        "passes": False,
        "notes": "",
    })
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
  git -C "$fixture_root" add scripts/ralph/prd.json
  git -C "$fixture_root" commit -qm 'add pending fixture stories'
}
export -f codex
export MOCK_REVIEW_CWDS_FILE="$TEST_ROOT/reviewer-cwds.txt"
: > "$MOCK_REVIEW_CWDS_FILE"

make_fixture() {
  local fixture_root="$1"
  mkdir -p "$fixture_root/scripts/ralph/logs"
  cat > "$fixture_root/scripts/ralph/prd.json" <<'JSON'
{
  "project": "Test",
  "branchName": "ralph/test",
  "description": "Test story",
  "userStories": [
    {
      "id": "US-001",
      "title": "Test gate",
      "description": "Exercise the gate",
      "acceptanceCriteria": ["Tests pass"],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
JSON
  printf '# Test instructions\n' > "$fixture_root/scripts/ralph/CLAUDE.md"
  printf '# Ralph Progress Log\n---\n' > "$fixture_root/scripts/ralph/progress.txt"
  printf 'logs/\n' > "$fixture_root/scripts/ralph/.gitignore"
  git -C "$fixture_root" init -q
  git -C "$fixture_root" config user.email test@example.com
  git -C "$fixture_root" config user.name Test
  git -C "$fixture_root" add -A
  git -C "$fixture_root" commit -qm fixture
}

reject_root="$TEST_ROOT/reject"
make_fixture "$reject_root"
export MOCK_MODE="reject-always"
export MOCK_CALLS_FILE="$TEST_ROOT/reject-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/reject-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
reject_output="$(cd "$reject_root" && bash "$RUNNER" 2)"
grep -Fq 'completed=0' <<< "$reject_output"
grep -Fq 'iterationsRun=2' <<< "$reject_output"
grep -Fq 'POLICY REVIEW REJECTED' "$reject_root/scripts/ralph/progress.txt"
[[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" -eq 2 ]]
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 2 ]]

second_root="$TEST_ROOT/second"
make_fixture "$second_root"
export MOCK_MODE="reject-once"
export MOCK_CALLS_FILE="$TEST_ROOT/second-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/second-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
second_output="$(cd "$second_root" && bash "$RUNNER" 3)"
grep -Fq 'completed=1' <<< "$second_output"
grep -Fq 'iterationsRun=2' <<< "$second_output"
grep -Fq 'You are the implementation worker for exactly one Ralph iteration.' "$MOCK_PROMPTS_FILE"
grep -Fq 'independent fail-close and clean-break policy reviewer' "$MOCK_PROMPTS_FILE"
grep -Fq 'This is a static diff review.' "$MOCK_PROMPTS_FILE"
grep -Fq 'Do not run builds, tests, linters, coverage commands, package managers' "$MOCK_PROMPTS_FILE"
if grep -Fq 'Also run "git status --short"' "$MOCK_PROMPTS_FILE"; then
  echo 'reviewer prompt must not request mutable repository checks' >&2
  exit 1
fi
git -C "$second_root" log -1 --format=%s | grep -Fq 'feat: US-001 - Test gate'

review_artifact_root="$TEST_ROOT/review-artifact"
make_fixture "$review_artifact_root"
export MOCK_MODE="review-artifact"
export MOCK_CALLS_FILE="$TEST_ROOT/review-artifact-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/review-artifact-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
review_artifact_output="$(cd "$review_artifact_root" && bash "$RUNNER" 1)"
grep -Fq 'completed=1' <<< "$review_artifact_output"
[[ ! -e "$review_artifact_root/coverage" ]]
[[ -z "$(git -C "$review_artifact_root" status --porcelain)" ]]
[[ "$(git -C "$review_artifact_root" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]
review_artifact_cwd="$(tail -1 "$MOCK_REVIEW_CWDS_FILE")"
[[ "$review_artifact_cwd" != "$review_artifact_root" ]]
[[ ! -e "$review_artifact_cwd" ]]

review_escape_root="$TEST_ROOT/review-escape"
make_fixture "$review_escape_root"
export MOCK_MODE="review-main-artifact"
export MOCK_MAIN_WORKTREE="$review_escape_root"
export MOCK_CALLS_FILE="$TEST_ROOT/review-escape-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/review-escape-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
review_escape_output="$(cd "$review_escape_root" && bash "$RUNNER" 1 2>&1)"
review_escape_status=$?
set -e
[[ "$review_escape_status" -eq 1 ]]
grep -Fq 'repository changed during policy review' <<< "$review_escape_output"
grep -Fq 'review tree:' <<< "$review_escape_output"
grep -Fq 'untracked paths appeared:' <<< "$review_escape_output"
grep -Fq 'reviewer-escaped.txt' <<< "$review_escape_output"

review_error_escape_root="$TEST_ROOT/review-error-escape"
make_fixture "$review_error_escape_root"
export MOCK_MODE="review-error-after-main-artifact"
export MOCK_MAIN_WORKTREE="$review_error_escape_root"
export MOCK_CALLS_FILE="$TEST_ROOT/review-error-escape-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/review-error-escape-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
review_error_escape_output="$(cd "$review_error_escape_root" && bash "$RUNNER" 1 2>&1)"
review_error_escape_status=$?
set -e
[[ "$review_error_escape_status" -eq 1 ]]
grep -Fq 'repository changed during policy review' <<< "$review_error_escape_output"
grep -Fq 'untracked paths appeared:' <<< "$review_error_escape_output"
grep -Fq 'reviewer-escaped.txt' <<< "$review_error_escape_output"
if grep -Fq 'policy review failed' <<< "$review_error_escape_output"; then
  echo 'main-worktree mutation must take precedence over reviewer exit status' >&2
  exit 1
fi

review_tracked_root="$TEST_ROOT/review-tracked"
make_fixture "$review_tracked_root"
export MOCK_MODE="review-main-tracked-and-staged"
export MOCK_MAIN_WORKTREE="$review_tracked_root"
export MOCK_CALLS_FILE="$TEST_ROOT/review-tracked-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/review-tracked-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
review_tracked_output="$(cd "$review_tracked_root" && bash "$RUNNER" 1 2>&1)"
review_tracked_status=$?
set -e
[[ "$review_tracked_status" -eq 1 ]]
grep -Fq 'staged tree changed:' <<< "$review_tracked_output"
grep -Fq 'staged paths changed:' <<< "$review_tracked_output"
grep -Fq 'tracked worktree paths changed:' <<< "$review_tracked_output"
[[ "$(grep -Fc 'app.txt' <<< "$review_tracked_output")" -ge 2 ]]

review_head_root="$TEST_ROOT/review-head"
make_fixture "$review_head_root"
export MOCK_MODE="review-main-head"
export MOCK_MAIN_WORKTREE="$review_head_root"
export MOCK_CALLS_FILE="$TEST_ROOT/review-head-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/review-head-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
review_head_output="$(cd "$review_head_root" && bash "$RUNNER" 1 2>&1)"
review_head_status=$?
set -e
[[ "$review_head_status" -eq 1 ]]
grep -Fq 'HEAD moved:' <<< "$review_head_output"
[[ "$(git -C "$review_head_root" rev-list --count HEAD)" -eq 2 ]]

mktemp_error_root="$TEST_ROOT/mktemp-error"
make_fixture "$mktemp_error_root"
export MOCK_MODE="approve"
export MOCK_CALLS_FILE="$TEST_ROOT/mktemp-error-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/mktemp-error-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
mktemp_error_output="$(cd "$mktemp_error_root" && MOCK_MKTEMP_FAILURE=1 bash "$RUNNER" 1 2>&1)"
mktemp_error_status=$?
set -e
[[ "$mktemp_error_status" -eq 1 ]]
grep -Fq 'could not allocate isolated policy review directory' <<< "$mktemp_error_output"
grep -Fq 'POLICY GATE FAILED' "$mktemp_error_root/scripts/ralph/progress.txt"
grep -Fq '"passes": false' "$mktemp_error_root/scripts/ralph/prd.json"

worktree_add_error_root="$TEST_ROOT/worktree-add-error"
make_fixture "$worktree_add_error_root"
export MOCK_MODE="approve"
export MOCK_CALLS_FILE="$TEST_ROOT/worktree-add-error-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/worktree-add-error-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
worktree_add_error_output="$(cd "$worktree_add_error_root" && MOCK_GIT_FAILURE=worktree-add bash "$RUNNER" 1 2>&1)"
worktree_add_error_status=$?
set -e
[[ "$worktree_add_error_status" -eq 1 ]]
grep -Fq 'could not create isolated policy review worktree' <<< "$worktree_add_error_output"
grep -Fq 'POLICY GATE FAILED' "$worktree_add_error_root/scripts/ralph/progress.txt"
grep -Fq '"passes": false' "$worktree_add_error_root/scripts/ralph/prd.json"
[[ "$(git -C "$worktree_add_error_root" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]

empty_root="$TEST_ROOT/empty"
make_fixture "$empty_root"
export MOCK_MODE="empty"
export MOCK_CALLS_FILE="$TEST_ROOT/empty-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/empty-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
empty_output="$(cd "$empty_root" && bash "$RUNNER" 3 2>&1)"
empty_status=$?
set -e
[[ "$empty_status" -eq 1 ]]
grep -Fq 'returned no final message in iteration 1' <<< "$empty_output"
[[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" -eq 1 ]]

blocked_root="$TEST_ROOT/blocked"
make_fixture "$blocked_root"
export MOCK_MODE="blocked"
export MOCK_CALLS_FILE="$TEST_ROOT/blocked-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/blocked-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
blocked_output="$(cd "$blocked_root" && bash "$RUNNER" 3 2>&1)"
blocked_status=$?
set -e
[[ "$blocked_status" -eq 1 ]]
grep -Fq 'did not produce one valid story transition' <<< "$blocked_output"
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE" || true)" -eq 0 ]]

dirty_root="$TEST_ROOT/dirty"
make_fixture "$dirty_root"
printf 'unrelated\n' > "$dirty_root/unrelated.txt"
export MOCK_MODE="approve"
export MOCK_CALLS_FILE="$TEST_ROOT/dirty-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/dirty-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
dirty_output="$(cd "$dirty_root" && bash "$RUNNER" 1 2>&1)"
dirty_status=$?
set -e
[[ "$dirty_status" -eq 1 ]]
grep -Fq 'pre-existing changes outside scripts/ralph' <<< "$dirty_output"

worker_error_root="$TEST_ROOT/worker-error"
make_fixture "$worker_error_root"
cp "$worker_error_root/scripts/ralph/prd.json" "$TEST_ROOT/worker-error-before.json"
export MOCK_MODE="worker-error"
export MOCK_CALLS_FILE="$TEST_ROOT/worker-error-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/worker-error-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
worker_error_output="$(cd "$worker_error_root" && bash "$RUNNER" 1 2>&1)"
worker_error_status=$?
set -e
[[ "$worker_error_status" -eq 6 ]]
grep -Fq 'codex exec failed' <<< "$worker_error_output"
cmp "$TEST_ROOT/worker-error-before.json" "$worker_error_root/scripts/ralph/prd.json"

empty_after_root="$TEST_ROOT/empty-after"
make_fixture "$empty_after_root"
cp "$empty_after_root/scripts/ralph/prd.json" "$TEST_ROOT/empty-after-before.json"
export MOCK_MODE="empty-after-mutate"
export MOCK_CALLS_FILE="$TEST_ROOT/empty-after-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/empty-after-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
empty_after_output="$(cd "$empty_after_root" && bash "$RUNNER" 1 2>&1)"
empty_after_status=$?
set -e
[[ "$empty_after_status" -eq 1 ]]
grep -Fq 'returned no final message' <<< "$empty_after_output"
cmp "$TEST_ROOT/empty-after-before.json" "$empty_after_root/scripts/ralph/prd.json"

wrong_retry_root="$TEST_ROOT/wrong-retry"
make_fixture "$wrong_retry_root"
add_second_story "$wrong_retry_root"
export MOCK_MODE="wrong-retry"
export MOCK_CALLS_FILE="$TEST_ROOT/wrong-retry-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/wrong-retry-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
wrong_retry_output="$(cd "$wrong_retry_root" && bash "$RUNNER" 2 2>&1)"
wrong_retry_status=$?
set -e
[[ "$wrong_retry_status" -eq 1 ]]
grep -Fq 'repair must stay on US-001' <<< "$wrong_retry_output"
[[ "$(grep -c '"passes": false' "$wrong_retry_root/scripts/ralph/prd.json")" -eq 2 ]]
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 1 ]]

worker_commit_root="$TEST_ROOT/worker-commit"
make_fixture "$worker_commit_root"
export MOCK_MODE="worker-commit"
export MOCK_CALLS_FILE="$TEST_ROOT/worker-commit-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/worker-commit-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
worker_commit_output="$(cd "$worker_commit_root" && bash "$RUNNER" 1 2>&1)"
worker_commit_status=$?
set -e
[[ "$worker_commit_status" -eq 1 ]]
grep -Fq 'worker changed HEAD before policy approval' <<< "$worker_commit_output"
grep -Fq '"passes": false' "$worker_commit_root/scripts/ralph/prd.json"
[[ "$(git -C "$worker_commit_root" rev-list --count HEAD)" -eq 2 ]]
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE" || true)" -eq 0 ]]

review_error_root="$TEST_ROOT/review-error"
make_fixture "$review_error_root"
export MOCK_MODE="review-error"
export MOCK_CALLS_FILE="$TEST_ROOT/review-error-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/review-error-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
review_error_output="$(cd "$review_error_root" && bash "$RUNNER" 1 2>&1)"
review_error_status=$?
set -e
[[ "$review_error_status" -eq 7 ]]
grep -Fq 'policy review failed' <<< "$review_error_output"
grep -Fq 'POLICY GATE FAILED' "$review_error_root/scripts/ralph/progress.txt"
grep -Fq '"passes": false' "$review_error_root/scripts/ralph/prd.json"
review_error_cwd="$(tail -1 "$MOCK_REVIEW_CWDS_FILE")"
[[ ! -e "$review_error_cwd" ]]
[[ "$(git -C "$review_error_root" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]

commit_error_root="$TEST_ROOT/commit-error"
make_fixture "$commit_error_root"
printf '#!/usr/bin/env bash\nexit 9\n' > "$commit_error_root/.git/hooks/pre-commit"
chmod +x "$commit_error_root/.git/hooks/pre-commit"
export MOCK_MODE="approve"
export MOCK_CALLS_FILE="$TEST_ROOT/commit-error-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/commit-error-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
commit_error_output="$(cd "$commit_error_root" && bash "$RUNNER" 1 2>&1)"
commit_error_status=$?
set -e
[[ "$commit_error_status" -eq 9 ]]
grep -Fq 'pre-commit hook failed' <<< "$commit_error_output"
grep -Fq 'POLICY GATE FAILED' "$commit_error_root/scripts/ralph/progress.txt"
grep -Fq '"passes": false' "$commit_error_root/scripts/ralph/prd.json"

hook_mutates_root="$TEST_ROOT/hook-mutates"
make_fixture "$hook_mutates_root"
cat > "$hook_mutates_root/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
printf 'created by hook\n' > hook-added.txt
git add hook-added.txt
HOOK
chmod +x "$hook_mutates_root/.git/hooks/pre-commit"
export MOCK_MODE="hook-mutates"
export MOCK_CALLS_FILE="$TEST_ROOT/hook-mutates-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/hook-mutates-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
hook_mutates_output="$(cd "$hook_mutates_root" && bash "$RUNNER" 1)"
grep -Fq 'completed=1' <<< "$hook_mutates_output"
git -C "$hook_mutates_root" show --format= --name-only HEAD | grep -Fxq 'hook-added.txt'
[[ -z "$(git -C "$hook_mutates_root" status --porcelain)" ]]

until_complete_root="$TEST_ROOT/until-complete"
make_fixture "$until_complete_root"
add_pending_stories "$until_complete_root" 11
export MOCK_MODE="approve"
export MOCK_CALLS_FILE="$TEST_ROOT/until-complete-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/until-complete-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
until_complete_output="$(cd "$until_complete_root" && bash "$RUNNER")"
grep -Fq 'completed=1' <<< "$until_complete_output"
grep -Fq 'iterationsRun=11' <<< "$until_complete_output"
grep -Fq 'maxIterations=0' <<< "$until_complete_output"
[[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" -eq 11 ]]

circuit_breaker_root="$TEST_ROOT/circuit-breaker"
make_fixture "$circuit_breaker_root"
export MOCK_MODE="reject-always"
export MOCK_CALLS_FILE="$TEST_ROOT/circuit-breaker-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/circuit-breaker-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
circuit_breaker_output="$(cd "$circuit_breaker_root" && bash "$RUNNER" 2>&1)"
circuit_breaker_status=$?
set -e
[[ "$circuit_breaker_status" -eq 1 ]]
grep -Fq 'rejected US-001 3 consecutive times' <<< "$circuit_breaker_output"
grep -Fq 'blocked=1' <<< "$circuit_breaker_output"
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 3 ]]

set +e
nested_output="$(cd "$reject_root" && RALPH_RUN_ACTIVE=1 bash "$RUNNER" 3 2>&1)"
nested_status=$?
set -e
[[ "$nested_status" -eq 1 ]]
grep -Fq 'refusing to start a nested Ralph runner' <<< "$nested_output"

printf 'PASS: policy rejection/repair, failure rollback, commit gate, dirty tree, and recursion guard.\n'
