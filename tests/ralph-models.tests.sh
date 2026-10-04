#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MODELS="$ROOT/skills/ralph-run/scripts/ralph_models.py"
export HOME="$TEST_ROOT/home"
unset CODEX_HOME RALPH_MODEL RALPH_REVIEW_MODEL RALPH_EFFORT RALPH_REVIEW_EFFORT
mkdir -p "$HOME/.codex" "$HOME/.cursor" "$HOME/.gemini/antigravity-cli"

# resolved AGENT [ENV...]: prints "worker|reviewer" models as the runner would use them.
resolved() {
  local agent="$1"
  shift
  env "$@" python3 "$MODELS" resolve --agent "$agent" | sed -n 1,2p | paste -sd '|'
}

# efforts AGENT [ENV...]: prints "worker|reviewer" reasoning efforts as the runner would use them.
efforts() {
  local agent="$1"
  shift
  env "$@" python3 "$MODELS" resolve --agent "$agent" | sed -n 3,4p | paste -sd '|'
}

expect_error() {
  local expected="$1"
  local output
  shift
  if output="$("$@" 2>&1)"; then
    echo "expected failure: $*" >&2
    exit 1
  fi
  grep -Fq -- "$expected" <<< "$output"
}

# Without any setting every agent keeps its CLI's default model.
for agent in codex cursor antigravity; do
  [[ "$(resolved "$agent")" == "|" ]]
  # resolve always prints the two models and then the two efforts.
  [[ "$(python3 "$MODELS" resolve --agent "$agent" | wc -l)" -eq 4 ]]
  [[ "$(efforts "$agent")" == "|" ]]
  # An empty override in the environment means "not set".
  [[ "$(resolved "$agent" RALPH_MODEL= RALPH_REVIEW_MODEL=)" == "|" ]]
  python3 "$MODELS" check --agent "$agent"
done

# Each agent reads its own settings file.
printf '{"model": "codex-worker", "review_model": "codex-reviewer"}\n' > "$HOME/.codex/ralph.json"
printf '{"model": "claude-opus-5-thinking-high"}\n' > "$HOME/.cursor/ralph.json"
printf '{"review_model": "gemini-3.1-pro-high"}\n' > "$HOME/.gemini/antigravity-cli/ralph.json"
[[ "$(resolved codex)" == "codex-worker|codex-reviewer" ]]
# The reviewer falls back to the worker's model.
[[ "$(resolved cursor)" == "claude-opus-5-thinking-high|claude-opus-5-thinking-high" ]]
# Only a reviewer default: workers keep the CLI default.
[[ "$(resolved antigravity)" == "|gemini-3.1-pro-high" ]]
# An empty override in the environment still falls back to the saved default.
[[ "$(resolved cursor RALPH_MODEL=)" == "claude-opus-5-thinking-high|claude-opus-5-thinking-high" ]]
[[ "$(resolved antigravity RALPH_REVIEW_MODEL=)" == "|gemini-3.1-pro-high" ]]

# An unknown agent is an error, never another agent's settings (the CLI only offers known agents).
python3 -B - "$ROOT/skills/ralph-run/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import ralph_models
for agent in ('gemini', 'Cursor', '', None):
    for function in (ralph_models.settings_path, ralph_models.saved, ralph_models.resolve,
                     ralph_models.resolve_efforts):
        try:
            function(agent)
        except ValueError as exc:
            assert str(exc) == f'unknown agent: {agent!r}', exc
        else:
            raise AssertionError(f'{function.__name__} accepted the agent {agent!r}')
PY

# Run overrides win over saved defaults, each role on its own.
[[ "$(resolved codex RALPH_MODEL=run-worker)" == "run-worker|codex-reviewer" ]]
[[ "$(resolved codex RALPH_REVIEW_MODEL=run-reviewer)" == "codex-worker|run-reviewer" ]]
[[ "$(resolved cursor RALPH_MODEL=gpt-5.3-codex)" == "gpt-5.3-codex|gpt-5.3-codex" ]]
[[ "$(resolved antigravity RALPH_MODEL=gemini-3.8-flash-high)" == "gemini-3.8-flash-high|gemini-3.1-pro-high" ]]
# Parameterized model names are accepted.
[[ "$(resolved cursor 'RALPH_MODEL=model[effort=high]')" == "model[effort=high]|model[effort=high]" ]]

# Codex follows CODEX_HOME, like the rest of the Codex setup.
mkdir -p "$TEST_ROOT/app-home"
printf '{"model": "app-worker"}\n' > "$TEST_ROOT/app-home/ralph.json"
[[ "$(resolved codex CODEX_HOME="$TEST_ROOT/app-home")" == "app-worker|app-worker" ]]

# Invalid settings are errors for both check and resolve, never ignored.
cursor_settings="$HOME/.cursor/ralph.json"
while IFS='|' read -r content expected; do
  printf '%s\n' "$content" > "$cursor_settings"
  expect_error "$expected" python3 "$MODELS" check --agent cursor
  expect_error "$expected" python3 "$MODELS" resolve --agent cursor
done <<'CASES'
{broken|invalid Ralph model settings
[]|Ralph model settings must be a JSON object
{"model": ""}|is not a valid model name
{"model": 5}|is not a valid model name
{"model": "has space"}|is not a valid model name
{"model": "-starts-with-dash"}|is not a valid model name
{"worker_model": "x"}|unknown keys in Ralph model settings
CASES
rm "$cursor_settings"
expect_error 'the run model is not a valid model name' \
  env RALPH_MODEL='bad model' python3 "$MODELS" resolve --agent cursor
expect_error 'the run review model is not a valid model name' \
  env RALPH_REVIEW_MODEL='--flag' python3 "$MODELS" resolve --agent cursor
# A settings path that is not a readable file is an error.
mkdir "$cursor_settings"
expect_error 'invalid Ralph model settings' python3 "$MODELS" check --agent cursor
rmdir "$cursor_settings"

# Codex reasoning effort: saved defaults, the reviewer falling back to the worker's, run
# overrides per role, and empty overrides meaning "not set". Efforts leave the models alone.
codex_settings="$HOME/.codex/ralph.json"
printf '{"effort": "high", "review_effort": "xhigh"}\n' > "$codex_settings"
python3 "$MODELS" check --agent codex
[[ "$(efforts codex)" == "high|xhigh" ]]
[[ "$(resolved codex)" == "|" ]]
[[ "$(efforts codex RALPH_EFFORT=low)" == "low|xhigh" ]]
[[ "$(efforts codex RALPH_REVIEW_EFFORT=max)" == "high|max" ]]
[[ "$(efforts codex RALPH_EFFORT= RALPH_REVIEW_EFFORT=)" == "high|xhigh" ]]
printf '{"model": "gpt-6-sol", "effort": "high"}\n' > "$codex_settings"
[[ "$(efforts codex)" == "high|high" ]]
[[ "$(resolved codex)" == "gpt-6-sol|gpt-6-sol" ]]
[[ "$(efforts codex RALPH_EFFORT=medium)" == "medium|medium" ]]
printf '{"review_effort": "medium"}\n' > "$codex_settings"
[[ "$(efforts codex)" == "|medium" ]]
rm "$codex_settings"
[[ "$(efforts codex RALPH_EFFORT=xhigh)" == "xhigh|xhigh" ]]
[[ "$(efforts codex RALPH_REVIEW_EFFORT=low)" == "|low" ]]

# Cursor and agy take the effort in the model name: an effort for them is an error, saved or run.
for agent in cursor antigravity; do
  for variable in RALPH_EFFORT RALPH_REVIEW_EFFORT; do
    expect_error 'only Codex takes a Ralph reasoning effort' \
      env "$variable=high" python3 "$MODELS" resolve --agent "$agent"
  done
done
printf '{"model": "claude-opus-5-5-high", "effort": "high"}\n' > "$cursor_settings"
expect_error 'only Codex takes a Ralph reasoning effort' python3 "$MODELS" check --agent cursor
expect_error 'only Codex takes a Ralph reasoning effort' python3 "$MODELS" resolve --agent cursor
rm "$cursor_settings"

# Invalid efforts are errors, never passed to Codex or ignored.
while IFS='|' read -r content expected; do
  printf '%s\n' "$content" > "$codex_settings"
  expect_error "$expected" python3 "$MODELS" check --agent codex
  expect_error "$expected" python3 "$MODELS" resolve --agent codex
done <<'CASES'
{"effort": ""}|is not a valid reasoning effort
{"effort": 5}|is not a valid reasoning effort
{"effort": "High"}|is not a valid reasoning effort
{"review_effort": "x high"}|is not a valid reasoning effort
{"effort": "high\""}|is not a valid reasoning effort
{"reasoning_effort": "high"}|unknown keys in Ralph model settings
CASES
rm "$codex_settings"
expect_error 'the run effort is not a valid reasoning effort' \
  env RALPH_EFFORT='high"' python3 "$MODELS" resolve --agent codex
expect_error 'the run review effort is not a valid reasoning effort' \
  env RALPH_REVIEW_EFFORT='-c' python3 "$MODELS" resolve --agent codex

printf '%s\n' 'PASS: Ralph model and Codex effort defaults, run overrides, empty overrides, reviewer fallback, unknown agents, and invalid settings.'
