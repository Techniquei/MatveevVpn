"""Run the sing-box installer in native user launchd, with only fixed system
paths/owners/root check adapted. Off-state tests never create a TUN or change
system DNS/routes. System launchd's quarantine rejection is modeled at bootstrap.
An optional second app argument exercises rollback of the real retired Go daemon.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
PACKAGED = len(sys.argv) > 1 and bool(sys.argv[1])
PAYLOAD_SOURCE = Path(sys.argv[1]).resolve() / 'Contents/Resources/.payload' if PACKAGED else ROOT / 'Resources/payload'
PREVIOUS_SOURCE = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
UID, GID = os.getuid(), os.getgid()
assert UID != 0, 'Run as a normal user, never root'

def run(*args, check=True):
    return subprocess.run(list(map(str, args)), capture_output=True, text=True, check=check)

def attrs(path):
    return run('/usr/bin/xattr', path).stdout.splitlines()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

DOMAIN = next((d for d in (f'gui/{UID}', f'user/{UID}') if run('/bin/launchctl', 'print', d, check=False).returncode == 0), None)
assert DOMAIN
with tempfile.TemporaryDirectory(prefix='mvlegacy-', dir='/private/tmp') as temp:
    work = Path(temp)
    base, installed_plist = work / 'service', work / 'service.plist'
    label = 'com.matveev.vpn.singbox-install-test.' + uuid.uuid4().hex
    target = DOMAIN + '/' + label
    app = work / 'Test.app'
    payload = app / 'Contents/Resources/.payload'
    payload.mkdir(parents=True)
    (app / 'Contents/MacOS').mkdir()
    shutil.copyfile('/usr/bin/true', app / 'Contents/MacOS/matveevVpn')
    (app / 'Contents/MacOS/matveevVpn').chmod(0o755)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.matveev.vpn'}))
    if not PACKAGED:
        fixture_source = work / 'engine.c'
        fixture_source.write_text('int main(void) { return 0; }\n')
        run('/usr/bin/xcrun', 'clang', '-target', 'arm64-apple-macos13.0', fixture_source, '-o', work / 'engine')
    for name in ('sing-box', 'xray'):
        source = PAYLOAD_SOURCE / name if PACKAGED else work / 'engine'
        shutil.copyfile(source, payload / name)
        (payload / name).chmod(0o755)
        run('/usr/bin/codesign', '--force', '--sign', '-', payload / name)
    for name in ('controller.sh', 'service-lifecycle.sh'):
        shutil.copy2(PAYLOAD_SOURCE / name, payload / name)
    # DNS-manager has its own command-injection tests. The real controller is
    # used here, with an inert DNS-manager so even failure cleanup is isolated.
    (payload / 'dns-manager.sh').write_text('#!/bin/bash\nexit 0\n')
    (payload / 'dns-manager.sh').chmod(0o755)
    legacy_plist = {'Label': label, 'ProgramArguments': [str(base / 'bin/controller.sh')],
                    'EnvironmentVariables': {'MATVEEV_BASE_DIR': str(base)},
                    'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 1,
                    'StandardErrorPath': str(work / 'daemon.log')}
    (payload / 'com.matveev.vpn.plist').write_bytes(plistlib.dumps(legacy_plist))
    run('/usr/bin/xattr', '-wr', 'com.apple.quarantine', '0083;12345678;Chrome;INSTALL-TEST', app)
    run('/usr/bin/xattr', '-w', 'com.matveev.test', 'preserve', payload / 'sing-box')
    config = work / 'config.json'
    config.write_text('{}')
    config.chmod(0o600)
    wrapper = work / 'launchctl'
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
    source = (PAYLOAD_SOURCE / 'install-service.sh').read_text()
    source = source.replace(' && "$EUID" == 0', '')
    source = source.replace('/Library/Application Support/matveevVpn', str(base))
    source = source.replace('/Library/LaunchDaemons/com.matveev.vpn.plist', str(installed_plist))
    source = source.replace("SERVICE_LABEL='com.matveev.vpn'", f"SERVICE_LABEL='{label}'")
    source = source.replace('-o root -g wheel', f'-o {UID} -g {GID}')
    source = source.replace('/bin/launchctl enable system/com.matveev.vpn', f"'{wrapper}' enable system/{label}")
    assert '/Library/' not in source
    installer = work / 'installer.sh'
    installer.write_text(source)
    env = {**os.environ, 'MATVEEV_LAUNCHCTL': str(wrapper)}

    def install(ok=True, desired='off'):
        result = subprocess.run(['/bin/bash', str(installer), str(payload), str(config), str(UID), str(GID), desired],
                                env=env, capture_output=True, text=True, timeout=85)
        assert (result.returncode == 0) == ok, (result.returncode, result.stdout, result.stderr,
                    (work / 'daemon.log').read_text() if (work / 'daemon.log').exists() else '')
        return result

    def stop():
        run('/bin/launchctl', 'bootout', target, check=False)
        end = time.monotonic() + 15
        while run('/bin/launchctl', 'print', target, check=False).returncode == 0:
            assert time.monotonic() < end
            time.sleep(0.1)

    def ready():
        end = time.monotonic() + 15
        while time.monotonic() < end:
            status = base / 'control/runtime-status'
            if status.exists() and status.read_text().strip() == 'stopped': return
            time.sleep(0.1)
        raise AssertionError('controller did not become ready')

    def check():
        ready()
        assert sorted(p.name for p in (base / 'bin').iterdir()) == ['controller.sh', 'dns-manager.sh', 'sing-box', 'xray']
        assert (base / 'run/desired-state').read_text().strip() == 'off'
        assert (base / 'control/version').read_text().strip() == '28'
        assert (base / 'control/config-sha256').read_text().strip() == digest(config)
        for path in (installed_plist, base / 'bin', *(base / 'bin').iterdir()):
            assert 'com.apple.quarantine' not in attrs(path), path
        assert 'com.apple.quarantine' in attrs(app) and 'com.apple.quarantine' in attrs(payload / 'com.matveev.vpn.plist')
        assert 'com.matveev.test' in attrs(base / 'bin/sing-box')

    def status():
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(2)
            sock.connect(str(base / 'ipc/service.sock'))
            sock.sendall(b'{"version":1,"requestID":"test-status","action":"GetStatus","expectedRevision":0}\n')
            with sock.makefile('rb') as stream: reply = json.loads(stream.readline(1 << 20))
        assert reply['success'], reply
        return reply['status']

    try:
        (work / 'fail-bootstrap').write_text('20')
        install(ok=False)
        assert not base.exists() and not installed_plist.exists(), 'failed first install left a partial component'
        (work / 'fail-bootstrap').unlink()
        install(desired='on')
        check()
        print('sing-box installer: quarantined clean install, cleanup/retry and stopped readiness passed', flush=True)

        (base / 'control/version').write_text('14\n')
        (base / '.preserved').write_text('hidden state')
        before = digest(base / 'config.json')
        (work / 'fail-bootstrap').write_text('20')
        install(ok=False)
        ready()
        assert (base / 'control/version').read_text().strip() == '14'
        assert digest(base / 'config.json') == before and (base / '.preserved').read_text() == 'hidden state'
        (work / 'fail-bootstrap').unlink()
        print('sing-box installer: failed legacy replacement restores complete state and native readiness', flush=True)

        original = (payload / 'sing-box').read_bytes()
        before_pid = re.search(r'pid = (\d+)', run('/bin/launchctl', 'print', target).stdout).group(1)
        run('/usr/bin/lipo', '/usr/bin/true', '-thin', 'x86_64', '-output', payload / 'sing-box')
        (payload / 'sing-box').chmod(0o755)
        run('/usr/bin/codesign', '--force', '--sign', '-', payload / 'sing-box')
        install(ok=False)
        after_pid = re.search(r'pid = (\d+)', run('/bin/launchctl', 'print', target).stdout).group(1)
        assert before_pid == after_pid, 'wrong architecture disrupted previous service'
        (payload / 'sing-box').write_bytes(original)
        run('/usr/bin/xattr', '-w', 'com.matveev.test', 'preserve', payload / 'sing-box')
        run('/usr/bin/xattr', '-w', 'com.apple.quarantine', '0083;12345678;Chrome;INSTALL-TEST', payload / 'sing-box')
        print('sing-box installer: Intel-only helper rejected before stopping previous service', flush=True)

        stop()
        shutil.rmtree(base)
        (base / 'bin').mkdir(parents=True)
        (base / 'control').mkdir()
        (base / 'state').mkdir(mode=0o700)
        (base / 'control/version').write_text('26\n')
        (base / 'state/marker').write_text('preserve previous Xray state')
        (base / 'owner-uid').write_text(f'{UID} {GID}\n')
        (base / 'app-bundle').write_text(str(app) + '\n')
        if PREVIOUS_SOURCE:
            for name in ('matveev-xray-service', 'matveev-xray-worker'):
                shutil.copy2(PREVIOUS_SOURCE / name, base / 'bin' / name)
        else:
            # Native launchd plus a minimal IPC fixture; no Go build dependency
            # is added to the returned sing-box branch's validation workflow.
            daemon = base / 'bin/matveev-xray-service'
            daemon.write_text(f'''#!/usr/bin/python3
import json, os, socket
path={str(base / 'ipc/service.sock')!r}
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path): os.unlink(path)
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.bind(path); s.listen(8)
while True:
    c,_=s.accept()
    c.recv(4096)
    c.sendall(json.dumps({{"success":True,"status":{{"runtimeState":"off","desiredOn":False}}}}).encode()+b'\\n')
    c.close()
''')
            daemon.chmod(0o755)
        previous_plist = dict(legacy_plist)
        previous_plist['ProgramArguments'] = [str(base / 'bin/matveev-xray-service')]
        previous_plist['EnvironmentVariables'] = {'MATVEEV_SERVICE_DIRECTORY': str(base)}
        installed_plist.write_bytes(plistlib.dumps(previous_plist))
        run('/bin/launchctl', 'bootstrap', DOMAIN, installed_plist)
        end = time.monotonic() + 15
        while True:
            try:
                assert status()['runtimeState'] == 'off'
                break
            except (OSError, ValueError):
                assert time.monotonic() < end
                time.sleep(0.1)
        assert not (base / 'config.json').exists(), 'fixture must reproduce an Xray-only installation'
        previous_binary = digest(base / 'bin/matveev-xray-service')
        (work / 'fail-bootstrap').write_text('20')
        install(ok=False)
        assert status()['runtimeState'] == 'off'
        assert digest(base / 'bin/matveev-xray-service') == previous_binary
        assert (base / 'state/marker').read_text() == 'preserve previous Xray state'
        assert (base / 'control/version').read_text().strip() == '26'
        (work / 'fail-bootstrap').unlink()
        print('sing-box installer: Xray-only installation restored after failed downgrade', flush=True)
        install()
        check()
        assert (base / 'state/marker').read_text() == 'preserve previous Xray state'
        print('sing-box installer: migration from Xray to stopped legacy controller passed', flush=True)
    finally:
        stop()
