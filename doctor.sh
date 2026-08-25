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

check_command codex
check_command bun
check_command git

for skill_name in gstack-plan-eng-review gstack-review prd ralph ralph-bootstrap ralph-run; do
  check_skill "$skill_name"
done

if [[ -f "$CODEX_DIR/AGENTS.md" ]] && grep -q '^<!-- BEGIN codex-workstation-bootstrap -->$' "$CODEX_DIR/AGENTS.md"; then
  pass "shared AGENTS.md guidance"
else
  fail "shared AGENTS.md guidance is missing"
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
