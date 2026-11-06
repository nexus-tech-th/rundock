#!/usr/bin/env python3
"""Real MCP stdio/daemon acceptance; pass --binary path."""
import argparse, json, os, pathlib, select, shutil, subprocess, tempfile, time
p = argparse.ArgumentParser(); p.add_argument('--binary', required=True); binary = str(pathlib.Path(p.parse_args().binary).resolve())
root = pathlib.Path(tempfile.mkdtemp(prefix='rundock-mcp-', dir='/private/tmp'))
env = dict(os.environ, PROCESSES_HOME=str(root/'state'))
proc = subprocess.Popen([binary, 'mcp'], cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
def write(obj): proc.stdin.write((json.dumps(obj)+'\n').encode())
def receive():
    assert select.select([proc.stdout], [], [], 15)[0], 'No MCP response'
    data = bytearray()
    while not data.endswith(b'\n'):
        part = os.read(proc.stdout.fileno(), 1)
        assert part, 'MCP EOF'; data.extend(part)
    return json.loads(data)
def request(id, method, params=None):
    write({'jsonrpc':'2.0','id':id,'method':method,'params':params or {}})
    reply = receive(); assert reply['id'] == id, reply
    return reply
try:
    reply = request(1, 'initialize', {'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'test','version':'1'}})
    assert reply['result']['protocolVersion'] == '2025-11-25'
    write({'jsonrpc':'2.0','method':'notifications/initialized'})
    listing = request(2, 'tools/list')['result']['tools']
    assert {'rundock_run','rundock_list','rundock_logs','rundock_input','rundock_start','rundock_stop','rundock_restart'} <= {t['name'] for t in listing}
    call = lambda id,name,args: request(id,'tools/call',{'name':name,'arguments':args})['result']
    run = call(3, 'rundock_run', {'command':"printf '%s' 'MCP quoted output'", 'cwd':str(root)})
    assert not run['isError'], run
    service = json.loads(run['content'][0]['text'])['services'][0]
    assert service['startedBy'] == 'test'
    deadline = time.monotonic()+8
    while True:
        data = call(4, 'rundock_logs', {'id':service['id']})
        output = json.loads(data['content'][0]['text'])
        if 'MCP quoted output' in output['text']: break
        assert time.monotonic()<deadline, output
        time.sleep(.1)
    while True:
        items = json.loads(call(5,'rundock_list',{})['content'][0]['text'])
        if any(i['id']==service['id'] and i['status'] == 'completed' for i in items): break
        assert time.monotonic() < deadline, items
        time.sleep(.1)
    assert request(8, 'tools/call', {'name':'unknown', 'arguments':{}})['error']['code'] == -32602
    failure = call(6,'rundock_stop', {'id':'missing'})
    assert failure['isError']
    proc.stdin.write(b'{bad json}\n')
    assert receive()['error']['code'] == -32700
    assert request(7,'ping')['result'] == {}
    print('MCP stdio initialize, notifications, tools, run, logs, errors and malformed input passed.')
finally:
    proc.stdin.close(); proc.wait(timeout=5)
    subprocess.run([binary,'daemon','stop','--stop-services'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    shutil.rmtree(root, ignore_errors=True)
