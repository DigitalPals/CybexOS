"""No image builds: isolated fixtures for desktop parity and boot appearance."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import jinja2
import yaml

from boot_branding import brand_boot_menu
from desktop_payload import prepare_defaults, split_seed

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
menuentry 'Start CybexOS' { linux /vmlinuz root=live:LABEL=CYBEXOS-LIVE-44 quiet rhgb; initrd /initrd.img; }
menuentry 'Check media' { linux /vmlinuz rd.live.check; }
menuentry 'Basic graphics' { linux /vmlinuz nomodeset; }
"""
            grub.write_text(original)
            bios = iso / "isolinux/isolinux.cfg"
            bios.parent.mkdir()
            bios.write_text("menu background splash.jpg\nmenu title Linux\nlabel linux\n  kernel /vmlinuz\n  append initrd=/initrd.img root=live:CDLABEL=CYBEXOS-LIVE-44\n")
            art = install / "usr/share/plymouth/themes/cybex/logo.png"
            art.parent.mkdir(parents=True)
            art.write_bytes(b"logo fixture")
            brand_boot_menu(iso, install)
            self.assertTrue(grub.read_text().startswith(original))
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
            bindir = directory / "bin"
            bindir.mkdir()
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
