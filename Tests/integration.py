#!/usr/bin/env python3
"""Real, isolated CLI/daemon/PTY acceptance check; no third-party Python packages."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import stat
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    root = Path(tempfile.mkdtemp(prefix="proc-check-", dir="/private/tmp"))
    env = dict(os.environ, PROCESSES_HOME=str(root))
    checks = []
    unrelated = subprocess.Popen(["/bin/sleep", "90"])
    daemon_pid = None

    def cli(*arguments, ok=True):
        result = subprocess.run([binary, *arguments], env=env, text=True, capture_output=True, timeout=15)
        if ok:
            assert result.returncode == 0, (arguments, result.stderr, result.stdout)
        else:
            assert result.returncode != 0, arguments
        return result

    def request(value):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(12)
            connection.connect(str(root / "control.sock"))
            connection.sendall(json.dumps(value).encode() + b"\n")
            reply = bytearray()
            while b"\n" not in reply:
                part = connection.recv(65536)
                assert part, "daemon closed unexpectedly"
                reply.extend(part)
            return json.loads(reply.split(b"\n", 1)[0])

    def wait_for(test, message):
        until = time.monotonic() + 8
        while time.monotonic() < until:
            if test():
                return
            time.sleep(.08)
        raise AssertionError(message)

    def services():
        return json.loads(cli("list", "--json").stdout)["services"]

    try:
        cli("daemon", "start")
        daemon_pid = request({"action": "ping"})["daemonPID"]
        cli("daemon", "status")
        assert stat.S_IMODE((root / "control.sock").stat().st_mode) == 0o600
        assert stat.S_IMODE(root.stat().st_mode) == 0o700
        checks.append("detached daemon survives one-shot CLI; private socket and state")
        cli("add", "--project", "Acceptance", "--name", "Shell", "--cwd", str(root), "--command", "/bin/zsh -f", "--actor", "Acceptance", "--branch", "test/native")
        item = services()[0]
        service_id = item["id"]
        cli("start", service_id, "--actor", "Codex")
        first_pid = services()[0]["pid"]
        os.kill(first_pid, 0)
        cli("start", service_id, ok=False)
        cli("remove", service_id, ok=False)
        cli("daemon", "stop", ok=False)
        cli("resize", service_id, "--cols", "92", "--rows", "26")
        cli("input", service_id, "--text", "printf 'PTY_%s\\n' READY; stty size\n")
        wait_for(lambda: "PTY_READY" in cli("logs", service_id).stdout and "26 92" in cli("logs", service_id).stdout, "interactive shell/resize output missing")
        checks.append("interactive PTY input/output and resize; duplicate start and unsafe shutdown refused")
        cli("event", service_id, "--message", "Task completed; keeping service running", "--actor", "Codex")
        assert services()[0]["pid"] == first_pid
        checks.append("agent handoff event leaves same service PID running")
        cli("input", service_id, "--text", "sleep 60\n")
        time.sleep(.2)
        cli("input", service_id, "--text", "\x03")
        cli("input", service_id, "--text", "printf 'AFTER_%s\\n' INTERRUPT\n")
        wait_for(lambda: "AFTER_INTERRUPT" in cli("logs", service_id).stdout, "terminal Ctrl-C did not interrupt foreground job")
        checks.append("terminal Ctrl-C interrupts foreground child while shell remains usable")
        cli("restart", service_id)
        assert services()[0]["pid"] != first_pid
        cli("stop", service_id)
        assert services()[0]["status"] != "running"
        assert unrelated.poll() is None
        checks.append("restart replaces managed PID; stop preserves unrelated process")
        bad = dict(item, id="../escape", name="Traversal")
        assert not request({"action": "add", "service": bad})["ok"]
        cli("add", "--project", "Bad", "--name", "Bad", "--cwd", "relative", "--command", "echo nope", ok=False)
        cli("add", "--project", "Bad", "--name", "Bad", "--cwd", str(root), "--command", "echo nope", "--port", "70000", ok=False)
        checks.append("path traversal, relative cwd and invalid port rejected")
        cli("daemon", "stop")
        wait_for(lambda: not (root / "control.sock").exists(), "socket remained after shutdown")
        cli("daemon", "start")
        restored = services()[0]
        assert restored["id"] == service_id and restored["status"] != "running"
        assert any("Task completed" in event["message"] for event in restored["events"])
        checks.append("definitions and activity survive daemon restart without automatic process launch")
        cli("remove", service_id)
        assert services() == []
        cli("skill", "install", "--path", str(root / "skills"))
        assert (root / "skills/rundock/SKILL.md").exists()
        cli("skill", "install", "--path", str(root / "skills"), ok=False)
        checks.append("skill installs to chosen directory and refuses overwrite")
        cli("daemon", "stop")
        print(json.dumps({"passed": checks, "count": len(checks)}, indent=2))
    finally:
        try:
            cli("daemon", "stop", "--stop-services")
        except Exception:
            # All records belong to this private test root; never scan or kill
            # processes outside the daemon/service IDs returned by this fixture.
            try:
                for item in request({"action": "list"}).get("services", []):
                    if item.get("pid"):
                        try:
                            os.killpg(item["pid"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                if daemon_pid:
                    os.kill(daemon_pid, signal.SIGTERM)
            except (OSError, KeyError):
                pass
        unrelated.terminate()
        unrelated.wait(timeout=5)
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
