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


class NotifyTests(unittest.TestCase):
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
sys.exit(int(os.environ.get('QUEUE_FAIL', '0')))
''')
        codex.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        QUEUE_CALLS=str(self.root / 'queue.jsonl'))
        self.env.pop('RALPH_RUN_ACTIVE', None)
        self.runs = []
        self.worker('completed')

    def tearDown(self):
        for run in self.runs:
            self.wait(run)
        self.temp.cleanup()

    def worker(self, mode, delay=0):
        footer = {
            'completed': 'completed=1\niterationsRun=1\nmaxIterations=0\nblocked=0',
            'blocked': 'completed=0\niterationsRun=3\nmaxIterations=0\nblocked=1',
            'limit': 'completed=0\niterationsRun=2\nmaxIterations=2\nblocked=0',
            'invalid': 'completed=1',
            'failure': '',
        }[mode]
        code = 7 if mode == 'failure' else 1 if mode == 'blocked' else 0
        (self.bin / 'ralph-run-codex.sh').write_text(
            f"#!/bin/bash\nsleep {delay}\nprintf 'PRIVATE_WORKER_LOG\\n'\n"
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
        for mode, expected in [('blocked', 'blocked'), ('limit', 'limit_reached'),
                               ('failure', 'failed'), ('invalid', 'failed')]:
            with self.subTest(mode=mode):
                self.worker(mode)
                result = self.launch('--max-iterations', '2')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.wait(json.loads(result.stdout))['status'], expected)

    def test_real_runner_queues_completion_keeps_details_local_and_releases_lock(self):
        for name in ('ralph-run-codex.sh', 'ralph-state.py'):
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

    def test_status_detects_lost_supervisor_without_restart(self):
        path = self.root / 'lost.json'
        path.write_text(json.dumps(dict(status='running', supervisor_pid=os.getpid(),
                                        supervisor_identity='not-the-current-process')))
        result = subprocess.run([sys.executable, str(self.script), '--status', str(path)],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)['status'], 'monitoring_lost')
        self.assertFalse((self.root / 'queue.jsonl').exists())


if __name__ == '__main__':
    unittest.main()
