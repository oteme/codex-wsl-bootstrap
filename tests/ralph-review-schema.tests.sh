#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The Cursor and Antigravity reviewers answer to copies of the policy review schema that add only
# reviewed_tree, and ralph-state.py accepts the same finding categories. A change to the policy
# must reach all of them.
python3 - "$ROOT" <<'PY'
import json
import runpy
import sys
from pathlib import Path

root = Path(sys.argv[1])
base = json.loads((root / "skills/ralph-run/assets/policy-review.schema.json").read_text())
for agent in ("cursor", "antigravity"):
    path = root / f"skills/ralph-run-{agent}/assets/policy-review-reviewed-tree.schema.json"
    extended = json.loads(path.read_text())
    tree = extended["properties"].pop("reviewed_tree")
    assert tree == {"type": "string", "pattern": "^([0-9a-f]{40}|[0-9a-f]{64})$"}, (path, tree)
    extended["required"].remove("reviewed_tree")
    assert extended == base, f"{path} is not the policy review schema plus reviewed_tree"

categories = base["properties"]["findings"]["items"]["properties"]["category"]["enum"]
state = runpy.run_path(str(root / "skills/ralph-run/scripts/ralph-state.py"))
assert set(categories) == state["REVIEW_CATEGORIES"], (categories, state["REVIEW_CATEGORIES"])
PY

printf 'PASS: reviewed-tree schemas and ralph-state.py follow the policy review schema.\n'
