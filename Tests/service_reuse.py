#!/usr/bin/env python3
"""Managed-role dedup with isolated daemon and fake package manager executables."""
import argparse, json, os, pathlib, shutil, socket, subprocess, tempfile, time, uuid
p = argparse.ArgumentParser(); p.add_argument('--binary', required=True); binary = str(pathlib.Path(p.parse_args().binary).resolve())
root = pathlib.Path(tempfile.mkdtemp(prefix='rundock-reuse-', dir='/private/tmp')); state = root/'state'
env = dict(os.environ, PROCESSES_HOME=str(state))
for name in ['npm', 'pnpm']:
    executable = root/name; executable.write_text('#!/bin/sh\necho running\nexec sleep 30\n'); executable.chmod(0o700)
project = root/'project'; project.mkdir(); other = root/'other'; other.mkdir()
proc = subprocess.Popen([binary, 'daemon', 'run'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def request(action, **kwargs):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(8); sock.connect(str(state/'control.sock'))
        sock.sendall((json.dumps({'action':action, **kwargs})+'\n').encode()); data = b''
        while not data.endswith(b'\n'):
            part = sock.recv(65536); assert part; data += part
    result = json.loads(data); assert result['ok'], result
    return result
def service(command, cwd=project):
    return {'id':str(uuid.uuid4()),'project':'P','name':'test','command':command,'cwd':str(cwd),'startedBy':'AI','status':'stopped','events':[]}
try:
    for _ in range(100):
        if (state/'control.sock').exists(): break
        time.sleep(.05)
    a = service(f"'{root}/npm' run dev"); b = service(f"'{root}/pnpm' dev")
    first = request('run', service=a); one = first['services'][0]
    assert first['reused'] is False and one['pid']
    second = request('run', service=b); assert second['reused'] is True and second['services'][0]['id'] == one['id'] and second['services'][0]['pid'] == one['pid'] and second['services'][0]['command'] == a['command']
    separate = request('run', service=service(b['command'], other)); assert separate['services'][0]['id'] != one['id']
    parallel = request('run', service=service(b['command']), forceNew=True); assert parallel['reused'] is False and parallel['services'][0]['id'] != one['id']
    request('stop', id=parallel['services'][0]['id'])
    live = request('run', service=b); assert live['services'][0]['pid'] == one['pid'], 'live role must beat stopped exact match'
    request('stop', id=one['id']); request('stop', id=separate['services'][0]['id'])
    restarted = request('run', service=b); assert restarted['reused'] and restarted['services'][0]['command'] == b['command']
    request('stop', id=restarted['services'][0]['id'])
    shell = request('run', service=service('exec /bin/sh -l'))['services'][0]
    request('input', id=shell['id'], data=__import__('base64').b64encode(b'export RUNDOCK_KEEP=stay_alive\n').decode())
    reused_shell = request('run', service=service('exec /bin/zsh -l'))['services'][0]
    assert reused_shell['id'] == shell['id'] and reused_shell['pid'] == shell['pid']
    request('input', id=shell['id'], data=__import__('base64').b64encode(b'echo RETAINED-$RUNDOCK_KEEP-END\n').decode())
    deadline = time.monotonic() + 6
    import base64
    while True:
        out = request('read', id=shell['id'], offset=0)
        if b'RETAINED-stay_alive-END' in base64.b64decode(out.get('data', '')): break
        assert time.monotonic() < deadline, out
        time.sleep(.1)
    request('stop', id=shell['id'])
    print('Role reuse, cwd isolation, explicit parallelism and restart passed')
finally:
    if (state/'control.sock').exists():
        try:
            for item in request('list').get('services', []):
                if item.get('pid'): request('stop', id=item['id'])
            request('shutdown')
        except Exception: pass
    try: proc.wait(timeout=10)
    except subprocess.TimeoutExpired: proc.terminate(); proc.wait(timeout=5)
    shutil.rmtree(root, ignore_errors=True)
