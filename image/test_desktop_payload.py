"""No image builds: isolated fixtures for desktop parity and boot appearance."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import jinja2
import yaml

from boot_branding import brand_boot_menu, grub_install_entries
from desktop_payload import prepare_defaults, split_seed, prepare_quickshell

ROOT = Path(__file__).resolve().parents[1]


def load(name, relative):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / relative))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


INIT = load("desktop_user_init", "image/rootfs/usr/libexec/cybexos-user-init")
ACCOUNTS = load("desktop_seed_accounts", "image/rootfs/usr/libexec/cybexos-seed-installed-users")


class DesktopPayload(unittest.TestCase):
    def test_launcher_focus_handoff_ships_identically_on_both_paths(self):
        checkout = ROOT / "roles/desktop/files/quickshell"
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_quickshell(ROOT, payload)
            installed = payload / "usr/share/cybexos/runtime/quickshell"
            for relative in ("LauncherWindow.qml", "LauncherView.qml", "shell.qml"):
                self.assertEqual((installed / relative).read_bytes(),
                                 (checkout / relative).read_bytes(), relative)
            window = (installed / "LauncherWindow.qml").read_text()
            self.assertIn("root.contentItem.Window.active", window)
            self.assertIn("active: Launcher.open && root.dismissalGrabReady", window)
            self.assertIn("WlrKeyboardFocus.Exclusive", window)

    def test_model_usage_runtime_matches_checkout_including_rust_live_activity(self):
        source = ROOT / "roles/desktop/files/quickshell/ModelUsage"
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_quickshell(ROOT, payload)
            installed = payload / "usr/share/cybexos/runtime/quickshell/ModelUsage"
            files = {p.relative_to(source): p for p in source.rglob("*")
                     if p.is_file() and not p.is_symlink() and "__pycache__" not in p.parts and p.suffix != ".pyc"}
            self.assertEqual(set(files), {p.relative_to(installed) for p in installed.rglob("*") if p.is_file()})
            for relative, path in files.items():
                expected = path.read_bytes()
                if path.suffix in (".qml", ".js"):
                    expected = expected.replace(b"/usr/local/libexec/cybexos-", b"/usr/libexec/cybexos-")
                self.assertEqual((installed / relative).read_bytes(), expected, str(relative))
            self.assertIn(b"def fetch_rust_account", (installed / "scripts/usage-fetch.py").read_bytes())
            self.assertIn(b"normalize_rust_activity", (installed / "scripts/proxy-activity.py").read_bytes())
            self.assertIn(b"additional_headers", (installed / "scripts/proxy-live.py").read_bytes())
            self.assertIn(b"UsageLogic.acquireLive", (installed / "UsageActivityBackend.qml").read_bytes())
            self.assertTrue((installed / "UsageLiveConnection.qml").is_file())
            helpers = payload / "usr/share/cybexos/runtime/quickshell/Common/SettingsHelpers.js"
            self.assertIn(b"liveAccountActivity: true", helpers.read_bytes())
            self.assertNotIn(b"showBarActivity", helpers.read_bytes())
            self.assertNotIn(b"showRecentSessions", helpers.read_bytes())
            # Both installation contracts provide the optional transport.
            self.assertIn("python3-websockets", (ROOT / "image/cybexos-desktop.spec").read_text())
            self.assertIn("python3-websockets", (ROOT / "roles/desktop/tasks/main.yml").read_text())

    def test_fusebox_widget_ships_identically_with_the_same_layout_on_both_paths(self):
        checkout = ROOT / "roles/desktop/files/quickshell"
        files = ["scripts/fusebox.py", "Common/Fusebox.qml", "Common/FuseboxHelpers.js",
                 "Bar/Modules/Fusebox.qml", "Popovers/FuseboxPopover.qml", "assets/fusebox.svg",
                 "assets/fusebox-white.svg", "Common/SettingsHelpers.js", "Common/BrandIcons.qml"]
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_quickshell(ROOT, payload)
            installed = payload / "usr/share/cybexos/runtime/quickshell"
            for relative in files:
                self.assertEqual((installed / relative).read_bytes(), (checkout / relative).read_bytes(), relative)
            # The checkout and the ISO derive the layout from the same helpers and
            # the same connected-widgets flag, so both start Fusebox the same way.
            script = ("const H = require(process.argv[1]); "
                      "console.log(JSON.stringify([false, true].map(connected => "
                      "H.merge(null, { connectedWidgets: connected }).mods.right.map(m => m.id + ':' + m.on))));")
            layouts = [subprocess.run(["node", "-e", script, str(base / "Common/SettingsHelpers.js")],
                                      text=True, capture_output=True, check=True).stdout
                       for base in (checkout, installed)]
            self.assertEqual(layouts[0], layouts[1])
            plain, connected = json.loads(layouts[1])
            self.assertIn("fusebox:false", plain)
            self.assertIn("fusebox:true", connected)
            self.assertEqual(connected[connected.index("modelusage:true") + 1], "fusebox:true")
        unit = (ROOT / "image/provision.yml").read_text()
        self.assertIn("CYBEXOS_CONNECTED_WIDGETS", unit)
        self.assertIn("CYBEXOS_CONNECTED_WIDGETS", (ROOT / "image/desktop_payload.py").read_text())

    def test_capture_tools_reach_both_installation_paths(self):
        # The capture helpers are user helpers: the checkout copies every one
        # into ~/.local/bin, the RPM into /usr/share/cybexos/bin, which
        # cybexos-user-init links into ~/.local/bin. `screenshot` finds
        # screenshot-stitch beside its resolved self, so both must be helpers.
        contract = json.loads((ROOT / "assets/desktop-contract.json").read_text())
        helpers = ("screenshot", "screenshot-stitch", "screen-record", "screen-ocr", "color-picker")
        for name in helpers:
            self.assertIn(name, contract["userHelpers"])
            self.assertTrue((ROOT / "assets/scripts" / name).read_text().startswith("#!"), name)
        screenshot = (ROOT / "assets/scripts/screenshot").read_text()
        self.assertIn('SCRIPT_DIR=$(dirname -- "$SCRIPT_PATH")', screenshot)
        self.assertIn('python3 "$SCRIPT_DIR/screenshot-stitch"', screenshot)
        dotfiles = (ROOT / "roles/dotfiles/tasks/main.yml").read_text()
        self.assertIn('loop: "{{ cybexos_desktop_contract.userHelpers }}"', dotfiles)
        self.assertIn('contract["userHelpers"]', (ROOT / "image/package").read_text())
        self.assertIn("contract['userHelpers']", (ROOT / "image/repair-installed").read_text())

        # Packages: the desktop task installs them on a checkout and is part
        # of the ISO's compose; the RPM also requires them.
        applications = load("desktop_payload_applications", "image/applications")
        packages, _ = applications.package_names()
        spec = (ROOT / "image/cybexos-desktop.spec").read_text()
        requires = {name for line in spec.splitlines() if line.startswith("Requires:")
                    for name in line.split()[1:]}
        for package in ("grim", "slurp", "satty", "wf-recorder", "hyprpicker", "ImageMagick",
                        "tesseract", "zbar", "qt6-qtmultimedia", "python3", "wl-clipboard"):
            self.assertIn(package, packages)
            self.assertIn(package, requires)

        # The shell side ships byte-identical, overlay registration included.
        checkout = ROOT / "roles/desktop/files/quickshell"
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_quickshell(ROOT, payload)
            installed = payload / "usr/share/cybexos/runtime/quickshell"
            for relative in ("WebcamOverlay.qml", "qmldir", "shell.qml", "Common/Recorder.qml",
                             "Common/CaptureHelpers.js", "Bar/Modules/Indicators.qml"):
                self.assertEqual((installed / relative).read_bytes(),
                                 (checkout / relative).read_bytes(), relative)

        # Both paths render the same bindings file.
        bindings = (ROOT / "roles/desktop/files/bindings.lua").read_text()
        for command in ("screenshot scroll", "screen-record --webcam", "color-picker"):
            self.assertIn(f'home .. "/.local/bin/{command}"', bindings)
        self.assertIn('"bindings.lua"', (ROOT / "image/package").read_text())

    def test_shell_translations_ship_identically_on_both_paths(self):
        """The I18n singleton and its catalogs are shell source: the checkout
        deploys the tree and the RPM copies it, so both read the same Dutch."""
        checkout = ROOT / "roles/desktop/files/quickshell"
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_quickshell(ROOT, payload)
            installed = payload / "usr/share/cybexos/runtime/quickshell"
            for relative in ("Common/I18n.qml", "Common/I18nHelpers.js", "Common/i18n/nl.js", "Common/qmldir"):
                self.assertEqual((installed / relative).read_bytes(), (checkout / relative).read_bytes(), relative)
            self.assertIn("singleton I18n I18n.qml", (installed / "Common/qmldir").read_text())

    def test_overview_dock_and_process_list_ship_identically_on_both_paths(self):
        checkout = ROOT / "roles/desktop/files/quickshell"
        files = ["shell.qml", "qmldir", "Common/qmldir", "Popovers/Drawer/qmldir",
                 "OverviewWindow.qml", "OverviewView.qml", "DockWindow.qml",
                 "Common/Overview.qml", "Common/Dock.qml", "Common/ProcessList.qml",
                 "Common/OverviewHelpers.js", "Common/DockHelpers.js",
                 "Common/ProcessListHelpers.js", "Common/WindowCommands.js",
                 "Popovers/Drawer/DrawerProcesses.qml", "Popovers/Drawer/DrawerOverview.qml",
                 "Settings/BarLayoutGroups.qml", "scripts/processes"]
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_quickshell(ROOT, payload)
            installed = payload / "usr/share/cybexos/runtime/quickshell"
            for relative in files:
                self.assertEqual((installed / relative).read_bytes(), (checkout / relative).read_bytes(), relative)
            # Both paths run the helper through bash; the ISO also marks it executable.
            self.assertEqual((installed / "scripts/processes").stat().st_mode & 0o777, 0o755)
            # One schema decides the defaults on both: the dock starts off and
            # unpinned, Top processes starts shown.
            script = ("const H = require(process.argv[1]); const d = H.merge(null); "
                      "console.log(JSON.stringify([d.dock, d.dockAutoHide, d.dockPinned, d.drawerOverview.processes]));")
            defaults = [subprocess.run(["node", "-e", script, str(base / "Common/SettingsHelpers.js")],
                                       text=True, capture_output=True, check=True).stdout
                        for base in (checkout, installed)]
            self.assertEqual(defaults[0], defaults[1])
            self.assertEqual(json.loads(defaults[1]), [False, False, [], True])
        # Super+Tab and the overview/dock layer rules come from the one
        # bindings.lua and looknfeel template that both installs use.
        bindings = (ROOT / "roles/desktop/files/bindings.lua").read_text()
        self.assertIn('bind(mainMod .. " + TAB", hl.dsp.global("quickshell:overviewToggle")', bindings)
        package = (ROOT / "image/package").read_text()
        self.assertIn('"bindings.lua"', package)
        self.assertIn('"looknfeel.lua"', package)
        self.assertIn("- bindings.lua", (ROOT / "roles/desktop/tasks/main.yml").read_text())
        look = (ROOT / "roles/desktop/templates/looknfeel.lua.j2").read_text()
        self.assertIn("|wallpaper|overview|dock)$", look)
        self.assertIn("|shortcuts|dock)$", look)

    def test_portable_defaults_and_boot_assets_share_workstation_sources(self):
        environment = jinja2.Environment(undefined=jinja2.StrictUndefined)
        environment.filters.update(bool=bool, ternary=lambda value, yes, no: yes if value else no)
        inventory = yaml.safe_load((ROOT / "inventory/group_vars/all.yml").read_text())
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            contract = prepare_defaults(ROOT, payload, environment, inventory)
            vendor = payload / "usr/share/cybexos"
            app = vendor / "user-seed/.rustup/toolchains/default/rustc"
            app.parent.mkdir(parents=True)
            app.write_bytes(b"offline compiler")
            split_seed(vendor, contract)
            defaults = json.loads((vendor / "essential-seed/.config/cybexos/shell.json").read_text())
            self.assertEqual(defaults, contract["shell"])
            # Exercise first-login seeding followed by the real shell merger:
            # an unversioned seed keeps current defaults and no personal host.
            (vendor / "bin").mkdir()
            (vendor / "runtime").mkdir()
            home = payload / "installed-user"
            with patch.dict(os.environ, {}, clear=True):
                INIT.initialize(home, vendor, mode="essential")
            preferences = home / ".config/cybexos/shell.json"
            result = subprocess.run([
                "node", "-e",
                "const fs = require('fs'), H = require(process.argv[1]); "
                "const s = H.merge(JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))); "
                "console.log(JSON.stringify({font: H.FONT_CHOICES.find(f => f.id === s.font).family, "
                "remote: s.mods.right.find(m => m.id === 'remote'), options: s.modOpts.remote}));",
                str(ROOT / "roles/desktop/files/quickshell/Common/SettingsHelpers.js"),
                str(preferences),
            ], text=True, capture_output=True, check=True)
            settings = json.loads(result.stdout)
            self.assertEqual(settings["font"], "JetBrainsMono Nerd Font")
            self.assertTrue(settings["remote"]["on"])
            self.assertEqual(settings["options"]["host"], "")
            self.assertEqual(settings["options"]["label"], "")
            wallpaper = vendor / "essential-seed/Pictures/Wallpapers" / defaults["wall"]
            self.assertEqual(wallpaper.read_bytes(), (ROOT / "assets/wallpapers" / defaults["wall"]).read_bytes())
            self.assertTrue(app.is_file())
            self.assertFalse((vendor / "essential-seed/.rustup").exists())
            self.assertEqual(json.loads((vendor / "seed-groups.json").read_text())["totalBytes"], app.stat().st_size)
            self.assertIn("x-scheme-handler/t3code=t3code-nightly.desktop",
                          (vendor / "essential-seed/.config/mimeapps.list").read_text())
            self.assertFalse(list(vendor.rglob("plugins.json")))
            self.assertFalse(list(vendor.rglob("user.lua")))
            for source in (ROOT / "roles/boot/files").iterdir():
                self.assertEqual((payload / "usr/share/plymouth/themes/cybex" / source.name).read_bytes(), source.read_bytes())
            self.assertEqual((payload / "usr/lib/sysctl.d/60-cybexos-hardening.conf").read_bytes(),
                             (ROOT / "roles/base/files/60-cybexos-hardening.conf").read_bytes())
            self.assertIn('target="DROP"', (payload / "usr/lib/firewalld/zones/cybexos.xml").read_text())

    def test_gestures_and_game_mode_render_identically_for_checkout_and_iso(self):
        """Touchpad gestures and game mode live in input.lua and looknfeel.lua.

        The checkout renders them with the machine's facts; image/package
        renders them with dynamic hardware and keyboard lookups. Only those
        lines may differ, so both paths share the same gestures, game mode,
        bindings and helper.
        """
        import json as json_module
        import shlex
        inventory = yaml.safe_load((ROOT / "inventory/group_vars/all.yml").read_text())
        environment = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
        environment.filters.update(bool=bool, ternary=lambda value, yes, no: yes if value else no,
                                   to_json=json_module.dumps, quote=shlex.quote)
        base = {"features": inventory["features"], "cybexos_xps_2026": False,
                "machine_keyboard_layout": "us", "machine_keyboard_variant": ""}
        for name, allowed in (("input.lua", ("kb_layout", "kb_variant")), ("looknfeel.lua", ("force_zero_scaling",))):
            template = environment.from_string((ROOT / "roles/desktop/templates" / (name + ".j2")).read_text())
            checkout = template.render(**base).splitlines()
            iso = template.render(**base, cybexos_dynamic_hardware=True)
            if name == "input.lua":
                # As image/package does for the installed keyboard choice.
                iso = iso.replace('kb_layout = "us"', 'kb_layout = os.getenv("CYBEXOS_KEYBOARD_LAYOUT") or "us"')
                iso = iso.replace('kb_variant = ""', 'kb_variant = os.getenv("CYBEXOS_KEYBOARD_VARIANT") or ""')
            iso = iso.splitlines()
            self.assertEqual(len(checkout), len(iso), name)
            different = [(a, b) for a, b in zip(checkout, iso) if a != b]
            self.assertTrue(all(any(key in a for key in allowed) for a, _ in different), (name, different))
        package = (ROOT / "image/package").read_text()
        self.assertIn('"input.lua", "looknfeel.lua"', package)
        self.assertIn('"bindings.lua", "autostart.lua", "displays.lua", "input_preferences.lua"', package)
        self.assertIn('helpers = contract["userHelpers"]', package)
        self.assertIn("game-mode", json.loads((ROOT / "assets/desktop-contract.json").read_text())["userHelpers"])

    def test_named_themes_ship_and_list_identically_on_both_paths(self):
        """Built-in themes, the theme helper and `cybex theme` on both layouts."""
        checkout = ROOT / "roles/desktop/files/quickshell"
        contract = json.loads((ROOT / "assets/desktop-contract.json").read_text())
        self.assertIn("cybexos-theme", contract["userHelpers"])
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            payload = base / "payload"
            prepare_quickshell(ROOT, payload)
            vendor = payload / "usr/share/cybexos"
            installed = vendor / "runtime/quickshell"
            themes = sorted(p.relative_to(checkout) for p in (checkout / "themes").rglob("*") if p.is_file())
            self.assertGreaterEqual(len(themes), 8)
            for relative in themes + [Path(name) for name in (
                    "scripts/theme-packs.py", "scripts/theme_packs.py", "scripts/settings-store",
                    "Common/Themes.qml", "Common/ThemeHelpers.js", "Common/SettingsHelpers.js")]:
                self.assertEqual((installed / relative).read_bytes(), (checkout / relative).read_bytes(),
                                 str(relative))
            self.assertEqual(sorted(p.relative_to(installed) for p in (installed / "themes").rglob("*")
                                    if p.is_file()), themes)
            # The RPM's helpers, as image/package installs them, and the
            # account link cybexos-user-init makes to the vendor runtime.
            (vendor / "bin").mkdir()
            for name in ("cybexos-theme", "cybexos-runtime"):
                target = vendor / "bin" / name
                target.write_bytes((ROOT / "assets/scripts" / name).read_bytes())
                target.chmod(0o755)
            iso_data = base / "iso-home/.local/share"
            (iso_data / "cybexos").mkdir(parents=True)
            (iso_data / "cybexos/runtime").symlink_to(vendor / "runtime")
            # The checkout: helpers in ~/.local/bin and the deployed runtime.
            checkout_home = base / "checkout-home"
            (checkout_home / ".local/bin").mkdir(parents=True)
            for name in ("cybexos-theme", "cybexos-runtime"):
                target = checkout_home / ".local/bin" / name
                target.write_bytes((ROOT / "assets/scripts" / name).read_bytes())
                target.chmod(0o755)
            (checkout_home / ".local/share/cybexos/runtime").mkdir(parents=True)
            (checkout_home / ".local/share/cybexos/runtime/quickshell").symlink_to(checkout)

            def listing(helper, home, data):
                environment = {key: value for key, value in os.environ.items()
                               if not key.startswith(("XDG_", "CYBEXOS_"))}
                environment.update(HOME=str(home), XDG_DATA_HOME=str(data), PYTHONDONTWRITEBYTECODE="1",
                                   XDG_CONFIG_HOME=str(home / ".config"))
                result = subprocess.run([str(helper), "list", "--json"], env=environment,
                                        capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                return json.loads(result.stdout)
            iso = listing(vendor / "bin/cybexos-theme", base / "iso-home", iso_data)
            source = listing(checkout_home / ".local/bin/cybexos-theme", checkout_home,
                             checkout_home / ".local/share")
            self.assertEqual(iso, source)
            self.assertEqual(iso["invalid"], [])
            self.assertEqual(iso["themes"][0]["id"], "cybexos")
            self.assertEqual(len(iso["themes"]), len(themes))
            self.assertTrue(all(theme["builtin"] for theme in iso["themes"]))

    def test_theme_command_dispatches_identically_on_both_paths(self):
        environment = jinja2.Environment(undefined=jinja2.StrictUndefined)
        environment.filters["quote"] = lambda value: "'" + str(value).replace("'", "'\\''") + "'"
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            stub = '#!/bin/sh\nprintf "%s|" "$@"\n'
            home = base / "home"
            (home / ".local/bin").mkdir(parents=True)
            (home / ".local/bin/cybexos-theme").write_text(stub)
            (home / ".local/bin/cybexos-theme").chmod(0o755)
            checkout = base / "cybex-checkout"
            checkout.write_text(environment.from_string(
                (ROOT / "roles/dotfiles/templates/cybex.j2").read_text()).render(primary_home=str(home)))
            vendor = base / "usr/share/cybexos/bin"
            vendor.mkdir(parents=True)
            (vendor / "cybexos-theme").write_text(stub)
            (vendor / "cybexos-theme").chmod(0o755)
            iso = base / "cybex-iso"
            iso.write_text((ROOT / "image/rootfs/usr/bin/cybex").read_text().replace(" /usr/", f" {base}/usr/"))
            for arguments in (["theme", "list", "--json"], ["theme", "apply", "nord"],
                              ["theme", "install", "https://github.com/a/b"],
                              ["theme", "export", "CURRENT", "/tmp/out dir", "--name", "Night shift"],
                              ["theme", "remove", "harbour"], ["theme"]):
                results = [subprocess.run(["bash", str(script), *arguments], capture_output=True,
                                          text=True, check=False) for script in (checkout, iso)]
                self.assertEqual([r.returncode for r in results], [0, 0], arguments)
                self.assertEqual(results[0].stdout, results[1].stdout, arguments)
                # printf repeats its format per argument, and runs it once for none.
                self.assertEqual(results[0].stdout, "".join(f"{a}|" for a in arguments[1:]) or "|")
            for script in (checkout, iso):
                usage = subprocess.run(["bash", str(script), "help"], capture_output=True, text=True).stdout
                self.assertRegex(usage, r"\n  theme +List, apply, install, export, or remove appearance themes\n")

    def test_contract_rejects_seed_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                split_seed(Path(temporary), {"essentialPaths": ["../../private"]})

    def test_personal_portal_is_disabled_without_private_binary(self):
        template = jinja2.Environment(undefined=jinja2.StrictUndefined)
        template.filters.update(bool=bool, ternary=lambda value, yes, no: yes if value else no)
        features = {key: True for key in ["podman", "developer_tools", "connected_widgets", "proprietary_apps", "private_hooks"]}
        text = (ROOT / "roles/desktop/templates/features.lua.j2").read_text()
        self.assertIn("private_portal = false", template.from_string(text).render(features=features, cybexos_xps_2026=False))
        self.assertIn("private_portal = true", template.from_string(text).render(
            features=features, private_services={"portal_binary": "/opt/private/portal"}, cybexos_xps_2026=False))

    def test_vpn_and_hotspot_ship_identically_with_their_runtime_on_both_paths(self):
        checkout = ROOT / "roles/desktop/files/quickshell"
        files = ["scripts/network-tool.py", "scripts/network_vpn_agent.py", "scripts/system_settings_network.py",
                 "Settings/VpnGroup.qml", "Settings/HotspotGroup.qml", "Settings/FolderDialog.qml",
                 "Settings/NetworkPage.qml", "Popovers/Drawer/DrawerNetwork.qml", "Common/NetworkDetails.qml",
                 "Common/NetworkHelpers.js", "NetworkOverlayWindow.qml"]
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_quickshell(ROOT, payload)
            installed = payload / "usr/share/cybexos/runtime/quickshell"
            for relative in files:
                self.assertEqual((installed / relative).read_bytes(), (checkout / relative).read_bytes(), relative)
        # The helpers run nmcli, qrencode and PyGObject (the VPN sign-in
        # agent); NetworkManager's shared mode needs dnsmasq for the hotspot's
        # clients. Both installation contracts name each one.
        requires = {name for line in (ROOT / "image/cybexos-desktop.spec").read_text().splitlines()
                    if line.startswith("Requires:") for name in line.split(":", 1)[1].split()}
        tasks = yaml.safe_load((ROOT / "roles/desktop/tasks/main.yml").read_text())
        packages = set()
        for task in tasks:
            names = (task.get("ansible.builtin.dnf") or {}).get("name", [])
            packages.update(names if isinstance(names, list) else [])
        for package in ("NetworkManager", "qrencode", "python3-gobject", "dnsmasq", "nm-connection-editor"):
            self.assertIn(package, requires, package)
            self.assertIn(package, packages, package)


class SeedLifecycle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.root = Path(self.temporary.name)
        self.vendor = self.root / "vendor"
        self.home = self.root / "alice"
        (self.vendor / "bin").mkdir(parents=True)
        (self.vendor / "runtime").mkdir()
        self.essential = self.vendor / "essential-seed/.config/cybexos/shell.json"
        self.essential.parent.mkdir(parents=True)
        self.essential.write_text('{"wall":"mountain.jpg"}')
        self.binary = self.vendor / "user-seed/.rustup/toolchains/default/bin/rustc"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"complete offline compiler")
        self.binary.chmod(0o755)
        (self.vendor / "seed-groups.json").write_text(json.dumps({"totalBytes": self.binary.stat().st_size}))

    def status(self):
        return json.loads((self.home / ".local/state/cybexos/seed-progress.json").read_text())

    def test_desktop_essentials_do_not_copy_toolchains(self):
        INIT.initialize(self.home, self.vendor, mode="essential")
        self.assertEqual((self.home / ".config/cybexos/shell.json").read_text(), self.essential.read_text())
        self.assertFalse((self.home / ".rustup").exists())
        self.assertEqual(self.status()["state"], "pending")
        self.assertTrue((self.home / ".local/share/cybexos/runtime").is_symlink())
        INIT.initialize(self.home, self.vendor)
        output = self.home / self.binary.relative_to(self.vendor / "user-seed")
        self.assertEqual(output.read_bytes(), self.binary.read_bytes())
        self.assertEqual(output.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.status()["state"], "ready")
        self.assertEqual(self.status()["completedBytes"], self.binary.stat().st_size)

    def test_interrupted_copy_has_no_partial_final_file_and_resumes(self):
        INIT.initialize(self.home, self.vendor, mode="essential")
        output = self.home / self.binary.relative_to(self.vendor / "user-seed")

        def interrupted(_source, target, **_kwargs):
            target.write(b"partial")
            raise InterruptedError("fixture interruption")

        with patch.object(INIT.fcntl, "ioctl", side_effect=OSError("no reflink")), \
                patch.object(INIT.shutil, "copyfileobj", side_effect=interrupted):
            with self.assertRaises(InterruptedError):
                INIT.initialize(self.home, self.vendor)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.home.rglob(".cybexos-seed-*")))
        self.assertEqual(self.status()["state"], "error")
        self.assertFalse((self.home / ".local/state/cybexos/offline-apps-seeded").exists())
        INIT.initialize(self.home, self.vendor)
        self.assertEqual(output.read_bytes(), self.binary.read_bytes())

    def test_editor_activation_follows_complete_offline_dependencies(self):
        config = self.vendor / "final-seed/.config/nvim/init.lua"
        config.parent.mkdir(parents=True)
        config.write_text("-- activate offline plugins")
        INIT.initialize(self.home, self.vendor, mode="essential")
        self.assertFalse((self.home / ".config/nvim/init.lua").exists())
        original = INIT.seed_applications

        def ordered(source, destination, progress=None):
            if source == self.vendor / "final-seed":
                self.assertEqual((self.home / self.binary.relative_to(self.vendor / "user-seed")).read_bytes(),
                                 self.binary.read_bytes())
            return original(source, destination, progress)

        with patch.object(INIT, "seed_applications", side_effect=ordered):
            INIT.initialize(self.home, self.vendor)
        self.assertEqual((self.home / ".config/nvim/init.lua").read_text(), config.read_text())

    def test_existing_personal_file_and_symlink_are_preserved(self):
        INIT.initialize(self.home, self.vendor, mode="essential")
        settings = self.home / ".config/cybexos/shell.json"
        settings.write_text('{"personal":true}')
        external = self.root / "external"
        external.mkdir()
        (external / "sentinel").write_text("keep")
        (self.home / ".rustup").symlink_to(external)
        INIT.initialize(self.home, self.vendor)
        self.assertEqual(settings.read_text(), '{"personal":true}')
        self.assertEqual(list(external.iterdir()), [external / "sentinel"])
        self.assertTrue((self.home / ".rustup").is_symlink())

    def test_installed_seeding_uses_only_real_accounts_as_their_owner(self):
        from types import SimpleNamespace
        def account(name, uid, home):
            return SimpleNamespace(pw_name=name, pw_uid=uid, pw_dir=home)
        users = [account("root", 0, "/root"), account("liveuser", 1000, "/home/liveuser"),
                 account("alice", 1001, "/home/alice"), account("service", 1002, "/var/lib/service")]
        with patch.object(ACCOUNTS.os, "geteuid", return_value=0), \
                patch.object(ACCOUNTS.pwd, "getpwall", return_value=users), \
                patch.object(ACCOUNTS.subprocess, "run") as run:
            ACCOUNTS.main()
        self.assertEqual(run.call_count, 1)
        command = run.call_args.args[0]
        self.assertEqual(command[:5], ["runuser", "--user", "alice", "--", "env"])
        self.assertIn("HOME=/home/alice", command)
        self.assertEqual(command[-1], "--all")


class BootMenu(unittest.TestCase):
    def test_menu_styling_keeps_boot_and_recovery_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            iso, install = root / "staging", root / "install"
            grub = iso / "EFI/BOOT/grub.cfg"
            grub.parent.mkdir(parents=True)
            original = """set timeout=3
search --set=root -l CYBEXOS-LIVE-44
menuentry 'Start CybexOS' --class fedora {
	linuxefi /vmlinuz root=live:LABEL=CYBEXOS-LIVE-44 quiet rhgb
	initrdefi /initrd.img
}
menuentry 'Check media' { linux /vmlinuz rd.live.check; }
menuentry 'Basic graphics' { linux /vmlinuz nomodeset; }
"""
            grub.write_text(original)
            bios = iso / "isolinux/isolinux.cfg"
            bios.parent.mkdir()
            bios.write_text("menu background splash.jpg\nmenu title Linux\nlabel linux0\n  menu label ^Start CybexOS\n"
                            "  kernel /vmlinuz\n  append initrd=/initrd.img root=live:CDLABEL=CYBEXOS-LIVE-44 quiet \n"
                            "  menu default\nmenu separator\nlabel basic0\n  menu label Start CybexOS in ^basic graphics mode.\n"
                            "  kernel /vmlinuz\n  append initrd=/initrd.img nomodeset\nlabel memtest\n  menu label Run a ^memory test.\n"
                            "  kernel memtest\n")
            art = install / "usr/share/plymouth/themes/cybex/logo.png"
            art.parent.mkdir(parents=True)
            art.write_bytes(b"logo fixture")
            brand_boot_menu(iso, install)
            branded = grub.read_text()
            self.assertTrue(branded.startswith(grub_install_entries(original)))
            # Installation-only entries come first, so the default boot installs;
            # every generated live entry, check and recovery entry remains.
            self.assertEqual(re.findall(r"menuentry '([^']+)'", branded),
                             ["Install CybexOS", "Try CybexOS live", "Check media", "Basic graphics"])
            installer, live = re.findall(r"(?m)^\tlinuxefi (.*)$", branded)
            self.assertTrue(installer.endswith(" cybexos.install"))
            self.assertEqual(installer.removesuffix(" cybexos.install"), live.rstrip())
            menu = bios.read_text()
            self.assertEqual(re.findall(r"(?m)^label (\S+)", menu), ["install-linux0", "linux0", "install-basic0", "basic0", "memtest"])
            self.assertEqual(re.findall(r"(?m)^\s*menu label (.*)", menu),
                             ["^Install CybexOS", "^Try CybexOS live", "Install CybexOS in basic graphics mode.",
                              "Try CybexOS live in ^basic graphics mode.", "Run a ^memory test."])
            self.assertEqual(menu.count("menu default"), 1)
            self.assertLess(menu.index("menu default"), menu.index("label linux0"))
            appends = re.findall(r"(?m)^\s*append (.*)", menu)
            self.assertEqual([line.endswith("cybexos.install") for line in appends], [True, False, True, False])
            self.assertIn("menu title CybexOS", bios.read_text())
            self.assertIn("root=live:CDLABEL=CYBEXOS-LIVE-44", bios.read_text())
            self.assertNotIn("menu background", bios.read_text())
            first = grub.read_text(), bios.read_text()
            brand_boot_menu(iso, install)
            self.assertEqual(first, (grub.read_text(), bios.read_text()))


class T3Callback(unittest.TestCase):
    def test_offline_launch_waits_for_seed_and_never_downloads_on_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            bindir = directory / "bin"
            bindir.mkdir()
            vendor = directory / "vendor"
            vendor.mkdir()
            launcher = directory / "t3-desktop"
            launcher.write_text((ROOT / "roles/dotfiles/templates/t3code-desktop.j2").read_text().replace(
                "/usr/share/cybexos/user-seed", str(vendor)))
            updater = directory / ".local/bin/t3code-update"
            updater.parent.mkdir(parents=True)
            updater.write_text('#!/bin/sh\ntouch "$HOME/download-attempted"\nexit 91\n')
            updater.chmod(0o755)
            systemctl = bindir / "systemctl"
            systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$HOME/service-request"\nexit 1\n')
            systemctl.chmod(0o755)
            env = {"PATH": str(bindir) + ":/usr/bin", "HOME": str(directory)}
            result = subprocess.run(["bash", str(launcher)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("not ready", result.stderr)
            self.assertFalse((directory / "download-attempted").exists())
            self.assertIn("cybexos-app-seed.service", (directory / "service-request").read_text())
            # A successful service response still cannot fall back to the
            # network when the expected offline binary is missing.
            systemctl.write_text("#!/bin/sh\nexit 0\n")
            result = subprocess.run(["bash", str(launcher)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("unavailable", result.stderr)
            self.assertFalse((directory / "download-attempted").exists())
            # Once seeding produces the app, launch it with the original URI.
            app = directory / ".local/share/t3code-nightly/T3-Code-Nightly-x86_64.AppImage"
            app.parent.mkdir(parents=True)
            app.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$HOME/app-args"\n')
            app.chmod(0o755)
            subprocess.run(["bash", str(launcher), "t3code://fixture"], env=env, check=True)
            self.assertIn("t3code://fixture", (directory / "app-args").read_text())
            self.assertFalse((directory / "download-attempted").exists())

    def test_oauth_redirect_uses_active_runtime_before_appimage(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            bindir = directory / ".local/bin"
            bindir.mkdir(parents=True)
            record = directory / "node-args"
            runtime = bindir / "cybexos-runtime"
            runtime.write_text('#!/bin/sh\nprintf "%s\\n" "$FIXTURE_RUNTIME"\n')
            node = bindir / "node"
            node.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$FIXTURE_RECORD"\n')
            for file in (runtime, node):
                file.chmod(0o755)
            env = dict(os.environ, PATH=str(bindir) + ":/usr/bin", HOME=str(directory),
                       FIXTURE_RUNTIME=str(directory / "runtime"), FIXTURE_RECORD=str(record))
            subprocess.run(["bash", str(ROOT / "roles/dotfiles/templates/t3code-desktop.j2"),
                            "t3code://app/oauth?fixture=1"], env=env, check=True)
            self.assertEqual(record.read_text().splitlines(), [str(directory / "runtime/scripts/t3-cloud.mjs"),
                             "oauth-callback", "t3code://app/oauth?fixture=1"])


if __name__ == "__main__":
    unittest.main()
