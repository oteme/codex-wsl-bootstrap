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
sys.exit(int(os.environ.get('QUEUE_FAIL', '0')))
''')
        codex.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        QUEUE_CALLS=str(self.root / 'queue.jsonl'), HOME=str(self.root / 'home'),
                        RUNNER_ENV=str(self.root / 'runner-env.txt'))
        for name in ('RALPH_RUN_ACTIVE', 'CODEX_HOME', 'RALPH_MODEL', 'RALPH_REVIEW_MODEL'):
            self.env.pop(name, None)
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



CONVERSATION = '22222222-2222-4222-8222-222222222222'
# A fake Cursor or agy CLI. It answers --help, and for a result delivery it records its arguments
# and RALPH_RUN_ACTIVE, then prints the reply configured by the test.
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
                             'cwd': os.getcwd()}) + '\n')
time.sleep(float(os.environ.get('FAKE_DELAY', '0')))
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


class AgentNotifyTests(unittest.TestCase):
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

    def install(self, agent, footer='completed=1\niterationsRun=1\nmaxIterations=10', runner=None):
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
        (scripts / self.AGENTS[agent]).write_text(runner or (
            "#!/bin/bash\nprintf 'PRIVATE_WORKER_LOG\\n'\n"
            'printf "%s|%s" "${RALPH_MODEL:-}" "${RALPH_REVIEW_MODEL:-}" > "$RUNNER_ENV"\n'
            "cat <<'EOF'\n" + footer
            + '\nprogress=/fixture/progress.txt\nlogs=/fixture/logs\nEOF\n'))
        self.env = dict(os.environ, FAKE_AGENT_KIND=agent,
                        DELIVERY_CALLS=str(self.root / 'delivery.jsonl'),
                        HOME=str(self.root / 'home'), RUNNER_ENV=str(self.root / 'runner-env.txt'))
        for name in ('RALPH_RUN_ACTIVE', 'CODEX_HOME', 'RALPH_MODEL', 'RALPH_REVIEW_MODEL'):
            self.env.pop(name, None)
        return scripts / SOURCE.name

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

    def test_delivery_timeout_is_recorded(self):
        script = self.install('cursor')
        script.write_text(script.read_text().replace('DELIVERY_TIMEOUT = 600', 'DELIVERY_TIMEOUT = 1'))
        self.env['FAKE_DELAY'] = '5'
        state = self.wait(json.loads(self.launch(script).stdout))
        self.assertEqual(state['notification'], 'failed')
        self.assertIn('timed out', state['notification_error'])

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

    def test_a_second_runtime_record_is_refused(self):
        script = self.install('antigravity')
        (script.parent / 'codex-runtime.json').write_text(
            json.dumps({'schema': 1, 'codex': str(self.root / 'fake-antigravity')}))
        result = self.launch(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exactly one Ralph runtime record', result.stderr)

    def test_real_runner_and_delivery_for_each_agent(self):
        root = Path(__file__).resolve().parents[1]
        for agent in self.AGENTS:
            with self.subTest(agent=agent):
                self.reset()
                skill = self.root / f'skill-{agent}'
                # install.sh parses its positional arguments when sourced, so pass values by name.
                subprocess.run(['bash', '-c', 'source "$INSTALL_SH" && stage_agent_ralph_skill "$AGENT" "$DEST"'],
                               env=dict(os.environ, INSTALL_SH=str(root / 'install.sh'), AGENT=agent,
                                        DEST=str(skill)), check=True)
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
                self.env = dict(os.environ, FAKE_AGENT_KIND=agent,
                                DELIVERY_CALLS=str(self.root / 'delivery.jsonl'))
                self.env.pop('RALPH_RUN_ACTIVE', None)
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
