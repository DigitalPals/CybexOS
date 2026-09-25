#!/usr/bin/env python3
"""Exercise installer defaults, saved opt-outs, and both public command names."""
import fcntl
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
    def test_login_adoption_restores_original_paths_and_display_manager_link(self):
        tasks = yaml.safe_load((ROOT / "roles/desktop/tasks/main.yml").read_text())
        backup = next(task for task in tasks
                      if task.get("name") == "Preserve the display manager before first SDDM adoption")
        uninstall = yaml.safe_load((ROOT / "roles/uninstall/tasks/main.yml").read_text())
        restore = next(task for task in uninstall
                       if task.get("name") == "Restore the login manager preserved before SDDM adoption")
        with tempfile.TemporaryDirectory(prefix="cybex-login-backup.") as temporary:
            root = Path(temporary)
            originals = {
                "etc/sddm.conf": "[Theme]\nCurrent=original\n",
                "etc/pam.d/sddm-autologin": "original PAM policy\n",
                "etc/systemd/system/sddm.service.d/50-cybexos.conf": "original drop-in\n",
                "etc/cybexos/login.json": '{"original":true}\n',
            }
            for name, content in originals.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            alias = root / "etc/systemd/system/display-manager.service"
            alias.symlink_to("/usr/lib/systemd/system/gdm.service")
            unrelated = root / "etc/systemd/system/sddm.service.d/99-personal.conf"
            unrelated.write_text("personal drop-in\n")

            def run_script(task):
                script = task["ansible.builtin.shell"]
                script = script.replace("/var/lib/cybexos", str(root / "var/lib/cybexos"))
                script = script.replace("source_path=/$relative", f"source_path={shlex.quote(temporary)}/$relative")
                script = script.replace("destination=/$relative", f"destination={shlex.quote(temporary)}/$relative")
                script = script.replace("rmdir /etc/systemd", f"rmdir {shlex.quote(temporary)}/etc/systemd")
                script = script.replace("/run/cybexos-login", str(root / "run/cybexos-login"))
                subprocess.run(["bash", "-e", "-c", "restorecon() { :; }\n" + script], check=True)

            run_script(backup)
            for name in originals:
                (root / name).write_text("CybexOS replacement\n")
            alias.unlink()
            alias.symlink_to("/usr/lib/systemd/system/sddm.service")
            helper = root / "usr/libexec/cybexos-login-prepare"
            helper.parent.mkdir(parents=True)
            helper.write_text("managed helper\n")
            run_script(restore)
            for name, content in originals.items():
                self.assertEqual((root / name).read_text(), content)
            self.assertEqual(os.readlink(alias), "/usr/lib/systemd/system/gdm.service")
            self.assertEqual(unrelated.read_text(), "personal drop-in\n")
            self.assertFalse(helper.exists())
            self.assertNotIn("systemctl", restore["ansible.builtin.shell"])

    def test_display_manager_neutral_autologin_preserves_saved_choices(self):
        with tempfile.TemporaryDirectory(prefix="cybex-login-migration.") as temporary:
            config = Path(temporary) / "config.yml"
            for answers, expected in (
                ({}, False),
                ({"gdm_autologin": True}, True),
                ({"gdm_autologin": False}, False),
                ({"gdm_autologin": True, "desktop_autologin": False}, False),
                ({"desktop_autologin": True}, True),
            ):
                with self.subTest(answers=answers):
                    config.write_text(yaml.safe_dump(answers))
                    result = subprocess.check_output(
                        [str(ROOT / "scripts/migrate-config"), str(config)], text=True,
                    )
                    self.assertIs(yaml.safe_load(result)["desktop_autologin"], expected)
            for key in ("desktop_autologin", "gdm_autologin"):
                config.write_text(yaml.safe_dump({key: "true"}))
                result = subprocess.run(
                    [str(ROOT / "scripts/migrate-config"), str(config)],
                    capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{key} must be a boolean", result.stderr)

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

    def test_saved_answers_never_imply_root_equivalent_docker_access(self):
        with tempfile.TemporaryDirectory(prefix="cybex-docker-group.") as temporary:
            config = Path(temporary) / "config.yml"
            config.write_text(yaml.safe_dump({"config_schema_version": 1,
                                              "features": {"docker": True}}))
            migrated = yaml.safe_load(subprocess.check_output(
                [str(ROOT / "scripts/migrate-config"), str(config)], text=True))
            self.assertIs(migrated["docker_sudoless"], False)
            config.write_text(yaml.safe_dump({"config_schema_version": 1,
                                              "docker_sudoless": True}))
            migrated = yaml.safe_load(subprocess.check_output(
                [str(ROOT / "scripts/migrate-config"), str(config)], text=True))
            self.assertIs(migrated["docker_sudoless"], True)
            config.write_text(yaml.safe_dump({"config_schema_version": 1,
                                              "docker_sudoless": "yes"}))
            self.assertNotEqual(subprocess.run(
                [str(ROOT / "scripts/migrate-config"), str(config)],
                capture_output=True, text=True).returncode, 0)
        tasks = yaml.safe_load((ROOT / "roles/base/tasks/accounts.yml").read_text())
        groups = next(task for task in tasks
                      if task.get("name") == "Configure primary user groups and Fish login shell")
        self.assertIn("docker_sudoless", groups["ansible.builtin.user"]["groups"])
        self.assertEqual(yaml.safe_load((ROOT / "inventory/group_vars/all.yml").read_text())
                         ["docker_sudoless"], False)
        post_install = (ROOT / "image/live-rootfs/usr/share/anaconda/post-scripts/90-cybexos.ks")
        self.assertNotRegex(post_install.read_text(), r"usermod[^\n]*docker")

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
            self.assertIs(config["passwordless_wheel"], True)
            for key in ("passwordless_local_polkit",
                        "docker_sudoless", "desktop_autologin"):
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
            runtime = home / "runtime"
            runtime.mkdir()
            # MOCK_SUDO_TTY_ONLY models sudo's default tty-scoped ticket, which
            # does not reach a process that left the terminal's session.
            probes = {
                binaries / "sudo": '[ "$*" = "-n true" ] || exit 1\n'
                'if [ -n "${MOCK_SUDO_TTY_ONLY:-}" ]; then\n'
                '  set -- $(cat /proc/$$/stat); [ "$6" != "$$" ] || exit 1\n'
                'fi',
                binaries / "ansible-playbook": 'printf "%s\\n" "$@"',
                home / "scripts/migrate-config": 'cat -- "$1"',
            }
            for path, body in probes.items():
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            environment = dict(os.environ, CYBEXOS_CONFIG_FILE=str(config),
                               TMPDIR=str(scratch), XDG_RUNTIME_DIR=str(runtime),
                               PATH=f"{binaries}:{os.environ['PATH']}")
            environment.pop("MOCK_SUDO_TTY_ONLY", None)
            result = subprocess.check_output(
                ["bash", str(installer)], env=environment, text=True,
            )
            self.assertIn(f"site.yml\n-e\n@{config}\n", result)
            self.assertNotIn("--ask-become-pass", result)
            self.assertEqual(list(scratch.iterdir()), [])

            # A terminal-scoped ticket cannot reach Ansible's detached become
            # processes, so the playbook asks for the password itself.
            result = subprocess.check_output(
                ["bash", str(installer)], text=True,
                env=dict(environment, MOCK_SUDO_TTY_ONLY="1"),
            )
            self.assertIn("--ask-become-pass", result.splitlines())

            # A running durable update owns the lock; never converge beside it.
            with open(runtime / "update.lock", "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                blocked = subprocess.run(
                    ["bash", str(installer)], env=environment, text=True,
                    capture_output=True,
                )
            self.assertEqual(blocked.returncode, 75, blocked.stderr)
            self.assertIn("update is running", blocked.stderr)
            self.assertNotIn("site.yml", blocked.stdout)

    def test_uninstall_honors_update_lock_and_detached_become(self):
        with tempfile.TemporaryDirectory(prefix="cybex-uninstall.") as temporary:
            home = Path(temporary)
            binaries = home / "bin"
            binaries.mkdir()
            runtime = home / "runtime"
            runtime.mkdir()
            source = (ROOT / "uninstall").read_text().replace(
                'repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)',
                "repo_dir=" + shlex.quote(str(home)),
            )
            uninstaller = home / "uninstall"
            uninstaller.write_text(source)
            config = home / "config.yml"
            config.write_text("config_schema_version: 1\n")
            probes = {
                binaries / "sudo": 'if [ "$*" = "-n true" ] && [ -n "${MOCK_SUDO_TTY_ONLY:-}" ]; then\n'
                '  set -- $(cat /proc/$$/stat); [ "$6" != "$$" ] || exit 1\n'
                'fi\n'
                'exit 0',
                binaries / "ansible-playbook": 'printf "%s\\n" "$@"',
            }
            for path, body in probes.items():
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            (home / "uninstall.yml").write_text("---\n")
            environment = dict(os.environ, CYBEXOS_CONFIG_FILE=str(config),
                               XDG_RUNTIME_DIR=str(runtime),
                               PATH=f"{binaries}:{os.environ['PATH']}")
            environment.pop("MOCK_SUDO_TTY_ONLY", None)
            result = subprocess.check_output(
                ["bash", str(uninstaller), "--yes"], env=environment, text=True,
            )
            self.assertIn("uninstall.yml", result.splitlines())
            self.assertNotIn("--ask-become-pass", result.splitlines())
            result = subprocess.check_output(
                ["bash", str(uninstaller), "--yes"], text=True,
                env=dict(environment, MOCK_SUDO_TTY_ONLY="1"),
            )
            self.assertIn("--ask-become-pass", result.splitlines())
            with open(runtime / "update.lock", "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                blocked = subprocess.run(
                    ["bash", str(uninstaller), "--yes"], env=environment,
                    text=True, capture_output=True,
                )
            self.assertEqual(blocked.returncode, 75, blocked.stderr)
            self.assertNotIn("uninstall.yml", blocked.stdout)

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
