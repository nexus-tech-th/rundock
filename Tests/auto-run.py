#!/usr/bin/env python3
"""Exercise automatic registration against an isolated real daemon."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import socket
import time
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
args = parser.parse_args()
binary = str(Path(args.binary).resolve())
root = Path(tempfile.mkdtemp(prefix='rundock-auto-', dir='/private/tmp'))
project = root / 'project'
project.mkdir()
env = dict(os.environ, PROCESSES_HOME=str(root / 'state'), RUNDOCK_ACTOR='Acceptance')

def cli(*arguments, cwd=project):
    return subprocess.run([binary, *arguments], cwd=cwd, env=env, text=True, capture_output=True, timeout=20)

def selected(result):
    assert result.returncode == 0, (result.stdout, result.stderr)
    items = json.loads(result.stdout)['services']
    assert len(items) == 1
    return items[0]

try:
    subprocess.run(['/usr/bin/git', 'init', '-q', str(project)], check=True)
    output = cli('run', '--wait', '--', '/usr/bin/printf', '%s|%s|%s', "a'b", '--help', 'space x')
    assert output.returncode == 0 and "a'b|--help|space x" in output.stdout, (output.stdout, output.stderr)
    failure = cli('run', '--wait', '--command', 'exit 7')
    assert failure.returncode == 7, (failure.returncode, failure.stderr)
    command = ('run', '--json', '--', '/bin/sleep', '10')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        items = list(pool.map(lambda _: selected(cli(*command)), range(4)))
    assert len({item['id'] for item in items}) == 1, items
    assert len({item.get('pid') for item in items}) == 1 and items[0].get('pid'), items
    item = items[0]
    assert item['project'] == 'project' and os.path.samefile(item['cwd'], project), item
    assert item['startedBy'] == 'Acceptance' and item['name'].startswith('/bin/sleep')
    assert item.get('branch'), item
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    server = selected(cli('run', '--json', '--', '/usr/bin/python3', '-m', 'http.server', str(port), '--bind', '127.0.0.1'))
    deadline = time.monotonic() + 10
    while True:
        listing = json.loads(cli('list', '--json').stdout)['services']
        listening = next(s for s in listing if s['id'] == server['id'])
        if port in (listening.get('ports') or []):
            break
        assert time.monotonic() < deadline, listening
        time.sleep(.25)

    assert any(s['status'] == 'completed' for s in listing), listing
    assert any(s['status'] == 'failed' and s.get('exitCode') == 7 for s in listing), listing
    print('Automatic metadata, argv preservation, exit status, completion, listener discovery and concurrent dedup passed.')
finally:
    cli('daemon', 'stop', '--stop-services')
    shutil.rmtree(root, ignore_errors=True)
