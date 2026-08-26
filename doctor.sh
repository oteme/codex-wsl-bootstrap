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
  [[ -f "$SKILLS_DIR/$skill_name/SKILL.md" ]] \
    && pass "skill: $skill_name" \
    || fail "skill missing: $skill_name"
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

for skill_name in gstack-plan-eng-review gstack-review go-backend prd ralph ralph-bootstrap ralph-run; do
  check_skill "$skill_name"
done

check_file "$SKILLS_DIR/go-backend/references/clean-architecture.md" \
  'go-backend clean architecture rules'
check_file "$SKILLS_DIR/go-backend/references/api-design.md" \
  'go-backend API rules'
check_file "$SKILLS_DIR/go-backend/references/database-and-migrations.md" \
  'go-backend database rules'

check_text "$SKILLS_DIR/prd/SKILL.md" \
  '## Fail-close and clean-break requirements' \
  'prd fail-close/clean-break policy'
check_text "$SKILLS_DIR/ralph/SKILL.md" \
  '## Preserve failure and removal semantics' \
  'ralph fail-close/clean-break policy'
check_file "$SKILLS_DIR/ralph-run/scripts/ralph-state.py" 'ralph state gate'
check_file "$SKILLS_DIR/ralph-run/assets/policy-review.schema.json" 'ralph review schema'

if [[ -f "$CODEX_DIR/AGENTS.md" ]] && grep -q '^<!-- BEGIN codex-workstation-bootstrap -->$' "$CODEX_DIR/AGENTS.md"; then
  pass "shared AGENTS.md guidance"
else
  fail "shared AGENTS.md guidance is missing"
fi

check_text "$CODEX_DIR/AGENTS.md" '## Fail-close and clean-break' \
  'shared fail-close/clean-break guidance'
check_text "$CODEX_DIR/AGENTS.md" '## Go backend' \
  'shared Go backend routing'

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
