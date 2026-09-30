#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# The parsers are imported from the repository, which must not receive bytecode.
export PYTHONDONTWRITEBYTECODE=1

# Unit tests for the parsers that turn Cursor and Antigravity CLI output into Ralph results.
python3 -B - "$ROOT/skills/ralph-run-cursor/scripts" "$ROOT/skills/ralph-run-antigravity/scripts" \
  "$TEST_ROOT" <<'PY'
import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys

cursor_scripts, antigravity_scripts, tmp = (Path(arg) for arg in sys.argv[1:4])
sys.path[:0] = [str(cursor_scripts), str(antigravity_scripts)]
import antigravity_output  # noqa: E402
import cursor_output  # noqa: E402

APPROVAL = {'approved': True, 'findings': []}
FINDING = {'category': 'fallback', 'message': 'unexpected fallback', 'evidence': 'app.txt'}


def run(module, *argv):
    """Runs module.main as its command line does; returns the exit status and the printed text."""
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        try:
            status = module.main([str(arg) for arg in argv])
        except SystemExit as exc:
            status = exc.code
    return status, printed.getvalue()


def empty_file(name):
    """An output file as the runner leaves it before each call: present and empty."""
    path = tmp / name
    path.write_text('')
    return path


# cursor_output.review_object: exactly one JSON object, bare or as the only fenced block.
body = json.dumps(APPROVAL)
assert cursor_output.review_object(body) == APPROVAL
for tag in ('json', 'JSON', 'Json', ''):
    assert cursor_output.review_object(f'```{tag}\n{body}\n```') == APPROVAL, tag
rejection = {'approved': False, 'findings': [FINDING]}
assert cursor_output.review_object(json.dumps(rejection)) == rejection
repeated_keys = {
    'a repeated top-level key': '{"approved": false, "findings": [], "approved": true}',
    'a repeated key in a finding': ('{"approved": false, "findings": [{"category": "fallback", '
                                    '"message": "unexpected fallback", "evidence": "app.txt", '
                                    '"evidence": "elsewhere"}]}'),
}
for text in repeated_keys.values():
    json.loads(text)  # valid JSON apart from the repeated key
rejected = {
    'a yaml fence': f'```yaml\n{body}\n```',
    'prose before the fence': f'I read the staged diff.\n```json\n{body}\n```',
    'prose after the fence': f'```json\n{body}\n```\nNo listed policy problem is present.',
    'two fenced blocks': f'```json\n{body}\n```\n```json\n{body}\n```',
    'a top-level array': json.dumps([APPROVAL]),
    'a fenced top-level array': f'```json\n{json.dumps([APPROVAL])}\n```',
    **repeated_keys,
}
for case, text in rejected.items():
    assert cursor_output.review_object(text) is None, case


# cursor_output.final_message: stream-json records end at "\n" only, and the run must end with a
# successful result event.
def events_file(name, *records):
    """A stream-json file as Cursor writes it: one record per line, non-ASCII text unescaped."""
    path = tmp / name
    path.write_text(''.join((record if isinstance(record, str)
                             else json.dumps(record, ensure_ascii=False)) + '\n'
                            for record in records), encoding='utf-8')
    return path


def assistant(text):
    return {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': text}]}}


INIT = {'type': 'system', 'subtype': 'init'}
SUCCESS = {'type': 'result', 'subtype': 'success', 'is_error': False}

separators = 'line separator paragraph\u0085next line'
events = events_file('separators.jsonl', INIT, assistant('Working on it.'), assistant(separators),
                     SUCCESS)
assert all(char in events.read_text(encoding='utf-8') for char in '  \u0085')
last_message = empty_file('separators-last-message.txt')
status, printed = run(cursor_output, 'worker', events, last_message)
assert (status, printed) == (0, ''), ('line separators inside a message', status, printed)
assert last_message.read_text(encoding='utf-8') == separators
assert cursor_output.final_message(events) == separators

cursor_failures = [
    (events_file('not-json.jsonl', INIT, assistant('done'), 'Cursor printed a warning', SUCCESS),
     'error: Cursor stream line 3 is not JSON'),
]
for number, final in enumerate([
    {'type': 'result', 'subtype': 'success', 'is_error': True},
    {'type': 'result', 'subtype': 'error', 'is_error': False},
    {'type': 'result', 'subtype': 'success'},
    assistant('done'),
]):
    cursor_failures.append((events_file(f'unsuccessful-{number}.jsonl', INIT, assistant('done'), final),
                            'error: Cursor did not finish successfully'))
cursor_failures.append((events_file('after-result.jsonl', INIT, SUCCESS, assistant('done')),
                        'error: Cursor did not finish successfully'))
for events, message in cursor_failures:
    last_message = empty_file(f'{events.stem}-last-message.txt')
    status, printed = run(cursor_output, 'worker', events, last_message)
    assert status == 1 and printed.startswith(message), (events.name, status, printed)
    assert last_message.read_text() == '', events.name

# antigravity_output: a reply counts only with status SUCCESS, no denied actions, and no auto-denied
# tool on stderr; a review also only for the staged tree it was given.
AUTO_DENIED = ('jetski: no output produced - a tool required the "command" permission that headless '
               'mode cannot prompt for, so it was auto-denied.\n')
DENIED = [{'action': 'command', 'display_name': 'RunCommand'}]
TREE = hashlib.sha256(b'staged tree').hexdigest()  # a tree id in a SHA-256 repository
assert len(TREE) == 64


def agy_call(name, stderr='', **fields):
    """The reply and stderr files of one agy call; a field set to None is left out."""
    reply = {'conversation_id': 'fixture', 'status': 'SUCCESS', 'response': 'worker finished',
             'structured_output': {**APPROVAL, 'reviewed_tree': TREE}}
    reply.update(fields)
    reply_path, stderr_path = tmp / f'{name}-reply.json', tmp / f'{name}-stderr.log'
    reply_path.write_text(json.dumps({key: value for key, value in reply.items()
                                      if value is not None}))
    stderr_path.write_text(stderr)
    return reply_path, stderr_path


for name, fields in {'agy-success': {}, 'agy-no-denied-actions': {'denied_actions': []}}.items():
    reply, stderr = agy_call(name, **fields)
    last_message = empty_file(f'{name}-last-message.txt')
    assert run(antigravity_output, 'worker', reply, stderr, last_message) == (0, ''), name
    assert last_message.read_text() == 'worker finished', name
    review_file = empty_file(f'{name}-review.json')
    assert run(antigravity_output, 'review', reply, stderr, TREE, review_file) == (0, ''), name
    assert json.loads(review_file.read_text()) == APPROVAL, name

agy_failures = {
    'agy-denied-actions': ({'denied_actions': DENIED}, '',
                           'error: Antigravity denied tools in headless mode: '
                           + json.dumps(DENIED)),
    'agy-status-error': ({'status': 'ERROR'}, '', "error: Antigravity finished with status 'ERROR'"),
    'agy-status-lowercase': ({'status': 'success'}, '',
                             "error: Antigravity finished with status 'success'"),
    'agy-no-status': ({'status': None}, '', 'error: Antigravity finished with status None'),
    'agy-auto-denied': ({}, AUTO_DENIED, 'error: Antigravity auto-denied a tool in headless mode'),
}
for name, (fields, stderr_text, message) in agy_failures.items():
    reply, stderr = agy_call(name, stderr_text, **fields)
    last_message = empty_file(f'{name}-last-message.txt')
    status, printed = run(antigravity_output, 'worker', reply, stderr, last_message)
    assert status == 1 and printed.startswith(message), (name, 'worker', status, printed)
    assert last_message.read_text() == '', name
    review_file = empty_file(f'{name}-review.json')
    status, printed = run(antigravity_output, 'review', reply, stderr, TREE, review_file)
    assert status == 1 and printed.startswith(message), (name, 'review', status, printed)
    assert review_file.read_text() == '', name

for case, reported in {
    'another-tree': hashlib.sha256(b'another tree').hexdigest(),
    'sha1-length-prefix': TREE[:40],
    'upper-case': TREE.upper(),
    'no-reviewed-tree': None,
}.items():
    structured = dict(APPROVAL) if reported is None else {**APPROVAL, 'reviewed_tree': reported}
    reply, stderr = agy_call(f'agy-tree-{case}', structured_output=structured)
    review_file = empty_file(f'agy-tree-{case}-review.json')
    status, printed = run(antigravity_output, 'review', reply, stderr, TREE, review_file)
    assert f'error: the reviewer did not report the staged tree {TREE}' in printed, (case, printed)
    assert review_file.read_text() == '', case


# Both parsers: once reviewed_tree is removed, a review holds exactly approved and findings, and
# each finding exactly category, message and evidence. Any other key set, such as an error note
# next to an approval, is invalid output and leaves the review file empty.
def cursor_review(name, review):
    events = events_file(f'{name}.jsonl', INIT, assistant(json.dumps(review)), SUCCESS)
    review_file = empty_file(f'{name}-review.json')
    return run(cursor_output, 'review', events, TREE, review_file), review_file


def agy_review(name, review):
    reply, stderr = agy_call(name, structured_output=review)
    review_file = empty_file(f'{name}-review.json')
    return run(antigravity_output, 'review', reply, stderr, TREE, review_file), review_file


SCHEMA_ERROR = 'error: the review has keys that the review schema does not allow'
accepted = {
    'an approval': APPROVAL,
    'a rejection with one finding': {'approved': False, 'findings': [FINDING]},
}
invalid = {
    'an extra key': {**APPROVAL, 'error': 'git write-tree failed'},
    'an extra key in a finding': {'approved': False, 'findings': [{**FINDING, 'severity': 'high'}]},
    **{f'a finding without {key}': {'approved': False, 'findings': [
        {name: value for name, value in FINDING.items() if name != key}]} for key in FINDING},
}
for parser, review_with in (('cursor', cursor_review), ('agy', agy_review)):
    for number, (case, review) in enumerate(accepted.items()):
        (status, printed), review_file = review_with(f'{parser}-schema-accepted-{number}',
                                                     {**review, 'reviewed_tree': TREE})
        assert (status, printed) == (0, ''), (parser, case, status, printed)
        assert json.loads(review_file.read_text()) == review, (parser, case)
    for number, (case, review) in enumerate(invalid.items()):
        (status, printed), review_file = review_with(f'{parser}-schema-invalid-{number}',
                                                     {**review, 'reviewed_tree': TREE})
        assert status == 0 and printed.startswith(SCHEMA_ERROR), (parser, case, status, printed)
        assert review_file.read_text() == '', (parser, case)
PY

printf 'PASS: Cursor and Antigravity output parsers accept exactly one review object, split stream-json only at newlines, fail denied, unsuccessful or auto-denied runs, and reject a foreign reviewed tree or a key outside the review schema.\n'
