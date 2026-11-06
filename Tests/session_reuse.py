#!/usr/bin/env python3
"""Isolated CLI/MCP shared shell and semantic server reuse acceptance."""
import argparse, json, os, pathlib, select, shutil, subprocess, tempfile, time
p = argparse.ArgumentParser(); p.add_argument('--binary', required=True); binary = str(pathlib.Path(p.parse_args().binary).resolve())
root = pathlib.Path(tempfile.mkdtemp(prefix='rundock-session-', dir='/private/tmp'))
a, b = root/'a', root/'b'; a.mkdir(); b.mkdir()
bin_dir = root/'bin'; bin_dir.mkdir()
for name in ('npm','pnpm'):
    path = bin_dir/name
    path.write_text('#!/bin/sh\nexec /usr/bin/python3 -m http.server 0 --bind 127.0.0.1\n'); path.chmod(0o755)
env = dict(os.environ, PROCESSES_HOME=str(root/'state'))
def cli(*args):
    result = subprocess.run([binary,*args], cwd=a, env=env, text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, (args,result.stderr,result.stdout)
    return result.stdout
mcp = None
def req(id, method, params):
    mcp.stdin.write((json.dumps({'jsonrpc':'2.0','id':id,'method':method,'params':params})+'\n').encode())
    assert select.select([mcp.stdout],[],[],15)[0]
    line=bytearray()
    while not line.endswith(b'\n'): line.extend(os.read(mcp.stdout.fileno(),1))
    result=json.loads(line); assert 'error' not in result, result
    return result['result']
try:
    first = json.loads(cli('shell','--cwd',str(a),'--json'))
    shell = first['services'][0]
    mcp = subprocess.Popen([binary,'mcp'],cwd=a,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
    req(1,'initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'test','version':'1'}})
    mcp.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    shared = req(2,'tools/call',{'name':'rundock_shell','arguments':{'cwd':str(a)}})
    assert not shared['isError'], shared
    second = json.loads(shared['content'][0]['text'])
    assert second['reused'] and second['services'][0]['id'] == shell['id'] and second['services'][0]['pid'] == shell['pid']
    cli('input',shell['id'],'--text',"printf '%s%s\\n' SESSION_REUSE_ MARKER\n")
    deadline=time.monotonic()+10
    while 'SESSION_REUSE_MARKER' not in cli('logs',shell['id']):
        assert time.monotonic()<deadline; time.sleep(.1)
    cmd1 = ('run','--cwd',str(a),'--json','--',str(bin_dir/'npm'),'run','dev')
    cmd2 = ('run','--cwd',str(a),'--json','--',str(bin_dir/'pnpm'),'dev')
    s1=json.loads(cli(*cmd1))['services'][0]
    deadline=time.monotonic()+10
    while True:
        services=json.loads(cli('list','--json'))['services']
        actual=next(x for x in services if x['id']==s1['id'])
        if actual.get('ports'): break
        assert time.monotonic()<deadline, actual
        time.sleep(.2)
    s2=json.loads(cli(*cmd2)); assert s2['reused'] and s2['services'][0]['id']==s1['id'] and s2['services'][0]['pid']==s1['pid'] and s2['services'][0]['ports']==actual['ports']
    separate=json.loads(cli('run','--cwd',str(b),'--json','--',str(bin_dir/'pnpm'),'dev'))
    assert separate['services'][0]['id']!=s1['id']
    new=json.loads(cli('run','--cwd',str(a),'--new','--json','--',str(bin_dir/'pnpm'),'dev'))
    assert new['services'][0]['id']!=s1['id'] and new.get('reused') != True
    print('Shared CLI/MCP PTY, input/logs, semantic dev reuse, distinct cwd, and --new passed.')
finally:
    if mcp:
        mcp.stdin.close(); mcp.wait(timeout=5)
    subprocess.run([binary,'daemon','stop','--stop-services'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
    shutil.rmtree(root,ignore_errors=True)
