#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"
export PATH="$TEST_ROOT/bin:$PATH"
# Fake CLIs print what the test puts in FAKE_* and exit with FAKE_STATUS.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  --version) printf "%s\n" "$FAKE_VERSION" ;;' \
  '  "status --format json") printf "%s\n" "$FAKE_STATUS_JSON"; exit "${FAKE_STATUS:-0}" ;;' \
  '  *) exit 90 ;;' \
  'esac' > "$TEST_ROOT/bin/agent"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  --version) printf "%s\n" "$FAKE_VERSION" ;;' \
  '  "-p /usage --output-format json") printf "%s\n" "$FAKE_STATUS_JSON"; exit "${FAKE_STATUS:-0}" ;;' \
  '  *) exit 90 ;;' \
  'esac' > "$TEST_ROOT/bin/agy"
chmod 0755 "$TEST_ROOT/bin/agent" "$TEST_ROOT/bin/agy"

# shellcheck source=../scripts/agent-cli.sh
source "$ROOT/scripts/agent-cli.sh"

expect_failure() {
  if "$@"; then
    echo "expected failure: $*" >&2
    exit 1
  fi
}

version_at_least 1.2.13 1.2.13
version_at_least 1.10.0 1.2.13
expect_failure version_at_least 1.2.9 1.2.13
version_at_least 2026.10.01 2026.09.28
expect_failure version_at_least 2026.09.27 2026.09.28

export FAKE_VERSION="2026.09.28-64d2043"
[[ "$(cursor_version)" == "2026.09.28" ]]
for version in "2026.9.28-64d2043" "2026.09.28" "v2026.09.28-64d2043" ""; do
  FAKE_VERSION="$version" expect_failure cursor_version
done

export FAKE_VERSION="1.2.13"
[[ "$(antigravity_version)" == "1.2.13" ]]
for version in "v1.2.13" "1.2" "1.2.13-beta" ""; do
  FAKE_VERSION="$version" expect_failure antigravity_version
done

FAKE_STATUS_JSON='{"status":"authenticated","isAuthenticated":true}' cursor_logged_in
FAKE_STATUS_JSON='{"status":"unauthenticated","isAuthenticated":false}' expect_failure cursor_logged_in
FAKE_STATUS_JSON='not json' expect_failure cursor_logged_in
FAKE_STATUS_JSON='{"isAuthenticated":true}' FAKE_STATUS=1 expect_failure cursor_logged_in

FAKE_STATUS_JSON='{"status":"SUCCESS","command":{"name":"usage"}}' antigravity_logged_in
FAKE_STATUS_JSON='{"status":"ERROR","error":"authentication failed or timed out"}' \
  expect_failure antigravity_logged_in
FAKE_STATUS_JSON='not json' expect_failure antigravity_logged_in
FAKE_STATUS_JSON='{"status":"SUCCESS"}' FAKE_STATUS=1 expect_failure antigravity_logged_in

# AGENT_SIGN_IN_TIMEOUT bounds both sign-in probes: a CLI that does not answer in time counts as
# signed out, even when it would report a session later.
[[ "$AGENT_SIGN_IN_TIMEOUT" == 30 ]]
AGENT_SIGN_IN_TIMEOUT=1
mkdir -p "$TEST_ROOT/hanging-bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$*" == "status --format json" ]] || exit 90' \
  'sleep 60' \
  'printf "%s\n" "{\"isAuthenticated\":true}"' > "$TEST_ROOT/hanging-bin/agent"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$*" == "-p /usage --output-format json" ]] || exit 90' \
  'sleep 60' \
  'printf "%s\n" "{\"status\":\"SUCCESS\"}"' > "$TEST_ROOT/hanging-bin/agy"
chmod 0755 "$TEST_ROOT/hanging-bin/agent" "$TEST_ROOT/hanging-bin/agy"
# Milliseconds since boot, with centisecond resolution. Unlike the wall clock, which WSL steps back
# by seconds, it only moves forward.
uptime_ms() {
  local uptime
  read -r uptime _ < /proc/uptime
  printf '%s\n' "$(( 10#${uptime/./} * 10 ))"
}
for probe in cursor_logged_in antigravity_logged_in; do
  started="$(uptime_ms)"
  PATH="$TEST_ROOT/hanging-bin:$PATH" expect_failure "$probe"
  elapsed_ms=$(( $(uptime_ms) - started ))
  # At least the timeout (the probe reached the hanging CLI), and well under the CLI's 60 s.
  if (( elapsed_ms < 900 || elapsed_ms > 5000 )); then
    echo "$probe took ${elapsed_ms} ms with AGENT_SIGN_IN_TIMEOUT=1" >&2
    exit 1
  fi
done

printf '%s\n' 'PASS: agent CLI version parsing, minimum versions, and sign-in checks.'
