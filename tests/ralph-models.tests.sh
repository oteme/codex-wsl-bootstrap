#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MODELS="$ROOT/skills/ralph-run/scripts/ralph_models.py"
export HOME="$TEST_ROOT/home"
unset CODEX_HOME RALPH_MODEL RALPH_REVIEW_MODEL
mkdir -p "$HOME/.codex" "$HOME/.cursor" "$HOME/.gemini/antigravity-cli"

# resolved AGENT [ENV...]: prints "worker|reviewer" as the runner would use them.
resolved() {
  local agent="$1"
  shift
  env "$@" python3 "$MODELS" resolve --agent "$agent" | paste -sd '|'
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
    for function in (ralph_models.settings_path, ralph_models.saved, ralph_models.resolve):
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

printf '%s\n' 'PASS: Ralph model defaults, run overrides, empty overrides, reviewer fallback, unknown agents, and invalid settings.'
