#!/usr/bin/env python3
"""Read Antigravity CLI (agy) JSON output for the Ralph loop.

`worker REPLY STDERR LAST_MESSAGE` writes the response of a successful run.
`review REPLY STDERR EXPECTED_TREE REVIEW_FILE` writes the reviewer's {approved, findings} JSON only
when the reviewer reported the staged tree it was given; otherwise REVIEW_FILE stays empty so the
loop rejects the review as invalid output.

agy exits 0 even when headless mode auto-denies a tool it could not ask about, so a run whose stderr
reports an auto-denied tool is a failure, not a result.
"""
import json
from pathlib import Path
import sys

AUTO_DENIED = 'auto-denied'


def fail(message):
    print(f'error: {message}')
    raise SystemExit(1)


def successful_reply(reply_path, stderr_path):
    if AUTO_DENIED in Path(stderr_path).read_text(errors='replace'):
        fail('Antigravity auto-denied a tool in headless mode; see the log above')
    try:
        reply = json.loads(Path(reply_path).read_text())
    except ValueError:
        fail('Antigravity did not print a JSON result')
    if not isinstance(reply, dict):
        fail('Antigravity printed a non-object result')
    if reply.get('status') != 'SUCCESS':
        fail(f"Antigravity finished with status {reply.get('status')!r}: {reply.get('error', '')}")
    return reply


def main(argv):
    if len(argv) == 4 and argv[0] == 'worker':
        response = successful_reply(argv[1], argv[2]).get('response')
        if not isinstance(response, str):
            fail('Antigravity result has no response text')
        Path(argv[3]).write_text(response)
        return 0
    if len(argv) == 5 and argv[0] == 'review':
        reply_path, stderr_path, expected_tree, review_file = argv[1:]
        review = successful_reply(reply_path, stderr_path).get('structured_output')
        if not isinstance(review, dict):
            print('error: the reviewer returned no structured output')
            return 0
        if review.pop('reviewed_tree', None) != expected_tree:
            print(f'error: the reviewer did not report the staged tree {expected_tree}')
            return 0
        Path(review_file).write_text(json.dumps(review, ensure_ascii=False) + '\n')
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
