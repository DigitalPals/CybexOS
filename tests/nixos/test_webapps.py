#!/usr/bin/env python3
"""nerdos-webapp contracts: strict addresses, desktop entries, defaults.

The network is never used: every fetch goes through a stubbed Fetcher, and
ImageMagick is hidden so icons pass through as the fixture's own PNG bytes.
"""

import configparser
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "assets/scripts/nerdos-webapp"
LOADER = importlib.machinery.SourceFileLoader("nerdos_webapp", str(HELPER))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
webapp = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(webapp)

PNG = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06"
       b"\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\x0f\x00\x00\x01\x01"
       b"\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82")


def desktop(path):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read_string(path.read_text())
    return parser["Desktop Entry"]


class Network:
    """A stand-in for the web: URL -> bytes, or an exception."""

    def __init__(self, pages):
        self.pages = pages
        self.requested = []

    def __call__(self):
        network = self

        class Fake(webapp.Fetcher):
            def get(self, url, limit):
                network.requested.append(url)
                if not url.startswith("https://"):
                    raise webapp.WebAppError("Only https addresses are fetched")
                value = network.pages.get(url)
                if value is None or isinstance(value, Exception):
                    raise webapp.WebAppError(f"offline: {url}")
                if len(value) > limit:
                    raise webapp.WebAppError("too large")
                return value, url

        return Fake


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name) / "home/alex"
        self.home.mkdir(parents=True)
        environment = {"HOME": str(self.home), "PATH": os.environ.get("PATH", "/usr/bin")}
        patcher = patch.dict(os.environ, environment, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        # No browser launches, notifications or ImageMagick conversions.
        self.spawned = []
        for target, value in (("spawn", self.spawned.append),
                              ("notify", lambda *args, **kwargs: self.notified.append(args))):
            stub = patch.object(webapp, target, value)
            stub.start()
            self.addCleanup(stub.stop)
        self.notified = []
        real_which = webapp.shutil.which
        self.installed_programs = set()

        def which(name, *args, **kwargs):
            if name == "magick":
                return None
            if name in ("brave", "firefox"):
                return f"/usr/bin/{name}" if name in self.installed_programs else None
            return real_which(name, *args, **kwargs)

        stub = patch.object(webapp.shutil, "which", which)
        stub.start()
        self.addCleanup(stub.stop)

    def apps(self):
        return self.home / ".local/share/nerdos/webapps"

    def entry(self, identifier):
        return self.home / f".local/share/applications/nerdos-webapp-{identifier}.desktop"


class Addresses(unittest.TestCase):
    def test_only_plain_http_and_https_addresses_are_accepted(self):
        for good, canonical in (
            ("https://app.slack.com", "https://app.slack.com/"),
            ("HTTPS://Example.com/path?q=1#x", "https://Example.com/path?q=1#x"),
            ("http://192.168.1.20:8123/lovelace", "http://192.168.1.20:8123/lovelace"),
            ("https://[::1]:8443/", "https://[::1]:8443/"),
            ("https://bücher.example/", "https://bücher.example/"),
        ):
            self.assertEqual(webapp.validate_url(good), canonical, good)
        for bad in ("ftp://example.com/", "javascript:alert(1)", "file:///etc/passwd",
                    "https://user:secret@example.com/", "https://token@example.com/",
                    "https://exa mple.com/", "https://exa\nmple.com/", "https://", "example.com",
                    "https://example.com:0/", "https://example.com:99999/",
                    "https://-bad.example/", "https://under_score.example/",
                    "data:text/html,<b>x</b>", "https://example.com/" + "a" * 2100):
            with self.assertRaises(webapp.WebAppError, msg=bad):
                webapp.validate_url(bad)

    def test_ids_and_names_are_plain(self):
        self.assertEqual(webapp.slug("Google Photos!"), "google-photos")
        self.assertEqual(webapp.name_from_host("https://app.slack.com/"), "Slack")
        self.assertEqual(webapp.name_from_host("https://www.bbc.co.uk/"), "Co")
        self.assertEqual(webapp.clean_name("  Two\nlines\x07 "), "Two lines")
        for bad in ("../x", "", "UPPER", "a" * 41, "-dash"):
            with self.assertRaises(webapp.WebAppError):
                webapp.validate_id(bad)


class Install(Fixture):
    def test_offline_install_writes_a_desktop_entry_and_a_monogram(self):
        record = webapp.install("https://app.example.com/inbox", "Mail & Co\nEvil=1",
                                offline=True)
        self.assertEqual(record["id"], "mail-co-evil-1")
        entry = desktop(self.entry("mail-co-evil-1"))
        self.assertEqual(entry["Name"], "Mail & Co Evil=1", "a newline cannot add keys")
        self.assertEqual(entry["Exec"],
                         "/run/current-system/sw/bin/nerdos-webapp launch mail-co-evil-1")
        self.assertNotIn("example.com", entry["Exec"], "the address never reaches Exec")
        self.assertEqual(entry["Icon"], str(self.apps() / "mail-co-evil-1/icon.svg"))
        self.assertEqual(entry["X-NerdOS-WebApp"], "mail-co-evil-1")
        self.assertEqual(entry["Type"], "Application")
        svg = (self.apps() / "mail-co-evil-1/icon.svg").read_text()
        self.assertIn(">M</text>", svg)
        self.assertNotIn("<script", svg)
        stored = json.loads((self.apps() / "mail-co-evil-1/app.json").read_text())
        self.assertEqual(stored["url"], "https://app.example.com/inbox")
        self.assertEqual(stored["iconSource"], "monogram")
        self.assertEqual(stored["iconAttempt"], 0, "the first launch fetches the icon")

    def test_a_second_site_with_the_same_name_gets_its_own_id(self):
        first = webapp.install("https://chat.one.example/", "Chat", offline=True)
        again = webapp.install("https://chat.one.example/", "Chat", offline=True)
        other = webapp.install("https://chat.two.example/", "Chat", offline=True)
        self.assertEqual((first["id"], again["id"], other["id"]), ("chat", "chat", "chat-2"))
        self.assertEqual(json.loads((self.apps() / "chat/app.json").read_text())["url"],
                         "https://chat.one.example/")
        replaced = webapp.install("https://chat.three.example/", "Chat", "chat", offline=True)
        self.assertEqual(replaced["id"], "chat", "an explicit id replaces that app")

    def test_exec_quotes_a_home_with_spaces(self):
        self.assertEqual(webapp.exec_argument("/home/a b/x"), '"/home/a b/x"')
        self.assertEqual(webapp.exec_argument('/h/$x"`\\'), '"/h/\\$x\\"\\`\\\\"')
        self.assertEqual(webapp.exec_argument("/h/50%"), '"/h/50%%"')

    def test_an_online_install_uses_the_sites_icon_and_name(self):
        network = Network({
            "https://chat.example.com/": (
                b'<html><head><meta name="application-name" content="Example Chat">'
                b'<link rel="mask-icon" href="/mask.svg">'
                b'<link rel="icon" type="image/svg+xml" href="/icon.svg">'
                b'<link rel="icon" href="data:image/png;base64,AAAA">'
                b'<link rel="icon" sizes="32x32" href="/small.png">'
                b'<link rel="apple-touch-icon" href="/touch.png"></head></html>'),
            "https://chat.example.com/touch.png": PNG,
        })
        with patch.object(webapp, "Fetcher", network()):
            record = webapp.install("https://chat.example.com/")
        self.assertEqual(record["name"], "Example Chat")
        self.assertEqual(record["id"], "example-chat")
        self.assertEqual(network.requested,
                         ["https://chat.example.com/", "https://chat.example.com/touch.png"])
        self.assertEqual((self.apps() / "example-chat/icon.png").read_bytes(), PNG)
        self.assertFalse((self.apps() / "example-chat/icon.svg").exists())
        self.assertEqual(desktop(self.entry("example-chat"))["Icon"],
                         str(self.apps() / "example-chat/icon.png"))

    def test_without_network_the_install_falls_back_to_a_monogram(self):
        network = Network({})
        with patch.object(webapp, "Fetcher", network()):
            record = webapp.install("https://notes.example.org/", "Notes")
        self.assertEqual(record["iconSource"], "monogram")
        self.assertTrue((self.apps() / "notes/icon.svg").is_file())
        self.assertIn("https://notes.example.org/favicon.ico", network.requested)
        self.assertGreater(json.loads((self.apps() / "notes/app.json").read_text())
                           ["iconAttempt"], 0, "a failed fetch waits before retrying")

    def test_http_addresses_and_non_images_are_never_used_as_icons(self):
        network = Network({"https://x.example/": b"<link rel=icon href=/a.ico>",
                           "https://x.example/a.ico": b"<html>not an icon</html>",
                           "https://x.example/favicon.ico": b"<svg/>"})
        with patch.object(webapp, "Fetcher", network()):
            webapp.install("http://intranet.local/", "Intranet")
            self.assertEqual(network.requested, [], "http is never fetched")
            record = webapp.install("https://x.example/", "X Example")
        self.assertEqual(record["iconSource"], "monogram")

    def test_icon_discovery_prefers_large_raster_icons(self):
        parser = webapp.IconLinks()
        parser.feed('<link rel="shortcut icon" href="/16.ico">'
                    '<link rel="icon" sizes="192x192" href="/192.png">'
                    '<link rel="apple-touch-icon-precomposed" href="/touch.png">'
                    '<meta property="og:site_name" content="Site">')
        ranked = [href for _size, href in sorted(parser.icons, key=lambda item: -item[0])]
        self.assertEqual(ranked, ["/touch.png", "/192.png", "/16.ico"])
        self.assertEqual(parser.name, "Site")
        ico = (b"\x00\x00\x01\x00\x02\x00" + bytes([16, 16]) + b"\x00" * 14
               + bytes([0, 0]) + b"\x00" * 14)
        self.assertEqual(webapp.largest_ico_frame(ico), 1, "0 means 256 pixels")

    def test_the_fetcher_refuses_plain_http(self):
        with self.assertRaisesRegex(webapp.WebAppError, "https"):
            webapp.Fetcher().get("http://example.com/", 10)

    def test_remove_deletes_only_its_own_files(self):
        webapp.install("https://a.example/", "Alpha", offline=True)
        foreign = self.entry("foreign")
        foreign.write_text("[Desktop Entry]\nName=Mine\n")
        with self.assertRaisesRegex(webapp.WebAppError, "not a NerdOS web app"):
            webapp.remove("foreign")
        self.assertTrue(foreign.exists())
        with self.assertRaisesRegex(webapp.WebAppError, "not a NerdOS web app"):
            webapp.install("https://b.example/", "Foreign", offline=True)
        webapp.remove("alpha")
        self.assertFalse(self.entry("alpha").exists())
        self.assertFalse((self.apps() / "alpha").exists())
        with self.assertRaisesRegex(webapp.WebAppError, "No web app"):
            webapp.remove("alpha")

    def test_list_reports_installed_apps_as_json(self):
        webapp.install("https://b.example/", "Beta", offline=True)
        webapp.install("https://a.example/", "Alpha", offline=True)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(webapp.main(["list", "--json"]), 0)
        listed = json.loads(output.getvalue())
        self.assertEqual([app["id"] for app in listed], ["alpha", "beta"])
        self.assertEqual(listed[0]["icon"], str(self.apps() / "alpha/icon.svg"))
        self.assertEqual(listed[0]["url"], "https://a.example/")


class Defaults(Fixture):
    def test_seeding_installs_the_five_defaults_once_and_never_readds_a_removed_one(self):
        self.assertEqual(webapp.seed(), ["slack", "whatsapp", "youtube", "google-photos", "x"])
        for identifier, name, url in webapp.DEFAULTS:
            entry = desktop(self.entry(identifier))
            self.assertEqual(entry["Name"], name)
            self.assertEqual(json.loads((self.apps() / identifier / "app.json").read_text())["url"],
                             url)
            self.assertTrue((self.apps() / identifier / "icon.svg").is_file(),
                            "seeding is offline: a monogram until the first launch")
        self.assertEqual(webapp.seed(), [], "a second run changes nothing")

        webapp.remove("youtube")
        self.assertEqual(webapp.seed(), [])
        self.assertFalse(self.entry("youtube").exists(), "a removed default stays removed")
        self.assertIn("youtube", json.loads((self.apps() / "defaults.json").read_text())["seeded"])

        # Its binding now explains how to reinstall it.
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            self.assertEqual(webapp.main(["launch", "youtube"]), 1)
        self.assertIn("nerdos-webapp install --name YouTube --url https://youtube.com/",
                      error.getvalue())
        self.assertTrue(self.notified)
        self.assertEqual(self.spawned, [])

        # The user may reinstall it on purpose.
        webapp.install("https://youtube.com/", "YouTube", offline=True)
        self.assertTrue(self.entry("youtube").exists())

    def test_seeding_keeps_a_users_own_file(self):
        self.entry("slack").parent.mkdir(parents=True)
        self.entry("slack").write_text("[Desktop Entry]\nName=My Slack\n")
        self.assertIn("slack", webapp.seed())
        self.assertEqual(self.entry("slack").read_text(), "[Desktop Entry]\nName=My Slack\n")

    def test_a_default_never_seeded_is_seeded_by_its_binding(self):
        self.installed_programs.add("firefox")
        webapp.launch("whatsapp")
        self.assertTrue(self.entry("whatsapp").exists())
        self.assertEqual(self.spawned[0], ["nerdos-apps", "webapp", "https://web.whatsapp.com/"])

    def test_launch_follows_the_browser_choice_and_fetches_a_real_icon_later(self):
        webapp.seed()
        self.installed_programs.update({"brave", "firefox"})
        webapp.launch("slack")
        self.assertEqual(self.spawned[0], ["nerdos-apps", "webapp", "https://app.slack.com/"])
        self.assertEqual(self.spawned[1][-3:], ["refresh", "--quiet", "slack"],
                         "a monogram is replaced by the site icon in the background")
        self.installed_programs.discard("brave")
        self.spawned.clear()
        record = json.loads((self.apps() / "x/app.json").read_text())
        record["iconAttempt"] = int(webapp.time.time())
        (self.apps() / "x/app.json").write_text(json.dumps(record))
        webapp.launch("x")
        self.assertEqual(self.spawned, [["nerdos-apps", "webapp", "https://x.com/"]],
                         "a recent failed fetch is not retried on every launch")

    def test_refresh_replaces_the_monogram(self):
        webapp.seed()
        network = Network({"https://app.slack.com/": b"<link rel=icon href=/i.png>",
                           "https://app.slack.com/i.png": PNG})
        with patch.object(webapp, "Fetcher", network()):
            self.assertTrue(webapp.refresh_icon("slack"))
        self.assertEqual(desktop(self.entry("slack"))["Icon"],
                         str(self.apps() / "slack/icon.png"))
        self.assertFalse((self.apps() / "slack/icon.svg").exists())
        record = json.loads((self.apps() / "slack/app.json").read_text())
        self.assertEqual(record["iconSource"], "favicon")

    def test_webapps_and_super_b_share_the_default_browser_helper(self):
        bindings = (ROOT / "desktop/hypr/bindings.lua").read_text()
        self.assertIn('local browser = "nerdos-apps browser"', bindings)
        self.assertEqual(webapp.browser_command("https://example.invalid/"), ["nerdos-apps", "webapp", "https://example.invalid/"])
        for identifier, _name, _url in webapp.DEFAULTS:
            self.assertIn(f'web_app("{identifier}")', bindings)
        self.assertIn('return "nerdos-webapp launch " .. id', bindings)


class CommandLine(Fixture):
    def test_install_reports_a_bad_address_without_writing_anything(self):
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            self.assertEqual(webapp.main(["install", "--notify", "--url", "ftp://x.example/"]), 1)
        self.assertIn("http and https", error.getvalue())
        self.assertEqual(len(self.notified), 1)
        self.assertFalse((self.home / ".local/share/applications").exists())


if __name__ == "__main__":
    unittest.main()
