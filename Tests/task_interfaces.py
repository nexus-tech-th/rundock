#!/usr/bin/env python3
"""Local CLI/MCP task contract checks; no network or existing repository writes."""
import argparse
import json
import os
import pathlib
import select
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True)
binary = str(pathlib.Path(parser.parse_args().binary).resolve())
root = pathlib.Path(tempfile.mkdtemp(prefix="rundock-task-interface-", dir="/private/tmp"))
env = dict(os.environ, PROCESSES_HOME=str(root / "state"))
proc = None


def cli(*args, ok=True):
    result = subprocess.run([binary, *args], cwd=root, env=env, capture_output=True, text=True, timeout=20)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return json.loads(result.stdout) if ok else result.stderr


def git(*args):
    return subprocess.run(["/usr/bin/git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


try:
    repo = root / "repository with spaces"
    repo.mkdir()
    git("init", "-b", "main")
    git("config", "user.name", "RunDock interface test")
    git("config", "user.email", "rundock-interface@example.invalid")
    (repo / "tracked file.txt").write_text("initial\n")
    git("add", "--", "tracked file.txt")
    git("commit", "-m", "Initial local fixture")
    task = cli("task", "ensure", "--repo", str(repo), "--task", "platform-conversation-123", "--name", "First task", "--client", "Test client", "--json")["task"]
    same = cli("task", "ensure", "--repo", str(repo), "--task", "platform-conversation-123", "--name", "Resume", "--client", "Test client", "--json")["task"]
    assert same["id"] == task["id"] and same["worktreePath"] == task["worktreePath"]
    task_id, worktree = task["id"], pathlib.Path(task["worktreePath"])
    assert worktree != repo and task_id in {t["id"] for t in cli("task", "list", "--json")["tasks"]}
    run = cli("run", "--task", task_id, "--json", "--", "/bin/pwd")["services"][0]
    assert run["taskID"] == task_id and run["cwd"] == str(worktree)
    shell = cli("shell", "--task", task_id, "--json")["services"][0]
    assert shell["taskID"] == task_id and shell["cwd"] == str(worktree)
    assert "rundock:" in cli("run", "--task", task_id, "--cwd", str(repo), "--", "/usr/bin/touch", "must-not-exist", ok=False)
    assert not (repo / "must-not-exist").exists()
    # Restart the private daemon to prove bindings survive process lifetime.
    stopped = subprocess.run([binary, "daemon", "stop", "--stop-services"], env=env, capture_output=True, text=True, timeout=20)
    assert stopped.returncode == 0, stopped.stderr
    persisted = cli("task", "list", "--json")["tasks"]
    assert any(t["id"] == task_id and t["worktreePath"] == str(worktree) for t in persisted)
    managed = cli("task", "ensure", "--repo", str(worktree), "--task", "platform-conversation-123", "--name", "Resume from worktree", "--client", "Test client", "--json")["task"]
    assert managed["id"] == task_id and managed["worktreePath"] == str(worktree)
    outside = root / "outside.txt"
    outside.write_text("must stay outside\n")
    cli("git", "stage", "--task", task_id, "--path", "../outside.txt", "--json", ok=False)
    escape = worktree / "escape"
    escape.symlink_to(repo, target_is_directory=True)
    cli("git", "stage", "--task", task_id, "--path", "escape/tracked file.txt", "--json", ok=False)
    escape.unlink()
    (worktree / "tracked file.txt").rename(worktree / "renamed file.txt")
    cli("git", "stage", "--task", task_id, "--path", "tracked file.txt", "--path", "renamed file.txt", "--json")
    renamed = cli("git", "status", "--task", task_id, "--json")["gitStatus"]
    assert any(c["path"] == "renamed file.txt" and c.get("originalPath") == "tracked file.txt" and c["indexStatus"] == "R" for c in renamed), renamed
    filename = "new file 'quoted'.txt"
    (worktree / filename).write_text("new content\n")
    cli("git", "stage", "--task", task_id, "--path", filename, "--json")
    changes = cli("git", "status", "--task", task_id, "--json")["gitStatus"]
    assert any(c["path"] == filename and c["indexStatus"] == "A" for c in changes), changes
    diff = cli("git", "diff", "--task", task_id, "--staged", "--path", filename, "--json")
    assert "new content" in diff["text"]
    cli("git", "unstage", "--task", task_id, "--path", filename, "--json")
    assert "stage requires --path" in cli("git", "stage", "--task", task_id, ok=False)
    assert "Unexpected arguments" in cli("git", "status", "--task", task_id, "--message", "bad", ok=False)

    proc = subprocess.Popen([binary, "mcp"], cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    sequence = 0

    def request(method, params):
        global sequence
        sequence += 1
        proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}) + "\n").encode())
        assert select.select([proc.stdout], [], [], 15)[0], "No MCP response"
        data = bytearray()
        while not data.endswith(b"\n"):
            byte = os.read(proc.stdout.fileno(), 1)
            assert byte, "MCP EOF"
            data.extend(byte)
        response = json.loads(data)
        assert response["id"] == sequence, response
        return response["result"]

    def call(name, arguments, ok=True):
        response = request("tools/call", {"name": name, "arguments": arguments})
        assert response["isError"] != ok, response
        text = response["content"][0]["text"]
        return json.loads(text) if ok else text

    request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "Interface acceptance", "version": "1"}})
    schemas = {tool["name"]: tool["inputSchema"] for tool in request("tools/list", {})["tools"]}
    assert {"rundock_task", "rundock_git"} <= schemas.keys()
    assert "oneOf" in schemas["rundock_git"] and "oneOf" in schemas["rundock_task"]
    assert "taskID" in schemas["rundock_run"]["properties"] and "anyOf" in schemas["rundock_shell"]
    assert task_id in {t["id"] for t in call("rundock_task", {"action": "list"})["tasks"]}
    resumed = call("rundock_task", {"action": "ensure", "repositoryPath": str(repo), "taskKey": "platform-conversation-123", "name": "Resume via MCP", "client": "Interface acceptance"})["task"]
    assert resumed["id"] == task_id
    terminal = call("rundock_shell", {"taskID": task_id})["services"][0]
    assert terminal["taskID"] == task_id and terminal["cwd"] == str(worktree)
    bound = call("rundock_run", {"taskID": task_id, "command": "/bin/pwd"})["services"][0]
    assert bound["taskID"] == task_id and bound["cwd"] == str(worktree)
    call("rundock_git", {"action": "stage", "taskID": task_id, "paths": [filename]})
    changes = call("rundock_git", {"action": "status", "taskID": task_id})["gitStatus"]
    assert any(c["path"] == filename and c["indexStatus"] == "A" for c in changes)
    for arguments in [
        {"action": "stage", "taskID": task_id},
        {"action": "stage", "taskID": task_id, "paths": filename},
        {"action": "stage", "taskID": task_id, "paths": [filename, 1]},
        {"action": "diff", "taskID": task_id, "staged": 1},
        {"action": "status", "taskID": task_id, "paths": [filename]},
        {"action": "commit", "taskID": task_id},
        {"action": "commit", "taskID": task_id, "message": ""},
        {"action": "invalid", "taskID": task_id},
    ]:
        call("rundock_git", arguments, ok=False)
    call("rundock_git", {"action": "commit", "taskID": task_id, "message": "Task commit with 'quoted' message"})
    committed = subprocess.run(["/usr/bin/git", "-C", str(worktree), "log", "-1", "--format=%s"], check=True, capture_output=True, text=True).stdout.strip()
    assert committed == "Task commit with 'quoted' message"
    # No remote is configured, so push exercises the action route without network.
    call("rundock_git", {"action": "push", "taskID": task_id}, ok=False)
    remote = root / "local remote.git"
    subprocess.run(["/usr/bin/git", "init", "--bare", str(remote)], check=True, capture_output=True)
    git("remote", "add", "origin", str(remote))
    call("rundock_git", {"action": "push", "taskID": task_id})
    remote_head = subprocess.run(["/usr/bin/git", "--git-dir", str(remote), "rev-parse", "refs/heads/" + task["branch"]], check=True, capture_output=True, text=True).stdout.strip()
    local_head = subprocess.run(["/usr/bin/git", "-C", str(worktree), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    assert remote_head == local_head
    call("rundock_task", {"action": "list", "taskKey": "unexpected"}, ok=False)
    call("rundock_task", {"action": "ensure", "repositoryPath": str(repo), "taskKey": "missing-name"}, ok=False)
    call("rundock_run", {"taskID": task_id, "cwd": str(repo), "command": "/usr/bin/touch must-not-exist"}, ok=False)
    assert not (repo / "must-not-exist").exists()
    assert git("status", "--porcelain") == "", "Source checkout must stay unchanged"
    print("Task CLI/MCP schemas, arguments, paths, persisted reuse, rename parsing and cwd binding passed.")
finally:
    if proc is not None:
        proc.stdin.close()
        proc.wait(timeout=10)
    subprocess.run([binary, "daemon", "stop", "--stop-services"], env=env, capture_output=True, timeout=10)
    shutil.rmtree(root, ignore_errors=True)
