import json
import plistlib
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

import appcast

NS = {"sparkle": appcast.SPARKLE_NS}


def item(build, channel="stable", version=None, pub_date="2026-09-28T06:00:00Z", tag=None):
    version = version or (f"0.{build}.0" if channel == "stable" else f"0.{build}.0-beta.1")
    return {
        "tag": tag or f"v{version}",
        "version": version,
        "build": build,
        "channel": channel,
        "minimumSystemVersion": "26.0",
        "length": 1000 + build,
        "edSignature": f"sig{build}",
        "pubDate": pub_date,
    }


class ParseTagTests(unittest.TestCase):
    def test_stable_and_beta_tags(self):
        self.assertEqual(appcast.parse_tag("v0.1.0"), {"version": "0.1.0", "channel": "stable"})
        self.assertEqual(appcast.parse_tag("v0.1.0-beta.1"), {"version": "0.1.0-beta.1", "channel": "beta"})

    def test_rejects_other_tags(self):
        for tag in ["0.1.0", "v0.2", "v0.1.0-alpha.1", "v0.1.0-beta", "v0.1.0-beta.1x", "v1.0.0-rc.1"]:
            with self.assertRaises(appcast.AppcastError, msg=tag):
                appcast.parse_tag(tag)


class RenderTests(unittest.TestCase):
    def test_empty_feed(self):
        root = ET.fromstring(appcast.render([]))
        self.assertEqual(root.find("channel/title").text, "Callsign")
        self.assertEqual(root.findall("channel/item"), [])

    def test_every_field_lands_in_the_xml(self):
        root = ET.fromstring(appcast.render([item(42, "beta", "0.1.0-beta.1")]))
        entry = root.find("channel/item")
        self.assertEqual(entry.find("title").text, "0.1.0-beta.1")
        self.assertEqual(entry.find("pubDate").text, "Mon, 28 Sep 2026 06:00:00 +0000")
        self.assertEqual(entry.find("sparkle:version", NS).text, "42")
        self.assertEqual(entry.find("sparkle:shortVersionString", NS).text, "0.1.0-beta.1")
        self.assertEqual(entry.find("sparkle:channel", NS).text, "beta")
        self.assertEqual(entry.find("sparkle:minimumSystemVersion", NS).text, "26.0")
        self.assertEqual(entry.find("sparkle:releaseNotesLink", NS).text,
                         "https://github.com/shylee2021/callsign/releases/tag/v0.1.0-beta.1")
        enclosure = entry.find("enclosure")
        self.assertEqual(enclosure.get("url"),
                         "https://github.com/shylee2021/callsign/releases/download/v0.1.0-beta.1/Callsign-0.1.0-beta.1.zip")
        self.assertEqual(enclosure.get("length"), "1042")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(enclosure.get(f"{{{appcast.SPARKLE_NS}}}edSignature"), "sig42")

    def test_channel_element_only_on_prereleases(self):
        root = ET.fromstring(appcast.render([item(1), item(2, "beta")]))
        channels = [entry.find("sparkle:channel", NS) for entry in root.findall("channel/item")]
        self.assertEqual([c.text if c is not None else None for c in channels], ["beta", None])

    def test_sorted_by_build_descending(self):
        root = ET.fromstring(appcast.render([item(3), item(10), item(2)]))
        builds = [entry.find("sparkle:version", NS).text for entry in root.findall("channel/item")]
        self.assertEqual(builds, ["10", "3", "2"])

    def test_duplicate_builds_collapse_to_the_newest(self):
        older = item(5, version="0.5.0", pub_date="2026-09-28T06:00:00Z")
        newer = item(5, version="0.5.1", pub_date="2026-09-29T06:00:00Z")
        root = ET.fromstring(appcast.render([newer, older]))
        entries = root.findall("channel/item")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].find("title").text, "0.5.1")

    def test_repository_override(self):
        root = ET.fromstring(appcast.render([item(1)], repository="someone/fork"))
        self.assertTrue(root.find("channel/item/enclosure").get("url").startswith("https://github.com/someone/fork/"))

    def test_output_declares_the_sparkle_namespace_once(self):
        text = appcast.render([item(1), item(2)])
        self.assertTrue(text.startswith("<?xml"))
        self.assertEqual(text.count(f'xmlns:sparkle="{appcast.SPARKLE_NS}"'), 1)


class LoadItemsTests(unittest.TestCase):
    def test_reads_nested_folders_and_rejects_missing_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            first = Path(folder, "v0.1.0")
            first.mkdir()
            (first / "appcast-item.json").write_text(json.dumps(item(1)))
            second = Path(folder, "v0.2.0")
            second.mkdir()
            (second / "appcast-item.json").write_text(json.dumps(item(2)))
            self.assertEqual([i["build"] for i in appcast.load_items(folder)], [1, 2])

            broken = dict(item(3))
            del broken["edSignature"]
            (Path(folder, "broken.json")).write_text(json.dumps(broken))
            with self.assertRaises(appcast.AppcastError):
                appcast.load_items(folder)


class MakeItemTests(unittest.TestCase):
    def app(self, folder, version, build):
        app = Path(folder, "Callsign.app")
        (app / "Contents").mkdir(parents=True)
        with open(app / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({
                "CFBundleShortVersionString": version,
                "CFBundleVersion": str(build),
                "LSMinimumSystemVersion": "26.0",
            }, handle)
        archive = Path(folder, "Callsign.zip")
        archive.write_bytes(b"x" * 123)
        return app, archive

    def test_item_from_app_and_archive(self):
        with tempfile.TemporaryDirectory() as folder:
            app, archive = self.app(folder, "0.1.0-beta.1", 42)
            when = datetime(2026, 9, 28, 6, 0, tzinfo=timezone.utc)
            result = appcast.make_item("v0.1.0-beta.1", 42, app, archive, "sig\n", now=when)
            self.assertEqual(result, {
                "tag": "v0.1.0-beta.1",
                "version": "0.1.0-beta.1",
                "build": 42,
                "channel": "beta",
                "minimumSystemVersion": "26.0",
                "length": 123,
                "edSignature": "sig",
                "pubDate": "2026-09-28T06:00:00Z",
            })
            self.assertEqual(sorted(result), sorted(appcast.ITEM_FIELDS))

    def test_rejects_mismatched_app(self):
        with tempfile.TemporaryDirectory() as folder:
            app, archive = self.app(folder, "0.1.0", 42)
            with self.assertRaises(appcast.AppcastError):
                appcast.make_item("v0.3.0", 42, app, archive, "sig")
            with self.assertRaises(appcast.AppcastError):
                appcast.make_item("v0.1.0", 43, app, archive, "sig")
            with self.assertRaises(appcast.AppcastError):
                appcast.make_item("v0.1.0", 42, app, archive, "  ")


class CommandLineTests(unittest.TestCase):
    def test_parse_prints_github_output_lines(self):
        import contextlib
        import io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(appcast.main(["parse", "v1.2.3-beta.4"]), 0)
        self.assertEqual(out.getvalue(), "version=1.2.3-beta.4\nchannel=beta\n")

    def test_parse_fails_on_bad_tag(self):
        import contextlib
        import io
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(appcast.main(["parse", "nightly"]), 1)

    def test_build_round_trip(self):
        import contextlib
        import io
        with tempfile.TemporaryDirectory() as folder:
            items = Path(folder, "items", "v0.1.0")
            items.mkdir(parents=True)
            (items / "appcast-item.json").write_text(json.dumps(item(1)))
            output = Path(folder, "appcast.xml")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(appcast.main(["build", str(items.parent), str(output)]), 0)
            root = ET.parse(output).getroot()
            self.assertEqual(len(root.findall("channel/item")), 1)


if __name__ == "__main__":
    unittest.main()
