#!/usr/bin/env python3
"""Exercise real detached processes with fake work and fake Codex queue (no model calls)."""
import json
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'skills/ralph-run/scripts/ralph-notify.py'
THREAD = '11111111-1111-4111-8111-111111111111'
# The caller's own Ralph and Codex settings, which must never reach a launcher under test.
AMBIENT = ('RALPH_RUN_ACTIVE', 'CODEX_HOME', 'RALPH_MODEL', 'RALPH_REVIEW_MODEL')
# What the initiating Cursor or Antigravity session exports to the shell that starts Ralph: its
# identity, and credentials with which an unattended run could ask the open session for a password.
SESSION_VARIABLES = ('CURSOR_CONVERSATION_ID', 'CURSOR_AGENT', 'CURSOR_ASKPASS_SECRET',
                     'CURSOR_ASKPASS_SOCKET', 'CURSOR_REQUEST_ID', 'SUDO_ASKPASS',
                     'ANTIGRAVITY_CONVERSATION_ID', 'ANTIGRAVITY_CSRF_TOKEN', 'ANTIGRAVITY_LS_ADDRESS',
                     'ANTIGRAVITY_SIDECAR_UI_TOKEN')
# Cursor CLI signs in from this variable, so it is the one CURSOR_* variable a run keeps.
CURSOR_SIGN_IN = {'CURSOR_API_KEY': 'fixture-api-key'}
# A second launch's refusal while a supervisor still holds the Ralph directory.
ALREADY_ACTIVE = ('a Ralph notification supervisor is already active: a run is still going, or a '
                  'finished run is still delivering its result')
# A fake runner line that saves the runner's whole environment for recorded_environ().
RECORD_ENVIRON = 'env -0 > "$RUNNER_ENVIRON"\n'
# Lines of a fake delivery CLI. With FAKE_GROUP set, the CLI starts a child that sleeps in the CLI's
# process group and saves both processes to FAKE_GROUP as [pid, /proc start time]. On SIGTERM the CLI
# takes half a second to exit, as a CLI finishing its request might, so a supervisor that leaves
# without waiting for it leaves it running.
DELIVERY_GROUP = r"""import json, os, signal, subprocess, time
if os.environ.get('FAKE_GROUP'):
    def finish_slowly(signum, frame):
        time.sleep(0.5)
        os._exit(128 + signum)
    signal.signal(signal.SIGTERM, finish_slowly)
    child = subprocess.Popen(['sleep', '30'], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def started(pid):
        with open(f'/proc/{pid}/stat') as stat:
            return stat.read().rsplit(')', 1)[1].split()[19]
    with open(os.environ['FAKE_GROUP'] + '.tmp', 'w') as stream:
        json.dump({'CLI': [os.getpid(), started(os.getpid())],
                   'child': [child.pid, started(child.pid)]}, stream)
    os.replace(os.environ['FAKE_GROUP'] + '.tmp', os.environ['FAKE_GROUP'])
"""
# How ralph-notify.py gives `codex queue` its fixed 30 seconds.
QUEUE_TIMEOUT = "'--message', message], 30,"


def without_delivery_delay(script, delay=0):
    """Let a copied launcher deliver after DELAY seconds instead of the production minute."""
    text = script.read_text()
    assert text.count('DELIVERY_DELAY = 60\n') == 1
    script.write_text(text.replace('DELIVERY_DELAY = 60\n', f'DELIVERY_DELAY = {delay}\n'))


def isolated_env(root, **extra):
    """This process's environment with HOME under the temporary root and without AMBIENT."""
    env = {name: value for name, value in os.environ.items() if name not in AMBIENT}
    env.update(HOME=str(root / 'home'), RUNNER_ENV=str(root / 'runner-env.txt'), **extra)
    return env


def fake_runner(before=''):
    """A runner that runs the shell lines BEFORE and then prints a completed run's final footer."""
    return ('#!/bin/bash\n' + before + "cat <<'EOF'\ncompleted=1\niterationsRun=1\nmaxIterations=10\n"
            'progress=/fixture/progress.txt\nlogs=/fixture/logs\nEOF\n')


def recorded_environ(path):
    """The environment a fake runner saved with RECORD_ENVIRON."""
    return dict(os.fsdecode(entry).split('=', 1) for entry in path.read_bytes().split(b'\0') if entry)


def alive(pid, identity):
    """Whether PID is still the running process with this /proc start time, as ralph-notify.py checks."""
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    except FileNotFoundError:
        return False
    return fields[0] != 'Z' and fields[19] == identity


def kill_leftovers(group):
    """Kill whatever of a delivery group (SupervisorTestCase.delivery_group) a failing test left."""
    for pid, identity in group.values():
        if alive(pid, identity):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


class SupervisorTestCase(unittest.TestCase):
    """Checks shared by the Codex and the Cursor and Antigravity supervisors."""

    def report(self, script, run):
        """What `ralph-notify.py --status` reports for the run."""
        result = subprocess.run([sys.executable, str(script), '--status', run['result_file']],
                                env=self.env, capture_output=True, text=True, check=True, timeout=15)
        return json.loads(result.stdout)

    def wait_for_exit(self, state, deadline):
        """Wait until the supervisor recorded in STATE has exited; fail if it runs past DEADLINE."""
        while alive(state['supervisor_pid'], state['supervisor_identity']):
            if time.monotonic() > deadline:
                self.fail('the supervisor is still running')
            time.sleep(0.01)

    def wait_until_released(self, deadline):
        """Wait until no supervisor holds the Ralph directory; fail if one still does after DEADLINE."""
        with (self.ralph / 'logs/notify.lock').open('a') as lock:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    return
                except BlockingIOError:
                    if time.monotonic() > deadline:
                        self.fail('a supervisor still holds the Ralph directory')
                    time.sleep(0.01)

    def delivery_group(self, path):
        """The delivery CLI and its child once a fake CLI run with FAKE_GROUP=PATH has started them
        (see DELIVERY_GROUP). Whatever of them is left when the test ends is killed."""
        deadline = time.monotonic() + 10
        while not path.exists():
            if time.monotonic() > deadline:
                self.fail('the delivery CLI did not start its child')
            time.sleep(0.01)
        group = json.loads(path.read_text())
        self.addCleanup(kill_leftovers, group)
        return group

    def assert_stopped(self, group):
        """Assert that neither the delivery CLI nor its child is still running."""
        self.assertEqual([name for name, (pid, identity) in group.items() if alive(pid, identity)],
                         [], 'still running')

    def assert_stop_ends_delivery(self, script, run, group, signum):
        """Send SIGNUM to RUN's supervisor while its delivery GROUP runs. The whole group must be gone
        by the time the Ralph directory is free, then the supervisor must exit and leave the result
        pending, which --status reports as lost."""
        state = json.loads(Path(run['result_file']).read_text())
        self.assertEqual((state['status'], state['notification']), ('completed', 'pending'))
        signalled = time.monotonic()
        os.kill(run['supervisor_pid'], signum)
        self.runs.remove(run)  # The stopped supervisor delivers nothing to wait for.
        self.wait_until_released(signalled + 3)
        self.assert_stopped(group)
        self.wait_for_exit(state, signalled + 3)
        self.assertEqual(json.loads(Path(run['result_file']).read_text())['notification'], 'pending')
        reported = self.report(script, run)
        self.assertEqual((reported['status'], reported['notification']), ('completed', 'lost'))
        self.assertTrue(reported['notification_error'])


class NotifyTests(SupervisorTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.ralph = self.root / 'project/scripts/ralph'
        self.ralph.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(self.ralph.parent.parent)], check=True)
        (self.ralph / 'prd.json').write_text('{}')
        (self.ralph / 'CLAUDE.md').write_text('fixture')
        self.script = self.bin / SOURCE.name
        shutil.copyfile(SOURCE, self.script)
        shutil.copyfile(SOURCE.with_name('ralph_runtime.py'), self.bin / 'ralph_runtime.py')
        shutil.copyfile(SOURCE.with_name('ralph_models.py'), self.bin / 'ralph_models.py')
        (self.bin / 'codex-runtime.json').write_text(json.dumps({
            'schema': 1, 'codex': str(self.bin / 'codex'), 'setup_version': 'fixture',
        }))
        codex = self.bin / 'codex'
        codex.write_text('''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:] == ['queue', '--help']:
    print('--thread')
    sys.exit(int(os.environ.get('HELP_FAIL', '0')))
with open(os.environ['QUEUE_CALLS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
''' + DELIVERY_GROUP + '''time.sleep(float(os.environ.get('FAKE_DELAY', '0')))
sys.exit(int(os.environ.get('QUEUE_FAIL', '0')))
''')
        codex.chmod(0o755)
        self.env = isolated_env(self.root, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                                QUEUE_CALLS=str(self.root / 'queue.jsonl'))
        self.runs = []
        self.worker('completed')

    def tearDown(self):
        for run in self.runs:
            self.wait(run)
        self.temp.cleanup()

    def worker(self, mode, delay=0):
        footer = {
            'completed': 'completed=1\niterationsRun=1\nmaxIterations=10',
            'limit': 'completed=0\niterationsRun=2\nmaxIterations=2',
            'invalid': 'completed=1',
            'failure': '',
        }[mode]
        code = 7 if mode == 'failure' else 0
        (self.bin / 'ralph-run-codex.sh').write_text(
            f"#!/bin/bash\nsleep {delay}\nprintf 'PRIVATE_WORKER_LOG\\n'\n"
            + 'printf "%s|%s" "${RALPH_MODEL:-}" "${RALPH_REVIEW_MODEL:-}" > "$RUNNER_ENV"\n'
            + "cat <<'EOF'\n" + footer + '\nprogress=/fixture/progress.txt\nlogs=/fixture/logs\nEOF\n'
            + f'exit {code}\n')

    def launch(self, *extra):
        result = subprocess.run([sys.executable, str(self.script), '--thread', THREAD,
                                 '--ralph-dir', str(self.ralph), *extra],
                                env=self.env, capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            run = json.loads(result.stdout)
            self.runs.append(run)
        return result

    def wait(self, run):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = json.loads(Path(run['result_file']).read_text())
            if state['notification'] in ('queued', 'failed'):
                return state
            time.sleep(0.02)
        self.fail('supervisor failed to finish')

    def test_completion_detaches_and_queues_only_summary(self):
        self.worker('completed', 0.4)
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        run = json.loads(result.stdout)
        self.assertEqual(json.loads(Path(run['result_file']).read_text())['status'], 'running')
        state = self.wait(run)
        self.assertEqual(state['status'], 'completed')
        calls = (self.root / 'queue.jsonl').read_text().splitlines()
        self.assertEqual(len(calls), 1)
        args = json.loads(calls[0])
        self.assertEqual(args[:3], ['queue', '--thread', THREAD])
        self.assertNotIn('PRIVATE_WORKER_LOG', args[-1])
        self.assertNotIn('PRIVATE_WORKER_LOG', result.stdout)
        self.assertIn('PRIVATE_WORKER_LOG', Path(state['log']).read_text())

    def test_invalid_runtime_refuses_before_start(self):
        record = self.bin / 'codex-runtime.json'
        for content in (None, '{}', '[]', '{broken',
                        json.dumps({'schema': 1, 'codex': 'codex'}),
                        json.dumps({'schema': 1, 'codex': str(self.root / 'missing')})):
            with self.subTest(content=content):
                if content is None:
                    record.unlink()
                else:
                    record.write_text(content)
                result = self.launch()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.ralph / 'logs/runs').exists())
                self.assertFalse((self.root / 'queue.jsonl').exists())

    def test_terminal_states(self):
        for mode, expected in [('limit', 'limit_reached'),
                               ('failure', 'failed'), ('invalid', 'failed')]:
            with self.subTest(mode=mode):
                self.worker(mode)
                result = self.launch('--max-iterations', '2')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.wait(json.loads(result.stdout))['status'], expected)

    def test_real_runner_queues_completion_keeps_details_local_and_releases_lock(self):
        for name in ('ralph-run-codex.sh', 'ralph-loop.sh', 'ralph-state.py'):
            shutil.copyfile(SOURCE.with_name(name), self.bin / name)
        shutil.copytree(SOURCE.parent.parent / 'assets', self.root / 'assets')
        project = self.ralph.parent.parent
        (self.ralph / 'prd.json').write_text(json.dumps({
            'project': 'fixture', 'branchName': 'test/notify', 'description': 'fixture',
            'userStories': [{'id': 'US-001', 'title': 'Write fixture',
                             'description': 'Exercise the real runner',
                             'acceptanceCriteria': ['Write app.txt'], 'priority': 1,
                             'passes': False, 'notes': ''}],
        }))
        for args in [('config', 'user.email', 'fixture@example.invalid'),
                     ('config', 'user.name', 'Fixture'), ('add', '-A'),
                     ('commit', '-qm', 'fixture')]:
            subprocess.run(['git', '-C', str(project), *args], check=True)
        background_pids = self.root / 'background-pids.jsonl'
        self.env['BACKGROUND_PIDS'] = str(background_pids)
        codex = self.bin / 'codex'
        codex.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
assert os.environ['CODEX_HOME'] == os.environ['EXPECTED_CODEX_HOME']
if args == ['queue', '--help']:
    print('--thread')
    sys.exit(0)
if args[0] == 'queue':
    with open(os.environ['QUEUE_CALLS'], 'a') as stream:
        stream.write(json.dumps(args) + '\\n')
    sys.exit(0)
assert args[0] == 'exec', args
root = pathlib.Path(args[args.index('--cd') + 1])
output = pathlib.Path(args[args.index('--output-last-message') + 1])
child = subprocess.Popen(['sleep', '30'], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         close_fds=False)
with open(os.environ['BACKGROUND_PIDS'], 'a') as stream:
    stream.write(json.dumps(child.pid) + '\\n')
if '--output-schema' in args:
    print('PRIVATE_REVIEWER_DETAILS')
    output.write_text(json.dumps({'approved': True, 'findings': []}))
else:
    print('PRIVATE_WORKER_DETAILS')
    prd = root / 'scripts/ralph/prd.json'
    document = json.loads(prd.read_text())
    document['userStories'][0]['passes'] = True
    prd.write_text(json.dumps(document))
    (root / 'app.txt').write_text('implementation')
    output.write_text('worker finished')
''')
        # Reproduce the desktop app PATH: an incompatible CLI shadows the setup CLI.
        shadow = self.root / 'old-bin'
        shadow.mkdir()
        (shadow / 'codex').write_text('#!/bin/sh\nexit 99\n')
        (shadow / 'codex').chmod(0o755)
        self.env['PATH'] = str(shadow) + os.pathsep + self.env['PATH']
        self.env['CODEX_HOME'] = str(self.root / 'windows-app-home')
        self.env['EXPECTED_CODEX_HOME'] = self.env['CODEX_HOME']
        try:
            result = self.launch()
            self.assertEqual(result.returncode, 0, result.stderr)
            state = self.wait(json.loads(result.stdout))
            self.assertEqual(state['status'], 'completed', Path(state['log']).read_text())
            self.assertEqual(state['codex'], str(codex))
            self.assertEqual(state['exit_code'], 0)
            self.assertEqual(state['iterations_run'], 1)
            calls = (self.root / 'queue.jsonl').read_text().splitlines()
            self.assertEqual(len(calls), 1)
            queue_args = json.loads(calls[0])
            self.assertEqual(queue_args[:3], ['queue', '--thread', THREAD])
            self.assertIn('"status": "completed"', queue_args[-1])
            iteration_log = (self.ralph / 'logs/codex-iteration-1.log').read_text()
            for detail in ('PRIVATE_WORKER_DETAILS', 'PRIVATE_REVIEWER_DETAILS'):
                self.assertIn(detail, iteration_log)
                self.assertNotIn(detail, Path(state['log']).read_text())
                self.assertNotIn(detail, result.stdout)
                self.assertNotIn(detail, queue_args[-1])
            pids = [json.loads(line) for line in background_pids.read_text().splitlines()]
            self.assertEqual(len(pids), 2)
            for pid in pids:
                os.kill(pid, 0)  # Both descendants must still be alive during this check.
            with (project / '.git/ralph-run.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            if background_pids.exists():
                for line in background_pids.read_text().splitlines():
                    try:
                        os.kill(json.loads(line), signal.SIGTERM)
                    except ProcessLookupError:
                        pass

    def test_codex_models_are_recorded_and_passed_without_a_model_list(self):
        self.worker('completed')
        default = self.wait(json.loads(self.launch().stdout))
        self.assertNotIn('worker_model', default)
        self.assertEqual((self.root / 'runner-env.txt').read_text(), '|')
        (self.root / 'home/.codex').mkdir(parents=True)
        (self.root / 'home/.codex/ralph.json').write_text(json.dumps({'review_model': 'saved-reviewer'}))
        state = self.wait(json.loads(self.launch('--model', 'gpt-6-sol').stdout))
        self.assertEqual((state['worker_model'], state['review_model']), ('gpt-6-sol', 'saved-reviewer'))
        self.assertEqual((self.root / 'runner-env.txt').read_text(), 'gpt-6-sol|saved-reviewer')
        self.assertNotEqual(self.launch('--model', 'has space').returncode, 0)

    def test_notification_failure_is_durable_without_retry(self):
        self.env['QUEUE_FAIL'] = '8'
        result = self.launch()
        state = self.wait(json.loads(result.stdout))
        self.assertEqual(state['status'], 'completed')
        self.assertEqual(state['notification'], 'failed')
        self.assertEqual(state['notification_exit_code'], 8)
        self.assertEqual(len((self.root / 'queue.jsonl').read_text().splitlines()), 1)

    def test_duplicate_launch_rejected(self):
        self.worker('completed', 0.5)
        self.assertEqual(self.launch().returncode, 0)
        second = self.launch()
        self.assertNotEqual(second.returncode, 0)
        self.assertIn('already active', second.stderr)
        self.assertIn(ALREADY_ACTIVE, second.stderr)

    def test_session_variables_still_reach_the_codex_runner(self):
        """Only a Cursor or Antigravity supervisor drops the initiating session's variables."""
        session = {name: 'initiating-' + name.lower() for name in SESSION_VARIABLES}
        session.update(CURSOR_SIGN_IN)
        self.env.update(session, RALPH_TEST_MARKER='kept',
                        RUNNER_ENVIRON=str(self.root / 'runner-environ'))
        (self.bin / 'ralph-run-codex.sh').write_text(fake_runner(RECORD_ENVIRON))
        state = self.wait(json.loads(self.launch().stdout))
        self.assertEqual(state['status'], 'completed')
        seen = recorded_environ(self.root / 'runner-environ')
        self.assertEqual({name: seen.get(name) for name in session}, session)
        self.assertEqual(seen.get('RALPH_TEST_MARKER'), 'kept')

    def test_invalid_input_and_missing_queue_never_start(self):
        for extra in [('--thread', 'invalid'), ('--max-iterations', '-1')]:
            self.assertNotEqual(self.launch(*extra).returncode, 0)
        self.env['HELP_FAIL'] = '1'
        self.assertNotEqual(self.launch().returncode, 0)
        self.assertFalse((self.ralph / 'logs').exists())

    def test_nested_start_rejected(self):
        self.env['RALPH_RUN_ACTIVE'] = '1'
        self.assertNotEqual(self.launch().returncode, 0)
        self.assertFalse((self.ralph / 'logs').exists())

    def test_interrupt_reports_failure_and_stops_child(self):
        self.worker('completed', 5)
        result = self.launch()
        run = json.loads(result.stdout)
        os.kill(run['supervisor_pid'], signal.SIGTERM)
        state = self.wait(run)
        self.assertEqual(state['status'], 'interrupted')
        self.assertNotEqual(state['exit_code'], 0)

    def test_a_stop_during_the_queue_ends_codex_and_its_children_first(self):
        """A SIGTERM or SIGINT to the supervisor while `codex queue` runs stops that CLI and every
        process it started, and waits for them, before the supervisor exits and frees the Ralph
        directory; the result stays pending, which --status reports as lost."""
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum.name):
                group = self.root / f'queue-group-{signum.name}.json'
                self.env.update(FAKE_DELAY='3', FAKE_GROUP=str(group))
                result = self.launch()
                self.assertEqual(result.returncode, 0, result.stderr)
                run = json.loads(result.stdout)
                self.assert_stop_ends_delivery(self.script, run, self.delivery_group(group), signum)

    def test_a_queue_timeout_ends_codex_and_its_children(self):
        """When `codex queue` outlasts its 30 seconds, that CLI and every process it started are
        stopped and reaped before the failure is recorded."""
        text = self.script.read_text()
        self.assertEqual(text.count(QUEUE_TIMEOUT), 1)
        self.script.write_text(text.replace(QUEUE_TIMEOUT, QUEUE_TIMEOUT.replace(' 30,', ' 1,')))
        group = self.root / 'queue-group.json'
        self.env.update(FAKE_DELAY='3', FAKE_GROUP=str(group))
        run = json.loads(self.launch().stdout)
        started = self.delivery_group(group)
        state = self.wait(run)
        self.assertEqual(state['status'], 'completed')
        self.assertEqual(state['notification'], 'failed')
        self.assertIn('timed out', state['notification_error'])
        self.assert_stopped(started)

    def test_status_detects_lost_supervisor_without_restart(self):
        path = self.root / 'lost.json'
        path.write_text(json.dumps(dict(status='running', supervisor_pid=os.getpid(),
                                        supervisor_identity='not-the-current-process')))
        result = subprocess.run([sys.executable, str(self.script), '--status', str(path)],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)['status'], 'monitoring_lost')
        self.assertFalse((self.root / 'queue.jsonl').exists())



CONVERSATION = '22222222-2222-4222-8222-222222222222'
# A fake Cursor or agy CLI. It answers --help, and for a result delivery it records its arguments,
# RALPH_RUN_ACTIVE, its whole environment and when it was called, runs DELIVERY_GROUP, sleeps
# FAKE_DELAY seconds, then prints the reply configured by the test. The time is on the monotonic
# clock, which every process shares: WSL steps the wall clock back by seconds, and the supervisor
# times the delay on the monotonic clock as well.
FAKE_AGENT = r"""#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
agent = os.environ['FAKE_AGENT_KIND']
if args == ['models']:
    if agent == 'cursor':
        print('Available models\n\nauto - Auto (current, default)\nmodel-a - Model A\nmodel-b - Model B')
    else:
        print('model-a\tModel A\nmodel-b\tModel B')
    sys.exit(int(os.environ.get('FAKE_MODELS_EXIT', '0')))
if args == ['--help']:
    text = '--resume' if agent == 'cursor' else '--conversation'
    text = os.environ.get('FAKE_HELP', text)
    print(text, file=sys.stdout if agent == 'cursor' else sys.stderr)
    sys.exit(0)
with open(os.environ['DELIVERY_CALLS'], 'a') as stream:
    stream.write(json.dumps({'args': args, 'active': os.environ.get('RALPH_RUN_ACTIVE'),
                             'cwd': os.getcwd(), 'at': time.monotonic(),
                             'env': dict(os.environ)}) + '\n')
""" + DELIVERY_GROUP + r"""time.sleep(float(os.environ.get('FAKE_DELAY', '0')))
reply = os.environ.get('FAKE_REPLY')
if reply is None:
    conversation = os.environ.get('FAKE_REPLY_CONVERSATION', '""" + CONVERSATION + r"""')
    if agent == 'cursor':
        reply = json.dumps({'type': 'result', 'subtype': 'success',
                            'is_error': os.environ.get('FAKE_UNSUCCESSFUL') == '1',
                            'session_id': conversation, 'result': 'summary'})
    else:
        reply = json.dumps({'conversation_id': conversation,
                            'status': 'ERROR' if os.environ.get('FAKE_UNSUCCESSFUL') == '1' else 'SUCCESS',
                            'response': 'summary'})
print(reply)
sys.exit(int(os.environ.get('FAKE_EXIT', '0')))
"""


class AgentNotifyTests(SupervisorTestCase):
    """The Cursor and Antigravity supervisors deliver the result by resuming the conversation."""

    AGENTS = {'cursor': 'ralph-run-cursor.sh', 'antigravity': 'ralph-run-antigravity.sh'}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.project = self.root / 'project'
        self.ralph = self.project / 'scripts/ralph'
        self.ralph.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(self.project)], check=True)
        (self.ralph / 'prd.json').write_text('{}')
        (self.ralph / 'CLAUDE.md').write_text('fixture')
        self.runs = []

    def tearDown(self):
        for run in self.runs:
            self.wait(run)
        self.temp.cleanup()

    def reset(self):
        """Start a subtest from a fresh fixture after cleaning up the previous one."""
        self.tearDown()
        self.setUp()

    def install(self, agent, footer='completed=1\niterationsRun=1\nmaxIterations=10', runner=None,
                delay=0):
        skill = self.root / f'skill-{agent}'
        scripts = skill / 'scripts'
        scripts.mkdir(parents=True)
        shutil.copyfile(SOURCE, scripts / SOURCE.name)
        without_delivery_delay(scripts / SOURCE.name, delay)
        shutil.copyfile(SOURCE.with_name('ralph_runtime.py'), scripts / 'ralph_runtime.py')
        shutil.copyfile(SOURCE.with_name('ralph_models.py'), scripts / 'ralph_models.py')
        cli = self.root / f'fake-{agent}'
        cli.write_text(FAKE_AGENT)
        cli.chmod(0o755)
        (scripts / f'{agent}-runtime.json').write_text(json.dumps(
            {'schema': 1, agent: str(cli), 'setup_version': 'fixture'}))
        (scripts / self.AGENTS[agent]).write_text(runner or (
            "#!/bin/bash\nprintf 'PRIVATE_WORKER_LOG\\n'\n"
            'printf "%s|%s" "${RALPH_MODEL:-}" "${RALPH_REVIEW_MODEL:-}" > "$RUNNER_ENV"\n'
            "cat <<'EOF'\n" + footer
            + '\nprogress=/fixture/progress.txt\nlogs=/fixture/logs\nEOF\n'))
        self.env = self.agent_env(agent)
        return scripts / SOURCE.name

    def agent_env(self, agent):
        """The isolated launcher environment for a skill of this agent, with its fake CLI's variables."""
        return isolated_env(self.root, FAKE_AGENT_KIND=agent,
                            DELIVERY_CALLS=str(self.root / 'delivery.jsonl'))

    def launch(self, script, *extra, conversation=CONVERSATION):
        args = [sys.executable, str(script), '--ralph-dir', str(self.ralph), *extra]
        if conversation is not None:
            args[2:2] = ['--conversation', conversation]
        result = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            self.runs.append(json.loads(result.stdout))
        return result

    def wait(self, run):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            state = json.loads(Path(run['result_file']).read_text())
            if state['notification'] in ('delivered', 'failed'):
                return state
            time.sleep(0.02)
        self.fail('supervisor failed to finish')

    def calls(self):
        path = self.root / 'delivery.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def pending(self, run):
        """The state once the run is over and its result waits to be delivered."""
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = json.loads(Path(run['result_file']).read_text())
            if state['notification'] == 'pending':
                return state
            time.sleep(0.02)
        self.fail('the run did not end')

    def test_result_is_delivered_to_the_initiating_conversation(self):
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                result = self.launch(script)
                self.assertEqual(result.returncode, 0, result.stderr)
                state = self.wait(json.loads(result.stdout))
                self.assertEqual(state['status'], 'completed')
                self.assertEqual(state['notification'], 'delivered', state)
                self.assertEqual((state['agent'], state['conversation']), (agent, CONVERSATION))
                self.assertNotIn('thread', state)
                calls = self.calls()
                self.assertEqual(len(calls), 1)
                args, message = calls[0]['args'], calls[0]['args'][-1]
                self.assertTrue(message.startswith('[Ralph result] '))
                self.assertNotIn('PRIVATE_WORKER_LOG', message)
                self.assertEqual(calls[0]['active'], '1')
                self.assertEqual(calls[0]['cwd'], str(self.project))
                if agent == 'cursor':
                    self.assertEqual(args[:-1], ['-p', f'--resume={CONVERSATION}', '--trust',
                                                 '--workspace', str(self.project),
                                                 '--output-format', 'json'])
                else:
                    self.assertEqual(args[:-1], ['--conversation', CONVERSATION,
                                                 '--output-format', 'json', '-p'])
                self.assertNotIn('--force', args)
                self.assertNotIn('--dangerously-skip-permissions', args)
                self.wait(json.loads(result.stdout))

    def test_failed_delivery_is_durable_without_retry(self):
        cases = {
            'another conversation': {'FAKE_REPLY_CONVERSATION': '33333333-3333-4333-8333-333333333333'},
            'unsuccessful turn': {'FAKE_UNSUCCESSFUL': '1'},
            'exit status': {'FAKE_EXIT': '5'},
            'invalid reply': {'FAKE_REPLY': 'not json'},
            'non-object reply': {'FAKE_REPLY': '[]'},
        }
        for agent in self.AGENTS:
            for name, env in cases.items():
                with self.subTest(agent=agent, case=name):
                    self.reset()
                    script = self.install(agent)
                    self.env.update(env)
                    result = self.launch(script)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    state = self.wait(json.loads(result.stdout))
                    self.assertEqual(state['status'], 'completed')
                    self.assertEqual(state['notification'], 'failed')
                    self.assertTrue(state['notification_error'])
                    self.assertEqual(len(self.calls()), 1)

    def test_a_quick_run_waits_before_resuming_the_conversation(self):
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent, delay=2)
                started = time.monotonic()
                state = self.wait(json.loads(self.launch(script).stdout))
                self.assertEqual(state['notification'], 'delivered', state)
                self.assertGreaterEqual(time.monotonic() - started, 2)
                # The conversation itself is resumed only after the delay, not just the state saved.
                calls = self.calls()
                self.assertEqual(len(calls), 1)
                self.assertGreaterEqual(calls[0]['at'] - started, 2)

    def test_a_stopped_run_waits_the_delay_from_its_end(self):
        """A run stopped from the conversation ends while that turn is still answering, so even a run
        that outlasted DELIVERY_DELAY waits it again from the moment it was stopped. A SIGTERM to the
        supervisor during the run still stops the runner, marks the run interrupted and delivers."""
        delay = 1
        # (agent, what the test signals, the runner's own SIGTERM handling, the signal, run status)
        cases = [('cursor', 'supervisor', '', signal.SIGTERM, 'interrupted'),
                 # Stopped by the request alone: the runner exits with an ordinary status.
                 ('antigravity', 'supervisor', "trap 'exit 1' TERM\n", signal.SIGTERM, 'interrupted'),
                 # A runner killed by a signal, or reporting one as 128+n, was stopped as well.
                 ('cursor', 'runner', '', signal.SIGKILL, 'failed'),
                 ('antigravity', 'runner', "trap 'exit 143' TERM\n", signal.SIGTERM, 'failed')]
        for agent, target, trap, signum, expected in cases:
            with self.subTest(agent=agent, target=target, signal=signum.name, trap=trap.strip()):
                self.reset()
                script = self.install(agent, delay=delay, runner=f'#!/bin/bash\n{trap}sleep 30\n')
                run = json.loads(self.launch(script).stdout)
                time.sleep(delay + 0.3)
                state = json.loads(Path(run['result_file']).read_text())
                stopped = time.monotonic()
                if target == 'supervisor':
                    os.kill(run['supervisor_pid'], signum)
                else:
                    os.killpg(state['runner_pid'], signum)
                self.assertEqual(state['status'], 'running')  # The run outlasted the delay.
                state = self.wait(run)
                self.assertEqual(state['status'], expected)
                self.assertNotEqual(state['exit_code'], 0)
                self.assertEqual(state['notification'], 'delivered', state)
                calls = self.calls()
                self.assertEqual(len(calls), 1)
                self.assertGreaterEqual(calls[0]['at'] - stopped, delay)

    def test_a_run_that_outlasts_the_delay_is_delivered_without_waiting_again(self):
        """Only a stopped run waits from its end; a run that ends by itself after DELIVERY_DELAY has
        passed is delivered at once."""
        delay = 2
        script = self.install('antigravity', delay=delay, runner=fake_runner(
            f'sleep {delay + 0.5}\n'
            "python3 -c 'import time; print(time.monotonic())' > \"$RUNNER_ENDED\"\n"))
        self.env['RUNNER_ENDED'] = str(self.root / 'runner-ended')
        state = self.wait(json.loads(self.launch(script).stdout))
        self.assertEqual(state['status'], 'completed')
        self.assertEqual(state['notification'], 'delivered', state)
        calls = self.calls()
        self.assertEqual(len(calls), 1)
        self.assertLess(calls[0]['at'] - float((self.root / 'runner-ended').read_text()), delay)

    def test_a_stop_after_the_run_ends_the_supervisor_without_delivery(self):
        """Once the runner has exited, SIGTERM or SIGINT ends the supervisor at once instead of letting
        it wait out DELIVERY_DELAY and deliver; --status then reports the result as lost."""
        for agent in self.AGENTS:
            for signum in (signal.SIGTERM, signal.SIGINT):
                with self.subTest(agent=agent, signal=signum.name):
                    self.reset()
                    script = self.install(agent, delay=3)
                    run = json.loads(self.launch(script).stdout)
                    state = self.pending(run)
                    self.assertEqual(state['status'], 'completed')
                    self.assertEqual(self.report(script, run)['notification'], 'pending')
                    # The finished run holds the Ralph directory until it has delivered its result.
                    second = self.launch(script)
                    self.assertNotEqual(second.returncode, 0)
                    self.assertIn(ALREADY_ACTIVE, second.stderr)
                    signalled = time.monotonic()
                    os.kill(run['supervisor_pid'], signum)
                    self.wait_for_exit(state, signalled + 1.5)
                    self.runs.remove(run)  # Nothing is left to wait for.
                    self.assertEqual(self.calls(), [])
                    saved = json.loads(Path(run['result_file']).read_text())
                    self.assertEqual(saved['notification'], 'pending')
                    reported = self.report(script, run)
                    self.assertEqual((reported['status'], reported['notification']),
                                     ('completed', 'lost'))
                    self.assertTrue(reported['notification_error'])

    def test_a_stop_during_delivery_ends_the_cli_and_its_children_first(self):
        """A SIGTERM or SIGINT to the supervisor while the CLI resumes the conversation stops that CLI
        and every process it started, and waits for them, before the supervisor exits and frees the
        Ralph directory; the result stays pending, which --status reports as lost."""
        for agent in self.AGENTS:
            for signum in (signal.SIGTERM, signal.SIGINT):
                with self.subTest(agent=agent, signal=signum.name):
                    self.reset()
                    script = self.install(agent)
                    group = self.root / 'delivery-group.json'
                    self.env.update(FAKE_DELAY='3', FAKE_GROUP=str(group))
                    result = self.launch(script)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    run = json.loads(result.stdout)
                    self.assert_stop_ends_delivery(script, run, self.delivery_group(group), signum)
                    self.assertEqual(len(self.calls()), 1)

    def test_the_initiating_session_reaches_neither_the_runner_nor_the_delivery(self):
        """Cursor and Antigravity export the initiating session's identity and credentials to the
        shell that starts Ralph; the runner and the result delivery get the rest of the environment
        without any CURSOR_* or ANTIGRAVITY_* variable or SUDO_ASKPASS, but with CURSOR_API_KEY."""
        session = {name: 'initiating-' + name.lower() for name in SESSION_VARIABLES}
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent, runner=fake_runner(RECORD_ENVIRON))
                self.env.update(session, **CURSOR_SIGN_IN, RALPH_TEST_MARKER='kept',
                                RUNNER_ENVIRON=str(self.root / 'runner-environ'))
                state = self.wait(json.loads(self.launch(script).stdout))
                self.assertEqual(state['status'], 'completed')
                self.assertEqual(state['notification'], 'delivered', state)
                calls = self.calls()
                self.assertEqual(len(calls), 1)
                for where, seen in (('runner', recorded_environ(self.root / 'runner-environ')),
                                    ('delivery', calls[0]['env'])):
                    self.assertEqual([name for name in SESSION_VARIABLES if name in seen], [], where)
                    self.assertEqual([name for name in seen if name == 'SUDO_ASKPASS' or (
                        name.startswith(('CURSOR_', 'ANTIGRAVITY_')) and name not in CURSOR_SIGN_IN)],
                        [], where)
                    self.assertEqual({name: seen.get(name) for name in CURSOR_SIGN_IN},
                                     CURSOR_SIGN_IN, where)
                    self.assertEqual(seen.get('RALPH_TEST_MARKER'), 'kept', where)
                    self.assertEqual(seen.get('PATH'), self.env['PATH'], where)

    def test_delivery_timeout_is_recorded(self):
        """When DELIVERY_TIMEOUT expires, the CLI and every process it started are stopped and reaped
        before the failure is recorded."""
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                script.write_text(script.read_text().replace('DELIVERY_TIMEOUT = 600',
                                                             'DELIVERY_TIMEOUT = 1'))
                group = self.root / 'delivery-group.json'
                self.env.update(FAKE_DELAY='5', FAKE_GROUP=str(group))
                run = json.loads(self.launch(script).stdout)
                started = self.delivery_group(group)
                state = self.wait(run)
                self.assertEqual(state['notification'], 'failed')
                self.assertIn('timed out', state['notification_error'])
                self.assert_stopped(started)

    def test_invalid_start_never_runs(self):
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                self.assertNotEqual(self.launch(script, conversation=None).returncode, 0)
                self.assertNotEqual(self.launch(script, conversation='invalid').returncode, 0)
                self.assertNotEqual(self.launch(script, '--thread', CONVERSATION).returncode, 0)
                self.env['FAKE_HELP'] = 'no such option'
                refused = self.launch(script)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn('refusing to start', refused.stderr)
                self.assertFalse((self.ralph / 'logs/runs').exists())
                self.assertEqual(self.calls(), [])

    def test_models_are_checked_recorded_and_passed_to_the_runner(self):
        settings = {'cursor': 'home/.cursor/ralph.json',
                    'antigravity': 'home/.gemini/antigravity-cli/ralph.json'}
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                path = self.root / settings[agent]
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps({'model': 'model-a'}))
                state = self.wait(json.loads(self.launch(script, '--review-model', 'model-b').stdout))
                self.assertEqual((state['worker_model'], state['review_model']), ('model-a', 'model-b'))
                self.assertEqual((self.root / 'runner-env.txt').read_text(), 'model-a|model-b')
                # A model the CLI does not list is refused before anything starts.
                refused = self.launch(script, '--model', 'not-listed')
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn("does not offer the model 'not-listed'", refused.stderr)
                self.env['FAKE_MODELS_EXIT'] = '3'
                self.assertIn('could not list its models', self.launch(script).stderr)
                del self.env['FAKE_MODELS_EXIT']
                path.write_text('{"model": "has space"}')
                self.assertIn('not a valid model name', self.launch(script).stderr)
                self.assertEqual(len(list((self.ralph / 'logs/runs').iterdir())), 1)

    def test_cursor_parameterized_models_are_left_to_cursor(self):
        # `agent models` lists no parameterized names; Cursor checks them in the first iteration.
        script = self.install('cursor')
        state = self.wait(json.loads(self.launch(script, '--model', 'model-z[effort=high]').stdout))
        self.assertEqual((state['worker_model'], state['review_model']),
                         ('model-z[effort=high]', 'model-z[effort=high]'))
        self.assertEqual((self.root / 'runner-env.txt').read_text(),
                         'model-z[effort=high]|model-z[effort=high]')
        # Only the parameterized name skips the list; the reviewer's plain name is still checked.
        refused = self.launch(script, '--model', 'model-z[effort=high]', '--review-model', 'not-listed')
        self.assertIn("does not offer the model 'not-listed'", refused.stderr)
        # Antigravity has no parameterized names, so the same spelling must be listed there.
        self.reset()
        script = self.install('antigravity')
        refused = self.launch(script, '--model', 'model-a[effort=high]')
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("does not offer the model 'model-a[effort=high]'", refused.stderr)

    def test_an_explicitly_empty_run_model_is_refused(self):
        """An empty --model or --review-model is an error, never the saved or CLI default model."""
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                for option, origin in (('--model', 'the run model'),
                                       ('--review-model', 'the run review model')):
                    refused = self.launch(script, option, '')
                    self.assertNotEqual(refused.returncode, 0, option)
                    self.assertIn(f"{origin} is not a valid model name: ''", refused.stderr)
                self.assertFalse((self.ralph / 'logs/runs').exists())
                self.assertEqual(self.calls(), [])

    def test_a_second_runtime_record_is_refused(self):
        script = self.install('antigravity')
        (script.parent / 'codex-runtime.json').write_text(
            json.dumps({'schema': 1, 'codex': str(self.root / 'fake-antigravity')}))
        result = self.launch(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exactly one Ralph runtime record', result.stderr)

    def test_a_missing_or_second_runtime_record_is_reported_whatever_the_options(self):
        """Without exactly one runtime record no agent is known, so the launcher reports the record
        itself, not a problem with the conversation options, and starts nothing."""
        cases = {'no record': ((), 'none'),
                 'two records': (('codex', 'cursor'), 'codex-runtime.json, cursor-runtime.json')}
        options = {'--conversation': ('--conversation', CONVERSATION),
                   '--thread': ('--thread', CONVERSATION), 'neither': ()}
        for case, (records, found) in cases.items():
            for name, identity in options.items():
                with self.subTest(case=case, options=name):
                    self.reset()
                    script = self.install('cursor')
                    (script.parent / 'cursor-runtime.json').unlink()
                    for agent in records:
                        (script.parent / f'{agent}-runtime.json').write_text(json.dumps(
                            {'schema': 1, agent: str(self.root / 'fake-cursor'), 'setup_version': 'fixture'}))
                    result = self.launch(script, *identity, conversation=None)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(result.stderr.startswith(
                        'error: expected exactly one Ralph runtime record'), result.stderr)
                    self.assertIn(f'found {found}; rerun Downloads/setup-wsl.cmd', result.stderr)
                    self.assertFalse((self.ralph / 'logs/runs').exists())
                    self.assertEqual(self.calls(), [])

    def test_real_runner_and_delivery_for_each_agent(self):
        root = Path(__file__).resolve().parents[1]
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                skill = self.root / f'skill-{agent}'
                # install.sh parses its positional arguments when sourced, so pass values by name.
                subprocess.run(['bash', '-c', 'source "$INSTALL_SH" && stage_agent_ralph_skill "$AGENT" "$DEST"'],
                               env=isolated_env(self.root, INSTALL_SH=str(root / 'install.sh'),
                                                AGENT=agent, DEST=str(skill)), check=True)
                cli = self.root / f'fake-{agent}'
                cli.write_text(REAL_RUN_AGENT)
                cli.chmod(0o755)
                (skill / f'scripts/{agent}-runtime.json').write_text(json.dumps(
                    {'schema': 1, agent: str(cli), 'setup_version': 'fixture'}))
                without_delivery_delay(skill / 'scripts' / SOURCE.name)
                (self.ralph / 'prd.json').write_text(json.dumps({
                    'project': 'fixture', 'branchName': 'test/notify', 'description': 'fixture',
                    'userStories': [{'id': 'US-001', 'title': 'Write fixture',
                                     'description': 'Exercise the real runner',
                                     'acceptanceCriteria': ['Write app.txt'], 'priority': 1,
                                     'passes': False, 'notes': ''}]}))
                for args in [('config', 'user.email', 'fixture@example.invalid'),
                             ('config', 'user.name', 'Fixture'), ('add', '-A'),
                             ('commit', '-qm', 'fixture')]:
                    subprocess.run(['git', '-C', str(self.project), *args], check=True)
                self.env = self.agent_env(agent)
                result = self.launch(skill / 'scripts' / SOURCE.name)
                self.assertEqual(result.returncode, 0, result.stderr)
                state = self.wait(json.loads(result.stdout))
                self.assertEqual(state['status'], 'completed', Path(state['log']).read_text())
                self.assertEqual(state['notification'], 'delivered', state)
                self.assertEqual(state['iterations_run'], 1)
                log = subprocess.check_output(['git', '-C', str(self.project), 'log', '-1', '--format=%s'],
                                              text=True)
                self.assertIn('feat: US-001 - Write fixture', log)
                self.assertTrue((self.ralph / f'logs/{agent}-iteration-1.log').exists())


# A fake CLI that plays worker, reviewer and result delivery for the real runner.
REAL_RUN_AGENT = r"""#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
agent = os.environ['FAKE_AGENT_KIND']
if args == ['--help']:
    print('--resume --conversation', file=sys.stderr if agent == 'antigravity' else sys.stdout)
    sys.exit(0)
if agent == 'cursor':
    prompt = args[-1]
    cwd = pathlib.Path(args[args.index('--workspace') + 1])
    resumed = next((a.split('=', 1)[1] for a in args if a.startswith('--resume=')), None)
else:
    prompt = args[args.index('-p') + 1]
    cwd = pathlib.Path.cwd()
    resumed = args[args.index('--conversation') + 1] if '--conversation' in args else None
if resumed:
    with open(os.environ['DELIVERY_CALLS'], 'a') as stream:
        stream.write(json.dumps({'args': args}) + '\n')
    if agent == 'cursor':
        print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False,
                          'session_id': resumed}))
    else:
        print(json.dumps({'conversation_id': resumed, 'status': 'SUCCESS', 'response': 'ok'}))
    sys.exit(0)
if 'independent fail-close and clean-break policy reviewer' in prompt:
    tree = subprocess.check_output(['git', '-C', str(cwd), 'write-tree'], text=True).strip()
    review = {'approved': True, 'findings': [], 'reviewed_tree': tree}
    final = json.dumps(review)
else:
    prd = cwd / 'scripts/ralph/prd.json'
    document = json.loads(prd.read_text())
    document['userStories'][0]['passes'] = True
    prd.write_text(json.dumps(document))
    (cwd / 'app.txt').write_text('implementation')
    review, final = None, 'worker finished'
if agent == 'cursor':
    for event in [{'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': final}]}},
                  {'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': 'x'}]:
        print(json.dumps(event))
else:
    reply = {'conversation_id': 'x', 'status': 'SUCCESS', 'response': final}
    if review is not None:
        reply['structured_output'] = review
    print(json.dumps(reply))
"""


if __name__ == '__main__':
    unittest.main()
