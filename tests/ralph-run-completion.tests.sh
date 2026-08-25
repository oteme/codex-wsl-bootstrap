#!/usr/bin/env bash
set -euo pipefail

RUNNER="${RUNNER:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/ralph-run/scripts/ralph-run-codex.sh"}"
TEST_ROOT="$(mktemp -d)"

codex() {
  local last_message=""
  local prompt="${*: -1}"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --output-last-message)
        last_message="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  printf 'call\n' >> "$MOCK_CALLS_FILE"
  printf '%s\n' "$prompt" >> "$MOCK_PROMPTS_FILE"
  local call_count
  call_count="$(wc -l < "$MOCK_CALLS_FILE" | tr -d ' ')"

  # codex exec logs echo the user prompt, including the completion marker.
  printf 'user\nIf complete, emit <promise>COMPLETE</promise>\n'

  if [[ "$MOCK_MODE" == "empty" ]]; then
    : > "$last_message"
  elif [[ "$MOCK_MODE" == "complete-on-second" && "$call_count" -eq 2 ]]; then
    printf '<promise>COMPLETE</promise>\n' > "$last_message"
  else
    printf 'NOT_DONE\n' > "$last_message"
  fi
}
export -f codex

make_fixture() {
  local fixture_root="$1"
  mkdir -p "$fixture_root/scripts/ralph"
  printf '{}\n' > "$fixture_root/scripts/ralph/prd.json"
  printf '# Test instructions\n' > "$fixture_root/scripts/ralph/CLAUDE.md"
}

never_root="$TEST_ROOT/never"
make_fixture "$never_root"
export MOCK_MODE="never"
export MOCK_CALLS_FILE="$never_root/calls.txt"
export MOCK_PROMPTS_FILE="$never_root/prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
never_output="$(cd "$never_root" && bash "$RUNNER" 3)"
grep -Fq 'completed=0' <<< "$never_output"
grep -Fq 'iterationsRun=3' <<< "$never_output"
grep -Fq 'You are the implementation worker for exactly one Ralph iteration.' "$MOCK_PROMPTS_FILE"
grep -Fq 'Do not invoke the ralph-run skill' "$MOCK_PROMPTS_FILE"

second_root="$TEST_ROOT/second"
make_fixture "$second_root"
export MOCK_MODE="complete-on-second"
export MOCK_CALLS_FILE="$second_root/calls.txt"
export MOCK_PROMPTS_FILE="$second_root/prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
second_output="$(cd "$second_root" && bash "$RUNNER" 3)"
grep -Fq 'completed=1' <<< "$second_output"
grep -Fq 'iterationsRun=2' <<< "$second_output"

empty_root="$TEST_ROOT/empty"
make_fixture "$empty_root"
export MOCK_MODE="empty"
export MOCK_CALLS_FILE="$empty_root/calls.txt"
export MOCK_PROMPTS_FILE="$empty_root/prompts.txt"
: > "$MOCK_CALLS_FILE"
: > "$MOCK_PROMPTS_FILE"
set +e
empty_output="$(cd "$empty_root" && bash "$RUNNER" 3 2>&1)"
empty_status=$?
set -e
[[ "$empty_status" -eq 1 ]]
grep -Fq 'returned no final message in iteration 1' <<< "$empty_output"
[[ "$(wc -l < "$MOCK_CALLS_FILE" | tr -d ' ')" -eq 1 ]]

set +e
nested_output="$(cd "$never_root" && RALPH_RUN_ACTIVE=1 bash "$RUNNER" 3 2>&1)"
nested_status=$?
set -e
[[ "$nested_status" -eq 1 ]]
grep -Fq 'refusing to start a nested Ralph runner' <<< "$nested_output"

printf 'PASS: completion, empty output, worker prompt, and recursion guard.\n'
