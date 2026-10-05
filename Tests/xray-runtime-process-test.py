"""Exercise the child-process boundary using only a loopback SOCKS listener."""
import json
import select
import socket
import subprocess
import sys


def reply(process):
    if not select.select([process.stdout], [], [], 5)[0]:
        raise AssertionError("worker did not respond before its deadline")
    return json.loads(process.stdout.readline())


def command(process, action, config=None):
    request = {"version": 1, "id": "process-test", "action": action}
    if config is not None:
        request["config"] = config
    process.stdin.write(json.dumps(request).encode() + b"\n")
    process.stdin.flush()
    return reply(process)


for termination in ("eof", "signal", "oversized"):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    config = {
        "inbounds": [{"listen": "127.0.0.1", "port": port, "protocol": "socks"}],
        "outbounds": [{"protocol": "freedom"}],
    }
    process = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        started = command(process, "start", config)
        assert started["success"] and started["running"], started
        assert started["core"] == "26.9.30", started
        rejected = command(process, "validate", {"env": {"PRIVATE": "secret"}})
        assert not rejected["success"] and rejected["running"], rejected
        assert rejected["error"] == "already_running", rejected
        if termination == "eof":
            process.stdin.close()
        elif termination == "signal":
            process.terminate()
        else:
            process.stdin.write(b"s" * ((1 << 20) + 2) + b"\n")
            process.stdin.flush()
        process.wait(timeout=7)
        assert process.returncode == (1 if termination == "oversized" else 0), process.returncode
        assert process.stdout.read() == b"", "engine log contaminated protocol output"
        assert process.stderr.read() == b"", "worker emitted an unstructured private diagnostic"
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", port))
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()
print("runtime process: EOF, signal, oversized input and listener cleanup passed")
