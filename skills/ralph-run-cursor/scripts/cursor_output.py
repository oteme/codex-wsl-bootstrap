#!/usr/bin/env python3
"""Read Cursor CLI stream-json output for the Ralph loop.

`worker EVENTS LAST_MESSAGE` writes the final assistant message of a successful run.
`review EVENTS EXPECTED_TREE REVIEW_FILE` writes the reviewer's {approved, findings} JSON only when
the reviewer reported the staged tree it was given; otherwise REVIEW_FILE stays empty so the loop
rejects the review as invalid output.
`review-instructions SCHEMA` prints the reviewer output contract appended to the review prompt.
"""
import json
from pathlib import Path
import re
import sys


def fail(message):
    print(f'error: {message}')
    raise SystemExit(1)


def final_message(events_path):
    events = []
    for number, line in enumerate(Path(events_path).read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            fail(f'Cursor stream line {number} is not JSON')
        if not isinstance(event, dict):
            fail(f'Cursor stream line {number} is not an object')
        events.append(event)
    if not events:
        fail('Cursor produced no stream events')
    result = events[-1]
    if (result.get('type') != 'result' or result.get('subtype') != 'success'
            or result.get('is_error') is not False):
        fail('Cursor did not finish successfully: ' + json.dumps(result, ensure_ascii=False)[:300])
    assistant = [event for event in events if event.get('type') == 'assistant']
    if not assistant:
        return ''
    content = (assistant[-1].get('message') or {}).get('content') or []
    return ''.join(part.get('text', '') for part in content
                   if isinstance(part, dict) and part.get('type') == 'text')


def review_object(text):
    """Accept exactly one JSON object, bare or as the only fenced block of the message."""
    stripped = text.strip()
    fenced = re.fullmatch(r'```(?:json)?\s*\n(.*)\n```', stripped, re.DOTALL)
    if fenced and '```' not in fenced.group(1):
        stripped = fenced.group(1).strip()
    try:
        value = json.loads(stripped)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def main(argv):
    if len(argv) == 3 and argv[0] == 'worker':
        Path(argv[2]).write_text(final_message(argv[1]))
        return 0
    if len(argv) == 4 and argv[0] == 'review':
        events, expected_tree, review_file = argv[1:]
        review = review_object(final_message(events))
        if review is None:
            print('error: the reviewer did not reply with exactly one JSON object')
            return 0
        if review.pop('reviewed_tree', None) != expected_tree:
            print(f'error: the reviewer did not report the staged tree {expected_tree}')
            return 0
        Path(review_file).write_text(json.dumps(review, ensure_ascii=False) + '\n')
        return 0
    if len(argv) == 2 and argv[0] == 'review-instructions':
        schema = json.loads(Path(argv[1]).read_text())
        print('Before judging, run "git write-tree" in that worktree and report its exact output as '
              'reviewed_tree.\nYour final message must be exactly one JSON object, with no other '
              'text, matching this JSON Schema:\n' + json.dumps(schema, ensure_ascii=False))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
