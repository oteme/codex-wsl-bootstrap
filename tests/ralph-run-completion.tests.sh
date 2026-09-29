#!/usr/bin/env bash
set -euo pipefail

# The same scenarios run for every agent: RALPH_TEST_AGENT=codex (default), cursor or antigravity.
RALPH_TEST_AGENT="${RALPH_TEST_AGENT:-codex}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$RALPH_TEST_AGENT" in
  codex)
    RUNNER_NAME="ralph-run-codex.sh"
    AGENT_COMMAND="codex"
    AUTONOMY_FLAG="--dangerously-bypass-approvals-and-sandbox"
    AGENT_FAILURE="codex exec failed"
    ;;
  cursor)
    RUNNER_NAME="ralph-run-cursor.sh"
    AGENT_COMMAND="agent"
    AUTONOMY_FLAG="--force"
    AGENT_FAILURE="agent -p failed"
    ;;
  antigravity)
    RUNNER_NAME="ralph-run-antigravity.sh"
    AGENT_COMMAND="agy"
    AUTONOMY_FLAG="--dangerously-skip-permissions"
    AGENT_FAILURE="agy -p failed"
    ;;
  *)
    echo "unknown RALPH_TEST_AGENT: $RALPH_TEST_AGENT" >&2
    exit 2
    ;;
esac
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# Ralph model settings live in the agent homes; keep this machine's own settings out of the runs.
export HOME="$TEST_ROOT/home"
unset CODEX_HOME RALPH_MODEL RALPH_REVIEW_MODEL
mkdir -p "$HOME"

# Isolate the installed runtime; the executable shim uses the existing exported mock.
if [[ "$RALPH_TEST_AGENT" == "codex" ]]; then
  RUNNER="${RUNNER:-"$REPO_ROOT/skills/ralph-run/scripts/ralph-run-codex.sh"}"
  cp -R "$(dirname "$RUNNER")/.." "$TEST_ROOT/skill"
else
  # The skill is assembled exactly as setup assembles it.
  (source "$REPO_ROOT/install.sh" && stage_agent_ralph_skill "$RALPH_TEST_AGENT" "$TEST_ROOT/skill")
fi
RUNNER="$TEST_ROOT/skill/scripts/$RUNNER_NAME"
printf '%s\n' '#!/usr/bin/env bash' "$AGENT_COMMAND \"\$@\"" > "$TEST_ROOT/mock-agent"
chmod +x "$TEST_ROOT/mock-agent"
python3 - "$TEST_ROOT" "$RALPH_TEST_AGENT" <<'PY_RUNTIME'
import json, pathlib, sys
root, agent = pathlib.Path(sys.argv[1]), sys.argv[2]
(root / f'skill/scripts/{agent}-runtime.json').write_text(json.dumps({
    'schema': 1, agent: str(root / 'mock-agent'), 'setup_version': 'fixture',
}))
PY_RUNTIME

# Turns the shared fake agent's final message into what Cursor or agy prints.
export MOCK_REPLY_TOOL="$TEST_ROOT/mock-reply.py"
cat > "$MOCK_REPLY_TOOL" <<'PY_REPLY'
import json
import os
import subprocess
import sys

kind, message_path, cwd, role = sys.argv[1:5]
mode = os.environ.get('MOCK_MODE', '')
text = open(message_path, encoding='utf-8').read()
review = None
if role == 'review':
    review = json.loads(text)
    tree = subprocess.check_output(['git', '-C', cwd, 'write-tree'], text=True).strip()
    review['reviewed_tree'] = '0' * 40 if mode == 'review-wrong-tree' else tree
if kind == 'cursor':
    if review is not None:
        text = json.dumps(review)
        if mode == 'review-fenced':
            text = '```json\n' + text + '\n```'
    for event in [
        {'type': 'system', 'subtype': 'init'},
        {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Working on it.'}]}},
        {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': text}]}},
        {'type': 'result', 'subtype': 'success', 'is_error': mode == 'cursor-unsuccessful',
         'session_id': 'fixture'},
    ]:
        print(json.dumps(event))
else:
    reply = {'conversation_id': 'fixture',
             'status': 'ERROR' if mode == 'agy-status-error' else 'SUCCESS', 'response': text}
    if review is not None:
        if '--json-schema' not in os.environ.get('MOCK_AGY_ARGS', ''):
            sys.exit('the agy reviewer must be constrained with --json-schema')
        reply['structured_output'] = review
        reply['response'] = json.dumps(review)
    if mode == 'agy-auto-denied':
        print('jetski: no output produced - a tool required the "command" permission that headless '
              'mode cannot prompt for, so it was auto-denied.', file=sys.stderr)
        reply['response'] = ''
    print(json.dumps(reply))
PY_REPLY

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

[[ "$(grep -Fc -- "$AUTONOMY_FLAG" "$RUNNER")" -eq 2 ]]
if grep -Fq -- '--sandbox read-only' "$RUNNER"; then
  echo 'reviewer must not use the read-only sandbox' >&2
  exit 1
fi

# Shared fake agent: working directory, prompt, final-message file, main worktree.
agent_behavior() {
  local codex_cwd="$1"
  local prompt="$2"
  local last_message="$3"
  local main_worktree="$4"

  printf '%s\n' "$prompt" >> "$MOCK_PROMPTS_FILE"

  if [[ "$prompt" == *"independent fail-close and clean-break policy reviewer"* ]]; then
    printf 'review\n' >> "$MOCK_CALLS_FILE"
    printf '%s\n' "$codex_cwd" >> "$MOCK_REVIEW_CWDS_FILE"
    if [[ "$codex_cwd" == "$main_worktree" ]]; then
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
  if [[ "$MOCK_MODE" == "spawn-child" ]]; then
    sleep 30 < /dev/null > /dev/null 2>&1 &
    printf '%s\n' "$!" >> "$MOCK_CHILD_PIDS"
  fi
  if [[ "$MOCK_MODE" == "empty" ]]; then
    : > "$last_message"
    return 0
  fi

  if [[ "$MOCK_MODE" == "progressing" ]]; then
    printf 'more work %s\n' "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" >> "$codex_cwd/app.txt"
    printf 'worker still working\n' > "$last_message"
    return 0
  fi

  if [[ "$MOCK_MODE" == "progress-later" ]] \
    && [[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" -eq 1 ]]; then
    printf 'partial work\n' >> "$codex_cwd/app.txt"
    printf 'worker paused\n' > "$last_message"
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
    if [[ "$MOCK_MODE" == "two-stories" ]]; then
      python3 - "$codex_cwd/scripts/ralph/prd.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
for story in document["userStories"]:
    story["passes"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
    fi
    if [[ "$MOCK_MODE" == "metadata" ]]; then
      python3 - "$codex_cwd/scripts/ralph/prd.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
document["description"] = "progress note written by the worker"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
    fi
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

# Codex: --cd and --output-last-message; the prompt is the last argument.
codex() {
  local last_message=""
  local codex_cwd=""
  local model=""
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
      --model)
        model="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  printf '%s %s\n' "$(agent_role "$prompt")" "${model:--}" >> "$MOCK_MODELS_FILE"
  agent_behavior "$codex_cwd" "$prompt" "$last_message" "$PWD"
}

agent_role() {
  if [[ "$1" == *"independent fail-close and clean-break policy reviewer"* ]]; then
    printf 'review\n'
  else
    printf 'worker\n'
  fi
}

# Cursor CLI: --workspace; the prompt is the last argument; stream-json on stdout.
agent() {
  local workspace=""
  local model=""
  local prompt="${*: -1}"
  local message status
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --workspace)
        workspace="$2"
        shift 2
        ;;
      --model)
        model="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  printf '%s %s\n' "$(agent_role "$prompt")" "${model:--}" >> "$MOCK_MODELS_FILE"
  message="$(command mktemp)"
  agent_behavior "$workspace" "$prompt" "$message" "$PWD"
  status=$?
  if [[ "$status" -eq 0 ]]; then
    python3 "$MOCK_REPLY_TOOL" cursor "$message" "$workspace" "$(agent_role "$prompt")"
    status=$?
  fi
  rm -f "$message"
  return "$status"
}

# Antigravity CLI: runs in the current directory; the prompt directly follows -p; one JSON reply.
agy() {
  local prompt=""
  local model=""
  local message status main_worktree
  export MOCK_AGY_ARGS="$*"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -p)
        prompt="$2"
        shift 2
        ;;
      --print-timeout)
        echo 'the runner must not pass --print-timeout' >&2
        return 9
        ;;
      --model)
        model="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  printf '%s %s\n' "$(agent_role "$prompt")" "${model:--}" >> "$MOCK_MODELS_FILE"
  main_worktree="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
  message="$(command mktemp)"
  agent_behavior "$PWD" "$prompt" "$message" "$main_worktree"
  status=$?
  if [[ "$status" -eq 0 ]]; then
    python3 "$MOCK_REPLY_TOOL" antigravity "$message" "$PWD" "$(agent_role "$prompt")"
    status=$?
  fi
  rm -f "$message"
  return "$status"
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
export -f agent_behavior codex agent_role agent agy
export MOCK_CHILD_PIDS="$TEST_ROOT/child-pids.txt"
: > "$MOCK_CHILD_PIDS"
export MOCK_MODELS_FILE="$TEST_ROOT/models.txt"
: > "$MOCK_MODELS_FILE"
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
grep -Fq 'You are the implementation worker for one Ralph story.' "$MOCK_PROMPTS_FILE"
grep -Fq 'Complete the selected story in this turn' "$MOCK_PROMPTS_FILE"
# The worker protocol ships with the runner and outranks the project's CLAUDE.md, so a plan-time
# rewrite of CLAUDE.md cannot decide when a story passes.
grep -Fq 'Follow the Ralph worker protocol below' "$MOCK_PROMPTS_FILE"
grep -Fq '# Ralph worker protocol' "$MOCK_PROMPTS_FILE"
grep -Fq 'this protocol wins' "$MOCK_PROMPTS_FILE"
grep -Fq 'decide it within the PRD' "$MOCK_PROMPTS_FILE"
grep -Fq "Read $second_root/scripts/ralph/CLAUDE.md in full as this project's notes" "$MOCK_PROMPTS_FILE"
if grep -Fq 'complete and authoritative task specification' "$MOCK_PROMPTS_FILE"; then
  echo 'the worker prompt must not let CLAUDE.md outrank the worker protocol' >&2
  exit 1
fi
grep -Fq 'independent fail-close and clean-break policy reviewer' "$MOCK_PROMPTS_FILE"
grep -Fq 'This is a static policy diff review.' "$MOCK_PROMPTS_FILE"
grep -Fq 'managers, or any command that creates or modifies files.' "$MOCK_PROMPTS_FILE"
grep -Fq 'Judge only the policy violations listed' "$MOCK_PROMPTS_FILE"
grep -Fq 'Read their acceptance criteria only to determine' "$MOCK_PROMPTS_FILE"
grep -Fq 'Do not review general correctness or completeness.' "$MOCK_PROMPTS_FILE"
if grep -Fq 'An unmet or contradicted acceptance criterion.' "$MOCK_PROMPTS_FILE"; then
  echo 'policy reviewer prompt must not grade general acceptance criteria' >&2
  exit 1
fi
if grep -Fq 'falsely mark acceptance' "$MOCK_PROMPTS_FILE"; then
  echo 'policy reviewer prompt must not retain a general acceptance backdoor' >&2
  exit 1
fi
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
# A worker that never completes the story does not stop the run; the budget does.
blocked_output="$(cd "$blocked_root" && bash "$RUNNER" 3 2>&1)"
grep -Fq 'Iteration 1 completed no story' <<< "$blocked_output"
grep -Fq 'Iteration 3 completed no story' <<< "$blocked_output"
grep -Fq 'used its iteration budget (3)' <<< "$blocked_output"
grep -Fq 'completed=0' <<< "$blocked_output"
grep -Fq 'iterationsRun=3' <<< "$blocked_output"
grep -Fq 'maxIterations=3' <<< "$blocked_output"
if grep -Fq 'blocked=' <<< "$blocked_output"; then
  echo 'the runner must not report a blocked status' >&2
  exit 1
fi
[[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" -eq 3 ]]
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE" || true)" -eq 0 ]]
grep -Fq '"passes": false' "$blocked_root/scripts/ralph/prd.json"

no_progress_limit_root="$TEST_ROOT/no-progress-limit"
make_fixture "$no_progress_limit_root"
export MOCK_MODE="blocked"
export MOCK_CALLS_FILE="$TEST_ROOT/no-progress-limit-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/no-progress-limit-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
no_progress_limit_output="$(cd "$no_progress_limit_root" && bash "$RUNNER" 2)"
grep -Fq 'completed=0' <<< "$no_progress_limit_output"
grep -Fq 'iterationsRun=2' <<< "$no_progress_limit_output"
grep -Fq 'used its iteration budget (2)' <<< "$no_progress_limit_output"

progress_later_root="$TEST_ROOT/progress-later"
make_fixture "$progress_later_root"
export MOCK_MODE="progress-later"
export MOCK_CALLS_FILE="$TEST_ROOT/progress-later-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/progress-later-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
progress_later_output="$(cd "$progress_later_root" && bash "$RUNNER" 3)"
grep -Fq 'Iteration 1 completed no story' <<< "$progress_later_output"
grep -Fq 'completed=1' <<< "$progress_later_output"
grep -Fq 'iterationsRun=2' <<< "$progress_later_output"
[[ "$(grep -c 'already contains uncommitted changes' "$MOCK_PROMPTS_FILE")" -eq 1 ]]
grep -Fq 'If they belong to story US-001, continue from them' "$MOCK_PROMPTS_FILE"
[[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" -eq 2 ]]
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 1 ]]
git -C "$progress_later_root" show HEAD:app.txt | grep -Fq 'partial work'
git -C "$progress_later_root" show HEAD:app.txt | grep -Fq 'implementation attempt'
[[ -z "$(git -C "$progress_later_root" status --porcelain)" ]]

metadata_root="$TEST_ROOT/metadata"
make_fixture "$metadata_root"
cp "$metadata_root/scripts/ralph/prd.json" "$TEST_ROOT/metadata-before.json"
export MOCK_MODE="metadata"
export MOCK_CALLS_FILE="$TEST_ROOT/metadata-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/metadata-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
# A worker that also edits prd.json metadata: the edit is discarded, the story still lands.
metadata_output="$(cd "$metadata_root" && bash "$RUNNER" 2 2>&1)"
grep -Fq 'ignored edits to prd.json metadata' <<< "$metadata_output"
grep -Fq 'completed=1' <<< "$metadata_output"
grep -Fq 'iterationsRun=1' <<< "$metadata_output"
grep -Fq 'change only the completed story'"'"'s passes and notes' "$MOCK_PROMPTS_FILE"
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 1 ]]
git -C "$metadata_root" show HEAD:scripts/ralph/prd.json | grep -Fq '"description": "Test story"'
git -C "$metadata_root" show HEAD:scripts/ralph/prd.json | grep -Fq '"passes": true'
[[ -z "$(git -C "$metadata_root" status --porcelain)" ]]

progressing_root="$TEST_ROOT/progressing"
make_fixture "$progressing_root"
export MOCK_MODE="progressing"
export MOCK_CALLS_FILE="$TEST_ROOT/progressing-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/progressing-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
# A worker that keeps changing files without completing the story runs to the budget.
progressing_output="$(cd "$progressing_root" && bash "$RUNNER" 4 2>&1)"
grep -Fq 'completed=0' <<< "$progressing_output"
grep -Fq 'iterationsRun=4' <<< "$progressing_output"
grep -Fq 'used its iteration budget (4)' <<< "$progressing_output"
[[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" -eq 4 ]]
[[ "$(grep -c 'more work' "$progressing_root/app.txt")" -eq 4 ]]
git -C "$progressing_root" status --porcelain | grep -Fq 'app.txt'

already_done_root="$TEST_ROOT/already-done"
make_fixture "$already_done_root"
python3 - "$already_done_root/scripts/ralph/prd.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["userStories"][0]["passes"] = True
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
git -C "$already_done_root" commit -qam 'all stories already pass'
export MOCK_MODE="approve"
export MOCK_CALLS_FILE="$TEST_ROOT/already-done-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/already-done-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
already_done_output="$(cd "$already_done_root" && bash "$RUNNER" 2)"
grep -Fq 'no pending story' <<< "$already_done_output"
grep -Fq 'completed=1' <<< "$already_done_output"
grep -Fq 'iterationsRun=0' <<< "$already_done_output"
[[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE" || true)" -eq 0 ]]

dirty_root="$TEST_ROOT/dirty"
make_fixture "$dirty_root"
printf 'unrelated\n' > "$dirty_root/unrelated.txt"
export MOCK_MODE="approve"
export MOCK_CALLS_FILE="$TEST_ROOT/dirty-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/dirty-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
# Uncommitted changes present before the run are kept, announced to the worker, and enter the
# next approved commit instead of refusing the run.
dirty_output="$(cd "$dirty_root" && bash "$RUNNER" 1 2>&1)"
grep -Fq 'uncommitted changes present outside scripts/ralph' <<< "$dirty_output"
grep -Fq 'unrelated.txt' <<< "$dirty_output"
grep -Fq 'completed=1' <<< "$dirty_output"
grep -Fq 'already contains uncommitted changes' "$MOCK_PROMPTS_FILE"
git -C "$dirty_root" show --format= --name-only HEAD | grep -Fxq 'unrelated.txt'
[[ -z "$(git -C "$dirty_root" status --porcelain)" ]]

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
grep -Fq "$AGENT_FAILURE" <<< "$worker_error_output"
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
# After a rejection, a worker that completes a different story is not stopped either.
wrong_retry_output="$(cd "$wrong_retry_root" && bash "$RUNNER" 2 2>&1)"
grep -Fq 'Policy review rejected US-001' <<< "$wrong_retry_output"
grep -Fq 'completed=0' <<< "$wrong_retry_output"
grep -Fq 'iterationsRun=2' <<< "$wrong_retry_output"
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 2 ]]
git -C "$wrong_retry_root" log -1 --format=%s | grep -Fq 'feat: US-002 - Second story'
[[ "$(grep -c '"passes": false' "$wrong_retry_root/scripts/ralph/prd.json")" -eq 1 ]]

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
# A failing pre-commit hook resets the story and continues; the work stays in the tree.
commit_error_output="$(cd "$commit_error_root" && bash "$RUNNER" 1 2>&1)"
grep -Fq 'pre-commit hook failed in iteration 1 with status 9' <<< "$commit_error_output"
grep -Fq 'completed=0' <<< "$commit_error_output"
grep -Fq 'iterationsRun=1' <<< "$commit_error_output"
grep -Fq 'POLICY GATE FAILED' "$commit_error_root/scripts/ralph/progress.txt"
grep -Fq '"passes": false' "$commit_error_root/scripts/ralph/prd.json"
git -C "$commit_error_root" status --porcelain | grep -Fq 'app.txt'
[[ "$(git -C "$commit_error_root" rev-list --count HEAD)" -eq 1 ]]
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE" || true)" -eq 0 ]]

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
grep -Fq 'Ralph iteration budget: 22 (twice the 11 pending stories, at least 10)' <<< "$until_complete_output"
grep -Fq 'completed=1' <<< "$until_complete_output"
grep -Fq 'iterationsRun=11' <<< "$until_complete_output"
grep -Fq 'maxIterations=22' <<< "$until_complete_output"
[[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" -eq 11 ]]

two_stories_root="$TEST_ROOT/two-stories"
make_fixture "$two_stories_root"
add_second_story "$two_stories_root"
export MOCK_MODE="two-stories"
export MOCK_CALLS_FILE="$TEST_ROOT/two-stories-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/two-stories-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
two_stories_output="$(cd "$two_stories_root" && bash "$RUNNER" 3)"
grep -Fq 'completed=1' <<< "$two_stories_output"
grep -Fq 'iterationsRun=1' <<< "$two_stories_output"
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 1 ]]
grep -Fq 'The stories under review are: US-001: Test gate; US-002: Second story.' "$MOCK_PROMPTS_FILE"
git -C "$two_stories_root" log -1 --format=%s | grep -Fq 'feat: US-001, US-002 - Test gate; Second story'

circuit_breaker_root="$TEST_ROOT/circuit-breaker"
make_fixture "$circuit_breaker_root"
export MOCK_MODE="reject-always"
export MOCK_CALLS_FILE="$TEST_ROOT/circuit-breaker-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/circuit-breaker-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
# Repeated rejections never stop the run; the default budget (at least 10) does.
circuit_breaker_output="$(cd "$circuit_breaker_root" && bash "$RUNNER" 2>&1)"
grep -Fq 'Ralph iteration budget: 10 (twice the 1 pending stories, at least 10)' <<< "$circuit_breaker_output"
grep -Fq 'used its iteration budget (10)' <<< "$circuit_breaker_output"
grep -Fq 'completed=0' <<< "$circuit_breaker_output"
grep -Fq 'iterationsRun=10' <<< "$circuit_breaker_output"
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 10 ]]
[[ "$(grep -c 'POLICY REVIEW REJECTED' "$circuit_breaker_root/scripts/ralph/progress.txt")" -eq 10 ]]

missing_protocol_root="$TEST_ROOT/missing-protocol"
make_fixture "$missing_protocol_root"
cp -R "$TEST_ROOT/skill" "$TEST_ROOT/skill-without-protocol"
rm "$TEST_ROOT/skill-without-protocol/assets/worker-protocol.md"
export MOCK_MODE="approve"
export MOCK_CALLS_FILE="$TEST_ROOT/missing-protocol-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/missing-protocol-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
# Without its protocol the runner fails before any worker starts.
set +e
missing_protocol_output="$(cd "$missing_protocol_root" \
  && bash "$TEST_ROOT/skill-without-protocol/scripts/$RUNNER_NAME" 1 2>&1)"
missing_protocol_status=$?
set -e
[[ "$missing_protocol_status" -eq 1 ]]
grep -Fq 'Ralph policy gate files are missing' <<< "$missing_protocol_output"
grep -Fq 'missing: ' <<< "$missing_protocol_output"
grep -Fq 'assets/worker-protocol.md' <<< "$missing_protocol_output"
[[ ! -s "$MOCK_CALLS_FILE" ]]

set +e
nested_output="$(cd "$reject_root" && RALPH_RUN_ACTIVE=1 bash "$RUNNER" 3 2>&1)"
nested_status=$?
set -e
[[ "$nested_status" -eq 1 ]]
grep -Fq 'refusing to start a nested Ralph runner' <<< "$nested_output"

python3 - "$RUNNER" "$reject_root" <<'PY'
import fcntl
from pathlib import Path
import subprocess
import sys

runner, root = sys.argv[1:]
with (Path(root) / '.git/ralph-run.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    result = subprocess.run(['bash', runner, '1'], cwd=root, capture_output=True, text=True)
assert result.returncode != 0
assert 'another Ralph runner is already active' in result.stderr
PY


# Without Ralph model settings no call names a model, so every agent keeps its CLI default.
[[ -s "$MOCK_MODELS_FILE" ]]
if grep -qv -- ' -$' "$MOCK_MODELS_FILE"; then
  echo 'a model was passed without any Ralph model setting' >&2
  exit 1
fi

case "$RALPH_TEST_AGENT" in
  codex) model_settings="$HOME/.codex/ralph.json" ;;
  cursor) model_settings="$HOME/.cursor/ralph.json" ;;
  antigravity) model_settings="$HOME/.gemini/antigravity-cli/ralph.json" ;;
esac
mkdir -p "$(dirname "$model_settings")"

# run_model_scenario NAME [ENV...]: one approved story; output in $model_output.
run_model_scenario() {
  local name="$1"
  shift
  model_root="$TEST_ROOT/$name"
  make_fixture "$model_root"
  export MOCK_MODE="approve"
  export MOCK_CALLS_FILE="$TEST_ROOT/$name-calls.txt"
  export MOCK_PROMPTS_FILE="$TEST_ROOT/$name-prompts.txt"
  : > "$MOCK_CALLS_FILE"
  : > "$MOCK_PROMPTS_FILE"
  : > "$MOCK_MODELS_FILE"
  model_output="$(cd "$model_root" && env "$@" bash "$RUNNER" 1)"
  grep -Fq 'completed=1' <<< "$model_output"
}

# Saved Ralph models reach the worker and the reviewer.
printf '{"model": "saved-worker", "review_model": "saved-reviewer"}\n' > "$model_settings"
run_model_scenario saved-models
grep -Fq 'Ralph models: worker=saved-worker reviewer=saved-reviewer' <<< "$model_output"
[[ "$(sort "$MOCK_MODELS_FILE" | paste -sd '|')" == "review saved-reviewer|worker saved-worker" ]]
# A run override replaces only its own role.
run_model_scenario run-model RALPH_MODEL=run-worker
[[ "$(sort "$MOCK_MODELS_FILE" | paste -sd '|')" == "review saved-reviewer|worker run-worker" ]]
# Without a reviewer model the reviewer uses the worker's.
printf '{"model": "saved-worker"}\n' > "$model_settings"
run_model_scenario worker-only-model
[[ "$(sort "$MOCK_MODELS_FILE" | paste -sd '|')" == "review saved-worker|worker saved-worker" ]]
# Invalid settings stop the runner before any agent call.
printf '{"model": "has space"}\n' > "$model_settings"
model_error_root="$TEST_ROOT/invalid-model-settings"
make_fixture "$model_error_root"
export MOCK_CALLS_FILE="$TEST_ROOT/invalid-model-settings-calls.txt"
: > "$MOCK_CALLS_FILE"
set +e
model_error_output="$(cd "$model_error_root" && bash "$RUNNER" 1 2>&1)"
model_error_status=$?
set -e
[[ "$model_error_status" -eq 1 ]]
grep -Fq 'is not a valid model name' <<< "$model_error_output"
[[ ! -s "$MOCK_CALLS_FILE" ]]
rm "$model_settings"

spawn_root="$TEST_ROOT/spawn-child"
make_fixture "$spawn_root"
export MOCK_MODE="spawn-child"
export MOCK_CALLS_FILE="$TEST_ROOT/spawn-child-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/spawn-child-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
# Every agent call closes the runner lock, so a process the agent leaves behind cannot hold it.
spawn_output="$(cd "$spawn_root" && bash "$RUNNER" 1)"
grep -Fq 'completed=1' <<< "$spawn_output"
python3 - "$spawn_root" "$MOCK_CHILD_PIDS" <<'PY'
import fcntl
import os
from pathlib import Path
import signal
import sys

root, pid_file = sys.argv[1:]
children = [int(pid) for pid in Path(pid_file).read_text().split()]
assert children, 'the fake agent left no child process behind'
try:
    for pid in children:
        os.kill(pid, 0)  # The child is still alive while the lock is taken.
    with (Path(root) / '.git/ralph-run.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
finally:
    for pid in children:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
PY

# run_failing_scenario NAME MODE BUDGET: runs the runner expecting failure; output in $scenario_output.
run_failing_scenario() {
  local name="$1"
  scenario_root="$TEST_ROOT/$name"
  make_fixture "$scenario_root"
  cp "$scenario_root/scripts/ralph/prd.json" "$TEST_ROOT/$name-before.json"
  export MOCK_MODE="$2"
  export MOCK_CALLS_FILE="$TEST_ROOT/$name-calls.txt"
  export MOCK_PROMPTS_FILE="$TEST_ROOT/$name-prompts.txt"
  : > "$MOCK_CALLS_FILE"
  : > "$MOCK_PROMPTS_FILE"
  set +e
  scenario_output="$(cd "$scenario_root" && bash "$RUNNER" "$3" 2>&1)"
  scenario_status=$?
  set -e
}

if [[ "$RALPH_TEST_AGENT" != "codex" ]]; then
  # The reviewer must prove it read the staged diff by reporting the staged tree.
  grep -Fq 'git write-tree' "$TEST_ROOT/second-prompts.txt"
  grep -Fq 'reviewed_tree' "$TEST_ROOT/second-prompts.txt"
  run_failing_scenario review-wrong-tree review-wrong-tree 1
  [[ "$scenario_status" -eq 1 ]]
  grep -Fq 'invalid policy review output' <<< "$scenario_output"
  grep -Fq 'POLICY GATE FAILED' "$scenario_root/scripts/ralph/progress.txt"
  grep -Fq '"passes": false' "$scenario_root/scripts/ralph/prd.json"
  grep -rFq 'did not report the staged tree' "$scenario_root/scripts/ralph/logs"
  [[ "$(git -C "$scenario_root" rev-list --count HEAD)" -eq 1 ]]
fi

if [[ "$RALPH_TEST_AGENT" == "cursor" ]]; then
  # Cursor has no output schema; the only fenced block of the final message is accepted.
  fenced_root="$TEST_ROOT/review-fenced"
  make_fixture "$fenced_root"
  export MOCK_MODE="review-fenced"
  export MOCK_CALLS_FILE="$TEST_ROOT/review-fenced-calls.txt"
  export MOCK_PROMPTS_FILE="$TEST_ROOT/review-fenced-prompts.txt"
  : > "$MOCK_CALLS_FILE"
  : > "$MOCK_PROMPTS_FILE"
  fenced_output="$(cd "$fenced_root" && bash "$RUNNER" 1)"
  grep -Fq 'completed=1' <<< "$fenced_output"
  grep -Fq 'Your final message must be exactly one JSON object' "$MOCK_PROMPTS_FILE"
  # A run that does not end with a successful result event is a failed worker, not a reply.
  run_failing_scenario cursor-unsuccessful cursor-unsuccessful 1
  [[ "$scenario_status" -eq 1 ]]
  grep -Fq "$AGENT_FAILURE" <<< "$scenario_output"
  cmp "$TEST_ROOT/cursor-unsuccessful-before.json" "$scenario_root/scripts/ralph/prd.json"
fi

if [[ "$RALPH_TEST_AGENT" == "antigravity" ]]; then
  # agy exits 0 when headless mode auto-denies a tool or a turn ends without SUCCESS.
  for mode in agy-auto-denied agy-status-error; do
    run_failing_scenario "$mode" "$mode" 1
    [[ "$scenario_status" -eq 1 ]]
    grep -Fq "$AGENT_FAILURE" <<< "$scenario_output"
    cmp "$TEST_ROOT/$mode-before.json" "$scenario_root/scripts/ralph/prd.json"
  done
  grep -rFq 'auto-denied' "$TEST_ROOT/agy-auto-denied/scripts/ralph/logs"
fi

printf 'PASS (%s): runner-owned worker protocol, policy rejection/repair, budget-bounded continuation, sanitized prd.json, dirty tree absorption, failure rollback, commit gate, recursion guard, and lock release.\n' "$RALPH_TEST_AGENT"
