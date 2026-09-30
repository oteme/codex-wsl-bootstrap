#!/usr/bin/env bash
set -euo pipefail

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SKILLS_DIR="$CODEX_DIR/skills"
if ! command -v node >/dev/null || ! command -v npx >/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
fi
# The Cursor and Antigravity installers put agent and agy in ~/.local/bin. Appending keeps any
# command already on PATH first.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$PATH:$HOME/.local/bin" ;;
esac
# shellcheck source=scripts/agent-cli.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/agent-cli.sh"
failures=0
skip_login=0
check_browser=0

for arg in "$@"; do
case "$arg" in
  "") ;;
  --skip-login) skip_login=1 ;;
  --check-browser=9222) check_browser=9222 ;;
  --check-browser=9223) check_browser=9223 ;;
  *) echo "Usage: ./doctor.sh [--skip-login] [--check-browser=9222|--check-browser=9223]" >&2; exit 2 ;;
esac
done

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'fail %s\n' "$1" >&2; failures=$((failures + 1)); }

check_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name: $($command_name --version 2>/dev/null | head -n 1)"
  else
    fail "$command_name is not on PATH"
  fi
}

check_skill() {
  local skill_name="$1"
  local skills_dir="${2:-$SKILLS_DIR}"
  local label="${3:-}"
  [[ -f "$skills_dir/$skill_name/SKILL.md" ]] \
    && pass "${label}skill: $skill_name" \
    || fail "${label}skill missing: $skill_name"
}

check_codex_home() {
  local codex_dir="$1"
  local label="$2"
  local skills_dir="$codex_dir/skills"

  for skill_name in gstack-plan-eng-review gstack-review go-backend orca-cli computer-use prd ralph ralph-bootstrap ralph-run; do
    check_skill "$skill_name" "$skills_dir" "$label"
  done

  if [[ -f "$codex_dir/AGENTS.md" ]] && grep -q '^<!-- BEGIN codex-workstation-bootstrap -->$' "$codex_dir/AGENTS.md"; then
    pass "${label}shared AGENTS.md guidance"
  else
    fail "${label}shared AGENTS.md guidance is missing"
  fi

  check_file "$skills_dir/go-backend/references/clean-architecture.md" \
    "${label}go-backend clean architecture rules"
  check_file "$skills_dir/go-backend/references/api-design.md" \
    "${label}go-backend API rules"
  check_file "$skills_dir/go-backend/references/database-and-migrations.md" \
    "${label}go-backend database rules"
  check_text "$skills_dir/prd/SKILL.md" \
    '## Fail-close and clean-break requirements' \
    "${label}prd fail-close/clean-break policy"
  check_text "$skills_dir/ralph/SKILL.md" \
    '## Preserve failure and removal semantics' \
    "${label}ralph fail-close/clean-break policy"
  check_file "$skills_dir/ralph-run/scripts/ralph-state.py" "${label}ralph state gate"
  check_file "$skills_dir/ralph-run/assets/policy-review.schema.json" "${label}ralph review schema"
  check_file "$skills_dir/ralph-run/assets/worker-protocol.md" "${label}ralph worker protocol"
  check_text "$codex_dir/AGENTS.md" '## Fail-close and clean-break' \
    "${label}shared fail-close/clean-break guidance"
  check_text "$codex_dir/AGENTS.md" '## Go backend' \
    "${label}shared Go backend routing"

  local rtk_hook_dir="$codex_dir/hooks/rtk-safe"
  check_file "$rtk_hook_dir/rtk-codex-safe-hook.py" "${label}Codex RTK Safe Hook"
  check_file "$rtk_hook_dir/rtk-version" "${label}Codex RTK pinned version"
  check_text "$codex_dir/hooks.json" 'rtk-codex-safe-hook.py' "${label}Codex RTK PreToolUse registration"

  if [[ -f "$rtk_hook_dir/rtk-version" ]] && command -v rtk >/dev/null 2>&1; then
    local expected_rtk_version actual_rtk_version
    expected_rtk_version="$(tr -d '[:space:]' < "$rtk_hook_dir/rtk-version")"
    actual_rtk_version="$(rtk --version 2>/dev/null | awk '{print $2}')"
    if [[ -n "$expected_rtk_version" && "$actual_rtk_version" == "$expected_rtk_version" ]]; then
      pass "${label}RTK pinned version: $actual_rtk_version"
    else
      fail "${label}RTK version mismatch: expected $expected_rtk_version, got ${actual_rtk_version:-unknown}"
    fi
  fi

  check_ralph_models codex "$label" "$codex_dir"

  check_hook_regression "$rtk_hook_dir/test.sh" "${label}Codex RTK Safe Hook regression"
}

check_agent_version() {
  local label="$1"
  local version_function="$2"
  local minimum="$3"
  local version=""
  if version="$("$version_function")" && version_at_least "$version" "$minimum"; then
    pass "$label version: $version (minimum $minimum)"
  else
    fail "$label version ${version:-unrecognized} is older than the verified minimum $minimum"
  fi
}

check_hook_regression() {
  local test_script="$1"
  local label="$2"
  local output
  if [[ ! -e "$test_script" ]]; then
    fail "$label missing: $test_script"
  elif [[ ! -x "$test_script" ]]; then
    fail "$label not executable: $test_script"
  elif output="$("$test_script" 2>&1)"; then
    pass "$label"
  else
    fail "$label failed"
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
  fi
}

# check_hook_registration LABEL COMMAND...: COMMAND is an installer run with --verify.
check_hook_registration() {
  local label="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    pass "$label hook registrations"
  else
    fail "$label hook registrations: ${output#error: }"
  fi
}

check_chrome_servers() {
  local config="$1"
  local label="$2"
  if python3 - "$config" <<'PY'
import json, sys
servers = json.load(open(sys.argv[1])).get("mcpServers", {})
for name, port in (("chrome-devtools", 9222), ("chrome-devtools-9223", 9223)):
    expected = ["-y", "chrome-devtools-mcp@latest", f"--browser-url=http://127.0.0.1:{port}"]
    server = servers.get(name) or {}
    if server.get("command") != "npx" or server.get("args") != expected:
        sys.exit(1)
PY
  then
    pass "$label Chrome MCP registrations: 9222 + 9223"
  else
    fail "$label Chrome MCP registrations are missing or different: $config"
  fi
}

check_ralph_runtime() {
  local skill_dir="$1"
  local agent="$2"
  local label="$3"
  if python3 "$skill_dir/scripts/ralph_runtime.py" --expect "$agent" >/dev/null 2>&1; then
    pass "$label Ralph runtime record"
  else
    fail "$label Ralph runtime record is missing or invalid: $skill_dir/scripts/$agent-runtime.json"
  fi
}

# An absent settings file is fine; an invalid one would stop every Ralph run of that agent.
check_ralph_models() {
  local agent="$1"
  local label="$2"
  local codex_home="${3:-}"
  local output
  if output="$(CODEX_HOME="$codex_home" python3 \
    "$(dirname "${BASH_SOURCE[0]}")/skills/ralph-run/scripts/ralph_models.py" check --agent "$agent" 2>&1)"; then
    pass "${label}Ralph model settings"
  else
    fail "${label}Ralph model settings are invalid: ${output#error: }"
  fi
}

check_cursor_home() {
  local cursor_dir="$HOME/.cursor"
  local managed="$cursor_dir/hooks/codex-workstation-bootstrap"
  check_file "$managed/rtk-cursor-safe-hook.py" "Cursor RTK Safe Hook"
  check_file "$managed/rtk-codex-safe-hook.py" "Cursor RTK Safe Hook rules"
  check_text "$managed/guidance.md" '<!-- BEGIN codex-workstation-bootstrap -->' "Cursor shared guidance"
  check_hook_registration "Cursor" python3 "$(dirname "${BASH_SOURCE[0]}")/scripts/install-cursor.py" --cursor-dir "$cursor_dir" \
    --hook-source-dir "$(dirname "${BASH_SOURCE[0]}")/hooks" --verify
  if printf '%s' '{"hook_event_name":"sessionStart","session_id":"doctor","conversation_id":"doctor"}' \
    | /usr/bin/python3 -B "$managed/cursor-session-guidance.py" 2>/dev/null \
    | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin).get("additional_context", "").strip() else 1)'; then
    pass "Cursor guidance hook"
  else
    fail "Cursor guidance hook does not return the shared guidance"
  fi
  check_hook_regression "$managed/test.sh" "Cursor RTK Safe Hook regression"
  check_chrome_servers "$cursor_dir/mcp.json" "Cursor"
  check_skill ralph-run-cursor "$cursor_dir/skills" "Cursor "
  check_ralph_runtime "$cursor_dir/skills/ralph-run-cursor" cursor "Cursor"
  check_ralph_models cursor "Cursor "
}

check_antigravity_home() {
  local gemini_dir="$HOME/.gemini"
  local managed="$gemini_dir/config/hooks/codex-workstation-bootstrap"
  check_text "$gemini_dir/AGENTS.md" '<!-- BEGIN codex-workstation-bootstrap -->' \
    "Antigravity shared AGENTS.md guidance"
  check_text "$gemini_dir/AGENTS.md" '## Fail-close and clean-break' \
    "Antigravity shared fail-close/clean-break guidance"
  check_file "$managed/rtk-antigravity-safe-hook.py" "Antigravity RTK Safe Hook"
  check_file "$managed/rtk-codex-safe-hook.py" "Antigravity RTK Safe Hook rules"
  check_hook_registration "Antigravity" python3 "$(dirname "${BASH_SOURCE[0]}")/scripts/install-antigravity.py" \
    --gemini-dir "$gemini_dir" --codex-skills-dir "$(realpath -m "$SKILLS_DIR")" \
    --hook-source-dir "$(dirname "${BASH_SOURCE[0]}")/hooks" --verify
  check_hook_regression "$managed/test.sh" "Antigravity RTK Safe Hook regression"
  # Antigravity's own skills directory comes first, so its ralph-run keeps a place in the skill
  # descriptions Antigravity shows the model.
  if python3 - "$gemini_dir/config/skills.json" "$(realpath -m "$SKILLS_DIR")" "$gemini_dir/antigravity-cli/skills" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1])).get("entries", [])
sys.exit(0 if entries[:1] == [{"path": sys.argv[3]}] and {"path": sys.argv[2], "exclude": ["ralph-run"]} in entries else 1)
PY
  then
    pass "Antigravity skills.json registration of its own skills first, then $SKILLS_DIR"
  else
    fail "Antigravity skills.json does not register $gemini_dir/antigravity-cli/skills first and $SKILLS_DIR"
  fi
  check_chrome_servers "$gemini_dir/config/mcp_config.json" "Antigravity"
  check_skill ralph-run "$gemini_dir/antigravity-cli/skills" "Antigravity "
  check_ralph_runtime "$gemini_dir/antigravity-cli/skills/ralph-run" antigravity "Antigravity"
  check_ralph_models antigravity "Antigravity "
}

check_file() {
  local file="$1"
  local label="$2"
  [[ -f "$file" ]] && pass "$label" || fail "$label missing: $file"
}

check_text() {
  local file="$1"
  local expected="$2"
  local label="$3"
  if [[ -f "$file" ]] && grep -Fq "$expected" "$file"; then
    pass "$label"
  else
    fail "$label is missing"
  fi
}

check_command codex
check_command bun
check_command git
check_command python3
check_command rtk
check_command agent
check_command agy
check_agent_version "Cursor CLI" cursor_version "$CURSOR_MIN_VERSION"
check_agent_version "Antigravity CLI" antigravity_version "$ANTIGRAVITY_MIN_VERSION"

source "$(dirname "${BASH_SOURCE[0]}")/scripts/ensure-node.sh"
if validate_chrome_node; then pass "Chrome MCP Node runtime"; else fail "Chrome MCP Node runtime"; fi
chrome_args=(--codex-home "$CODEX_DIR")
if [[ -n "${CODEX_APP_HOME:-}" && "$(realpath -m "$CODEX_DIR")" == "$(realpath -m "$CODEX_APP_HOME")" ]]; then
  chrome_args+=(--app)
fi
[[ "$check_browser" -eq 0 ]] || chrome_args+=(--check-browser "$check_browser")
if ! python3 "$(dirname "${BASH_SOURCE[0]}")/scripts/chrome-devtools-mcp.py" "${chrome_args[@]}"; then
  fail "Chrome MCP verification"
fi

check_codex_home "$CODEX_DIR" "CLI "

if [[ -n "${CODEX_APP_HOME:-}" ]] && [[ "$(realpath -m "$CODEX_APP_HOME")" != "$(realpath -m "$CODEX_DIR")" ]]; then
  check_codex_home "$(realpath -m "$CODEX_APP_HOME")" "App "
  if ! python3 "$(dirname "${BASH_SOURCE[0]}")/scripts/chrome-devtools-mcp.py" --codex-home "$CODEX_APP_HOME" --app; then
    fail "App Chrome MCP verification"
  fi
fi

check_cursor_home
check_antigravity_home

if [[ "$skip_login" -eq 0 ]]; then
  if command -v codex >/dev/null 2>&1 && codex login status >/dev/null 2>&1; then
    pass "Codex login"
  else
    fail "Codex login required: codex login --device-auth"
  fi
  if cursor_logged_in; then
    pass "Cursor CLI login"
  else
    fail "Cursor CLI login required: agent login"
  fi
  printf 'wait Antigravity CLI sign-in check (up to %s s without a session)\n' "$AGENT_SIGN_IN_TIMEOUT"
  if antigravity_logged_in; then
    pass "Antigravity CLI sign-in"
  else
    fail "Antigravity CLI sign-in required: run agy once and follow the prompt"
  fi
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\nDoctor found %d problem(s).\n' "$failures" >&2
  exit 1
fi

if [[ "$check_browser" -eq 0 ]]; then
  printf '\nSetup checks passed. Live Chrome connection was not checked; run doctor.sh --check-browser=9222 or --check-browser=9223 after starting that profile.\n'
else
  printf '\nEverything is ready, including the Chrome connection.\n'
fi
