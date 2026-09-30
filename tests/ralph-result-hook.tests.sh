#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
# A failed test may leave behind a directory it made read-only.
trap 'chmod -R u+rwX "$TEST_ROOT" 2> /dev/null; rm -rf "$TEST_ROOT"' EXIT
# Every hook call gets its own HOME in TEST_ROOT; the real ~/.cursor and ~/.gemini are never touched.
export HOME="$TEST_ROOT/home"
export PYTHONDONTWRITEBYTECODE=1

python3 -B - "$ROOT/hooks/ralph-result-hook.py" "$TEST_ROOT" <<'PY'
import collections
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid

HOOK = Path(sys.argv[1])
TEST_ROOT = Path(sys.argv[2])
# Setup registers the hook as `/usr/bin/python3 -B <hook> <agent>` (hook_command in scripts/install-*.py).
PYTHON = ['/usr/bin/python3', '-B']
# Each agent's inboxes under HOME, as ralph-notify.py fills them.
INBOX = {'cursor': Path('.cursor/ralph-inbox'), 'antigravity': Path('.gemini/antigravity-cli/ralph-inbox')}
AGENTS = tuple(INBOX)
CONVERSATION = 'c0ffee00-1234-4abc-9def-0123456789ab'
OTHER_CONVERSATION = '0badcafe-5678-4def-8abc-ba9876543210'
# Cursor drops an additional_context longer than 10,000 UTF-16 code units; the hook keeps 500 of them
# in reserve.
CURSOR_LIMIT = 9500
MAX_INPUT_BYTES = 1024 * 1024
INSTRUCTIONS = ('\nThis Ralph run has ended. Read the result file and tell the user its outcome before '
                'answering their message. Do not start another Ralph run because of this result unless '
                'the user asks for one. Read detailed logs only if needed to explain a failure.')
# How Cursor's hook marks a first result that it cut to fit the limit.
CUT = ' [cut to fit the message]'
# The note on a result whose file cannot record the delivery, around the problem's first 300 characters.
NOTE = '\n(The delivery cannot be recorded in the result file: {}.)'
BROKEN = b'{broken'
BROKEN_PROBLEM = ('JSONDecodeError: Expecting property name enclosed in double quotes: line 1 column 2 '
                  '(char 1)')
# JSON nested deeper than Python's recursion limit.
DEEP = b'[' * 100_000 + b']' * 100_000
try:
    json.loads(DEEP.decode())
except RecursionError as error:
    DEEP_PROBLEM = f'RecursionError: {error}'
# A message with a lone surrogate, which cannot be written as UTF-8 output.
SURROGATE = b'{"message": "[Ralph result] \\ud800", "result_file": "/r"}'
try:
    '[Ralph result] \ud800'.encode('utf-8')
except UnicodeEncodeError as error:
    SURROGATE_PROBLEM = f'UnicodeEncodeError: {error}'
USAGE = 'usage: ralph-result-hook.py cursor|antigravity'
INVALID_JSON = 'Ralph result hook rejected invalid JSON.'
NOT_AN_OBJECT = 'Ralph result hook expected a JSON object.'
OVERSIZED = 'Ralph result hook rejected an oversized hook payload.'
CURSOR_EVENT = 'Ralph result hook received an unexpected Cursor hook event.'
ANTIGRAVITY_INPUT = 'Ralph result hook received an unexpected Antigravity hook input.'
NO_CONVERSATION = 'Ralph result hook received no valid conversation ID.'
# Cursor and agy may start the hook from any directory; nothing there may be imported.
HOSTILE = TEST_ROOT / 'hostile'
HOSTILE.mkdir()
for module in ('json', 'uuid', 'tempfile', 'pathlib'):
    (HOSTILE / f'{module}.py').write_text(f'raise SystemExit("loaded {module}.py from the caller cwd")\n')
# Wrappers run as `python3 -c WRAPPER <hook> <agent> <target>`: each patches os to stage a race or a
# failure around TARGET, then runs the hook as its script.
RUN_HOOK = '''
sys.argv = [hook, agent]
runpy.run_path(hook, run_name='__main__')
'''
# Another call (process 1, which never ends) claims TARGET between this call's listing of the inbox and
# its own claim.
RIVAL = r'''
import os, runpy, sys
hook, agent, target = sys.argv[1:]
rename = os.rename
def rival_first(source, destination, *args, **kwargs):
    if os.fspath(source) == target and os.path.exists(target):
        rename(target, target + '.1.claimed')
    return rename(source, destination, *args, **kwargs)
os.rename = rival_first
''' + RUN_HOOK
# Another call puts the abandoned claim TARGET back between this call's listing and its own attempt.
PUT_BACK_FIRST = r'''
import os, runpy, sys
hook, agent, target = sys.argv[1:]
kill = os.kill
def put_back_first(pid, signal):
    if signal == 0 and os.path.exists(target):
        os.rename(target, target.rsplit('.', 2)[0])
    return kill(pid, signal)
os.kill = put_back_first
''' + RUN_HOOK
# Claiming TARGET fails with an I/O error.
FAILING_CLAIM = r'''
import errno, os, runpy, sys
hook, agent, target = sys.argv[1:]
rename = os.rename
def fail_on_target(source, destination, *args, **kwargs):
    if os.fspath(source) == target and os.fspath(destination).endswith('.claimed'):
        raise OSError(errno.EIO, 'injected failure')
    return rename(source, destination, *args, **kwargs)
os.rename = fail_on_target
''' + RUN_HOOK

Queued = collections.namedtuple('Queued', 'entry result_file message state')


def payload(agent, conversation=CONVERSATION):
    """What each CLI sends the hook before the conversation's next message goes to the model."""
    if agent == 'cursor':
        return {'conversation_id': conversation, 'generation_id': 'generation-1',
                'hook_event_name': 'beforeSubmitPrompt', 'prompt': 'How did the run go?',
                'attachments': [], 'workspace_roots': ['/work/project']}
    # agy's first model call of a turn; only that one may add results.
    return {'invocationNum': 0, 'conversationId': conversation, 'workspacePaths': ['/work/project'],
            'transcriptPath': '/tmp/transcript.jsonl', 'modelName': 'test'}


def output(agent, messages):
    """What the hook prints to add MESSAGES to the conversation's next message."""
    if not messages:
        return {}
    if agent == 'cursor':
        return {'additional_context': '\n\n'.join(messages)}
    return {'injectSteps': [{'userMessage': message} for message in messages]}


def messages_in(agent, added):
    """The messages in the hook's output ADDED; no message in these tests holds a blank line."""
    if not added:
        return []
    if agent == 'cursor':
        return added['additional_context'].split('\n\n')
    return [step['userMessage'] for step in added['injectSteps']]


def utf16(text):
    return len(text.encode('utf-16-le')) // 2


def message_of(units, fill='a', tag='[Ralph result] '):
    """A result message of exactly UNITS UTF-16 code units: TAG, then FILL repeated."""
    count, rest = divmod(units - utf16(tag), utf16(fill))
    assert rest == 0 and count >= 0, (units, fill)
    return tag + fill * count


def tree(root):
    """Every path under ROOT, hidden ones included, with each file's bytes (None for a directory)."""
    return {str(path.relative_to(root)): None if path.is_dir() else path.read_bytes()
            for path in sorted(root.rglob('*'))}


def report(entry, problem):
    """How the hook tells the conversation about an entry it could not read."""
    return (f'[Ralph result] A Ralph result in {entry} could not be read ({problem}); '
            f'it was kept as {entry.name}.invalid.')


def os_error(text, path):
    """How an OSError about PATH reads in the hook's messages."""
    return f'{text}: {str(path)!r}'


def missing(path):
    return os_error('FileNotFoundError: [Errno 2] No such file or directory', path)


def unrecorded(queued, problem):
    """The hook's stderr line for a result it delivered but could not record as delivered."""
    return (f'Ralph result hook delivered {queued.entry.name} but could not record it in '
            f'{queued.result_file}: {problem}\n')


class ResultHookTests(unittest.TestCase):
    def setUp(self):
        # Spaces and quotes, as a Windows user name may have: every path the hook reads, writes and
        # reports goes through HOME.
        self.home = Path(tempfile.mkdtemp(prefix='it\'s "a home" ', dir=TEST_ROOT))
        self.addCleanup(shutil.rmtree, self.home)
        self.queued = 0

    def inbox(self, agent, conversation=CONVERSATION):
        return self.home / INBOX[agent] / conversation

    def entry(self, agent, at, run_id=None, conversation=CONVERSATION):
        """The path of an entry in AGENT's inbox for CONVERSATION, named as the supervisor names it:
        the time prefix AT, then the run."""
        inbox = self.inbox(agent, conversation)
        inbox.mkdir(parents=True, exist_ok=True)
        return inbox / f'{at:020d}-{run_id or uuid.uuid4()}.json'

    def queue(self, agent, message=None, *, conversation=CONVERSATION, at=None, run_id=None):
        """Leave a result in AGENT's inbox for CONVERSATION as the supervisor does (queue_result in
        ralph-notify.py), with a result file that records notification=queued. AT is the time prefix
        of the entry's name; by default results sort in the order they are queued."""
        self.queued += 1
        run_id = run_id or str(uuid.uuid4())
        ralph = self.home / f'{agent} project/scripts/ralph'
        run_dir = ralph / 'logs/runs' / run_id
        run_dir.mkdir(parents=True)
        (run_dir / 'runner.log').write_text('PRIVATE_WORKER_LOG\n')
        result_file = run_dir / 'result.json'
        state = {'run_id': run_id, 'agent': agent, 'conversation': conversation,
                 'ralph_dir': str(ralph), 'project_root': str(ralph.parent.parent), 'max_iterations': 3,
                 'executable': '/usr/local/bin/fixture', 'status': 'completed', 'notification': 'queued',
                 'progress': str(ralph / '進捗.txt'), 'log': str(run_dir / 'runner.log'),
                 'runner_pid': 4241, 'supervisor_pid': 4242, 'supervisor_identity': '777',
                 'exit_code': 0, 'iterations_run': 1, 'worker_model': 'model-a', 'review_model': 'model-b'}
        result_file.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')
        if message is None:
            message = '[Ralph result] ' + json.dumps({
                'run_id': run_id, 'status': 'completed', 'exit_code': 0, 'iterations_run': 1,
                'result_file': str(result_file)}, ensure_ascii=False) + INSTRUCTIONS
        entry = self.entry(agent, self.queued if at is None else at, run_id, conversation)
        entry.write_text(json.dumps({'run_id': run_id, 'result_file': str(result_file), 'message': message},
                                    ensure_ascii=False, indent=2) + '\n')
        return Queued(entry, result_file, message, state)

    def hook(self, argv, data, env=(), **options):
        """Run the hook as setup registers it, from an unrelated directory, with DATA on stdin."""
        stdin = data if isinstance(data, bytes) else json.dumps(data).encode()
        options.setdefault('capture_output', True)
        return subprocess.run(PYTHON + [str(HOOK), *argv], input=stdin, cwd=HOSTILE, timeout=30,
                              env={**os.environ, 'HOME': str(self.home), **dict(env)}, **options)

    def staged(self, wrapper, agent, target):
        """Run the hook through WRAPPER, which stages a race or a failure around TARGET. It runs from
        HOME, since `python3 -c` imports from the working directory."""
        return subprocess.run(PYTHON + ['-c', wrapper, str(HOOK), agent, str(target)],
                              input=json.dumps(payload(agent)).encode(), cwd=self.home, timeout=30,
                              env={**os.environ, 'HOME': str(self.home)}, capture_output=True)

    def call(self, agent, data=None):
        """The exit status, the one JSON line added to the conversation's next message, and the
        stderr of a call that writes its output."""
        result = self.hook([agent], payload(agent) if data is None else data)
        text = result.stdout.decode('utf-8')
        self.assertTrue(text.endswith('\n') and text.count('\n') == 1, text)
        return result.returncode, json.loads(text), result.stderr.decode()

    def deliver(self, agent, data=None):
        """What a call that must succeed without a word on stderr adds to the next message."""
        code, added, stderr = self.call(agent, data)
        self.assertEqual((code, stderr), (0, ''))
        return added

    def assert_delivered(self, *results):
        """Each result is recorded as delivered, with the rest of its result file unchanged and no
        temporary file left beside it, and its entry is gone."""
        for queued in results:
            self.assertEqual(json.loads(queued.result_file.read_text(encoding='utf-8')),
                             {**queued.state, 'notification': 'delivered'})
            self.assertEqual(sorted(path.name for path in queued.result_file.parent.iterdir()),
                             ['result.json', 'runner.log'])
            self.assertEqual(list(queued.entry.parent.glob(queued.entry.name + '*')), [])

    def assert_marked_delivered(self, queued, entry):
        """QUEUED was delivered but not recorded: its entry, as it was (ENTRY), stays as <name>.delivered,
        which later calls leave alone, and its result file is as it was."""
        marker = queued.entry.with_name(queued.entry.name + '.delivered')
        self.assertEqual(sorted(queued.entry.parent.glob(queued.entry.name + '*')), [marker])
        self.assertEqual(marker.read_bytes(), entry)

    def assert_waiting(self, *results):
        """Each result is still in its inbox under its own name, untouched, and not recorded."""
        for queued in results:
            self.assertEqual(json.loads(queued.entry.read_text(encoding='utf-8'))['message'],
                             queued.message)
            self.assertEqual(json.loads(queued.result_file.read_text(encoding='utf-8')), queued.state)
            self.assertEqual(sorted(queued.entry.parent.glob(queued.entry.name + '*')), [queued.entry])

    def test_nothing_waiting_adds_nothing_and_creates_no_inbox(self):
        for agent in AGENTS:
            layouts = {'no inbox': (), 'an empty inbox': (INBOX[agent],),
                       'an empty conversation inbox': (INBOX[agent] / CONVERSATION,)}
            for layout, directories in layouts.items():
                with self.subTest(agent=agent, layout=layout):
                    for directory in directories:
                        (self.home / directory).mkdir(parents=True, exist_ok=True)
                    before = tree(self.home)
                    result = self.hook([agent], payload(agent))
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b'{}\n', b''))
                    self.assertEqual(tree(self.home), before)
            with self.subTest(agent=agent, layout='only files that are not waiting results'):
                run = uuid.uuid4()
                # The supervisor's unpublished entry, one a live call is taking, one kept unreadable, and
                # one delivered but not recorded.
                for name in (f'.{1:020d}-{run}.json.tmp', f'{2:020d}-{run}.json.{os.getpid()}.claimed',
                             f'{3:020d}-{run}.json.invalid', f'{4:020d}-{run}.json.delivered'):
                    (self.inbox(agent) / name).write_text('{}')
                before = tree(self.home)
                self.assertEqual(self.deliver(agent), {})
                self.assertEqual(tree(self.home), before)

    def test_every_waiting_result_is_added_oldest_first(self):
        """Cursor gets the results as one additional_context, agy as one injected user message each,
        oldest first by the time prefix of the entry's name, whatever order they were written in."""
        for agent in AGENTS:
            with self.subTest(agent=agent):
                newest = self.queue(agent, at=10 ** 18, run_id='00000000-0000-4000-8000-000000000000')
                oldest = self.queue(agent, at=9, run_id='ffffffff-ffff-4fff-bfff-ffffffffffff')
                middle = self.queue(agent, at=10, run_id='88888888-8888-4888-8888-888888888888')
                self.assertEqual(self.deliver(agent),
                                 output(agent, [oldest.message, middle.message, newest.message]))
                self.assert_delivered(oldest, middle, newest)
                self.assertEqual(list(self.inbox(agent).iterdir()), [])
                self.assertEqual(self.deliver(agent), {})

    def test_other_conversations_and_the_other_agent_keep_their_results(self):
        for agent, other in (AGENTS, AGENTS[::-1]):
            with self.subTest(agent=agent):
                mine = self.queue(agent)
                elsewhere = [self.queue(agent, conversation=OTHER_CONVERSATION),
                             self.queue(other, conversation=CONVERSATION)]
                self.assertEqual(self.deliver(agent), output(agent, [mine.message]))
                self.assert_delivered(mine)
                self.assert_waiting(*elsewhere)
                self.assertEqual(self.deliver(agent), {})
                self.assertEqual(self.deliver(agent, payload(agent, OTHER_CONVERSATION)),
                                 output(agent, [elsewhere[0].message]))
                self.assertEqual(self.deliver(other), output(other, [elsewhere[1].message]))
                self.assert_delivered(*elsewhere)

    def test_a_result_file_that_cannot_be_read_is_noted_and_the_message_still_delivered(self):
        """The message reaches the conversation with a note on why its result file cannot say delivered,
        the failed record is reported on stderr, the result file stays as it was, and the entry stays
        as <name>.delivered for --status."""
        def holding(content, problem):
            def spoil(path):
                path.write_bytes(content)
                return problem
            return spoil

        def gone(path):
            path.unlink()
            return missing(path)

        def directory(path):
            path.unlink()
            path.mkdir()
            return os_error('IsADirectoryError: [Errno 21] Is a directory', path)

        cases = {
            'missing': gone,
            'invalid JSON': holding(BROKEN, BROKEN_PROBLEM),
            'not a JSON object': holding(b'[]\n', 'it is not a JSON object'),
            'not UTF-8': holding(b'\xff\n', "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in "
                                            'position 0: invalid start byte'),
            'nested too deeply': holding(DEEP, DEEP_PROBLEM),
            'a directory': directory,
        }
        for agent in AGENTS:
            for case, spoil in cases.items():
                with self.subTest(agent=agent, case=case):
                    queued = self.queue(agent)
                    entry = queued.entry.read_bytes()
                    problem = spoil(queued.result_file)
                    before = tree(queued.result_file.parent)
                    self.assertEqual(self.call(agent), (
                        0, output(agent, [queued.message + NOTE.format(problem[:300])]),
                        unrecorded(queued, problem)))
                    self.assertEqual(tree(queued.result_file.parent), before)
                    self.assert_marked_delivered(queued, entry)
                    self.assertEqual(self.deliver(agent), {})
                    self.assert_marked_delivered(queued, entry)

    def test_a_delivery_that_cannot_be_recorded_is_reported_on_stderr(self):
        """A result file that reads well but cannot be replaced: the message arrives as usual, the
        failed record is reported on stderr, and the entry stays as <name>.delivered, so it is not added
        again."""
        if os.geteuid() == 0:
            self.skipTest('root writes into a read-only directory')
        for agent in AGENTS:
            with self.subTest(agent=agent):
                queued = self.queue(agent)
                entry = queued.entry.read_bytes()
                queued.result_file.parent.chmod(0o555)
                self.addCleanup(queued.result_file.parent.chmod, 0o755)
                code, added, stderr = self.call(agent)
                self.assertEqual((code, added), (0, output(agent, [queued.message])))
                # The temporary file that could not be created has a random name.
                start = unrecorded(queued, os_error('PermissionError: [Errno 13] Permission denied',
                                                    queued.result_file.parent / '.result.'))
                self.assertRegex(stderr, '^' + re.escape(start[:-2]) + r"\w+\.tmp'\n$")
                self.assertEqual(json.loads(queued.result_file.read_text(encoding='utf-8')), queued.state)
                self.assert_marked_delivered(queued, entry)
                self.assertEqual(self.deliver(agent), {})

    def test_an_unreadable_entry_is_kept_as_invalid_and_reported(self):
        """The conversation learns that a result could not be read, the entry stays as <name>.invalid
        for inspection and is not reported again, and the results around it arrive as usual."""
        cases = {
            'invalid JSON': (BROKEN, BROKEN_PROBLEM),
            'not UTF-8': (b'\xff', "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in "
                                   'position 0: invalid start byte'),
            'not a JSON object': (b'[]', 'TypeError: list indices must be integers or slices, not str'),
            'no message': (b'{"run_id": "r", "result_file": "/r"}', "KeyError: 'message'"),
            'no result file': (b'{"run_id": "r", "message": "m"}', "KeyError: 'result_file'"),
            'a message that is not text': (b'{"message": 5, "result_file": "/r"}',
                                           'ValueError: message and result_file must be strings'),
            'a result file that is not text': (b'{"message": "m", "result_file": null}',
                                               'ValueError: message and result_file must be strings'),
            'a lone surrogate in the message': (SURROGATE, SURROGATE_PROBLEM),
            'nested too deeply': (DEEP, DEEP_PROBLEM),
            'a directory': (None, None),
        }
        for agent in AGENTS:
            for case, (content, problem) in cases.items():
                with self.subTest(agent=agent, case=case):
                    before = self.queue(agent, at=1)
                    entry = self.entry(agent, 2)
                    after = self.queue(agent, at=3)
                    kept = entry.with_name(entry.name + '.invalid')
                    if content is None:
                        entry.mkdir()
                    else:
                        entry.write_bytes(content)
                    messages = messages_in(agent, self.deliver(agent))
                    self.assertEqual(len(messages), 3, messages)
                    self.assertEqual((messages[0], messages[2]), (before.message, after.message))
                    if content is None:
                        # Reading failed under the name the entry was claimed with.
                        start, end = report(entry, '|').split('|')
                        claimed = os_error('IsADirectoryError: [Errno 21] Is a directory', f'{entry}.')[:-1]
                        self.assertTrue(messages[1].startswith(start + claimed), messages[1])
                        self.assertTrue(messages[1].endswith(end), messages[1])
                        self.assertRegex(messages[1][len(start + claimed):-len(end)], r"^\d+\.claimed'$")
                        self.assertTrue(kept.is_dir())
                    else:
                        self.assertEqual(messages[1], report(entry, problem))
                        self.assertEqual(kept.read_bytes(), content)
                    self.assertEqual(sorted(self.inbox(agent).iterdir()), [kept])
                    self.assert_delivered(before, after)
                    self.assertEqual(self.deliver(agent), {})
                    self.assertEqual(sorted(self.inbox(agent).iterdir()), [kept])
                    shutil.rmtree(self.inbox(agent))

    def test_antigravity_adds_results_only_at_the_first_call_of_a_turn(self):
        """agy runs PreInvocation before every model call of a turn. Results are added at the first call
        (invocationNum 0) only, so that none lands inside the turn's tool loop; the other calls answer {}
        and leave the inbox as it is, abandoned claims included."""
        ended = subprocess.Popen(['true'])
        ended.wait()
        waiting, abandoned = self.queue('antigravity'), self.queue('antigravity')
        abandoned.entry.rename(f'{abandoned.entry}.{ended.pid}.claimed')
        before = tree(self.home)
        for number in (1, 2, 17, -1):
            with self.subTest(invocationNum=number):
                result = self.hook(['antigravity'], {**payload('antigravity'), 'invocationNum': number})
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b'{}\n', b''))
                self.assertEqual(tree(self.home), before)
        self.assertEqual(self.deliver('antigravity'),
                         output('antigravity', [waiting.message, abandoned.message]))
        self.assert_delivered(waiting, abandoned)

    def test_a_result_already_recorded_as_delivered_is_dropped_quietly(self):
        """A call stopped after it recorded a delivery and before it removed the entry leaves a result that
        the conversation got: the next call removes it without adding it again."""
        ended = subprocess.Popen(['true'])
        ended.wait()
        for agent in AGENTS:
            with self.subTest(agent=agent):
                recorded, abandoned, fresh = self.queue(agent), self.queue(agent), self.queue(agent)
                abandoned.entry.rename(f'{abandoned.entry}.{ended.pid}.claimed')
                for queued in (recorded, abandoned):
                    queued.result_file.write_text(json.dumps(
                        {**queued.state, 'notification': 'delivered'}, ensure_ascii=False, indent=2) + '\n')
                self.assertEqual(self.deliver(agent), output(agent, [fresh.message]))
                self.assert_delivered(recorded, abandoned, fresh)
                self.assertEqual(list(self.inbox(agent).iterdir()), [])

    def test_the_result_file_keeps_its_mode(self):
        for agent in AGENTS:
            for mode in (0o644, 0o640, 0o600):
                with self.subTest(agent=agent, mode=oct(mode)):
                    queued = self.queue(agent)
                    queued.result_file.chmod(mode)
                    self.assertEqual(self.deliver(agent), output(agent, [queued.message]))
                    self.assert_delivered(queued)
                    self.assertEqual(stat.S_IMODE(queued.result_file.stat().st_mode), mode)

    def test_a_report_on_a_path_that_is_not_utf8_is_written_escaped(self):
        """A report can hold a path that is not UTF-8, here from HOME: its bytes are escaped, so the
        report is written and the unreadable result is kept as .invalid like any other."""
        self.home = Path(os.fsdecode(os.fsencode(self.home) + b'/not utf-8 \xff'))
        self.home.mkdir()
        for agent in AGENTS:
            with self.subTest(agent=agent):
                entry = self.entry(agent, 1)
                entry.write_bytes(BROKEN)
                result = self.hook([agent], payload(agent))
                self.assertEqual(result.returncode, 0, result.stderr)
                text = result.stdout.decode('utf-8')
                self.assertIn('not utf-8 \\\\udcff', text)
                self.assertIn('could not be read', text)
                self.assertFalse(entry.exists())
                self.assertTrue(entry.with_name(entry.name + '.invalid').is_file())

    def test_invalid_input_takes_nothing(self):
        waiting = [self.queue(agent) for agent in AGENTS]
        prompt = {'hook_event_name': 'beforeSubmitPrompt', 'conversation_id': CONVERSATION}
        tool_call = {'toolCall': {'name': 'run_command', 'args': {'CommandLine': 'ls'}},
                     'conversationId': CONVERSATION, 'stepIdx': 2}
        cases = []
        for agent in AGENTS:
            data = json.dumps(payload(agent)).encode()
            cases += [
                ([agent], b'', INVALID_JSON), ([agent], b'{', INVALID_JSON),
                ([agent], b'\xff', INVALID_JSON), ([agent], b'[]', NOT_AN_OBJECT),
                ([agent], b'"text"', NOT_AN_OBJECT), ([agent], b'null', NOT_AN_OBJECT),
                # A valid payload one byte over the limit.
                ([agent], data + b' ' * (MAX_INPUT_BYTES + 1 - len(data)), OVERSIZED),
            ]
        cases += [(['cursor'], data, CURSOR_EVENT) for data in (
            {**prompt, 'hook_event_name': 'sessionStart'},
            {**prompt, 'hook_event_name': 'beforesubmitprompt'},
            {'conversation_id': CONVERSATION}, payload('antigravity'))]
        cases += [(['cursor'], data, NO_CONVERSATION) for data in (
            {'hook_event_name': 'beforeSubmitPrompt'}, {**prompt, 'conversation_id': 'not-a-uuid'},
            {**prompt, 'conversation_id': '../' + CONVERSATION}, {**prompt, 'conversation_id': 5},
            {**prompt, 'conversation_id': None}, {**prompt, 'conversation_id': ''},
            {'hook_event_name': 'beforeSubmitPrompt', 'conversationId': CONVERSATION})]
        cases += [(['antigravity'], data, ANTIGRAVITY_INPUT) for data in (
            {'conversationId': CONVERSATION}, {'invocationNum': '2', 'conversationId': CONVERSATION},
            {'invocationNum': 2.5, 'conversationId': CONVERSATION},
            {'invocationNum': None, 'conversationId': CONVERSATION},
            {'invocationNum': True, 'conversationId': CONVERSATION},
            {'invocationNum': False, 'conversationId': CONVERSATION}, payload('cursor'), tool_call)]
        cases += [(['antigravity'], data, NO_CONVERSATION) for data in (
            {'invocationNum': 2}, {'invocationNum': 2, 'conversationId': 'not-a-uuid'},
            {'invocationNum': 2, 'conversationId': CONVERSATION[:-1]},
            {'invocationNum': 2, 'conversation_id': CONVERSATION})]
        cases += [(argv, payload('cursor'), USAGE) for argv in (
            [], ['codex'], ['Cursor'], ['cursor', 'antigravity'], ['antigravity', '--verbose'])]
        before = tree(self.home)
        for argv, data, reason in cases:
            with self.subTest(argv=argv, data=data if isinstance(data, dict) else data[:40]):
                result = self.hook(argv, data)
                self.assertEqual((result.returncode, result.stdout, result.stderr.decode()),
                                 (1, b'', reason + '\n'))
                self.assertEqual(tree(self.home), before)
        self.assert_waiting(*waiting)

    def test_a_payload_of_exactly_the_size_limit_is_read(self):
        for agent in AGENTS:
            with self.subTest(agent=agent):
                queued = self.queue(agent)
                data = json.dumps(payload(agent)).encode()
                self.assertEqual(self.deliver(agent, data + b' ' * (MAX_INPUT_BYTES - len(data))),
                                 output(agent, [queued.message]))
                self.assert_delivered(queued)

    def test_an_uppercase_conversation_id_names_the_lowercase_inbox(self):
        self.assertNotEqual(CONVERSATION.upper(), CONVERSATION)
        for agent in AGENTS:
            with self.subTest(agent=agent):
                queued = self.queue(agent)
                self.assertEqual(self.deliver(agent, payload(agent, CONVERSATION.upper())),
                                 output(agent, [queued.message]))
                self.assert_delivered(queued)
                self.assertEqual([path.name for path in (self.home / INBOX[agent]).iterdir()],
                                 [CONVERSATION])

    def test_a_home_with_spaces_and_quotes(self):
        for character in ' \'"':
            self.assertIn(character, str(self.home))
        for agent in AGENTS:
            with self.subTest(agent=agent):
                queued = self.queue(agent)
                self.assertIn(json.dumps(str(self.home))[1:-1], queued.message)
                self.assertEqual(self.deliver(agent), output(agent, [queued.message]))
                self.assert_delivered(queued)

    def test_messages_are_written_in_utf8_whatever_the_output_encoding(self):
        for agent in AGENTS:
            with self.subTest(agent=agent):
                queued = self.queue(agent, '[Ralph result] 実行が終わりました 😀')
                result = self.hook([agent], payload(agent), env={'PYTHONIOENCODING': 'ascii'})
                self.assertEqual((result.returncode, result.stderr), (0, b''))
                self.assertIn('実行が終わりました 😀'.encode('utf-8'), result.stdout)
                self.assertEqual(json.loads(result.stdout.decode('utf-8')), output(agent, [queued.message]))
                self.assert_delivered(queued)

    def test_output_that_cannot_be_written_leaves_every_result_waiting(self):
        """A result leaves the inbox, and its file says delivered, only once the output is written:
        after a failed write every result waits under its own name for the next message."""
        for agent in AGENTS:
            for target in ('a closed pipe', 'a full device'):
                with self.subTest(agent=agent, output=target):
                    waiting = [self.queue(agent), self.queue(agent)]
                    unreadable = self.entry(agent, self.queued + 1)
                    unreadable.write_bytes(BROKEN)
                    before = tree(self.home)
                    if target == 'a closed pipe':
                        reader, stdout = os.pipe()
                        os.close(reader)
                        problem = 'BrokenPipeError: [Errno 32] Broken pipe'
                    else:
                        stdout = os.open('/dev/full', os.O_WRONLY)
                        problem = 'OSError: [Errno 28] No space left on device'
                    try:
                        result = self.hook([agent], payload(agent), capture_output=False, stdout=stdout,
                                           stderr=subprocess.PIPE)
                    finally:
                        os.close(stdout)
                    self.assertEqual((result.returncode, result.stderr.decode()),
                                     (1, f'Ralph result hook could not write its output: {problem}\n'))
                    self.assertEqual(tree(self.home), before)
                    self.assert_waiting(*waiting)
                    messages = messages_in(agent, self.deliver(agent))
                    self.assertEqual(messages, [q.message for q in waiting]
                                     + [report(unreadable, BROKEN_PROBLEM)])
                    self.assert_delivered(*waiting)
                    shutil.rmtree(self.inbox(agent))

    def test_a_hook_started_without_stdout_leaves_every_result_waiting(self):
        """Started with stdout closed, the hook cannot hand anything over: it fails like any failed write,
        every result waits under its own name, and the next call delivers them."""
        for agent in AGENTS:
            with self.subTest(agent=agent):
                waiting = [self.queue(agent), self.queue(agent)]
                before = tree(self.home)
                result = subprocess.run(['bash', '-c', 'exec "$@" >&-', 'bash', *PYTHON, str(HOOK), agent],
                                        input=json.dumps(payload(agent)).encode(), cwd=HOSTILE, timeout=30,
                                        env={**os.environ, 'HOME': str(self.home)},
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                self.assertEqual((result.returncode, result.stderr.decode()), (
                    1, 'Ralph result hook could not write its output: OSError: stdout is closed\n'))
                self.assertEqual(tree(self.home), before)
                self.assert_waiting(*waiting)
                self.assertEqual(self.deliver(agent), output(agent, [q.message for q in waiting]))
                self.assert_delivered(*waiting)

    def test_a_claim_left_by_a_call_that_died_is_taken_again(self):
        """A call killed while it held results (for example on the CLI's hook timeout) leaves them claimed
        under its process ID. The next call puts back the claims of processes that no longer exist, or
        could not exist, and adds them in order; claims of live processes, of this user's or not, stay
        with them."""
        ended = subprocess.Popen(['true'])
        ended.wait()
        for agent in AGENTS:
            with self.subTest(agent=agent):
                stale, impossible, mine, others, odd, fresh = (self.queue(agent) for _ in range(6))
                held = [(stale, ended.pid), (impossible, 2 ** 31), (mine, os.getpid()), (others, 1),
                        (odd, 'x')]
                for queued, pid in held:
                    queued.entry.rename(f'{queued.entry}.{pid}.claimed')
                self.assertEqual(self.deliver(agent),
                                 output(agent, [stale.message, impossible.message, fresh.message]))
                self.assert_delivered(stale, impossible, fresh)
                for queued, pid in held[2:]:
                    claimed = Path(f'{queued.entry}.{pid}.claimed')
                    self.assertEqual(sorted(queued.entry.parent.glob(queued.entry.name + '*')), [claimed])
                    self.assertEqual(json.loads(claimed.read_text())['message'], queued.message)
                    self.assertEqual(json.loads(queued.result_file.read_text()), queued.state)
                self.assertEqual(self.deliver(agent), {})

    def test_a_failure_part_way_through_the_inbox_puts_every_claim_back(self):
        for agent in AGENTS:
            with self.subTest(agent=agent):
                waiting = [self.queue(agent), self.queue(agent), self.queue(agent)]
                before = tree(self.home)
                result = self.staged(FAILING_CLAIM, agent, waiting[1].entry)
                self.assertEqual((result.returncode, result.stdout, result.stderr.decode()), (
                    1, b'', 'Ralph result hook could not read its inbox: OSError: [Errno 5] injected '
                            'failure\n'))
                self.assertEqual(tree(self.home), before)
                self.assertEqual(self.deliver(agent), output(agent, [q.message for q in waiting]))
                self.assert_delivered(*waiting)

    def test_files_that_are_not_results_are_left_alone(self):
        """Only the names ralph-notify.py gives results (<20 digits>-<lowercase UUID>.json) and the
        hook's claims of them count: anything else in an inbox stays as it is, and the results beside
        it arrive, an abandoned claim among them."""
        ended = subprocess.Popen(['true'])
        ended.wait()
        run = str(uuid.uuid4())
        foreign = {
            'notes.txt': b'notes\n',
            'x.json': b'{}',
            # Its claim would be a name too long for the file system.
            'z' * 246 + '.json': b'{}',
            f'{1:019d}-{run}.json': b'{}',
            f'{1:020d}-{CONVERSATION.upper()}.json': b'{}',
            f'{1:020d}-{run}.json.x.claimed': b'{}',
            f'notes.json.{ended.pid}.claimed': b'{}',
        }
        for agent in AGENTS:
            with self.subTest(agent=agent):
                waiting, abandoned = self.queue(agent), self.queue(agent)
                abandoned.entry.rename(f'{abandoned.entry}.{ended.pid}.claimed')
                for name, content in foreign.items():
                    (self.inbox(agent) / name).write_bytes(content)
                self.assertEqual(self.deliver(agent), output(agent, [waiting.message, abandoned.message]))
                self.assert_delivered(waiting, abandoned)
                self.assertEqual({path.name: path.read_bytes() for path in self.inbox(agent).iterdir()},
                                 foreign)
                self.assertEqual(self.deliver(agent), {})

    def test_an_inbox_the_hook_cannot_change_is_reported_and_kept(self):
        if os.geteuid() == 0:
            self.skipTest('root renames in a read-only directory')
        for agent in AGENTS:
            with self.subTest(agent=agent):
                queued = self.queue(agent)
                self.inbox(agent).chmod(0o555)
                self.addCleanup(self.inbox(agent).chmod, 0o755)
                result = self.hook([agent], payload(agent))
                self.assertEqual((result.returncode, result.stdout), (1, b''))
                self.assertTrue(result.stderr.decode().startswith(
                    'Ralph result hook could not read its inbox: PermissionError: [Errno 13] Permission '
                    'denied: '), result.stderr)
                self.assert_waiting(queued)

    def test_cursor_takes_only_what_fits_in_its_context_limit(self):
        """Cursor drops a longer additional_context whole, so a result that would not fit, counted in
        UTF-16 code units with the blank lines between results, waits under its own name for the next
        message."""
        first = message_of(5000)
        room = CURSOR_LIMIT - utf16(first) - 2
        cases = {
            'exactly the limit': (message_of(room), True),
            'one unit over the limit': (message_of(room + 1), False),
            # 2,242 emoji are 4,484 UTF-16 code units: one unit too many.
            'a character beyond the BMP counts twice': (message_of(room + 1, '😀'), False),
            # 4,483 'あ' are as many code units, though 13,449 bytes in UTF-8.
            'any other character counts once': (message_of(room, 'あ'), True),
        }
        for case, (second, fits) in cases.items():
            with self.subTest(case=case):
                conversation = str(uuid.uuid4())
                queued = [self.queue('cursor', first, conversation=conversation),
                          self.queue('cursor', second, conversation=conversation)]
                added = self.deliver('cursor', payload('cursor', conversation))
                if fits:
                    self.assertEqual(added, output('cursor', [first, second]))
                    self.assertEqual(utf16(added['additional_context']), CURSOR_LIMIT)
                    self.assert_delivered(*queued)
                else:
                    self.assertEqual(added, output('cursor', [first]))
                    self.assert_delivered(queued[0])
                    self.assert_waiting(queued[1])
                    self.assertEqual(self.deliver('cursor', payload('cursor', conversation)),
                                     output('cursor', [second]))
                    self.assert_delivered(queued[1])
                self.assertEqual(self.deliver('cursor', payload('cursor', conversation)), {})

    def test_cursor_counts_a_note_against_the_limit(self):
        for fits in (True, False):
            with self.subTest(fits=fits):
                conversation = str(uuid.uuid4())
                second = self.queue('cursor', message_of(100), conversation=conversation, at=2)
                entry = second.entry.read_bytes()
                second.result_file.unlink()
                noted = second.message + NOTE.format(missing(second.result_file)[:300])
                first = self.queue('cursor', message_of(CURSOR_LIMIT - 2 - utf16(noted) + (not fits)),
                                   conversation=conversation, at=1)
                code, added, stderr = self.call('cursor', payload('cursor', conversation))
                self.assert_delivered(first)
                if fits:
                    self.assertEqual((code, added), (0, output('cursor', [first.message, noted])))
                    self.assertEqual(utf16(added['additional_context']), CURSOR_LIMIT)
                else:
                    self.assertEqual((code, added, stderr), (0, output('cursor', [first.message]), ''))
                    self.assertEqual(sorted(second.entry.parent.iterdir()), [second.entry])
                    code, added, stderr = self.call('cursor', payload('cursor', conversation))
                    self.assertEqual((code, added), (0, output('cursor', [noted])))
                self.assertEqual(stderr, unrecorded(second, missing(second.result_file)))
                self.assertEqual(list(second.entry.parent.iterdir()),
                                 [second.entry.with_name(second.entry.name + '.delivered')])
                self.assert_marked_delivered(second, entry)

    def test_cursor_hands_many_results_over_in_turns(self):
        # 23 results of 400 code units and the blank lines between them fill 9,244 of the 9,500.
        queued = [self.queue('cursor', message_of(400, tag=f'[Ralph result] #{number:02d} '))
                  for number in range(30)]
        self.assertEqual(self.deliver('cursor'), output('cursor', [q.message for q in queued[:23]]))
        self.assert_delivered(*queued[:23])
        self.assert_waiting(*queued[23:])
        self.assertEqual(self.deliver('cursor'), output('cursor', [q.message for q in queued[23:]]))
        self.assert_delivered(*queued[23:])
        self.assertEqual(self.deliver('cursor'), {})

    def test_cursor_cuts_a_first_result_too_long_on_its_own(self):
        """The oldest result is always added, alone if need be, instead of blocking the inbox; one that
        alone exceeds the limit is cut to fit, marked as cut, and recorded as delivered."""
        cases = {
            'exactly the limit': message_of(CURSOR_LIMIT),
            'one unit over the limit': message_of(CURSOR_LIMIT + 1),
            'three times the limit': message_of(3 * CURSOR_LIMIT),
            # 4,800 emoji: 9,615 UTF-16 code units in 4,815 characters.
            'characters beyond the BMP': message_of(CURSOR_LIMIT + 115, '😀'),
        }
        for case, long in cases.items():
            with self.subTest(case=case):
                conversation = str(uuid.uuid4())
                # The second result would not fit beside any first one cut to more than 8,900 units.
                queued = [self.queue('cursor', long, conversation=conversation),
                          self.queue('cursor', message_of(600), conversation=conversation)]
                (added,) = messages_in('cursor', self.deliver('cursor', payload('cursor', conversation)))
                if utf16(long) <= CURSOR_LIMIT:
                    self.assertEqual(added, long)
                elif long.isascii():
                    self.assertEqual(added, long[:CURSOR_LIMIT - len(CUT)] + CUT)
                else:
                    self.assertTrue(added.endswith(CUT), added[-40:])
                    self.assertTrue(long.startswith(added[:-len(CUT)]))
                    self.assertLessEqual(utf16(added), CURSOR_LIMIT)
                    self.assertGreater(utf16(added), CURSOR_LIMIT - 500)
                self.assert_delivered(queued[0])
                self.assert_waiting(queued[1])
                self.assertEqual(self.deliver('cursor', payload('cursor', conversation)),
                                 output('cursor', [queued[1].message]))
                self.assert_delivered(queued[1])

    def test_cursor_counts_a_report_of_an_unreadable_entry_against_the_limit(self):
        """A report that would not fit waits like a result: its entry keeps its own name, and it is
        reported, and only then kept as <name>.invalid, with the next message."""
        for fits in (True, False):
            with self.subTest(fits=fits):
                conversation = str(uuid.uuid4())
                entry = self.entry('cursor', 2, conversation=conversation)
                entry.write_bytes(BROKEN)
                reported = report(entry, BROKEN_PROBLEM)
                first = self.queue('cursor', message_of(CURSOR_LIMIT - 2 - utf16(reported) + (not fits)),
                                   conversation=conversation, at=1)
                kept = entry.with_name(entry.name + '.invalid')
                added = self.deliver('cursor', payload('cursor', conversation))
                self.assert_delivered(first)
                if fits:
                    self.assertEqual(added, output('cursor', [first.message, reported]))
                else:
                    self.assertEqual(added, output('cursor', [first.message]))
                    self.assertEqual(sorted(entry.parent.iterdir()), [entry])
                    self.assertEqual(entry.read_bytes(), BROKEN)
                    self.assertEqual(self.deliver('cursor', payload('cursor', conversation)),
                                     output('cursor', [reported]))
                self.assertEqual(sorted(entry.parent.iterdir()), [kept])
                self.assertEqual(kept.read_bytes(), BROKEN)
                self.assertEqual(self.deliver('cursor', payload('cursor', conversation)), {})

    def test_antigravity_takes_every_result_at_once(self):
        queued = [self.queue('antigravity', message_of(400, tag=f'[Ralph result] #{number:02d} '))
                  for number in range(30)] + [self.queue('antigravity', message_of(3 * CURSOR_LIMIT))]
        self.assertEqual(self.deliver('antigravity'), output('antigravity', [q.message for q in queued]))
        self.assert_delivered(*queued)

    def test_long_reports_and_notes_are_cut(self):
        """A report of an unreadable entry keeps its first 2,000 characters, and a note on a result file
        that cannot record the delivery keeps the first 300 of the problem; stderr gets all of it."""
        self.home = self.home / Path(*['d' * 200] * 11)
        self.home.mkdir(parents=True)
        for agent in AGENTS:
            with self.subTest(agent=agent):
                entry = self.entry(agent, 1)
                entry.write_bytes(BROKEN)
                queued = self.queue(agent, at=2)
                queued_entry = queued.entry.read_bytes()
                queued.result_file.unlink()
                full = report(entry, BROKEN_PROBLEM)
                problem = missing(queued.result_file)
                self.assertGreater(len(full), 2000)
                self.assertGreater(len(problem), 300)
                self.assertEqual(self.call(agent), (0, output(agent, [
                    full[:2000], queued.message + NOTE.format(problem[:300])]), unrecorded(queued, problem)))
                self.assertEqual(sorted(self.inbox(agent).iterdir()),
                                 [entry.with_name(entry.name + '.invalid'),
                                  queued.entry.with_name(queued.entry.name + '.delivered')])
                self.assert_marked_delivered(queued, queued_entry)

    def test_a_result_another_call_took_first_is_left_to_it(self):
        """Two calls may list the same entry; the one that loses the rename leaves that result to the
        other and takes the rest."""
        for agent in AGENTS:
            with self.subTest(agent=agent):
                taken, left = self.queue(agent), self.queue(agent)
                result = self.staged(RIVAL, agent, taken.entry)
                self.assertEqual((result.returncode, result.stderr), (0, b''))
                self.assertEqual(json.loads(result.stdout), output(agent, [left.message]))
                self.assert_delivered(left)
                self.assertEqual(sorted(self.inbox(agent).iterdir()),
                                 [taken.entry.with_name(taken.entry.name + '.1.claimed')])
                self.assertEqual(json.loads(taken.result_file.read_text()), taken.state)

    def test_an_abandoned_claim_another_call_puts_back_first_is_taken_as_usual(self):
        """Two calls may both find a claim abandoned; the one that loses the rename back goes on and
        takes the result under its own name."""
        ended = subprocess.Popen(['true'])
        ended.wait()
        for agent in AGENTS:
            with self.subTest(agent=agent):
                queued = self.queue(agent)
                abandoned = Path(f'{queued.entry}.{ended.pid}.claimed')
                queued.entry.rename(abandoned)
                result = self.staged(PUT_BACK_FIRST, agent, abandoned)
                self.assertEqual((result.returncode, result.stderr), (0, b''))
                self.assertEqual(json.loads(result.stdout), output(agent, [queued.message]))
                self.assert_delivered(queued)

    def test_concurrent_calls_add_each_result_once(self):
        for agent in AGENTS:
            with self.subTest(agent=agent):
                queued = [self.queue(agent) for _ in range(40)]
                calls = [subprocess.Popen(PYTHON + [str(HOOK), agent], stdin=subprocess.PIPE,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=HOSTILE,
                                          env={**os.environ, 'HOME': str(self.home)})
                         for _ in range(6)]
                # Each call reads its input to the end, so closing the inputs starts them together.
                for call in calls:
                    call.stdin.write(json.dumps(payload(agent)).encode())
                for call in calls:
                    call.stdin.close()
                # Reap the calls only once all have ended: an unreaped call still counts as alive, so no
                # call takes another's finished claim, which vanishes, for an abandoned one.
                outputs = []
                for call in calls:
                    with call.stdout, call.stderr:
                        outputs.append((call.stdout.read(), call.stderr.read()))
                messages = []
                for call, (stdout, stderr) in zip(calls, outputs):
                    self.assertEqual((call.wait(timeout=30), stderr), (0, b''))
                    messages += messages_in(agent, json.loads(stdout))
                # Cursor leaves what did not fit for the next message.
                for _ in queued:
                    added = self.deliver(agent)
                    if not added:
                        break
                    messages += messages_in(agent, added)
                else:
                    self.fail('the inbox never emptied')
                self.assertEqual(sorted(messages), sorted(q.message for q in queued))
                self.assert_delivered(*queued)
                self.assertEqual(list(self.inbox(agent).iterdir()), [])


unittest.main(argv=['ralph-result-hook.tests'])
PY

printf 'PASS: Ralph result hook adds queued results to the next Cursor message or agy turn oldest first within the Cursor context limit, records delivery only after writing its output (or marks it .delivered), recovers abandoned claims, drops duplicates, keeps unreadable entries, and takes nothing on invalid input.\n'
