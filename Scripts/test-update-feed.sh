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
stable = max(int(i.findtext('s:version', namespaces=ns)) for i in items if i.find('s:channel', ns) is None)
beta = max(int(i.findtext('s:version', namespaces=ns)) for i in items if i.findtext('s:channel', namespaces=ns) == 'beta')
assert beta > stable, 'This regression check requires a beta newer than stable'
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
    result = subprocess.run([sys.argv[2], f'http://127.0.0.1:{server.server_port}/appcast.xml', str(stable), str(beta), sys.argv[3]], timeout=75)
    assert not unexpected, 'The information probe must never download an archive'
    sys.exit(result.returncode)
finally:
    server.shutdown()
    server.server_close()
PY
