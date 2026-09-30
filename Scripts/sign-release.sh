#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVES="${1:?Pass the directory containing only the release DMG}"
VERSION="${2:?Pass the release version}"
CHANNEL="${3:-stable}"
/bin/bash "$ROOT_DIR/Scripts/fetch-sparkle.sh"
ARGS=(--download-url-prefix "https://github.com/Techniquei/MatveevVpn/releases/download/v$VERSION/" --maximum-deltas 0)
case "$CHANNEL" in
  stable) ;;
  beta) ARGS+=(--channel beta) ;;
  *) echo "Unknown release channel: $CHANNEL" >&2; exit 1 ;;
esac
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$ROOT_DIR/.build/sparkle/bin/generate_appcast" --ed-key-file - "${ARGS[@]}" "$ARCHIVES"
else
  "$ROOT_DIR/.build/sparkle/bin/generate_appcast" --account matveevVpn "${ARGS[@]}" "$ARCHIVES"
fi
test -s "$ARCHIVES/appcast.xml"
/usr/bin/python3 - "$ARCHIVES/appcast.xml" "$VERSION" "$CHANNEL" <<'PY'
import sys, xml.etree.ElementTree as ET
feed, version, channel = sys.argv[1:]
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(feed).findall('./channel/item')
matching = [item for item in items if item.findtext('s:shortVersionString', namespaces=ns) == version]
assert len(matching) == 1, 'The new release must occur exactly once in the feed'
item = matching[0]
assert item.findtext('s:channel', namespaces=ns) == (None if channel == 'stable' else 'beta'), 'Incorrect update channel'
enclosure = item.find('enclosure')
assert enclosure is not None and enclosure.get('{'+ns['s']+'}edSignature'), 'The archive must be signed'
assert enclosure.get('url', '').startswith('https://github.com/Techniquei/MatveevVpn/releases/download/v'+version+'/'), 'Incorrect download URL'
if channel == 'beta':
    assert any(i.find('s:channel', ns) is None for i in items), 'A beta feed must preserve stable updates'
print('Signed feed verified:', version, channel)
PY
