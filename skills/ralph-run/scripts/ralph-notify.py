#!/usr/bin/env python3
"""Run Ralph without model polling; deliver one terminal result to the initiating conversation.

Codex queues the result to its thread with `codex queue`. Cursor and Antigravity have no queue, so
the result is delivered by one headless turn resumed in the initiating conversation, and delivery
counts only when the CLI reports that same conversation back (both CLIs silently start a new
conversation for an unknown ID).
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time
import uuid

from ralph_models import resolve as resolve_models
from ralph_runtime import AGENTS, load_agent, record_agent

RUNNERS = {'codex': 'ralph-run-codex.sh', 'cursor': 'ralph-run-cursor.sh',
           'antigravity': 'ralph-run-antigravity.sh'}
# The option each CLI must offer before a run starts, so a finished run can report back.
REQUIRED_OPTION = {'cursor': b'--resume', 'antigravity': b'--conversation'}
DELIVERY_TIMEOUT = 600
# Cursor and Antigravity have no queue. Resuming the conversation while the turn that started Ralph
# is still answering would collide with it, so a run that ends quickly waits this long after start.
DELIVERY_DELAY = 60
# Signing Cursor CLI in from the environment; every other session variable below is dropped.
CURSOR_SIGN_IN_VARIABLE = 'CURSOR_API_KEY'
# How each CLI lists the model names it accepts; Codex has no such command.
MODEL_LIST = {'cursor': re.compile(r'^(\S+) - '), 'antigravity': re.compile(r'^(\S+)\t')}
# `agent models` does not list Cursor's parameterized names such as `id[effort=high]`; Cursor rejects
# an invalid one when the first iteration starts.
CURSOR_PARAMETERIZED = re.compile(r'[^\[\]]+\[[^\[\]]+\]')


def without_session_variables(environ):
    """The environment for Cursor and Antigravity runs and deliveries.

    The interactive sessions export variables to the shell that started Ralph: the session's identity,
    and credentials such as Cursor's askpass secret, with which an unattended run could ask the user's
    open session for a password. The headless runs were verified without any of them, so every
    CURSOR_* and ANTIGRAVITY_* variable and SUDO_ASKPASS are dropped, except CURSOR_API_KEY.
    """
    return {name: value for name, value in environ.items()
            if name == CURSOR_SIGN_IN_VARIABLE
            or not (name.startswith(('CURSOR_', 'ANTIGRAVITY_')) or name == 'SUDO_ASKPASS')}


def reaped(child):
    try:
        return os.waitpid(child.pid, os.WNOHANG)[0] != 0
    except ChildProcessError:
        return True


def end_group(child):
    """Stop CHILD's process group and reap CHILD. This calls os.waitpid itself, not Popen.wait: a signal
    handler may run while communicate() holds Popen's wait lock, and waiting on it would deadlock."""
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 5
    while not reaped(child) and time.monotonic() < deadline:
        time.sleep(0.05)
    try:
        os.killpg(child.pid, signal.SIGKILL)  # whatever is left of the group
    except ProcessLookupError:
        pass
    while not reaped(child):
        time.sleep(0.05)


def run_delivery(command, timeout, **options):
    """Run a delivery CLI in its own process group. A stop request or the timeout ends the whole group
    before the supervisor goes, so no CLI keeps resuming the conversation once the lock is free."""
    started = []

    def stop_delivery(signum, frame):
        for child in started:
            end_group(child)
        raise SystemExit(128 + signum)

    # The handler is in place before the CLI starts; only a stop request that arrives inside Popen,
    # before the CLI is recorded below, can still leave it running.
    handlers = {number: signal.signal(number, stop_delivery)
                for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True, **options)
        started.append(child)
        stdout, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        end_group(child)
        raise
    finally:
        for number, handler in handlers.items():
            signal.signal(number, handler)
    return subprocess.CompletedProcess(command, child.returncode, stdout)


def save(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)


def identity(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return fields[19] if fields[0] != 'Z' else None
    except FileNotFoundError:
        return None


def supervisor_alive(state):
    return bool(state.get('supervisor_identity')) and (
        identity(state['supervisor_pid']) == state['supervisor_identity'])


def status(path):
    state = json.loads(path.read_text())
    if state['status'] in ('starting', 'running') and not supervisor_alive(state):
        state.update(status='monitoring_lost', error='supervisor is not alive; completion is unknown')
    elif state.get('notification') == 'pending' and not supervisor_alive(state):
        state.update(notification='lost',
                     notification_error='the supervisor stopped before it delivered the result')
    return state


def outcome(log, code):
    # Only the runner's final footer is authoritative, never worker text.
    with log.open('rb') as stream:
        stream.seek(0, 2)
        stream.seek(max(0, stream.tell() - 16384))
        tail = stream.read().decode('utf-8', errors='replace')
    match = re.search(r'\ncompleted=([01])\niterationsRun=(\d+)\nmaxIterations=(\d+)'
                      r'\nprogress=[^\n]+\nlogs=[^\n]+\n\Z', '\n' + tail)
    if match:
        complete, iterations, limit = map(int, match.groups())
        if code == 0 and complete == 1:
            return 'completed', iterations
        if code == 0 and complete == 0 and limit > 0 and iterations == limit:
            return 'limit_reached', iterations
    return 'failed', None


def check_models(agent, executable, models):
    """Refuse to start with a model the Cursor or Antigravity CLI does not list."""
    models = [model for model in dict.fromkeys(models) if model and not (
        agent == 'cursor' and CURSOR_PARAMETERIZED.fullmatch(model))]
    if agent not in MODEL_LIST or not models:
        return
    listing = subprocess.run([executable, 'models'], stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, timeout=60)
    if listing.returncode != 0:
        raise ValueError(f'{AGENTS[agent]} could not list its models (exit {listing.returncode})')
    offered = {match.group(1) for line in listing.stdout.splitlines()
               if (match := MODEL_LIST[agent].match(line))}
    for model in models:
        if model not in offered:
            raise ValueError(f'{AGENTS[agent]} does not offer the model {model!r}; '
                             f'run `{Path(executable).name} models` for the list')


def deliver(state, message, log):
    """Resume the initiating Cursor or Antigravity conversation once with the result."""
    agent, conversation = state['agent'], state['conversation']
    if agent == 'cursor':
        command = [state['executable'], '-p', f'--resume={conversation}', '--trust',
                   '--workspace', state['project_root'], '--output-format', 'json', message]
    else:
        command = [state['executable'], '--conversation', conversation,
                   '--output-format', 'json', '-p', message]
    env = without_session_variables(os.environ)
    env['RALPH_RUN_ACTIVE'] = '1'
    result = run_delivery(command, DELIVERY_TIMEOUT, cwd=state['project_root'],
                          stdout=subprocess.PIPE, stderr=log, env=env)
    log.write(result.stdout)
    state['notification_exit_code'] = result.returncode
    if result.returncode != 0:
        state['notification_error'] = f'{AGENTS[agent]} exited with status {result.returncode}'
        return 'failed'
    try:
        reply = json.loads(result.stdout)
    except ValueError:
        state['notification_error'] = f'{AGENTS[agent]} returned invalid JSON'
        return 'failed'
    if not isinstance(reply, dict):
        state['notification_error'] = f'{AGENTS[agent]} returned a non-object reply'
        return 'failed'
    if agent == 'cursor':
        replied = reply.get('session_id')
        succeeded = reply.get('subtype') == 'success' and reply.get('is_error') is False
    else:
        replied = reply.get('conversation_id')
        succeeded = reply.get('status') == 'SUCCESS'
    if replied != conversation:
        state['notification_error'] = f'the result went to conversation {replied!r}, not the initiating one'
        return 'failed'
    if not succeeded:
        state['notification_error'] = f'{AGENTS[agent]} did not finish the result turn successfully'
        return 'failed'
    return 'delivered'


def supervise(run_dir, lock_fd, ready_fd):
    started = time.monotonic()
    state_path = run_dir / 'result.json'
    state = json.loads(state_path.read_text())
    runner = Path(__file__).with_name(RUNNERS[state.get('agent', 'codex')])
    child = None
    code = None
    ended = None
    interrupted = False

    def stop(signum, frame):
        nonlocal interrupted
        interrupted = True
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    env = without_session_variables(os.environ) if 'agent' in state else dict(os.environ)
    # The runner resolves the same models again; passing them keeps the checked models in use.
    for key, variable in (('worker_model', 'RALPH_MODEL'), ('review_model', 'RALPH_REVIEW_MODEL')):
        if state.get(key):
            env[variable] = state[key]
    try:
        with (run_dir / 'runner.log').open('wb') as log:
            child = subprocess.Popen(['bash', str(runner), str(state['max_iterations']),
                                      state['ralph_dir']], cwd=state['project_root'],
                                     stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                     start_new_session=True, env=env)
            state.update(status='running', runner_pid=child.pid, supervisor_pid=os.getpid(),
                         supervisor_identity=identity(os.getpid()))
            save(state_path, state)
            os.write(ready_fd, b'1')
            os.close(ready_fd)
            ready_fd = None
            code = child.wait()
            ended = time.monotonic()
        status, iterations = outcome(run_dir / 'runner.log', code)
        state.update(status='interrupted' if interrupted else status,
                     exit_code=code, iterations_run=iterations)
    except Exception as exc:
        # A failed supervisor must not abandon its still-running child.
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait()
        state.update(status='failed', error=str(exc))
    finally:
        if ready_fd is not None:
            os.close(ready_fd)
    # The run is over: a stop request now ends the supervisor at once instead of waiting and
    # delivering (run_delivery also stops a delivery in progress). --status then reports the pending
    # result as lost.
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    state['notification'] = 'pending'
    save(state_path, state)
    message = ('[Ralph result] ' + json.dumps({
        'run_id': state['run_id'], 'status': state['status'],
        'exit_code': state.get('exit_code'), 'iterations_run': state.get('iterations_run'),
        'result_file': str(state_path),
    }, ensure_ascii=False) + '\nRead the result file and summarize it. Do not restart Ralph. '
               'Read detailed logs only if needed to explain a failure.')
    try:
        with (run_dir / 'notification.log').open('wb') as log:
            if 'agent' in state:
                # A run stopped from the conversation ends while that turn is still answering, so its
                # result waits from the end; any other result waits from the start of the run.
                stopped = interrupted or (code is not None and (code < 0 or code >= 128))
                wait_from = ended if stopped and ended is not None else started
                time.sleep(max(0.0, DELIVERY_DELAY - (time.monotonic() - wait_from)))
                state['notification'] = deliver(state, message, log)
            else:
                result = run_delivery([state['codex'], 'queue', '--thread', state['thread'],
                                       '--message', message], 30, stdout=log, stderr=log)
                state['notification'] = 'queued' if result.returncode == 0 else 'failed'
                state['notification_exit_code'] = result.returncode
    except Exception as exc:
        state.update(notification='failed', notification_error=str(exc))
    save(state_path, state)
    os.close(lock_fd)
    return 0 if state['notification'] in ('queued', 'delivered') else 1


def start(args, agent):
    if os.environ.get('RALPH_RUN_ACTIVE') == '1':
        raise ValueError('refusing to start a nested Ralph runner')
    if agent == 'codex':
        conversation = str(uuid.UUID(args.thread))
    else:
        conversation = str(uuid.UUID(args.conversation))
    if args.max_iterations < 0:
        raise ValueError('max iterations must be non-negative')
    ralph = Path(args.ralph_dir).resolve(strict=True)
    for name in ('prd.json', 'CLAUDE.md'):
        if not (ralph / name).is_file():
            raise ValueError('missing Ralph input: ' + str(ralph / name))
    project = subprocess.check_output(['git', '-C', str(ralph), 'rev-parse', '--show-toplevel'],
                                      text=True).strip()
    _, executable = load_agent()
    if agent == 'codex':
        check = subprocess.run([executable, 'queue', '--help'], capture_output=True, timeout=10)
        if check.returncode != 0 or b'--thread' not in check.stdout:
            raise ValueError('this Codex does not support queue --thread; refusing to start')
    else:
        check = subprocess.run([executable, '--help'], capture_output=True, timeout=10)
        if check.returncode != 0 or REQUIRED_OPTION[agent] not in check.stdout + check.stderr:
            option = REQUIRED_OPTION[agent].decode()
            raise ValueError(f'this {AGENTS[agent]} CLI does not support {option}; refusing to start')
    worker_model, review_model = resolve_models(agent, args.model, args.review_model)
    check_models(agent, executable, (worker_model, review_model))
    logs = ralph / 'logs'
    logs.mkdir(exist_ok=True)
    lock = (logs / 'notify.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise ValueError('a Ralph notification supervisor is already active: a run is still going, or a '
                         'finished run is still delivering its result') from None
    run_id = str(uuid.uuid4())
    run_dir = logs / 'runs' / run_id
    run_dir.mkdir(parents=True)
    if agent == 'codex':
        state = dict(run_id=run_id, thread=conversation, ralph_dir=str(ralph),
                     project_root=project, max_iterations=args.max_iterations,
                     codex=executable, status='starting', notification='not_sent',
                     progress=str(ralph / 'progress.txt'), log=str(run_dir / 'runner.log'))
    else:
        state = dict(run_id=run_id, agent=agent, conversation=conversation, ralph_dir=str(ralph),
                     project_root=project, max_iterations=args.max_iterations,
                     executable=executable, status='starting', notification='not_sent',
                     progress=str(ralph / 'progress.txt'), log=str(run_dir / 'runner.log'))
    if worker_model or review_model:
        state.update(worker_model=worker_model, review_model=review_model)
    save(run_dir / 'result.json', state)
    read_fd, write_fd = os.pipe()
    with (run_dir / 'supervisor.log').open('wb') as log:
        supervisor = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), '_supervise', str(run_dir),
             str(lock.fileno()), str(write_fd)], stdin=subprocess.DEVNULL,
            stdout=log, stderr=log, start_new_session=True,
            pass_fds=(lock.fileno(), write_fd))
    os.close(write_fd)
    try:
        ready = select.select([read_fd], [], [], 10)[0]
        if not ready or os.read(read_fd, 1) != b'1':
            supervisor.terminate()
            raise ValueError('supervisor startup was not acknowledged; inspect ' + str(run_dir))
    finally:
        os.close(read_fd)
        lock.close()
    print(json.dumps(dict(started=True, run_id=run_id, result_file=str(run_dir / 'result.json'),
                          supervisor_pid=supervisor.pid), ensure_ascii=False))


def installed_agent():
    """The agent named by this skill's single runtime record, or None when it is missing or
    ambiguous (main() then reports the record problem through load_agent())."""
    try:
        return record_agent()
    except ValueError:
        return None


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '_supervise':
        return supervise(Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
    if len(sys.argv) == 3 and sys.argv[1] == '--status':
        print(json.dumps(status(Path(sys.argv[2])), ensure_ascii=False))
        return 0
    agent = installed_agent()
    parser = argparse.ArgumentParser(description=__doc__)
    if agent in ('codex', None):
        parser.add_argument('--thread', required=agent == 'codex',
                            help='initiating Codex thread UUID')
    if agent in ('cursor', 'antigravity', None):
        parser.add_argument('--conversation', required=agent is not None,
                            help='initiating Cursor or Antigravity conversation UUID')
    parser.add_argument('--ralph-dir', default=str(Path.cwd() / 'scripts/ralph'))
    parser.add_argument('--max-iterations', type=int, default=0)
    parser.add_argument('--model', help='worker model for this run (default: saved Ralph model, '
                                        'then the CLI default)')
    parser.add_argument('--review-model', help='policy reviewer model for this run (default: saved '
                                               'Ralph review model, then the worker model)')
    args = parser.parse_args()
    try:
        if agent is None:
            load_agent()  # Reports the missing or ambiguous runtime record.
        start(args, agent)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print('error: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
