"""Build Sparkle metadata from the verified release build (no private key access)."""
import email.utils
import os
from pathlib import Path
import xml.etree.ElementTree as ET

sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)
version, build = os.environ["VERSION"], os.environ["BUILD"]
repository, tag = os.environ["GITHUB_REPOSITORY"], os.environ["RELEASE_TAG"]
archive = os.environ["ARCHIVE"]
release_url = f"https://github.com/{repository}/releases/tag/{tag}"
# Parse the tool's attributes as XML instead of interpolating unescaped XML.
enclosure = ET.fromstring(f'<enclosure xmlns:sparkle="{sparkle}" {os.environ["SIGNATURE"]}/>')
assert enclosure.get(f"{{{sparkle}}}edSignature")
assert int(enclosure.get("length")) == Path(archive).stat().st_size
enclosure.set("url", f"https://github.com/{repository}/releases/download/{tag}/{archive}")
enclosure.set("type", "application/octet-stream")
rss = ET.Element("rss", version="2.0")
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Wren for Mac"
item = ET.SubElement(channel, "item")
for name, value in [
    ("title", f"Wren {version} (build {build})"),
    ("pubDate", email.utils.formatdate(usegmt=True)),
    (f"{{{sparkle}}}version", build),
    (f"{{{sparkle}}}shortVersionString", version),
    (f"{{{sparkle}}}minimumSystemVersion", "14.0"),
    (f"{{{sparkle}}}fullReleaseNotesLink", release_url),
]:
    ET.SubElement(item, name).text = value
ET.SubElement(item, "description").text = "A new Wren build is ready. View the GitHub release for its source revision."
item.append(enclosure)
ET.indent(rss)
ET.ElementTree(rss).write("appcast.xml", encoding="utf-8", xml_declaration=True)
Path("release-notes.md").write_text(
    f"Built from [{os.environ['GITHUB_SHA'][:7]}](https://github.com/{repository}/commit/{os.environ['GITHUB_SHA']}).\n\n"
    "Includes an Apple Silicon and Intel app. Updates and the update feed are signed with Sparkle's Ed25519 key. "
    "This build is ad-hoc signed, not Apple-notarized. On first installation, macOS may require approval in "
    "System Settings → Privacy & Security → Open Anyway.\n\n"
    "Existing updater-enabled installations can use Wren → Check for Updates. "
    "Automatic checks run hourly while Wren is running; installation requires your choice.\n"
)
