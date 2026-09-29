# Cursor CLI (agent) and Antigravity CLI (agy) checks shared by install.sh and doctor.sh.

# Minimum versions verified on 2026-09-29: sessionStart context, preToolUse rewrites with failClosed,
# stream-json results and --resume for Cursor; exact-name skills.json excludes, PreToolUse overwrite,
# ANTIGRAVITY_CONVERSATION_ID and an unlimited default print timeout for agy.
CURSOR_MIN_VERSION="2026.09.28"
ANTIGRAVITY_MIN_VERSION="1.2.13"

version_at_least() {
  local actual="$1"
  local minimum="$2"
  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n 1)" == "$minimum" ]]
}

# Cursor prints YYYY.MM.DD-<build>; the date is its comparable version.
cursor_version() {
  local version
  version="$(agent --version 2>/dev/null | head -n 1)"
  [[ "$version" =~ ^([0-9]{4}\.[0-9]{2}\.[0-9]{2})-[0-9a-f]+$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

antigravity_version() {
  local version
  version="$(agy --version 2>/dev/null | head -n 1)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

# Unreadable status output counts as signed out.
json_field_is() {
  python3 -c '
import json, sys
try:
    value = json.loads(sys.argv[1]).get(sys.argv[2])
except (ValueError, AttributeError):
    sys.exit(1)
sys.exit(0 if json.dumps(value) == sys.argv[3] else 1)
' "$@"
}

cursor_logged_in() {
  local reply
  reply="$(agent status --format json < /dev/null 2>/dev/null)" || return 1
  json_field_is "$reply" isAuthenticated true
}

antigravity_logged_in() {
  # /usage answers without a model turn; without a session agy waits for a sign-in, so it is bounded.
  local reply
  reply="$(cd "$HOME" && timeout 30 agy -p "/usage" --output-format json < /dev/null 2>/dev/null)" || return 1
  json_field_is "$reply" status '"SUCCESS"'
}
