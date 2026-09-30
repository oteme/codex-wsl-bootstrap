#!/usr/bin/env python3
"""Exercise real detached processes with fake work, a fake Codex queue, fake Cursor and agy CLIs and
the result hook (no model calls)."""
import ctypes
import json
import fcntl
import os
from pathlib import Path
import re
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
# prctl(2) option that gives this process the orphans among its descendants.
PR_SET_CHILD_SUBREAPER = 36


def adopt_orphans(enabled):
    """Make this process the parent of the orphans among its descendants, such as the supervisor a
    launcher leaves behind, so that a test can reap one and read its exit status; or stop doing so."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, int(enabled), 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


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
    """Whether PID is still the running process with this /proc start time, as ralph-notify.py checks.
    Reading the stat of a process that is reaped meanwhile fails with ESRCH, not ENOENT."""
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    except (FileNotFoundError, ProcessLookupError):
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

    def adopt_supervisors(self):
        """Adopt the supervisors that this test's launchers leave behind, for exit_status()."""
        adopt_orphans(True)
        self.addCleanup(adopt_orphans, False)

    def exit_status(self, run):
        """The exit status of RUN's supervisor, adopted with adopt_supervisors(), once it has exited."""
        deadline = time.monotonic() + 10
        while True:
            pid, status = os.waitpid(run['supervisor_pid'], os.WNOHANG)
            if pid:
                return os.waitstatus_to_exitcode(status)
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
OTHER_CONVERSATION = '33333333-3333-4333-8333-333333333333'
HOOK = Path(__file__).resolve().parents[1] / 'hooks/ralph-result-hook.py'
# Where a Cursor or Antigravity supervisor leaves results, under HOME (INBOX in ralph-notify.py).
INBOX = {'cursor': Path('.cursor/ralph-inbox'),
         'antigravity': Path('.gemini/antigravity-cli/ralph-inbox')}
# What follows the summary of the run in a Cursor or Antigravity result message.
AGENT_INSTRUCTIONS = ('\nThis Ralph run has ended. Read the result file and tell the user its outcome '
                      'before answering their message. Do not start another Ralph run because of this '
                      'result unless the user asks for one. Read detailed logs only if needed to explain a '
                      'failure.')
LOST_BEFORE_THE_INBOX = 'the supervisor stopped before it left the result in the inbox'
NOT_RECORDED = 'the result hook could not record the delivery in this file'
# Where setup installs the result hook, under HOME (RESULT_HOOK in ralph-notify.py).
RESULT_HOOK = {'cursor': Path('.cursor/hooks/codex-workstation-bootstrap/ralph-result-hook.py'),
               'antigravity': Path('.gemini/config/hooks/codex-workstation-bootstrap/ralph-result-hook.py')}
# The lines of ralph-notify.py around which a test stops the supervisor or fails a step: leaving the
# result in the inbox (after notification=queued is saved), and publishing the entry there.
QUEUE_CALL = '            queue_result(state, state_path, message)\n'
ENTRY_PUBLISHED = '        temp.replace(inbox / name)\n'
# A fake Cursor or agy CLI that lists models and records the arguments of every call. The launcher only
# lists models; once a run is over, nothing may call the CLI.
FAKE_AGENT = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['AGENT_CALLS'], 'a') as stream:
    stream.write(json.dumps(args) + '\n')
if args == ['models']:
    if os.environ['FAKE_AGENT_KIND'] == 'cursor':
        print('Available models\n\nauto - Auto (current, default)\nmodel-a - Model A\nmodel-b - Model B')
    else:
        print('model-a\tModel A\nmodel-b\tModel B')
    sys.exit(int(os.environ.get('FAKE_MODELS_EXIT', '0')))
sys.exit(97)
"""
# Runs `ralph-notify.py --status RESULT` (arguments: the script, RESULT) while every read under /proc
# fails as it does for a process that is being reaped (ESRCH).
REAPED_WHILE_READ = r'''
import pathlib, runpy, sys
script, result = sys.argv[1:]
read_text = pathlib.Path.read_text
def reaped(self, *args, **kwargs):
    if str(self).startswith('/proc/'):
        raise ProcessLookupError(3, 'No such process')
    return read_text(self, *args, **kwargs)
pathlib.Path.read_text = reaped
sys.path.insert(0, str(pathlib.Path(script).parent))
sys.argv = [script, '--status', result]
runpy.run_path(script, run_name='__main__')
'''
# Runs `ralph-notify.py --status RESULT` (arguments: the script, RESULT) as if the result hook recorded
# the delivery in RESULT, and removed the entry, just after --status first read RESULT.
DELIVERED_MEANWHILE = r'''
import json, pathlib, runpy, sys
script, result = sys.argv[1:]
iterdir = pathlib.Path.iterdir
def delivered_first(self):
    state = json.loads(pathlib.Path(result).read_text())
    if self.name == state['conversation']:
        pathlib.Path(result).write_text(json.dumps({**state, 'notification': 'delivered'}))
    return iterdir(self)
pathlib.Path.iterdir = delivered_first
sys.path.insert(0, str(pathlib.Path(script).parent))
sys.argv = [script, '--status', result]
runpy.run_path(script, run_name='__main__')
'''
# The listings of the caller's own inboxes for the fixture conversations. Every launcher and hook call
# in these tests gets a temporary HOME, so no test may change them (tearDownModule).
REAL_INBOXES = {}


def real_inbox_listing(path):
    return sorted(os.listdir(path)) if path.exists() else None


def setUpModule():
    REAL_INBOXES.update({path: real_inbox_listing(path) for path in (
        Path.home() / inbox / conversation for inbox in INBOX.values()
        for conversation in (CONVERSATION, OTHER_CONVERSATION))})


def tearDownModule():
    changed = [str(path) for path, listing in REAL_INBOXES.items() if real_inbox_listing(path) != listing]
    if changed:
        raise AssertionError('the tests changed the real inboxes ' + ', '.join(changed))


def agent_message(state, result_file):
    """The message a Cursor or Antigravity supervisor leaves for the run recorded in STATE."""
    return '[Ralph result] ' + json.dumps({
        'run_id': state['run_id'], 'status': state['status'], 'exit_code': state['exit_code'],
        'iterations_run': state['iterations_run'], 'result_file': result_file,
    }, ensure_ascii=False) + AGENT_INSTRUCTIONS


def added(agent, messages):
    """What the result hook prints to add MESSAGES to the conversation's next message."""
    if agent == 'cursor':
        return {'additional_context': '\n\n'.join(messages)}
    return {'injectSteps': [{'userMessage': message} for message in messages]}


def stopped_at(script, line, after=False):
    """Make the supervisor of a copied launcher kill itself just before (or after) LINE, as a stop
    request or a crash could end it there."""
    text = script.read_text()
    assert text.count(line) == 1, line
    kill = line[:len(line) - len(line.lstrip())] + 'os.kill(os.getpid(), signal.SIGKILL)\n'
    script.write_text(text.replace(line, line + kill if after else kill + line))


def failing_at(script, line):
    """Make the supervisor of a copied launcher fail with an I/O error just before LINE."""
    text = script.read_text()
    assert text.count(line) == 1, line
    error = line[:len(line) - len(line.lstrip())] + "raise OSError(5, 'injected failure')\n"
    script.write_text(text.replace(line, error + line))


class AgentNotifyTests(SupervisorTestCase):
    """The Cursor and Antigravity supervisors leave the result in the initiating conversation's inbox,
    where the result hook adds it to that conversation's next message."""

    AGENTS = {'cursor': 'ralph-run-cursor.sh', 'antigravity': 'ralph-run-antigravity.sh'}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'  # HOME in isolated_env()
        self.project = self.root / 'project'
        self.ralph = self.ralph_dir(self.project)
        self.runs = []

    def tearDown(self):
        for run in self.runs:
            self.wait(run)
        self.temp.cleanup()

    def reset(self):
        """Start a subtest from a fresh fixture after cleaning up the previous one."""
        self.tearDown()
        self.setUp()

    def ralph_dir(self, project):
        """The Ralph directory of a new git project at PROJECT."""
        ralph = project / 'scripts/ralph'
        ralph.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        (ralph / 'prd.json').write_text('{}')
        (ralph / 'CLAUDE.md').write_text('fixture')
        return ralph

    def install(self, agent, runner=None):
        """Install a copy of the launcher as AGENT's Ralph skill, with a fake CLI and RUNNER. The default
        runner completes a run, once the file RUNNER_GATE exists if that is set (within 30 seconds), and
        saves the models it got in RUNNER_ENV."""
        skill = self.root / f'skill-{agent}'
        scripts = skill / 'scripts'
        scripts.mkdir(parents=True)
        shutil.copyfile(SOURCE, scripts / SOURCE.name)
        shutil.copyfile(SOURCE.with_name('ralph_runtime.py'), scripts / 'ralph_runtime.py')
        shutil.copyfile(SOURCE.with_name('ralph_models.py'), scripts / 'ralph_models.py')
        cli = self.root / f'fake-{agent}'
        cli.write_text(FAKE_AGENT)
        cli.chmod(0o755)
        (scripts / f'{agent}-runtime.json').write_text(json.dumps(
            {'schema': 1, agent: str(cli), 'setup_version': 'fixture'}))
        self.install_result_hook(agent)
        (scripts / self.AGENTS[agent]).write_text(runner or fake_runner(
            'for _ in {1..1500}; do\n'
            '  [[ -z "${RUNNER_GATE:-}" || -e "$RUNNER_GATE" ]] && break\n'
            '  sleep 0.02\n'
            'done\n'
            "printf 'PRIVATE_WORKER_LOG\\n'\n"
            'printf "%s|%s" "${RALPH_MODEL:-}" "${RALPH_REVIEW_MODEL:-}" > "$RUNNER_ENV"\n'))
        self.env = self.agent_env(agent)
        return scripts / SOURCE.name

    def install_result_hook(self, agent):
        """Install the result hook where setup puts it for AGENT, which start() requires."""
        installed = self.home / RESULT_HOOK[agent]
        installed.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HOOK, installed)
        return installed

    def agent_env(self, agent):
        """The isolated launcher environment for a skill of this agent, with its fake CLI's variables."""
        return isolated_env(self.root, FAKE_AGENT_KIND=agent,
                            AGENT_CALLS=str(self.root / 'agent-calls.jsonl'))

    def launch(self, script, *extra, conversation=CONVERSATION, ralph=None):
        args = [sys.executable, str(script), '--ralph-dir', str(ralph or self.ralph), *extra]
        if conversation is not None:
            args[2:2] = ['--conversation', conversation]
        result = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            self.runs.append(json.loads(result.stdout))
        return result

    def wait(self, run, timeout=10):
        """RUN's result file once its supervisor has exited; nothing is left to wait for after the run."""
        self.wait_for_exit(json.loads(Path(run['result_file']).read_text()), time.monotonic() + timeout)
        return json.loads(Path(run['result_file']).read_text())

    def calls(self):
        """The arguments of every call of the fake CLI so far."""
        path = self.root / 'agent-calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def inbox(self, agent, conversation=CONVERSATION):
        return self.home / INBOX[agent] / conversation

    def entry(self, agent, run):
        """RUN's entry, the only file in the conversation's inbox, named by its end time and the run."""
        files = list(self.inbox(agent).iterdir())
        self.assertEqual(len(files), 1, files)
        self.assertRegex(files[0].name, r'^\d{20}-' + re.escape(run['run_id']) + r'\.json$')
        return files[0]

    def run_hook(self, agent, conversation=CONVERSATION):
        """Run the installed result hook as the CLI does before CONVERSATION's next message."""
        payload = ({'hook_event_name': 'beforeSubmitPrompt', 'conversation_id': conversation}
                   if agent == 'cursor' else {'invocationNum': 0, 'conversationId': conversation})
        return subprocess.run(['/usr/bin/python3', '-B', str(self.home / RESULT_HOOK[agent]), agent],
                              input=json.dumps(payload), env=self.env, capture_output=True, text=True,
                              timeout=30)

    def hook(self, agent, conversation=CONVERSATION):
        """What the result hook adds to CONVERSATION's next message; the call must succeed quietly."""
        result = self.run_hook(agent, conversation)
        self.assertEqual((result.returncode, result.stderr), (0, ''))
        return json.loads(result.stdout)

    def test_a_finished_run_leaves_its_result_in_the_conversations_inbox(self):
        """However the run ends, the supervisor records notification=queued, leaves one entry with the
        result message in the initiating conversation's inbox under HOME, calls no CLI to deliver it,
        exits 0 and frees the Ralph directory."""
        endings = {
            'completed': (None, None, ('completed', 0, 1)),
            'failed': ('#!/bin/bash\nprintf "PRIVATE_WORKER_LOG\\n"\nexit 7\n', None, ('failed', 7, None)),
            # A stop request ends the runner's process group; bash dies of the signal.
            'interrupted': ('#!/bin/bash\nsleep 30\n', signal.SIGTERM,
                            ('interrupted', -signal.SIGTERM, None)),
        }
        self.adopt_supervisors()
        for agent in self.AGENTS:
            other = next(name for name in self.AGENTS if name != agent)
            for ending, (runner, stop, outcome) in endings.items():
                with self.subTest(agent=agent, ending=ending):
                    self.reset()
                    script = self.install(agent, runner)
                    result = self.launch(script)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    run = json.loads(result.stdout)
                    if stop:
                        os.kill(run['supervisor_pid'], stop)
                    self.assertEqual(self.exit_status(run), 0)
                    state = self.wait(run)
                    self.assertEqual((state['status'], state['exit_code'], state['iterations_run']), outcome)
                    self.assertEqual(state['notification'], 'queued', state)
                    self.assertNotIn('notification_error', state)
                    self.assertEqual((state['agent'], state['conversation']), (agent, CONVERSATION))
                    self.assertNotIn('thread', state)
                    entry = self.entry(agent, run)
                    self.assertEqual(json.loads(entry.read_text()), {
                        'run_id': run['run_id'], 'result_file': run['result_file'],
                        'message': agent_message(state, run['result_file'])})
                    self.assertNotIn('PRIVATE_WORKER_LOG', entry.read_text())
                    # Nothing else in the inboxes: no temporary file, no other conversation or agent.
                    inboxes = self.home / INBOX[agent]
                    self.assertEqual(sorted(path.relative_to(inboxes) for path in inboxes.rglob('*')),
                                     [Path(CONVERSATION), Path(CONVERSATION, entry.name)])
                    self.assertFalse((self.home / INBOX[other]).exists())
                    self.assertEqual(self.calls(), [])
                    self.wait_until_released(time.monotonic())
                    self.assertEqual(self.report(script, run)['notification'], 'queued')

    def test_the_next_run_starts_once_the_supervisor_has_queued_the_result(self):
        """Nothing waits for the conversation after a run: once its supervisor has left the result and
        exited, the next run in the Ralph directory starts, and its result sorts after the first."""
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                first = json.loads(self.launch(script).stdout)
                self.wait(first)
                second = self.launch(script)
                self.assertEqual(second.returncode, 0, second.stderr)
                second = json.loads(second.stdout)
                self.wait(second)
                self.assertEqual([path.name[21:] for path in sorted(self.inbox(agent).iterdir())],
                                 [f"{first['run_id']}.json", f"{second['run_id']}.json"])

    def test_results_of_one_conversation_arrive_in_the_order_their_runs_ended(self):
        """Two Ralph directories started from the same conversation: the run started first ends last,
        so its result sorts after the other's, and the result hook adds it after the other."""
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                gate = self.root / 'gate'
                self.env['RUNNER_GATE'] = str(gate)
                slow = json.loads(self.launch(script).stdout)
                del self.env['RUNNER_GATE']
                try:
                    quick = self.launch(script, ralph=self.ralph_dir(self.root / 'other project'))
                    self.assertEqual(quick.returncode, 0, quick.stderr)
                    quick = json.loads(quick.stdout)
                    ended = [self.wait(quick)]
                finally:
                    gate.touch()  # Only now does the run started first end.
                ended.append(self.wait(slow))
                messages = [agent_message(state, run['result_file'])
                            for state, run in zip(ended, (quick, slow))]
                entries = sorted(self.inbox(agent).iterdir())
                self.assertEqual([entry.name[21:] for entry in entries],
                                 [f"{quick['run_id']}.json", f"{slow['run_id']}.json"])
                self.assertEqual([json.loads(entry.read_text())['message'] for entry in entries], messages)
                self.assertEqual(self.hook(agent), added(agent, messages))
                for run in (quick, slow):
                    self.assertEqual(self.report(script, run)['notification'], 'delivered')

    def test_a_result_sorts_after_every_result_still_in_the_inbox(self):
        """WSL steps the wall clock back by seconds, so a result is numbered after every result still in
        the inbox, whether waiting, being taken or kept as unreadable, even one numbered ahead of the
        clock. The supervisor's unpublished temporary files do not count."""
        ahead = time.time_ns() + 10 ** 12  # about 17 minutes ahead of the clock
        earlier = '55555555-5555-4555-8555-555555555555'
        lettered = 'abcdef01-2345-4678-9abc-def012345678'  # upper case makes it no run ID
        cases = {
            'waiting': ([f'{ahead:020d}-{earlier}.json'], ahead + 1),
            'being taken': ([f'{ahead:020d}-{earlier}.json',
                             f'{ahead + 5:020d}-{earlier}.json.{os.getpid()}.claimed'], ahead + 6),
            'kept as unreadable': ([f'{ahead + 9:020d}-{earlier}.json.invalid'], ahead + 10),
            'a temporary file': ([f'{ahead:020d}-{earlier}.json', f'.{ahead + 100:020d}-{earlier}.json.tmp'],
                                 ahead + 1),
            'names that are not results': ([f'{ahead:020d}-{earlier}.json', '1' * 21 + '-notes.txt',
                                            '²3-notes.txt', f'{ahead + 7:020d}-{lettered.upper()}.json',
                                            f'{ahead + 8:020d}-{earlier}.json.backup',
                                            f'{ahead + 9:020d}-{earlier}.json.x.claimed'], ahead + 1),
        }
        for agent in self.AGENTS:
            for case, (names, number) in cases.items():
                with self.subTest(agent=agent, case=case):
                    self.reset()
                    script = self.install(agent)
                    result_file = self.root / 'earlier-result.json'
                    result_file.write_text(json.dumps({'run_id': earlier, 'notification': 'queued'}))
                    inbox = self.inbox(agent)
                    inbox.mkdir(parents=True)
                    entry = {'run_id': earlier, 'result_file': str(result_file),
                             'message': 'an earlier result'}
                    for name in names:
                        (inbox / name).write_text(json.dumps(entry))
                    run = json.loads(self.launch(script).stdout)
                    state = self.wait(run)
                    self.assertEqual(sorted(path.name for path in inbox.iterdir()),
                                     sorted([*names, f"{number:020d}-{run['run_id']}.json"]))
                    if case == 'waiting':
                        self.assertEqual(self.hook(agent), added(agent, [
                            'an earlier result', agent_message(state, run['result_file'])]))

    def test_the_result_hook_adds_the_result_to_the_conversations_next_message(self):
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                run = json.loads(self.launch(script).stdout)
                queued = self.wait(run)
                message = json.loads(self.entry(agent, run).read_text())['message']
                self.assertEqual(self.hook(agent, OTHER_CONVERSATION), {})
                self.assertEqual(self.hook(agent), added(agent, [message]))
                self.assertEqual(json.loads(Path(run['result_file']).read_text()),
                                 {**queued, 'notification': 'delivered'})
                self.assertEqual(list(self.inbox(agent).iterdir()), [])
                self.assertEqual(self.report(script, run)['notification'], 'delivered')
                self.assertEqual(self.hook(agent), {})

    def test_a_result_the_inbox_cannot_take_is_recorded_as_failed(self):
        """When the result cannot be left in the inbox, because a file stands where the conversation's
        inbox belongs or because no 20-digit number sorts after the results already there, the
        supervisor records notification=failed with the error, tries nothing else and exits 1."""
        last = f'{10 ** 20 - 1}-55555555-5555-4555-8555-555555555555.json'
        self.adopt_supervisors()
        for agent in self.AGENTS:
            for case in ('a file for the inbox', 'no number left'):
                with self.subTest(agent=agent, case=case):
                    self.reset()
                    script = self.install(agent)
                    inbox = self.inbox(agent)
                    if case == 'a file for the inbox':
                        inbox.parent.mkdir(parents=True)
                        inbox.write_text('not an inbox\n')
                        error = f'[Errno 17] File exists: {str(inbox)!r}'
                    else:
                        inbox.mkdir(parents=True)
                        (inbox / last).write_text('{}')
                        error = f'the results in {inbox} leave no 20-digit number for this one'
                    before = sorted(path.relative_to(self.home) for path in self.home.rglob('*'))
                    run = json.loads(self.launch(script).stdout)
                    self.assertEqual(self.exit_status(run), 1)
                    state = self.wait(run)
                    self.assertEqual((state['status'], state['notification'], state['notification_error']),
                                     ('completed', 'failed', error))
                    self.assertEqual(sorted(path.relative_to(self.home) for path in self.home.rglob('*')),
                                     before)
                    self.assertEqual(self.calls(), [])
                    reported = self.report(script, run)
                    self.assertEqual((reported['notification'], reported['notification_error']),
                                     ('failed', error))
                    self.wait_until_released(time.monotonic())

    def test_a_supervisor_stopped_before_the_inbox_leaves_its_result_lost(self):
        """Stopped between recording queued and leaving the entry, the supervisor leaves nothing for the
        result hook, and --status reports the result lost."""
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                stopped_at(script, QUEUE_CALL)
                run = json.loads(self.launch(script).stdout)
                state = self.wait(run)
                self.assertEqual((state['status'], state['notification']), ('completed', 'queued'))
                self.assertFalse(self.inbox(agent).exists())
                reported = self.report(script, run)
                self.assertEqual((reported['notification'], reported['notification_error']),
                                 ('lost', LOST_BEFORE_THE_INBOX))
                self.assertEqual(self.hook(agent), {})

    def test_a_result_in_the_inbox_arrives_though_the_supervisor_stops_right_after(self):
        """The supervisor records queued before it publishes the entry, so a supervisor stopped right
        after leaves a result that --status reports queued and the result hook delivers."""
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                stopped_at(script, ENTRY_PUBLISHED, after=True)
                run = json.loads(self.launch(script).stdout)
                state = self.wait(run)
                self.assertEqual((state['status'], state['notification']), ('completed', 'queued'))
                message = json.loads(self.entry(agent, run).read_text())['message']
                self.assertEqual(message, agent_message(state, run['result_file']))
                self.assertEqual(self.report(script, run)['notification'], 'queued')
                self.assertEqual(self.hook(agent), added(agent, [message]))
                self.assertEqual(self.report(script, run)['notification'], 'delivered')

    def test_status_reports_a_queued_result_the_inbox_never_got_as_lost(self):
        """Once the supervisor has gone, --status reports a queued result lost unless the inbox still
        holds it: waiting, being taken by the result hook, or kept as unreadable. A live supervisor may
        still be leaving it, and a Codex run's queued means that codex queue took it. The result hook's
        <entry>.delivered marker means it delivered the result without recording it in the file."""
        script = self.install('cursor')
        run_id = '44444444-4444-4444-8444-444444444444'
        other_run = '55555555-5555-4555-8555-555555555555'
        me = Path(f'/proc/{os.getpid()}/stat').read_text().rsplit(')', 1)[1].split()[19]
        gone = {'supervisor_pid': os.getpid(), 'supervisor_identity': 'not-the-current-process'}
        live = {'supervisor_pid': os.getpid(), 'supervisor_identity': me}
        entry = f'{time.time_ns():020d}-{run_id}.json'
        cases = {
            'nothing in the inbox': (gone, CONVERSATION, [], 'lost'),
            'waiting': (gone, CONVERSATION, [entry], 'queued'),
            'being taken': (gone, CONVERSATION, [f'{entry}.4242.claimed'], 'queued'),
            'kept as unreadable': (gone, CONVERSATION, [f'{entry}.invalid'], 'queued'),
            # The result hook never takes the supervisor's unpublished temporary file.
            'only its unpublished temporary file': (gone, CONVERSATION, [f'.{entry}.tmp'], 'lost'),
            'only names that are not results': (gone, CONVERSATION, [
                entry[1:], f'{entry}.backup', f'{entry}.x.claimed'], 'lost'),
            'only another run waiting': (gone, CONVERSATION, [entry.replace(run_id, other_run)], 'lost'),
            'waiting for another conversation': (gone, OTHER_CONVERSATION, [entry], 'lost'),
            'the supervisor still running': (live, CONVERSATION, [], 'queued'),
            'delivered, not recorded': (gone, CONVERSATION, [f'{entry}.delivered'], 'delivered'),
            'delivered, not recorded, before the supervisor ended': (
                live, CONVERSATION, [f'{entry}.delivered'], 'delivered'),
            'another run delivered, not recorded': (
                gone, CONVERSATION, [f'{entry.replace(run_id, other_run)}.delivered'], 'lost'),
        }
        path = self.root / 'result.json'
        for agent in self.AGENTS:
            for case, (supervisor, conversation, files, expected) in cases.items():
                with self.subTest(agent=agent, case=case):
                    shutil.rmtree(self.home, ignore_errors=True)
                    inbox = self.inbox(agent, conversation)
                    inbox.mkdir(parents=True)
                    for name in files:
                        (inbox / name).write_text('{}')
                    state = dict(run_id=run_id, agent=agent, conversation=CONVERSATION, status='completed',
                                 notification='queued', **supervisor)
                    path.write_text(json.dumps(state))
                    if expected == 'lost':
                        state.update(notification='lost', notification_error=LOST_BEFORE_THE_INBOX)
                    elif expected == 'delivered':
                        state.update(notification='delivered', notification_error=NOT_RECORDED)
                    self.assertEqual(self.report(script, {'result_file': str(path)}), state)
        with self.subTest(agent='codex'):
            shutil.rmtree(self.home, ignore_errors=True)
            state = dict(run_id=run_id, thread=THREAD, status='completed', notification='queued', **gone)
            path.write_text(json.dumps(state))
            self.assertEqual(self.report(script, {'result_file': str(path)}), state)

    def test_status_counts_a_supervisor_reaped_while_it_is_read_as_gone(self):
        """Reading /proc of a process that is being reaped fails with ESRCH, not ENOENT; --status then
        counts the supervisor as gone instead of failing."""
        script = self.install('cursor')
        me = Path(f'/proc/{os.getpid()}/stat').read_text().rsplit(')', 1)[1].split()[19]
        path = self.root / 'result.json'
        cases = {
            'a running run': ({'status': 'running'}, {
                'status': 'monitoring_lost', 'error': 'supervisor is not alive; completion is unknown'}),
            'a pending Codex result': ({'status': 'completed', 'notification': 'pending', 'thread': THREAD}, {
                'notification': 'lost',
                'notification_error': 'the supervisor stopped before it delivered the result'}),
        }
        for case, (state, change) in cases.items():
            with self.subTest(case=case):
                state.update(supervisor_pid=os.getpid(), supervisor_identity=me)
                path.write_text(json.dumps(state))
                self.assertEqual(self.report(script, {'result_file': str(path)}), state)
                result = subprocess.run(
                    [sys.executable, '-B', '-c', REAPED_WHILE_READ, str(script), str(path)],
                    env=self.env, capture_output=True, text=True, timeout=15)
                self.assertEqual((result.returncode, result.stderr), (0, ''))
                self.assertEqual(json.loads(result.stdout), {**state, **change})

    def test_status_reads_the_result_file_again_before_it_reports_a_loss(self):
        """The result hook records delivered before it removes the entry, so an empty inbox after a
        queued result file may mean the hook finished in between: --status reads the file again."""
        script = self.install('cursor')
        path = self.root / 'result.json'
        state = dict(run_id='44444444-4444-4444-8444-444444444444', agent='cursor',
                     conversation=CONVERSATION, status='completed', notification='queued',
                     supervisor_pid=os.getpid(), supervisor_identity='not-the-current-process')
        path.write_text(json.dumps(state))
        self.inbox('cursor').mkdir(parents=True)
        result = subprocess.run([sys.executable, '-B', '-c', DELIVERED_MEANWHILE, str(script), str(path)],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual((result.returncode, result.stderr), (0, ''))
        self.assertEqual(json.loads(result.stdout), {**state, 'notification': 'delivered'})

    def test_status_fails_when_it_cannot_read_the_inbox(self):
        """Only a missing inbox means that nothing is there; an inbox that cannot be read makes --status
        fail instead of reporting the result lost."""
        script = self.install('cursor')
        path = self.root / 'result.json'
        path.write_text(json.dumps(dict(
            run_id='44444444-4444-4444-8444-444444444444', agent='cursor', conversation=CONVERSATION,
            status='completed', notification='queued', supervisor_pid=os.getpid(),
            supervisor_identity='not-the-current-process')))
        inbox = self.inbox('cursor')
        inbox.parent.mkdir(parents=True)
        cases = {'a file in its place': 'NotADirectoryError'}
        if os.geteuid() != 0:  # root reads a directory without read permission
            cases['no permission to read it'] = 'PermissionError'
        for case, error in cases.items():
            with self.subTest(case=case):
                if case == 'a file in its place':
                    inbox.write_text('not an inbox\n')
                else:
                    inbox.unlink()
                    inbox.mkdir(mode=0o000)
                try:
                    result = subprocess.run([sys.executable, str(script), '--status', str(path)],
                                            env=self.env, capture_output=True, text=True, timeout=15)
                finally:
                    if inbox.is_dir():
                        inbox.chmod(0o755)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn(error, result.stderr)

    def test_status_reports_a_delivery_the_hook_could_not_record(self):
        """When the result hook delivers a result but cannot record it in the result file, it keeps the
        entry as <entry>.delivered and --status reports the result delivered, with why the file does not
        say so."""
        if os.geteuid() == 0:
            self.skipTest('root writes into a read-only directory')
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                run = json.loads(self.launch(script).stdout)
                queued = self.wait(run)
                entry = self.entry(agent, run)
                message = json.loads(entry.read_text())['message']
                run_dir = Path(run['result_file']).parent
                run_dir.chmod(0o555)
                try:
                    result = self.run_hook(agent)
                finally:
                    run_dir.chmod(0o755)
                self.assertEqual((result.returncode, json.loads(result.stdout)),
                                 (0, added(agent, [message])))
                self.assertTrue(result.stderr.startswith(
                    f'Ralph result hook delivered {entry.name} but could not record it in '
                    f"{run['result_file']}: PermissionError: "), result.stderr)
                self.assertEqual(list(self.inbox(agent).iterdir()),
                                 [entry.with_name(entry.name + '.delivered')])
                self.assertEqual(json.loads(Path(run['result_file']).read_text()), queued)
                self.assertEqual(self.report(script, run),
                                 {**queued, 'notification': 'delivered', 'notification_error': NOT_RECORDED})
                self.assertEqual(self.hook(agent), {})

    def test_a_run_without_the_result_hook_is_refused(self):
        """Without the result hook a queued result would never leave the inbox, so a Cursor or
        Antigravity run starts only once setup has installed it."""
        names = {'cursor': 'Cursor', 'antigravity': 'Antigravity'}
        for agent in self.AGENTS:
            for case in ('missing', 'a directory in its place'):
                with self.subTest(agent=agent, case=case):
                    self.reset()
                    script = self.install(agent)
                    installed = self.home / RESULT_HOOK[agent]
                    installed.unlink()
                    if case == 'a directory in its place':
                        installed.mkdir()
                    result = self.launch(script)
                    self.assertEqual((result.returncode, result.stdout), (1, ''))
                    self.assertEqual(result.stderr,
                                     f'error: the {names[agent]} Ralph result hook is not installed: '
                                     f'{installed}; rerun Downloads/setup-wsl.cmd\n')
                    self.assertFalse((self.ralph / 'logs').exists())
                    self.assertFalse((self.home / INBOX[agent]).exists())
                    self.assertEqual(self.calls(), [])

    def test_a_result_that_cannot_be_published_leaves_no_temporary_file(self):
        """When the entry cannot be published in the inbox, the supervisor removes its temporary file,
        records notification=failed with the error and exits 1."""
        self.adopt_supervisors()
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                failing_at(script, ENTRY_PUBLISHED)
                run = json.loads(self.launch(script).stdout)
                self.assertEqual(self.exit_status(run), 1)
                state = self.wait(run)
                self.assertEqual((state['status'], state['notification'], state['notification_error']),
                                 ('completed', 'failed', '[Errno 5] injected failure'))
                self.assertEqual(list(self.inbox(agent).iterdir()), [])
                self.assertEqual(self.report(script, run)['notification'], 'failed')

    def test_the_initiating_session_does_not_reach_the_runner(self):
        """Cursor and Antigravity export the initiating session's identity and credentials to the shell
        that starts Ralph; the runner gets the rest of the environment without any CURSOR_* or
        ANTIGRAVITY_* variable or SUDO_ASKPASS, but with CURSOR_API_KEY."""
        session = {name: 'initiating-' + name.lower() for name in SESSION_VARIABLES}
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent, runner=fake_runner(RECORD_ENVIRON))
                self.env.update(session, **CURSOR_SIGN_IN, RALPH_TEST_MARKER='kept',
                                RUNNER_ENVIRON=str(self.root / 'runner-environ'))
                state = self.wait(json.loads(self.launch(script).stdout))
                self.assertEqual((state['status'], state['notification']), ('completed', 'queued'))
                seen = recorded_environ(self.root / 'runner-environ')
                self.assertEqual([name for name in SESSION_VARIABLES if name in seen], [])
                self.assertEqual([name for name in seen if name == 'SUDO_ASKPASS' or (
                    name.startswith(('CURSOR_', 'ANTIGRAVITY_')) and name not in CURSOR_SIGN_IN)], [])
                self.assertEqual({name: seen.get(name) for name in CURSOR_SIGN_IN}, CURSOR_SIGN_IN)
                self.assertEqual(seen.get('RALPH_TEST_MARKER'), 'kept')
                self.assertEqual(seen.get('PATH'), self.env['PATH'])
                self.assertEqual(self.calls(), [])

    def test_invalid_start_never_runs(self):
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                self.assertNotEqual(self.launch(script, conversation=None).returncode, 0)
                self.assertNotEqual(self.launch(script, conversation='invalid').returncode, 0)
                self.assertNotEqual(self.launch(script, '--thread', CONVERSATION).returncode, 0)
                self.assertNotEqual(self.launch(script, '--max-iterations', '-1').returncode, 0)
                self.assertFalse((self.ralph / 'logs/runs').exists())
                self.assertFalse((self.home / INBOX[agent]).exists())
                self.assertEqual(self.calls(), [])

    def test_nested_start_rejected(self):
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                self.env['RALPH_RUN_ACTIVE'] = '1'
                result = self.launch(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('refusing to start a nested Ralph runner', result.stderr)
                self.assertFalse((self.ralph / 'logs').exists())
                self.assertFalse((self.home / INBOX[agent]).exists())
                self.assertEqual(self.calls(), [])

    def test_models_are_checked_recorded_and_passed_to_the_runner(self):
        settings = {'cursor': 'home/.cursor/ralph.json',
                    'antigravity': 'home/.gemini/antigravity-cli/ralph.json'}
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                script = self.install(agent)
                path = self.root / settings[agent]
                path.parent.mkdir(parents=True, exist_ok=True)
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
                # Listing the models is the CLI's only use outside the runs.
                self.assertEqual({tuple(call) for call in self.calls()}, {('models',)})

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

    def test_real_runner_for_each_agent_leaves_its_result_for_the_hook(self):
        root = Path(__file__).resolve().parents[1]
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                skill = self.root / f'skill-{agent}'
                # install.sh parses its positional arguments when sourced, so pass values by name.
                subprocess.run(['bash', '-c', 'source "$INSTALL_SH" && stage_agent_ralph_skill "$AGENT" "$DEST"'],
                               env=isolated_env(self.root, INSTALL_SH=str(root / 'install.sh'),
                                                AGENT=agent, DEST=str(skill)), check=True)
                self.install_result_hook(agent)
                cli = self.root / f'fake-{agent}'
                cli.write_text(REAL_RUN_AGENT)
                cli.chmod(0o755)
                (skill / f'scripts/{agent}-runtime.json').write_text(json.dumps(
                    {'schema': 1, agent: str(cli), 'setup_version': 'fixture'}))
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
                run = json.loads(result.stdout)
                state = self.wait(run, timeout=120)
                self.assertEqual(state['status'], 'completed', Path(state['log']).read_text())
                self.assertEqual(state['notification'], 'queued', state)
                self.assertEqual(state['iterations_run'], 1)
                log = subprocess.check_output(['git', '-C', str(self.project), 'log', '-1', '--format=%s'],
                                              text=True)
                self.assertIn('feat: US-001 - Write fixture', log)
                self.assertTrue((self.ralph / f'logs/{agent}-iteration-1.log').exists())
                # The CLI ran for the worker and the reviewer only; nothing resumed the conversation.
                calls = self.calls()
                self.assertEqual(len(calls), 2, calls)
                self.assertEqual([call for call in calls if CONVERSATION in json.dumps(call)], [])
                message = agent_message(state, run['result_file'])
                self.assertEqual(json.loads(self.entry(agent, run).read_text())['message'], message)
                self.assertEqual(self.hook(agent), added(agent, [message]))
                self.assertEqual(self.report(skill / 'scripts' / SOURCE.name, run)['notification'],
                                 'delivered')


# A fake CLI that plays worker and reviewer for the real runner, recording the arguments of every call.
REAL_RUN_AGENT = r"""#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
agent = os.environ['FAKE_AGENT_KIND']
with open(os.environ['AGENT_CALLS'], 'a') as stream:
    stream.write(json.dumps(args) + '\n')
if agent == 'cursor':
    prompt = args[-1]
    cwd = pathlib.Path(args[args.index('--workspace') + 1])
else:
    prompt = args[args.index('-p') + 1]
    cwd = pathlib.Path.cwd()
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
