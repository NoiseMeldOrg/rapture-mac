#!/usr/bin/env python3
"""Insert a newest-first Sparkle <item> into appcast.xml.

Called by Scripts/release.sh after the DMG is signed with sign_update.
Usage:
  append_appcast_item.py <appcast.xml> <shortVersion> <buildVersion> \
                         <dmgURL> <sigAttrs> <pubDate> <releaseLink>

<sigAttrs> is the raw output of `sign_update`, e.g.
  sparkle:edSignature="BASE64==" length="1234"
which is embedded directly into the <enclosure> tag.
"""
import sys

def main() -> int:
    if len(sys.argv) != 8:
        print(__doc__, file=sys.stderr)
        return 2
    appcast, shortv, build, url, sig, pubdate, link = sys.argv[1:8]
    marker = "<!-- appcast:items -->"

    text = open(appcast, encoding="utf-8").read()
    if marker not in text:
        print(f"error: marker '{marker}' not found in {appcast}", file=sys.stderr)
        return 1
    if f"<sparkle:shortVersionString>{shortv}</sparkle:shortVersionString>" in text:
        print(f"appcast already has an item for {shortv}; nothing to do")
        return 0

    item = (
        "    <item>\n"
        f"      <title>{shortv}</title>\n"
        f"      <pubDate>{pubdate}</pubDate>\n"
        f"      <sparkle:version>{build}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{shortv}</sparkle:shortVersionString>\n"
        "      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n"
        f"      <link>{link}</link>\n"
        f'      <enclosure url="{url}" type="application/octet-stream" {sig} />\n'
        "    </item>"
    )
    # Newest-first: directly below the marker.
    text = text.replace(marker, marker + "\n" + item, 1)
    open(appcast, "w", encoding="utf-8").write(text)
    print(f"appended appcast item for {shortv}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
