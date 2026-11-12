"""Verify the archive/feed and require the app to trust the actual signing key."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

feed, archive, info_path, signer_path = sys.argv[1:]
signer = Path(signer_path).resolve()
key = os.environ["SPARKLE_PRIVATE_KEY"].encode()
info = plistlib.loads(Path(info_path).read_bytes())
with tempfile.TemporaryDirectory() as directory:
    key_file = Path(directory) / "key"
    key_file.write_bytes(key)
    key_file.chmod(0o600)
    subprocess.run([str(signer.parent / "generate_keys"), "--account", "wren-release-verification", "-f", str(key_file)], check=True, stdout=subprocess.DEVNULL)
public = subprocess.check_output([str(signer.parent / "generate_keys"), "--account", "wren-release-verification", "-p"], text=True).strip()
assert public == info["SUPublicEDKey"], "The app does not trust the release signing key"
item = ET.parse(feed).find("./channel/item")
assert item.find("{http://www.andymatuschak.org/xml-namespaces/sparkle}version").text == info["CFBundleVersion"]
assert item.find("{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString").text == info["CFBundleShortVersionString"]
enclosure = item.find("enclosure")
assert int(enclosure.get("length")) == Path(archive).stat().st_size
signature = enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
for args in [[feed], [archive, signature]]:
    subprocess.run([str(signer), "--verify", "--ed-key-file", "-", *args], input=key, check=True)
print("Verified feed, archive, build version, and embedded public key.")
