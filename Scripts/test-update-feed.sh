#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FEED="${1:?Pass a combined appcast XML file}"
TEST_BUILD="$(mktemp -d /private/tmp/matveev-feed-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_BUILD"' EXIT
bash "$ROOT_DIR/Scripts/fetch-sparkle.sh"
xcrun swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -F "$ROOT_DIR/.build/sparkle" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$ROOT_DIR/.build/sparkle" \
  "$ROOT_DIR/Sources/AppLogger.swift" "$ROOT_DIR/Sources/Updater.swift" \
  "$ROOT_DIR/Tests/SparkleChannelTests.swift" -o "$TEST_BUILD/channel-tests"
/usr/bin/python3 - "$FEED" "$TEST_BUILD/channel-tests" "$ROOT_DIR/Resources/sparkle-public-key.txt" <<'PY'
import http.server, pathlib, subprocess, sys, threading, xml.etree.ElementTree as ET
feed = pathlib.Path(sys.argv[1]).read_bytes()
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.fromstring(feed).findall('./channel/item')
host_build = 1305
stable_builds = [int(i.findtext('s:version', namespaces=ns)) for i in items if i.find('s:channel', ns) is None]
beta_builds = [int(i.findtext('s:version', namespaces=ns)) for i in items if i.findtext('s:channel', namespaces=ns) == 'beta']
assert stable_builds, 'The feed must preserve a stable release'
assert max(stable_builds + beta_builds) > host_build, 'The feed must offer an update beyond 1.3.5'
def offered(builds):
    candidates = [build for build in builds if build > host_build]
    return str(max(candidates)) if candidates else 'none'
stable = offered(stable_builds)
beta = offered(stable_builds + beta_builds)
unexpected = []
class FeedServer(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/appcast.xml':
            unexpected.append(self.path)
            self.send_error(403)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/rss+xml')
        self.end_headers()
        self.wfile.write(feed)
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FeedServer)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    result = subprocess.run([sys.argv[2], f'http://127.0.0.1:{server.server_port}/appcast.xml', stable, beta, sys.argv[3]], timeout=75)
    assert not unexpected, 'The information probe must never download an archive'
    sys.exit(result.returncode)
finally:
    server.shutdown()
    server.server_close()
PY
