#!/usr/bin/env bash
set -euo pipefail

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SKILLS_DIR="$CODEX_DIR/skills"
failures=0
skip_login=0

case "${1:-}" in
  "") ;;
  --skip-login) skip_login=1 ;;
  *) echo "Usage: ./doctor.sh [--skip-login]" >&2; exit 2 ;;
esac

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

  for skill_name in gstack-plan-eng-review gstack-review go-backend prd ralph ralph-bootstrap ralph-run; do
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
  check_text "$codex_dir/AGENTS.md" '## Fail-close and clean-break' \
    "${label}shared fail-close/clean-break guidance"
  check_text "$codex_dir/AGENTS.md" '## Go backend' \
    "${label}shared Go backend routing"

  local rtk_hook_dir="$codex_dir/hooks/rtk-safe"
  check_file "$rtk_hook_dir/rtk-codex-safe-hook.py" "${label}Codex RTK Safe Hook"
  check_file "$rtk_hook_dir/test.sh" "${label}Codex RTK Safe Hook regression test"
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

  if [[ -x "$rtk_hook_dir/test.sh" ]]; then
    local rtk_regression_output
    if rtk_regression_output="$("$rtk_hook_dir/test.sh" 2>&1)"; then
      pass "${label}Codex RTK Safe Hook regression"
    else
      fail "${label}Codex RTK Safe Hook regression failed"
      [[ -n "$rtk_regression_output" ]] && printf '%s\n' "$rtk_regression_output" >&2
    fi
  fi
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

check_codex_home "$CODEX_DIR" "CLI "

if [[ -n "${CODEX_APP_HOME:-}" ]] && [[ "$(realpath -m "$CODEX_APP_HOME")" != "$(realpath -m "$CODEX_DIR")" ]]; then
  check_codex_home "$(realpath -m "$CODEX_APP_HOME")" "App "
fi

if [[ "$skip_login" -eq 0 ]]; then
  if command -v codex >/dev/null 2>&1 && codex login status >/dev/null 2>&1; then
    pass "Codex login"
  else
    fail "Codex login required: codex login --device-auth"
  fi
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\nDoctor found %d problem(s).\n' "$failures" >&2
  exit 1
fi

printf '\nEverything is ready.\n'
