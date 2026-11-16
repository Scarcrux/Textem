"""Validate staged update identity, URLs, bytes and archive signature locally."""
import base64
import pathlib
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

def require(condition, message):
    if not condition:
        raise SystemExit(message)


require(len(sys.argv) == 2, 'Expected one private staging directory')
directory = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(__file__).resolve().parents[2]
require(directory.is_relative_to(root / '.build.nosync/updates'), 'Refused a directory outside private staging')
archives = list(directory.glob('Textem-*.zip'))
require(len(archives) == 1, 'Expected exactly one staged update archive')
archive = archives[0]
feed = directory / 'appcast.xml'
require(feed.is_file() and feed.stat().st_size <= 1024 * 1024, 'Missing or oversized feed')
tree = ET.parse(feed)
items = tree.findall('./channel/item')
require(len(items) == 1, 'Expected exactly one staged release')
item = items[0]
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
enclosure = item.find('enclosure')
require(enclosure is not None, 'Missing update enclosure')
require(enclosure.attrib['url'] == 'https://textem.scarcrux.com/updates/' + archive.name, 'Wrong download URL')
require(int(enclosure.attrib['length']) == archive.stat().st_size, 'Archive byte length mismatch')
signature = enclosure.attrib[ns + 'edSignature']
require(len(base64.b64decode(signature, validate=True)) == 64, 'Invalid archive signature encoding')
version = item.findtext(ns + 'version') or enclosure.attrib.get(ns + 'version')
with zipfile.ZipFile(archive) as bundle:
    info = plistlib.loads(bundle.read('Textem.app/Contents/Info.plist'))
require(info['CFBundleIdentifier'] == 'com.scarcrux.textem', 'Wrong update bundle identity')
require(version == info['CFBundleVersion'] == directory.name, 'Update version mismatch')
require(info['SUFeedURL'] == 'https://textem.scarcrux.com/updates/appcast.xml', 'Wrong appcast URL')
tool = root / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
result = subprocess.run([str(tool), '--account', 'textem-updates', '--verify', str(archive), signature], capture_output=True)
require(result.returncode == 0, 'Archive signature verification failed')
result = subprocess.run([str(tool), '--account', 'textem-updates', '--verify', str(feed)], capture_output=True)
require(result.returncode == 0, 'Feed signature verification failed')
print('staged_identity_version_url_length_archive_and_feed_signatures=PASS')
