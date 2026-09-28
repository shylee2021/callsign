#!/usr/bin/env python3
"""Release helpers for the Sparkle appcast. Standard library only.

    appcast.py parse TAG
        Print `version=` and `channel=` lines for a release tag (GITHUB_OUTPUT format).
    appcast.py item --tag TAG --build N --app APP --archive ZIP --signature SIG --output FILE
        Write the appcast-item.json that is attached to a GitHub Release.
    appcast.py build ITEM_DIR OUTPUT [--repository OWNER/NAME]
        Assemble appcast.xml from every appcast-item.json under ITEM_DIR.
"""

import argparse
import json
import plistlib
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from xml.etree import ElementTree as ET

TAG_PATTERN = re.compile(r"^v(?P<version>\d+\.\d+\.\d+(?:-(?P<channel>beta)\.\d+)?)$")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DEFAULT_REPOSITORY = "shylee2021/callsign"
ITEM_FIELDS = ("tag", "version", "build", "channel", "minimumSystemVersion", "length", "edSignature", "pubDate")


class AppcastError(Exception):
    pass


def parse_tag(tag):
    match = TAG_PATTERN.match(tag)
    if not match:
        raise AppcastError(f"tag {tag!r} does not match vX.Y.Z or vX.Y.Z-beta.N")
    return {"version": match["version"], "channel": match["channel"] or "stable"}


def make_item(tag, build, app_path, archive_path, signature, now=None):
    parsed = parse_tag(tag)
    if not signature.strip():
        raise AppcastError("empty signature")
    with open(Path(app_path) / "Contents" / "Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    minimum = info.get("LSMinimumSystemVersion")
    if not minimum:
        raise AppcastError("LSMinimumSystemVersion missing from the app's Info.plist")
    if info.get("CFBundleShortVersionString") != parsed["version"]:
        raise AppcastError(
            f"app version {info.get('CFBundleShortVersionString')!r} does not match tag {tag!r}")
    if info.get("CFBundleVersion") != str(build):
        raise AppcastError(f"app build {info.get('CFBundleVersion')!r} does not match {build}")
    when = now or datetime.now(timezone.utc)
    return {
        "tag": tag,
        "version": parsed["version"],
        "build": int(build),
        "channel": parsed["channel"],
        "minimumSystemVersion": minimum,
        "length": Path(archive_path).stat().st_size,
        "edSignature": signature.strip(),
        "pubDate": when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def load_items(item_dir):
    items = []
    for path in sorted(Path(item_dir).rglob("*.json")):
        with open(path, encoding="utf-8") as handle:
            item = json.load(handle)
        missing = [field for field in ITEM_FIELDS if field not in item]
        if missing:
            raise AppcastError(f"{path}: missing {', '.join(missing)}")
        items.append(item)
    return items


def merge_items(items):
    """Newest pubDate wins for a build number; result is sorted by build number descending."""
    by_build = {}
    for item in items:
        current = by_build.get(item["build"])
        if current is None or item["pubDate"] > current["pubDate"]:
            by_build[item["build"]] = item
    return sorted(by_build.values(), key=lambda item: item["build"], reverse=True)


def render(items, repository=DEFAULT_REPOSITORY):
    ET.register_namespace("sparkle", SPARKLE_NS)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Callsign"
    for item in merge_items(items):
        element = ET.SubElement(channel, "item")
        ET.SubElement(element, "title").text = item["version"]
        published = datetime.strptime(item["pubDate"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        ET.SubElement(element, "pubDate").text = format_datetime(published)
        ET.SubElement(element, f"{{{SPARKLE_NS}}}version").text = str(item["build"])
        ET.SubElement(element, f"{{{SPARKLE_NS}}}shortVersionString").text = item["version"]
        if item["channel"] != "stable":
            ET.SubElement(element, f"{{{SPARKLE_NS}}}channel").text = item["channel"]
        ET.SubElement(element, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = item["minimumSystemVersion"]
        ET.SubElement(element, f"{{{SPARKLE_NS}}}releaseNotesLink").text = (
            f"https://github.com/{repository}/releases/tag/{item['tag']}")
        ET.SubElement(element, "enclosure", {
            "url": f"https://github.com/{repository}/releases/download/{item['tag']}/Callsign-{item['version']}.zip",
            "length": str(item["length"]),
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}edSignature": item["edSignature"],
        })
    ET.indent(rss, space="  ")
    return ET.tostring(rss, encoding="unicode", xml_declaration=True) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    parse = commands.add_parser("parse")
    parse.add_argument("tag")

    item = commands.add_parser("item")
    item.add_argument("--tag", required=True)
    item.add_argument("--build", required=True, type=int)
    item.add_argument("--app", required=True)
    item.add_argument("--archive", required=True)
    item.add_argument("--signature", required=True)
    item.add_argument("--output", required=True)

    build = commands.add_parser("build")
    build.add_argument("item_dir")
    build.add_argument("output")
    build.add_argument("--repository", default=DEFAULT_REPOSITORY)

    args = parser.parse_args(argv)
    try:
        if args.command == "parse":
            for key, value in parse_tag(args.tag).items():
                print(f"{key}={value}")
        elif args.command == "item":
            result = make_item(args.tag, args.build, args.app, args.archive, args.signature)
            Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        elif args.command == "build":
            items = load_items(args.item_dir)
            Path(args.output).write_text(render(items, args.repository), encoding="utf-8")
            print(f"{len(merge_items(items))} item(s) written to {args.output}")
    except (AppcastError, OSError, ValueError) as error:
        print(f"appcast: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
