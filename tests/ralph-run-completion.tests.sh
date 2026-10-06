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
    REINSTALL_HINT="reinstall the ralph-run skill"
    REVIEW_DIFF_COMMAND="git diff --cached HEAD"
    ;;
  cursor)
    RUNNER_NAME="ralph-run-cursor.sh"
    AGENT_COMMAND="agent"
    AUTONOMY_FLAG="--force"
    AGENT_FAILURE="agent -p failed"
    REINSTALL_HINT="reinstall the ralph-run-cursor skill"
    REVIEW_DIFF_COMMAND="git diff --cached HEAD | cat"
    ;;
  antigravity)
    RUNNER_NAME="ralph-run-antigravity.sh"
    AGENT_COMMAND="agy"
    AUTONOMY_FLAG="--dangerously-skip-permissions"
    AGENT_FAILURE="agy -p failed"
    REINSTALL_HINT="reinstall the Antigravity ralph-run skill"
    REVIEW_DIFF_COMMAND="git diff --cached HEAD"
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
unset CODEX_HOME RALPH_MODEL RALPH_REVIEW_MODEL RALPH_EFFORT RALPH_REVIEW_EFFORT
# Only the runner may set RALPH_RUN_ACTIVE: the fake agent requires it on every call.
unset RALPH_RUN_ACTIVE
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
auto_denied = ('jetski: no output produced - a tool required the "command" permission that headless '
               'mode cannot prompt for, so it was auto-denied.')
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
        # An approval wrapped in prose, bare or fenced, is not exactly one JSON object.
        if mode == 'cursor-review-prose':
            text = 'I read the staged diff.\n' + text + '\nNo listed policy problem is present.'
        if mode == 'cursor-review-prose-fenced':
            text = ('I read the staged diff.\n```json\n' + text
                    + '\n```\nNo listed policy problem is present.')
    unsuccessful = (mode == 'cursor-unsuccessful'
                    or (mode == 'cursor-review-unsuccessful' and review is not None))
    for event in [
        {'type': 'system', 'subtype': 'init'},
        {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Working on it.'}]}},
        {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': text}]}},
        {'type': 'result', 'subtype': 'success', 'is_error': unsuccessful,
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
        # A well-formed approval that only the reviewer's own stderr betrays.
        if mode == 'agy-review-auto-denied':
            print(auto_denied, file=sys.stderr)
        # The approval appears only as response text, never as structured output.
        if mode == 'agy-review-no-structured-output':
            del reply['structured_output']
    if mode == 'agy-auto-denied':
        print(auto_denied, file=sys.stderr)
        reply['response'] = ''
    # A tool the headless run denied, reported only in the reply: status SUCCESS, nothing on stderr.
    if mode == ('agy-review-denied-actions' if review is not None else 'agy-denied-actions'):
        reply['denied_actions'] = [{'action': 'command', 'display_name': 'RunCommand'}]
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

  # RALPH_RUN_ACTIVE=1 is what makes a runner started inside a worker or reviewer refuse to run.
  if [[ "${RALPH_RUN_ACTIVE:-}" != "1" ]]; then
    echo 'fake agent: every worker and reviewer call must run with RALPH_RUN_ACTIVE=1' >&2
    return 13
  fi

  printf '%s\n' "$prompt" >> "$MOCK_PROMPTS_FILE"

  if [[ "$prompt" == *"independent fail-close and clean-break policy reviewer"* ]]; then
    printf 'review\n' >> "$MOCK_CALLS_FILE"
    printf '%s\n' "$codex_cwd" >> "$MOCK_REVIEW_CWDS_FILE"
    # The latest reviewer prompt, byte for byte.
    printf '%s' "$prompt" > "$MOCK_REVIEW_PROMPT_FILE"
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
    # An instruction file: every time, or only on the first worker call (the next worker removes
    # it, as the gate's note in progress.txt asks).
    if [[ "$MOCK_MODE" == "instruction-file" || "$MOCK_MODE" == "instruction-file-named" \
      || ( "$MOCK_MODE" == "instruction-file-once" && "$worker_count" -eq 1 ) ]]; then
      mkdir -p "$codex_cwd/docs"
      printf 'a learning\n' > "$codex_cwd/docs/CLAUDE.md"
    fi
    if [[ "$MOCK_MODE" == "instruction-file-once" && "$worker_count" -gt 1 ]]; then
      rm -f "$codex_cwd/docs/CLAUDE.md"
    fi
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

# Codex CLI: the exec subcommand first, the prompt last. Every call must carry --cd DIR,
# --dangerously-bypass-approvals-and-sandbox and --output-last-message FILE, in any order, and the
# reviewer call also --ephemeral and --output-schema FILE; nothing else is allowed but an optional
# --model NAME and an optional -c model_reasoning_effort="EFFORT".
codex() {
  local last_message=""
  local codex_cwd=""
  local model=""
  local effort=""
  local prompt="${*: -1}"
  local subcommand="${1-}"
  local bypass=0 ephemeral=0 schema_given=0 output_schema="" unexpected=""
  local -a options=()
  local index=0
  [[ "$#" -lt 2 ]] || options=("${@:2:$#-2}")
  while [[ "$index" -lt "${#options[@]}" ]]; do
    case "${options[index]}" in
      --cd)
        codex_cwd="${options[index + 1]-}"
        index=$((index + 1))
        ;;
      --dangerously-bypass-approvals-and-sandbox) bypass=1 ;;
      --ephemeral) ephemeral=1 ;;
      --output-schema)
        schema_given=1
        output_schema="${options[index + 1]-}"
        index=$((index + 1))
        ;;
      --output-last-message)
        last_message="${options[index + 1]-}"
        index=$((index + 1))
        ;;
      --model)
        model="${options[index + 1]-}"
        index=$((index + 1))
        ;;
      -c)
        if [[ "${options[index + 1]-}" =~ ^model_reasoning_effort=\"([a-z]+)\"$ ]]; then
          effort="${BASH_REMATCH[1]}"
        else
          unexpected+=" -c ${options[index + 1]-}"
        fi
        index=$((index + 1))
        ;;
      *) unexpected+=" ${options[index]}" ;;
    esac
    index=$((index + 1))
  done
  if [[ "$(agent_role "$prompt")" == "review" ]]; then
    if [[ "$ephemeral" -ne 1 || "$schema_given" -ne 1 || ! -f "$output_schema" ]]; then
      echo 'fake codex: the reviewer call must carry --ephemeral and --output-schema FILE' >&2
      return 12
    fi
  else
    [[ "$ephemeral" -eq 0 ]] || unexpected+=" --ephemeral"
    [[ "$schema_given" -eq 0 ]] || unexpected+=" --output-schema $output_schema"
  fi
  if [[ "$subcommand" != "exec" || ! -d "$codex_cwd" || "$bypass" -ne 1 \
    || -z "$last_message" || "$last_message" == -* || -z "$prompt" || "$prompt" == -* \
    || -n "$unexpected" ]]; then
    echo "fake codex: expected exec --cd DIR --dangerously-bypass-approvals-and-sandbox" \
      "[--ephemeral --output-schema FILE] [--model NAME] [-c model_reasoning_effort=\"EFFORT\"]" \
      "--output-last-message FILE PROMPT; got: $subcommand ${options[*]} PROMPT" >&2
    return 12
  fi
  printf '%s %s\n' "$(agent_role "$prompt")" "${model:--}" >> "$MOCK_MODELS_FILE"
  printf '%s %s\n' "$(agent_role "$prompt")" "${effort:--}" >> "$MOCK_EFFORTS_FILE"
  agent_behavior "$codex_cwd" "$prompt" "$last_message" "$PWD"
}

agent_role() {
  if [[ "$1" == *"independent fail-close and clean-break policy reviewer"* ]]; then
    printf 'review\n'
  else
    printf 'worker\n'
  fi
}

# Cursor CLI: --workspace; the prompt is the last argument; stream-json on stdout. Every call must
# carry -p --force --trust --sandbox disabled --workspace DIR --output-format stream-json, in any
# order, with nothing else before the prompt but an optional --model NAME.
agent() {
  local workspace=""
  local model=""
  local prompt="${*: -1}"
  local message status
  local print=0 force=0 trust=0 sandbox="" output_format="" unexpected=""
  local -a options=("${@:1:$#-1}")
  local index=0
  while [[ "$index" -lt "${#options[@]}" ]]; do
    case "${options[index]}" in
      -p) print=1 ;;
      --force) force=1 ;;
      --trust) trust=1 ;;
      --sandbox)
        sandbox="${options[index + 1]-}"
        index=$((index + 1))
        ;;
      --workspace)
        workspace="${options[index + 1]-}"
        index=$((index + 1))
        ;;
      --output-format)
        output_format="${options[index + 1]-}"
        index=$((index + 1))
        ;;
      --model)
        model="${options[index + 1]-}"
        index=$((index + 1))
        ;;
      *) unexpected+=" ${options[index]}" ;;
    esac
    index=$((index + 1))
  done
  if [[ "$print" -ne 1 || "$force" -ne 1 || "$trust" -ne 1 || "$sandbox" != "disabled" \
    || ! -d "$workspace" || "$output_format" != "stream-json" || -n "$unexpected" ]]; then
    echo "fake agent: expected -p --force --trust --sandbox disabled --workspace DIR" \
      "--output-format stream-json [--model NAME] PROMPT; got: ${options[*]} PROMPT" >&2
    return 12
  fi
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
# Every call must carry --dangerously-skip-permissions, --output-format json and -p PROMPT, and the
# reviewer call also --json-schema FILE; nothing else is allowed but an optional --model NAME.
agy() {
  local prompt=""
  local model=""
  local message status main_worktree
  local prompt_given=0 skip_permissions=0 output_format="" schema_given=0 json_schema=""
  local unexpected=""
  local -a args=("$@")
  local index=0
  export MOCK_AGY_ARGS="$*"
  while [[ "$index" -lt "${#args[@]}" ]]; do
    case "${args[index]}" in
      -p)
        prompt_given=1
        prompt="${args[index + 1]-}"
        index=$((index + 1))
        ;;
      --print-timeout)
        echo 'the runner must not pass --print-timeout' >&2
        return 9
        ;;
      --dangerously-skip-permissions) skip_permissions=1 ;;
      --output-format)
        output_format="${args[index + 1]-}"
        index=$((index + 1))
        ;;
      --json-schema)
        schema_given=1
        json_schema="${args[index + 1]-}"
        index=$((index + 1))
        ;;
      --model)
        model="${args[index + 1]-}"
        index=$((index + 1))
        ;;
      *) unexpected+=" ${args[index]}" ;;
    esac
    index=$((index + 1))
  done
  # agy reads the argument after -p as the prompt, so an option there would take its place.
  if [[ "$prompt_given" -ne 1 || -z "$prompt" || "$prompt" == -* ]]; then
    echo 'fake agy: -p must be immediately followed by the prompt' >&2
    return 12
  fi
  if [[ "$(agent_role "$prompt")" == "review" ]]; then
    if [[ "$schema_given" -ne 1 || ! -f "$json_schema" ]]; then
      echo 'fake agy: the reviewer call must carry --json-schema FILE' >&2
      return 12
    fi
  elif [[ "$schema_given" -eq 1 ]]; then
    unexpected+=" --json-schema $json_schema"
  fi
  if [[ "$skip_permissions" -ne 1 || "$output_format" != "json" || -n "$unexpected" ]]; then
    echo "fake agy: expected --dangerously-skip-permissions --output-format json [--model NAME]" \
      "-p PROMPT; got: ${args[*]//"$prompt"/PROMPT}" >&2
    return 12
  fi
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
# Codex only: the reasoning effort of each call ("-" without one).
export MOCK_EFFORTS_FILE="$TEST_ROOT/efforts.txt"
: > "$MOCK_EFFORTS_FILE"
export MOCK_REVIEW_CWDS_FILE="$TEST_ROOT/reviewer-cwds.txt"
: > "$MOCK_REVIEW_CWDS_FILE"
export MOCK_REVIEW_PROMPT_FILE="$TEST_ROOT/review-prompt.txt"

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
# Both reviewers read the staged diff with their agent's command; Cursor's pipes it through cat.
review_diff_line="Inspect the complete staged snapshot using \"$REVIEW_DIFF_COMMAND\" in this disposable worktree:"
[[ "$(grep -Fxc -- "$review_diff_line" "$MOCK_PROMPTS_FILE")" -eq 2 ]]
if [[ "$RALPH_TEST_AGENT" == "codex" ]]; then
  # The Codex reviewer prompt stays byte for byte what it was before the command became per-agent.
  golden_worktree="$(tail -1 "$MOCK_REVIEW_CWDS_FILE")"
  golden_review_prompt=$(cat <<EOF
You are the independent fail-close and clean-break policy reviewer for one Ralph iteration.

This is a static policy diff review. Do not run builds, tests, linters, coverage commands, package
managers, or any command that creates or modifies files. Judge only the policy violations listed
below from the staged diff. The implementation worker and pre-commit hook own test execution.

Inspect the complete staged snapshot using "git diff --cached HEAD" in this disposable worktree:
$golden_worktree

The runner already verified that the staged snapshot is complete. Do not use the main worktree or
plain "git diff HEAD"; every newly created file must be reviewed from the cached diff.

The stories under review are: US-001: Test gate. Read their acceptance criteria only to determine
whether fallback, compatibility, removal, or test behavior is explicitly required or allowed:
$golden_worktree/scripts/ralph/prd.json

Ignore bookkeeping-only changes under scripts/ralph. Reject only when the diff contains at least
one of these concrete problems:

1. A newly introduced fallback, guessed default, broad retry, swallowed error, or no-op that turns
   a required failure into apparent success without explicit acceptance criteria.
2. A compatibility shim, dual path, retained legacy implementation, migration behavior, or feature
   flag that is not explicitly required by acceptance criteria.
3. Obsolete behavior that acceptance criteria require to be removed but remains reachable.
4. A skipped, weakened, or deleted valid test used to make checks pass.

Do not review general correctness or completeness. Do not reject for an acceptance criterion that
is unrelated to the four policy checks above, style, optional refactors, or hypothetical
improvements. Existing compatibility and fallback behavior outside the story's change is not a
finding. Every finding must cite specific diff evidence such as a file and symbol or changed
behavior. Return JSON matching the provided schema. Set approved=true with findings=[] only when no
listed policy problem is present.
EOF
)
  if ! cmp -s <(printf '%s' "$golden_review_prompt") "$MOCK_REVIEW_PROMPT_FILE"; then
    diff <(printf '%s\n' "$golden_review_prompt") <(cat "$MOCK_REVIEW_PROMPT_FILE"; echo) >&2 || true
    echo 'the Codex reviewer prompt must stay byte-identical' >&2
    exit 1
  fi
fi

# The worker protocol keeps workers out of instruction files unless the story names the file.
grep -Fq 'which instruction files you may change, the protocol wins' "$MOCK_PROMPTS_FILE"
grep -Fq 'Proposed instruction changes:' "$MOCK_PROMPTS_FILE"

# A story that changes an instruction file it does not name is held back before review: it stays
# incomplete, nothing is committed, and the change stays in the working tree.
instruction_root="$TEST_ROOT/instruction"
make_fixture "$instruction_root"
export MOCK_MODE="instruction-file"
export MOCK_CALLS_FILE="$TEST_ROOT/instruction-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/instruction-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
instruction_output="$(cd "$instruction_root" && bash "$RUNNER" 2)"
grep -Fq 'completed=0' <<< "$instruction_output"
grep -Fq 'Instruction files changed without US-001 naming them' <<< "$instruction_output"
grep -Fxq '  docs/CLAUDE.md' <<< "$instruction_output"
[[ "$(grep -c '^worker$' "$MOCK_CALLS_FILE")" -eq 2 ]]
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE" || true)" -eq 0 ]]
grep -Fq 'POLICY GATE FAILED' "$instruction_root/scripts/ralph/progress.txt"
grep -Fq 'Changed instruction files that the story does not name: docs/CLAUDE.md.' \
  "$instruction_root/scripts/ralph/progress.txt"
[[ "$(git -C "$instruction_root" rev-list --count HEAD)" -eq 1 ]]
[[ -f "$instruction_root/docs/CLAUDE.md" ]]
python3 - "$instruction_root/scripts/ralph/prd.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["userStories"][0]["passes"] is False
PY

# The next worker undoes the change, and the story is reviewed and committed without it.
instruction_once_root="$TEST_ROOT/instruction-once"
make_fixture "$instruction_once_root"
export MOCK_MODE="instruction-file-once"
export MOCK_CALLS_FILE="$TEST_ROOT/instruction-once-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/instruction-once-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
instruction_once_output="$(cd "$instruction_once_root" && bash "$RUNNER" 3)"
grep -Fq 'completed=1' <<< "$instruction_once_output"
grep -Fq 'iterationsRun=2' <<< "$instruction_once_output"
[[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 1 ]]
git -C "$instruction_once_root" log -1 --format=%s | grep -Fq 'feat: US-001 - Test gate'
if git -C "$instruction_once_root" ls-files | grep -Fxq 'docs/CLAUDE.md'; then
  echo 'an instruction file the story does not name must not be committed' >&2
  exit 1
fi

# A story whose acceptance criteria name the file may change it.
instruction_named_root="$TEST_ROOT/instruction-named"
make_fixture "$instruction_named_root"
python3 - "$instruction_named_root/scripts/ralph/prd.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path, encoding="utf-8"))
document["userStories"][0]["acceptanceCriteria"].append("Record the convention in docs/CLAUDE.md")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
git -C "$instruction_named_root" commit -qam 'name the instruction file'
export MOCK_MODE="instruction-file-named"
export MOCK_CALLS_FILE="$TEST_ROOT/instruction-named-calls.txt"
export MOCK_PROMPTS_FILE="$TEST_ROOT/instruction-named-prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
instruction_named_output="$(cd "$instruction_named_root" && bash "$RUNNER" 2)"
grep -Fq 'completed=1' <<< "$instruction_named_output"
grep -Fq 'iterationsRun=1' <<< "$instruction_named_output"
git -C "$instruction_named_root" ls-files | grep -Fxq 'docs/CLAUDE.md'

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
# The shared loop names the skill of the runner that sourced it.
grep -Fxq "error: Ralph policy gate files are missing; $REINSTALL_HINT" <<< "$missing_protocol_output"
grep -Fq 'missing: ' <<< "$missing_protocol_output"
grep -Fq 'assets/worker-protocol.md' <<< "$missing_protocol_output"
[[ ! -s "$MOCK_CALLS_FILE" ]]

if [[ "$RALPH_TEST_AGENT" != "codex" ]]; then
  # Without the reviewed-tree schema the Cursor and Antigravity runners stop before any agent call
  # as well, naming their own skill and the missing file.
  missing_schema_root="$TEST_ROOT/missing-schema"
  make_fixture "$missing_schema_root"
  cp -R "$TEST_ROOT/skill" "$TEST_ROOT/skill-without-schema"
  missing_schema="$TEST_ROOT/skill-without-schema/assets/policy-review-reviewed-tree.schema.json"
  rm "$missing_schema"
  export MOCK_MODE="approve"
  export MOCK_CALLS_FILE="$TEST_ROOT/missing-schema-calls.txt"
  export MOCK_PROMPTS_FILE="$TEST_ROOT/missing-schema-prompts.txt"
  : > "$MOCK_CALLS_FILE"
  : > "$MOCK_PROMPTS_FILE"
  set +e
  missing_schema_output="$(cd "$missing_schema_root" \
    && bash "$TEST_ROOT/skill-without-schema/scripts/$RUNNER_NAME" 1 2>&1)"
  missing_schema_status=$?
  set -e
  [[ "$missing_schema_status" -eq 1 ]]
  grep -Fxq "error: Ralph policy gate files are missing; $REINSTALL_HINT" <<< "$missing_schema_output"
  # Exactly one file is reported missing, and it is the schema.
  missing_schema_reported="$(grep '^missing: ' <<< "$missing_schema_output")"
  [[ "$(realpath -m "${missing_schema_reported#missing: }")" == "$(realpath -m "$missing_schema")" ]]
  [[ ! -s "$MOCK_CALLS_FILE" ]]
  [[ ! -s "$MOCK_PROMPTS_FILE" ]]
  # No iteration started, so there is no agent log either.
  [[ -z "$(ls -A "$missing_schema_root/scripts/ralph/logs")" ]]
fi

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
# Likewise no Codex call sets a reasoning effort, so Codex keeps its configured one.
if [[ "$RALPH_TEST_AGENT" == "codex" ]]; then
  [[ -s "$MOCK_EFFORTS_FILE" ]]
  if grep -qv -- ' -$' "$MOCK_EFFORTS_FILE"; then
    echo 'a reasoning effort was passed without any Ralph effort setting' >&2
    exit 1
  fi
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
  : > "$MOCK_EFFORTS_FILE"
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

# expect_effort_refused NAME EXPECTED [ENV...]: the runner stops before any agent call.
expect_effort_refused() {
  local name="$1" expected="$2" root output status
  shift 2
  root="$TEST_ROOT/$name"
  make_fixture "$root"
  export MOCK_CALLS_FILE="$TEST_ROOT/$name-calls.txt"
  : > "$MOCK_CALLS_FILE"
  set +e
  output="$(cd "$root" && env "$@" bash "$RUNNER" 1 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]]
  grep -Fq -- "$expected" <<< "$output"
  [[ ! -s "$MOCK_CALLS_FILE" ]]
}

if [[ "$RALPH_TEST_AGENT" == "codex" ]]; then
  # Saved Codex reasoning efforts reach the worker and the reviewer, next to the models.
  printf '{"model": "saved-worker", "effort": "high", "review_effort": "xhigh"}\n' > "$model_settings"
  run_model_scenario saved-efforts
  grep -Fq 'Ralph reasoning effort: worker=high reviewer=xhigh' <<< "$model_output"
  [[ "$(sort "$MOCK_EFFORTS_FILE" | paste -sd '|')" == "review xhigh|worker high" ]]
  [[ "$(sort "$MOCK_MODELS_FILE" | paste -sd '|')" == "review saved-worker|worker saved-worker" ]]
  # A run override replaces only its own role.
  run_model_scenario run-effort RALPH_REVIEW_EFFORT=low
  [[ "$(sort "$MOCK_EFFORTS_FILE" | paste -sd '|')" == "review low|worker high" ]]
  # Without a reviewer effort the reviewer uses the worker's; an effort alone names no model.
  printf '{"effort": "medium"}\n' > "$model_settings"
  run_model_scenario worker-only-effort
  grep -Fq 'Ralph reasoning effort: worker=medium reviewer=medium' <<< "$model_output"
  if grep -Fq 'Ralph models:' <<< "$model_output"; then
    echo 'an effort alone must not print Ralph models' >&2
    exit 1
  fi
  [[ "$(sort "$MOCK_EFFORTS_FILE" | paste -sd '|')" == "review medium|worker medium" ]]
  [[ "$(sort "$MOCK_MODELS_FILE" | paste -sd '|')" == "review -|worker -" ]]
  run_model_scenario run-only-effort RALPH_EFFORT=max
  [[ "$(sort "$MOCK_EFFORTS_FILE" | paste -sd '|')" == "review max|worker max" ]]
  # An invalid effort stops the runner before any agent call.
  printf '{"effort": "High"}\n' > "$model_settings"
  expect_effort_refused invalid-effort-settings 'is not a valid reasoning effort'
  rm "$model_settings"
  expect_effort_refused invalid-run-effort 'the run effort is not a valid reasoning effort' \
    'RALPH_EFFORT=high"'
else
  # Cursor and agy take the effort in the model name, so an effort stops the runner before any
  # agent call, from the settings file or from the run.
  printf '{"effort": "high"}\n' > "$model_settings"
  expect_effort_refused saved-effort-refused 'only Codex takes a Ralph reasoning effort'
  rm "$model_settings"
  expect_effort_refused run-effort-refused 'only Codex takes a Ralph reasoning effort' \
    RALPH_EFFORT=high
  expect_effort_refused run-review-effort-refused 'only Codex takes a Ralph reasoning effort' \
    RALPH_REVIEW_EFFORT=high
fi

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

# assert_review_blocked MESSAGE: after its one review the scenario's run exited 1 with MESSAGE,
# committed nothing and left the story pending.
assert_review_blocked() {
  [[ "$scenario_status" -eq 1 ]]
  grep -Fq "$1" <<< "$scenario_output"
  [[ "$(grep -c '^review$' "$MOCK_CALLS_FILE")" -eq 1 ]]
  [[ "$(git -C "$scenario_root" rev-list --count HEAD)" -eq 1 ]]
  grep -Fq '"passes": false' "$scenario_root/scripts/ralph/prd.json"
  grep -Fq 'POLICY GATE FAILED' "$scenario_root/scripts/ralph/progress.txt"
}

if [[ "$RALPH_TEST_AGENT" != "codex" ]]; then
  # The reviewer must report the staged tree, which shows it ran commands in that snapshot.
  grep -Fq 'git write-tree' "$TEST_ROOT/second-prompts.txt"
  grep -Fq 'reviewed_tree' "$TEST_ROOT/second-prompts.txt"
  if [[ "$RALPH_TEST_AGENT" == "cursor" ]]; then
    # Claude Code's RTK hook, which Cursor also runs, would cut a plain git diff.
    grep -Fq 'git diff --cached HEAD | cat' "$TEST_ROOT/second-prompts.txt"
  fi
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
  # The same holds for the reviewer: an unsuccessful result event voids its approval.
  run_failing_scenario cursor-review-unsuccessful cursor-review-unsuccessful 1
  assert_review_blocked 'policy review failed in iteration 1 with status 1'
  grep -rFq 'Cursor did not finish successfully' "$scenario_root/scripts/ralph/logs"
  # An approval inside prose, bare or fenced, is not exactly one JSON object.
  for mode in cursor-review-prose cursor-review-prose-fenced; do
    run_failing_scenario "$mode" "$mode" 1
    assert_review_blocked 'invalid policy review output in iteration 1'
    grep -rFq 'did not reply with exactly one JSON object' "$scenario_root/scripts/ralph/logs"
  done
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
  # The reviewer's own stderr is checked as well: an auto-denied tool voids a well-formed approval.
  run_failing_scenario agy-review-auto-denied agy-review-auto-denied 1
  assert_review_blocked 'policy review failed in iteration 1 with status 1'
  grep -rFq 'Antigravity auto-denied a tool in headless mode' "$scenario_root/scripts/ralph/logs"
  # Only structured output is the review; an approval in the response text alone is not.
  run_failing_scenario agy-review-no-structured-output agy-review-no-structured-output 1
  assert_review_blocked 'invalid policy review output in iteration 1'
  grep -rFq 'the reviewer returned no structured output' "$scenario_root/scripts/ralph/logs"
  # A reply that lists denied actions fails the call although its status is SUCCESS and stderr
  # reports no auto-denied tool: first for the worker, then for the reviewer's approval.
  run_failing_scenario agy-denied-actions agy-denied-actions 1
  [[ "$scenario_status" -eq 1 ]]
  grep -Fq "$AGENT_FAILURE" <<< "$scenario_output"
  cmp "$TEST_ROOT/agy-denied-actions-before.json" "$scenario_root/scripts/ralph/prd.json"
  grep -Fq '"passes": false' "$scenario_root/scripts/ralph/prd.json"
  [[ "$(git -C "$scenario_root" rev-list --count HEAD)" -eq 1 ]]
  [[ "$(grep -c '^review$' "$MOCK_CALLS_FILE" || true)" -eq 0 ]]
  grep -Fq '"status": "SUCCESS"' "$scenario_root/scripts/ralph/logs/antigravity-iteration-1-reply.json"
  run_failing_scenario agy-review-denied-actions agy-review-denied-actions 1
  assert_review_blocked 'policy review failed in iteration 1 with status 1'
  grep -Fq '"status": "SUCCESS"' \
    "$scenario_root/scripts/ralph/logs/antigravity-iteration-1-policy-review-reply.json"
  for mode in agy-denied-actions agy-review-denied-actions; do
    grep -rFq 'Antigravity denied tools in headless mode' "$TEST_ROOT/$mode/scripts/ralph/logs"
    if grep -rFq 'auto-denied' "$TEST_ROOT/$mode/scripts/ralph/logs"; then
      echo "$mode: denied_actions alone must fail the call, with no auto-denied tool on stderr" >&2
      exit 1
    fi
  done
fi

printf 'PASS (%s): runner-owned worker protocol, policy rejection/repair, instruction-file gate, budget-bounded continuation, sanitized prd.json, dirty tree absorption, failure rollback, commit gate, recursion guard, and lock release.\n' "$RALPH_TEST_AGENT"
