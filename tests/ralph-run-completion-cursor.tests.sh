#!/usr/bin/env bash
set -euo pipefail
# The completion scenarios, run against the Cursor runner and a fake agent CLI.
RALPH_TEST_AGENT=cursor exec bash "$(dirname "${BASH_SOURCE[0]}")/ralph-run-completion.tests.sh"
