#!/usr/bin/env bash
set -euo pipefail
# The completion scenarios, run against the Antigravity runner and a fake agy CLI.
RALPH_TEST_AGENT=antigravity exec bash "$(dirname "${BASH_SOURCE[0]}")/ralph-run-completion.tests.sh"
