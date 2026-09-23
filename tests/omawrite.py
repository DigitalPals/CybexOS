#!/usr/bin/env python3
"""Exercise editor associations and transactional installation without root."""
import configparser
import hashlib
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tarfile
import tempfile
import unittest

import jinja2

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / "tests/installer-convergence.py"))


class Omawrite(unittest.TestCase):
    def test_install_repair_offline_convergence_and_failure_preservation(self):
        with tempfile.TemporaryDirectory(prefix="cybex-omawrite-install.") as temporary:
            root = Path(temporary)
            common = root / "common.sh"
            shutil.copyfile(ROOT / "roles/apps/files/cybexos-common.sh", common)
            installer = root / "install"
            HELPERS["render_installer"](ROOT / "roles/apps/files/omawrite-install", installer, root, common)
            source = root / "source"
            for name in ("omawrite.pro", "pkgbuild/omawrite.svg", "LICENSE", "fonts/OFL.txt"):
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n")
            archive = root / "source.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                output.add(source, arcname="omawrite-fixture")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            mock = root / "mock"
            executable = HELPERS["executable"]
            executable(mock / "curl", '''
[[ ${OFFLINE:-0} == 0 ]] || exit 99
cp "$ARCHIVE" "${@: -1}"
''')
            executable(mock / "qmake6", '[[ $1 != -query ]] || echo 6.11.2\n')
            executable(mock / "make", '''
[[ ${FAIL_BUILD:-0} == 0 ]] || exit 98
printf '#!/bin/sh\necho omawrite\n' > omawrite
chmod 0755 omawrite
''')
            env = dict(os.environ, PATH=f"{mock}:{os.environ['PATH']}", ARCHIVE=str(archive))
            command = [str(installer), "v0.5.0", "a" * 40, "sha256:" + digest]

            def run(args=command, **overrides):
                return subprocess.run(args, env=dict(env, **overrides), capture_output=True, text=True)

            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CHANGED:", result.stdout)
            current = root / "apps/omawrite/current"
            original = current.resolve()
            self.assertEqual(original.stat().st_mode & 0o777, 0o755)
            self.assertTrue((current / "share/licenses/OFL.txt").is_file())
            result = run(OFFLINE="1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("UNCHANGED:", result.stdout)

            # Neither untrusted source nor a failed compiler can replace a
            # working installation, and both clean their temporary staging.
            for args, overrides in (
                (command[:-1] + ["sha256:" + "0" * 64], {}),
                ([str(installer), "v0.6.0", "b" * 40, "sha256:" + digest], {"FAIL_BUILD": "1"}),
            ):
                result = run(args, **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(current.resolve(), original)
                self.assertFalse(list(current.parent.glob(".build.*")))
                self.assertEqual(list((current.parent / "versions").iterdir()), [original])

            (root / "bin/omawrite").unlink()
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((root / "bin/omawrite").is_file())
            self.assertFalse(list(current.parent.glob(".build.*")))

    def test_desktop_resolves_text_nfo_and_markdown_with_developer_tools_on_or_off(self):
        environment = jinja2.Environment(undefined=jinja2.StrictUndefined)
        environment.filters.update(bool=bool, ternary=lambda value, yes, no: yes if value else no)
        template = environment.from_string((ROOT / "roles/dotfiles/templates/mimeapps.list.j2").read_text())
        desktop = ROOT / "roles/apps/files/omawrite.desktop"
        subprocess.run(["desktop-file-validate", str(desktop)], check=True)
        with tempfile.TemporaryDirectory(prefix="cybex-omawrite-mime.") as temporary:
            root = Path(temporary)
            config = root / "config"
            data = root / "data"
            config.mkdir()
            (data / "applications").mkdir(parents=True)
            shutil.copyfile(desktop, data / "applications/omawrite.desktop")
            env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(config),
                       XDG_CONFIG_DIRS=str(root / "no-config"), XDG_DATA_HOME=str(data),
                       XDG_DATA_DIRS="/usr/share", XDG_CURRENT_DESKTOP="CybexOS")
            subprocess.run(["update-desktop-database", str(data / "applications")], check=True, env=env)
            for developer_tools in (True, False):
                rendered = template.render(features={"developer_tools": developer_tools,
                                                    "proprietary_apps": False, "connected_widgets": False})
                (config / "mimeapps.list").write_text(rendered)
                defaults = configparser.ConfigParser()
                defaults.read_string(rendered)
                self.assertEqual(defaults["Default Applications"]["text/x-markdown"], "omawrite.desktop")
                self.assertEqual(defaults["Default Applications"]["application/json"],
                                 "nvim-kitty.desktop" if developer_tools else "org.gnome.TextEditor.desktop")
                for suffix, mime in (("txt", "text/plain"), ("nfo", "text/x-nfo"), ("md", "text/markdown")):
                    document = root / f"file with spaces.{suffix}"
                    document.write_text("Hello world\n")
                    # GIO uses the shared MIME filename rules, as Nautilus
                    # does. Generic xdg-mime may use file(1) content sniffing
                    # and report text/plain for all three instead.
                    info = subprocess.check_output(["gio", "info", "-a", "standard::content-type", str(document)], env=env, text=True)
                    actual = info.split("standard::content-type: ", 1)[1].strip()
                    self.assertEqual(actual, mime)
                    selected = subprocess.check_output(["xdg-mime", "query", "default", actual], env=env, text=True).strip()
                    self.assertEqual(selected, "omawrite.desktop")


if __name__ == "__main__":
    unittest.main()
