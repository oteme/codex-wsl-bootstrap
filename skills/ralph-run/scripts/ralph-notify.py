#!/usr/bin/env python3
"""Run Ralph without model polling; queue one terminal result to the initiating thread."""
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
import uuid

from ralph_runtime import load as load_codex


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


def status(path):
    state = json.loads(path.read_text())
    if state['status'] in ('starting', 'running') and (
        not state.get('supervisor_identity') or
        identity(state['supervisor_pid']) != state['supervisor_identity']
    ):
        state.update(status='monitoring_lost', error='supervisor is not alive; completion is unknown')
    return state


def outcome(log, code):
    # Only the runner's final footer is authoritative, never worker text.
    with log.open('rb') as stream:
        stream.seek(0, 2)
        stream.seek(max(0, stream.tell() - 16384))
        tail = stream.read().decode('utf-8', errors='replace')
    match = re.search(r'\ncompleted=([01])\niterationsRun=(\d+)\nmaxIterations=(\d+)'
                      r'\nblocked=([01])\nprogress=[^\n]+\nlogs=[^\n]+\n\Z', '\n' + tail)
    if match:
        complete, iterations, limit, blocked = map(int, match.groups())
        if code == 0 and complete == 1 and blocked == 0:
            return 'completed', iterations
        if code != 0 and complete == 0 and blocked == 1:
            return 'blocked', iterations
        if code == 0 and complete == 0 and blocked == 0 and limit > 0 and iterations == limit:
            return 'limit_reached', iterations
    return 'failed', None


def supervise(run_dir, lock_fd, ready_fd):
    state_path = run_dir / 'result.json'
    state = json.loads(state_path.read_text())
    runner = Path(__file__).with_name('ralph-run-codex.sh')
    child = None
    interrupted = False

    def stop(signum, frame):
        nonlocal interrupted
        interrupted = True
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        with (run_dir / 'runner.log').open('wb') as log:
            child = subprocess.Popen(['bash', str(runner), str(state['max_iterations']),
                                      state['ralph_dir']], cwd=state['project_root'],
                                     stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                     start_new_session=True)
            state.update(status='running', runner_pid=child.pid, supervisor_pid=os.getpid(),
                         supervisor_identity=identity(os.getpid()))
            save(state_path, state)
            os.write(ready_fd, b'1')
            os.close(ready_fd)
            ready_fd = None
            code = child.wait()
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
            result = subprocess.run([state['codex'], 'queue', '--thread', state['thread'],
                                     '--message', message], stdin=subprocess.DEVNULL,
                                    stdout=log, stderr=log, timeout=30)
        state['notification'] = 'queued' if result.returncode == 0 else 'failed'
        state['notification_exit_code'] = result.returncode
    except Exception as exc:
        state.update(notification='failed', notification_error=str(exc))
    save(state_path, state)
    os.close(lock_fd)
    return 0 if state['notification'] == 'queued' else 1


def start(args):
    if os.environ.get('RALPH_RUN_ACTIVE') == '1':
        raise ValueError('refusing to start a nested Ralph runner')
    thread = str(uuid.UUID(args.thread))
    if args.max_iterations < 0:
        raise ValueError('max iterations must be non-negative')
    ralph = Path(args.ralph_dir).resolve(strict=True)
    for name in ('prd.json', 'CLAUDE.md'):
        if not (ralph / name).is_file():
            raise ValueError('missing Ralph input: ' + str(ralph / name))
    project = subprocess.check_output(['git', '-C', str(ralph), 'rev-parse', '--show-toplevel'],
                                      text=True).strip()
    codex = load_codex()
    check = subprocess.run([codex, 'queue', '--help'], capture_output=True, timeout=10)
    if check.returncode != 0 or b'--thread' not in check.stdout:
        raise ValueError('this Codex does not support queue --thread; refusing to start')
    logs = ralph / 'logs'
    logs.mkdir(exist_ok=True)
    lock = (logs / 'notify.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise ValueError('a Ralph notification supervisor is already active') from None
    run_id = str(uuid.uuid4())
    run_dir = logs / 'runs' / run_id
    run_dir.mkdir(parents=True)
    state = dict(run_id=run_id, thread=thread, ralph_dir=str(ralph),
                 project_root=project, max_iterations=args.max_iterations,
                 codex=codex, status='starting', notification='not_sent',
                 progress=str(ralph / 'progress.txt'), log=str(run_dir / 'runner.log'))
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


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '_supervise':
        return supervise(Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
    if len(sys.argv) == 3 and sys.argv[1] == '--status':
        print(json.dumps(status(Path(sys.argv[2])), ensure_ascii=False))
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--thread', required=True, help='initiating Codex thread UUID')
    parser.add_argument('--ralph-dir', default=str(Path.cwd() / 'scripts/ralph'))
    parser.add_argument('--max-iterations', type=int, default=0)
    args = parser.parse_args()
    try:
        start(args)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print('error: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
