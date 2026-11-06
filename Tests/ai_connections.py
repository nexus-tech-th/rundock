#!/usr/bin/env python3
"""Exercise real MCP stdio session tracking in an isolated local daemon."""
import argparse, json, os, pathlib, select, shutil, socket, subprocess, tempfile, time
parser = argparse.ArgumentParser(); parser.add_argument('--binary', required=True)
binary = str(pathlib.Path(parser.parse_args().binary).resolve())
root = pathlib.Path(tempfile.mkdtemp(prefix='rundock-ai-', dir='/private/tmp'))
env = dict(os.environ, PROCESSES_HOME=str(root / 'state'))
socket_path = str(root / 'state' / 'control.sock')
def mcp(name):
    process = subprocess.Popen([binary, 'mcp'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    request = {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': name, 'version': '42'}}}
    process.stdin.write((json.dumps(request) + '\n').encode())
    assert select.select([process.stdout], [], [], 15)[0], 'initialize timed out'
    reply = json.loads(process.stdout.readline()); assert 'result' in reply, reply
    return process
def request(action, **params):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(8); sock.connect(socket_path)
        sock.sendall((json.dumps({'action': action, **params}) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'): data += sock.recv(65536)
    reply = json.loads(data); assert reply['ok'], reply
    return reply
proc = None
try:
    verifier = mcp('RunDock setup verifier'); verifier.stdin.close(); verifier.wait(timeout=5)
    assert not os.path.exists(socket_path), 'verifier must not start daemon'
    proc = mcp('Example AI')
    entry = next(x for x in request('ai-connections')['connections'] if x['clientName'] == 'Example AI')
    assert entry['isConnected'] and entry['clientVersion'] == '42' and not entry.get('lastUsedAt'), entry
    proc.stdin.write((json.dumps({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'rundock_list','arguments':{}}})+'\n').encode())
    assert not json.loads(proc.stdout.readline())['result']['isError']
    entry = next(x for x in request('ai-connections')['connections'] if x['sessionID'] == entry['sessionID'])
    assert entry.get('lastUsedAt'), entry
    previous = entry['lastSeen']; time.sleep(6)
    entry = next(x for x in request('ai-connections')['connections'] if x['sessionID'] == entry['sessionID'])
    assert entry['isConnected'] and entry['lastSeen'] > previous, entry
    proc.stdin.close(); proc.wait(timeout=5); proc = None
    entry = next(x for x in request('ai-connections')['connections'] if x['sessionID'] == entry['sessionID'])
    assert not entry['isConnected'] and entry.get('disconnectedAt'), entry
    request('ai-connect', id='stale-test', actor='Stale test'); time.sleep(16)
    stale = next(x for x in request('ai-connections')['connections'] if x['sessionID'] == 'stale-test')
    assert not stale['isConnected'], stale
    print('MCP session registration, heartbeat, use, EOF, stale expiry and verifier isolation passed')
finally:
    if proc is not None:
        proc.stdin.close(); proc.wait(timeout=10)
    if os.path.exists(socket_path): subprocess.run([binary, 'daemon', 'stop'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    shutil.rmtree(root, ignore_errors=True)
