#!/usr/bin/env python3
"""Exercise installer defaults, saved opt-outs, and both public command names."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[1]
APPLICATIONS = {
    "developer_tools", "connected_widgets", "proprietary_apps", "tailscale",
    "docker", "podman", "steam", "source_builds",
}


class ApplicationDefaults(unittest.TestCase):
    def test_fresh_configuration_and_saved_opt_outs(self):
        defaults = yaml.safe_load((ROOT / "inventory/group_vars/all.yml").read_text())
        for key in APPLICATIONS:
            self.assertIs(defaults["features"][key], True, key)
        with tempfile.TemporaryDirectory(prefix="cybex-defaults.") as temporary:
            config = Path(temporary) / "config.yml"
            for schema in (0, 1):
                config.write_text(yaml.safe_dump({
                    "config_schema_version": schema,
                    "features": {"steam": False, "source_builds": False},
                }))
                result = subprocess.check_output(
                    [str(ROOT / "scripts/migrate-config"), str(config)], text=True,
                )
                migrated = yaml.safe_load(result)
                for key in APPLICATIONS - {"steam", "source_builds"}:
                    self.assertIs(migrated["features"][key], True, key)
                self.assertIs(migrated["features"]["steam"], False)
                self.assertIs(migrated["features"]["source_builds"], False)
                for key in ("private_hooks", "apple_display", "local_network_services"):
                    self.assertIs(migrated["features"][key], False)
                config.write_text(result)
                self.assertEqual(subprocess.check_output(
                    [str(ROOT / "scripts/migrate-config"), str(config)], text=True,
                ), result)

    def test_noninteractive_installer_selects_every_application(self):
        with tempfile.TemporaryDirectory(prefix="cybex-installer.") as temporary:
            home = Path(temporary)
            binaries = home / "bin"
            binaries.mkdir()
            # Replace only the platform/account probes; run the real installer
            # through --check, so it cannot write configuration or install RPMs.
            source = (ROOT / "install").read_text().replace(
                'repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)',
                "repo_dir=" + shlex.quote(str(ROOT)),
            ).replace('[[ -r /etc/fedora-release ]]', 'true')
            installer = home / "install"
            installer.write_text(source)
            probes = {
                "getent": f"printf '%s\\n' 'cybex-test:x:1000:1000::{home}:/bin/bash'",
                "id": "printf '%s\\n' cybex-test",
                "hostnamectl": "printf '%s\\n' cybex-test",
                "timedatectl": "printf '%s\\n' UTC",
                "localectl": "exit 0",
                "sudo": "echo 'sudo must not run during --check' >&2; exit 97",
            }
            for name, body in probes.items():
                path = binaries / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            environment = dict(os.environ, HOME=str(home), SUDO_USER="cybex-test",
                               CYBEXOS_CONFIG_FILE=str(home / "absent.yml"),
                               PATH=f"{binaries}:{os.environ['PATH']}")
            result = subprocess.check_output(
                ["bash", str(installer), "--non-interactive", "--check"],
                env=environment, text=True,
            )
            config = yaml.safe_load(result)
            for key in APPLICATIONS:
                self.assertIs(config["features"][key], True, key)
            self.assertFalse((home / "absent.yml").exists())
            for key in ("passwordless_wheel", "passwordless_local_polkit", "gdm_autologin"):
                self.assertIs(config[key], False)
            # hostnamectl succeeds with empty output when no static hostname
            # is configured; use the transient hostname in that case.
            (binaries / "hostnamectl").write_text("#!/bin/sh\nexit 0\n")
            hostname = binaries / "hostname"
            hostname.write_text("#!/bin/sh\nprintf '%s\\n' transient-host\n")
            hostname.chmod(0o755)
            result = subprocess.check_output(
                ["bash", str(installer), "--non-interactive", "--check"],
                env=environment, text=True,
            )
            self.assertEqual(yaml.safe_load(result)["machine_hostname"], "transient-host")

    def test_saved_install_accepts_passwordless_sudo_and_cleans_temporary_config(self):
        with tempfile.TemporaryDirectory(prefix="cybex-saved-install.") as temporary:
            home = Path(temporary)
            binaries = home / "bin"
            binaries.mkdir()
            scratch = home / "tmp"
            scratch.mkdir()
            (home / "scripts").mkdir()
            (home / "scripts/ui.sh").write_text("ui_header() { :; }\n")
            source = (ROOT / "install").read_text().replace(
                '[[ -r /etc/fedora-release ]]', 'true',
            )
            installer = home / "install"
            installer.write_text(source)
            config = home / "config.yml"
            config.write_text("config_schema_version: 1\n")
            probes = {
                binaries / "sudo": '[ "$*" = "-n true" ]',
                binaries / "ansible-playbook": 'printf "%s\\n" "$@"',
                home / "scripts/migrate-config": 'cat -- "$1"',
            }
            for path, body in probes.items():
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            environment = dict(os.environ, CYBEXOS_CONFIG_FILE=str(config),
                               TMPDIR=str(scratch), PATH=f"{binaries}:{os.environ['PATH']}")
            result = subprocess.check_output(
                ["bash", str(installer)], env=environment, text=True,
            )
            self.assertIn(f"site.yml\n-e\n@{config}\n", result)
            self.assertEqual(list(scratch.iterdir()), [])

    def test_both_command_names_preserve_arguments_and_verification_scope(self):
        with tempfile.TemporaryDirectory(prefix="cybex-command.") as temporary:
            home = Path(temporary)
            release = home / ".local/share/cybexos/current"
            release.mkdir(parents=True)
            (release / "VERSION").write_text("1.2.3\n")
            verifier = release / "verify"
            verifier.write_text("#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
            verifier.chmod(0o755)
            environment = jinja2.Environment(undefined=jinja2.StrictUndefined)
            environment.filters["quote"] = shlex.quote
            source = environment.from_string(
                (ROOT / "roles/dotfiles/templates/cybex.j2").read_text(),
            ).render(primary_home=str(home))
            for name in ("cybex",):
                command = home / name
                command.write_text(source)
                command.chmod(0o755)
                def run(*args):
                    return subprocess.check_output([str(command), *args], text=True)
                self.assertIn("Usage: cybex", run("--help"))
                self.assertEqual(run("version"), "1.2.3\n")
                self.assertEqual(json.loads(run("verify", "--json")), ["--system", "--json"])
                self.assertEqual(json.loads(run("doctor", "--source")), ["--source"])


if __name__ == "__main__":
    unittest.main()
