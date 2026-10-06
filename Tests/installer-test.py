"""Native launchd/install/xattr/IPC tests in a disposable, unprivileged directory.

Only the fixed system paths, root check and ownership in a saved installer copy
are adapted. Service binaries, file copies, quarantine and launchd are real.
All accepted configurations remain off: no TUN, DNS overrides or routes change.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
SOURCE_PAYLOAD = Path(sys.argv[1]).resolve() / "Contents/Resources/.payload" if len(sys.argv) > 1 else None
UID, GID = os.getuid(), os.getgid()
assert UID != 0, "Run this test as a normal user, never root"
DOMAIN = next((domain for domain in (f"gui/{UID}", f"user/{UID}")
               if subprocess.run(["/bin/launchctl", "print", domain], capture_output=True).returncode == 0), None)
assert DOMAIN, "A native launchd user domain is required"


def run(*args, check=True):
    return subprocess.run(list(map(str, args)), check=check, capture_output=True, text=True)


def attrs(path):
    return run("/usr/bin/xattr", path).stdout.splitlines()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


with tempfile.TemporaryDirectory(prefix="mvinst-", dir="/private/tmp") as temp:
    work = Path(temp)
    base, installed_plist = work / "service", work / "service.plist"
    label = "com.matveev.vpn.install-test." + uuid.uuid4().hex
    target = DOMAIN + "/" + label
    app = work / "Test.app"
    payload = app / "Contents/Resources/.payload"
    payload.mkdir(parents=True)
    (app / "Contents/MacOS").mkdir()
    shutil.copyfile("/usr/bin/true", app / "Contents/MacOS/matveevVpn")
    (app / "Contents/MacOS/matveevVpn").chmod(0o755)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.matveev.vpn"}))
    for name in ("matveev-xray-service", "matveev-xray-worker"):
        shutil.copy2((SOURCE_PAYLOAD or ROOT / ".build/xray-runtime") / name, payload / name)
        run("/usr/bin/codesign", "--force", "--sign", "-", payload / name)
    shutil.copy2((SOURCE_PAYLOAD or ROOT / "Resources/payload") / "service-lifecycle.sh", payload / "service-lifecycle.sh")
    (payload / "com.matveev.vpn.plist").write_bytes(plistlib.dumps({
        "Label": label, "ProgramArguments": [str(base / "bin/matveev-xray-service")],
        "EnvironmentVariables": {"MATVEEV_SERVICE_DIRECTORY": str(base)},
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 1,
        "StandardErrorPath": str(work / "daemon.log"),
    }))
    # This reproduces a downloaded app, including a quarantined payload plist.
    run("/usr/bin/xattr", "-wr", "com.apple.quarantine", "0083;12345678;Chrome;INSTALL-TEST", app)
    run("/usr/bin/xattr", "-w", "com.matveev.test", "preserve", payload / "matveev-xray-service")
    config = work / "intent.json"
    empty = {"nodes": [], "selectedNodeID": "", "mode": "selective"}
    config.write_text(json.dumps(empty))
    config.chmod(0o600)

    # Map only launchd's system domain; inject a bootstrap failure when asked.
    wrapper = work / "launchctl"
    wrapper.write_text(f'''#!/bin/bash
set -eu
if [[ "$1" == bootstrap && -f '{work}/fail-bootstrap' ]]; then
  remaining="$(cat '{work}/fail-bootstrap')"
  if [[ "$remaining" -gt 0 ]]; then
    echo "$((remaining - 1))" > '{work}/fail-bootstrap'
    echo 'Injected bootstrap failure' >&2
    exit 5
  fi
fi
# User launchd can accept quarantine; model the documented system-daemon
# rejection while retaining native launchd for process lifecycle and IPC.
if [[ "$1" == bootstrap ]] && /usr/bin/xattr "$3" | /usr/bin/grep -qx com.apple.quarantine; then
  echo 'Plist has the com.apple.quarantine xattr set' >&2
  exit 5
fi
args=()
for arg in "$@"; do
  if [[ "$arg" == system ]]; then arg='{DOMAIN}'; fi
  if [[ "$arg" == system/* ]]; then arg="{DOMAIN}/${{arg#system/}}"; fi
  args+=("$arg")
done
exec /bin/launchctl "${{args[@]}}"
''')
    wrapper.chmod(0o755)
    source = ((SOURCE_PAYLOAD or ROOT / "Resources/payload") / "install-service.sh").read_text()
    source = source.replace(' && "$EUID" == 0', '')
    source = source.replace('/Library/Application Support/matveevVpn', str(base))
    source = source.replace('/Library/LaunchDaemons/com.matveev.vpn.plist', str(installed_plist))
    source = source.replace("SERVICE_LABEL='com.matveev.vpn'", f"SERVICE_LABEL='{label}'")
    source = source.replace('-o root -g wheel', f'-o {UID} -g {GID}')
    source = source.replace('/bin/launchctl enable system/com.matveev.vpn', f"'{wrapper}' enable system/{label}")
    assert '/Library/' not in source, 'The test must never modify a system path'
    installer = work / "installer.sh"
    installer.write_text(source)
    env = {**os.environ, "MATVEEV_LAUNCHCTL": str(wrapper)}

    def install(ok=True):
        result = subprocess.run(["/bin/bash", str(installer), str(payload), str(config), str(UID), str(GID), "off"],
                                env=env, capture_output=True, text=True, timeout=65)
        assert (result.returncode == 0) == ok, (result.returncode, result.stdout, result.stderr,
                                              (work / "daemon.log").read_text() if (work / "daemon.log").exists() else "")
        return result

    def stop():
        run('/bin/launchctl', 'bootout', target, check=False)
        deadline = time.monotonic() + 12
        while run('/bin/launchctl', 'print', target, check=False).returncode == 0:
            assert time.monotonic() < deadline, 'launchd did not remove the test service'
            time.sleep(0.1)

    def call(action='GetStatus', payload_data=None):
        command = {"version": 1, "requestID": str(uuid.uuid4()), "action": action, "expectedRevision": 0}
        if payload_data is not None:
            command['payload'] = payload_data
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(3)
            sock.connect(str(base / 'ipc/service.sock'))
            sock.sendall(json.dumps(command).encode() + b'\n')
            with sock.makefile('rb') as stream:
                reply = json.loads(stream.readline(1 << 20))
        assert reply['success'], reply
        return reply['status']

    def check_clean():
        assert sorted(path.name for path in (base / 'bin').iterdir()) == ['matveev-xray-service', 'matveev-xray-worker']
        for path in (installed_plist, base / 'bin', base / 'bin/matveev-xray-service', base / 'bin/matveev-xray-worker'):
            assert 'com.apple.quarantine' not in attrs(path), path
        assert 'com.apple.quarantine' in attrs(payload / 'com.matveev.vpn.plist'), 'Source app was modified'
        assert 'com.apple.quarantine' in attrs(app), 'Downloaded app quarantine was removed'
        status = call()
        assert status['runtimeState'] == 'off' and not status['desiredOn'], status
        assert (base / 'control/config-sha256').read_text().strip() == digest(config)
        assert (base / 'config.json').stat().st_mode & 0o777 == 0o600
        assert 'com.matveev.test' in attrs(base / 'bin/matveev-xray-service'), 'Unrelated xattr was cleared'
        for name in ('matveev-xray-service', 'matveev-xray-worker'):
            run('/usr/bin/codesign', '--verify', '--strict', base / 'bin' / name)

    try:
        # A local failure must remove the partial component and permit retry.
        (work / 'fail-bootstrap').write_text('20')
        install(ok=False)
        assert (work / 'fail-bootstrap').read_text().strip() == '0'
        assert not base.exists() and not installed_plist.exists(), 'Failed first install left a component'
        install()
        check_clean()
        assert call()['acceptedRevision'] == 2, 'Initial intent was not applied'
        print('installer: quarantined clean install, failed startup cleanup and retry passed', flush=True)

        # Probe quarantine policy directly: the user domain differs from system launchd.
        stop()
        run('/usr/bin/xattr', '-w', 'com.apple.quarantine', '0083;12345678;Chrome;INSTALL-TEST', installed_plist)
        rejected = run('/bin/launchctl', 'bootstrap', DOMAIN, installed_plist, check=False)
        if rejected.returncode == 0:
            stop()
            print('installer: user launchd accepts quarantine; system rejection is modeled at bootstrap boundary', flush=True)
        else:
            print('installer: native launchd rejected quarantined plist:', rejected.stderr.strip(), flush=True)
        boundary = run(wrapper, 'bootstrap', 'system', installed_plist, check=False)
        assert boundary.returncode != 0 and 'quarantine' in boundary.stderr
        run('/usr/bin/xattr', '-dr', 'com.apple.quarantine', installed_plist)
        run('/bin/launchctl', 'bootstrap', DOMAIN, installed_plist)
        for _ in range(50):
            if (base / 'ipc/service.sock').exists():
                try:
                    call()
                    break
                except (OSError, ValueError):
                    pass
            time.sleep(0.1)

        # Xray repairs must work without the legacy config.json. Apply a >4 KiB
        # subscription through the actual service and actual validation worker.
        (base / 'config.json').unlink()
        nodes = [{"id": f"node-{i}", "uri": f"vless://11111111-1111-1111-1111-111111111111@server-{i}.test:443?encryption=none"}
                 for i in range(80)]
        intent = {"nodes": nodes, "selectedNodeID": "node-0", "mode": "selective"}
        config.write_text(json.dumps(intent))
        assert config.stat().st_size > 4096
        install()
        check_clean()
        snapshot = base / 'state/snapshots' / (call()['snapshotID'] + '.json')
        assert len(json.loads(snapshot.read_text())['nodes']) == 80
        print('installer: repair without legacy config and real worker validation of 80 nodes passed', flush=True)

        # Reject an Intel-only helper before stopping the existing service.
        original_worker = work / 'worker-original'
        shutil.copy2(payload / 'matveev-xray-worker', original_worker)
        run('/usr/bin/lipo', '/usr/bin/true', '-thin', 'x86_64', '-output', payload / 'matveev-xray-worker')
        before = digest(base / 'state/accepted.json')
        install(ok=False)
        assert digest(base / 'state/accepted.json') == before
        assert call()['runtimeState'] == 'off'
        shutil.copy2(original_worker, payload / 'matveev-xray-worker')
        print('installer: Intel-only helper rejected before disrupting installed service passed', flush=True)

        # Rollback restores accepted state and version, clears old quarantine,
        # then waits on Xray IPC instead of the legacy runtime-status file.
        (base / 'control/version').write_text('24\n')
        run('/usr/bin/xattr', '-w', 'com.apple.quarantine', '0083;12345678;Chrome;OLD', installed_plist)
        accepted_hash = digest(base / 'state/accepted.json')
        old_worker_hash = digest(base / 'bin/matveev-xray-worker')
        old_config_hash = digest(base / 'config.json')
        (work / 'fail-bootstrap').write_text('20')
        install(ok=False)
        assert digest(base / 'state/accepted.json') == accepted_hash
        assert digest(base / 'bin/matveev-xray-worker') == old_worker_hash
        assert digest(base / 'config.json') == old_config_hash
        assert (base / 'control/version').read_text().strip() == '24'
        assert 'com.apple.quarantine' not in attrs(installed_plist)
        assert call()['runtimeState'] == 'off'
        print('installer: Xray upgrade failure restores state, binaries, version and native IPC readiness passed', flush=True)

        # An invalid intent after bootstrap must take the same rollback path.
        config.write_text('{"nodes": [], "mode": "invalid"}')
        install(ok=False)
        assert digest(base / 'state/accepted.json') == accepted_hash
        assert digest(base / 'config.json') == old_config_hash
        assert call()['runtimeState'] == 'off'
        print('installer: rejected initial configuration rolls back the running service passed', flush=True)

        # Verify legacy controller-to-Xray upgrade and rollback as well.
        stop()
        shutil.rmtree(base)
        for name in ('bin', 'run', 'control'):
            (base / name).mkdir(parents=True, exist_ok=True)
        controller = base / 'bin/controller.sh'
        controller.write_text(f'#!/bin/bash\necho stopped > "{base}/control/runtime-status"\nexec /bin/sleep 300\n')
        controller.chmod(0o755)
        (base / 'run/desired-state').write_text('off\n')
        (base / 'config.json').write_text('{"legacy": true}')
        (base / 'config.json').chmod(0o600)
        (base / 'control/version').write_text('14\n')
        (base / 'app-bundle').write_text(str(app) + '\n')
        installed_plist.write_bytes(plistlib.dumps({'Label': label, 'ProgramArguments': ['/bin/bash', str(controller)], 'RunAtLoad': True}))
        run('/bin/launchctl', 'bootstrap', DOMAIN, installed_plist)
        config.write_text(json.dumps(empty))
        (work / 'fail-bootstrap').write_text('20')
        install(ok=False)
        assert (base / 'config.json').read_text() == '{"legacy": true}'
        assert (base / 'control/version').read_text().strip() == '14'
        assert (base / 'control/runtime-status').read_text().strip() == 'stopped'
        install()
        check_clean()
        assert call()['acceptedRevision'] == 2
        print('installer: legacy controller rollback and migration to stopped Xray passed', flush=True)
    finally:
        stop()
