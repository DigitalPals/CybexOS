"""Hyprland and Quickshell stay on their qualified series on both paths.

The checkout installer, the image installer and upgrade reconciliation all run
roles/base/tasks/versionlock.yml with image/library/cybexos_versionlock.py, and
image/compose refuses to publish an image whose resolved packages fall outside
the same series. The version order is checked against RPM's own test vectors
and against what dnf5 5.4.3 was observed to do with the versionlock.toml
conditions (docs/dependency-policy.md).
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cybexos_versionlock", ROOT / "image/library/cybexos_versionlock.py")
versionlock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versionlock)
INVENTORY = yaml.safe_load((ROOT / "inventory/group_vars/all.yml").read_text())
SERIES = INVENTORY["qualified_package_series"]
ci_spec = importlib.util.spec_from_file_location(
    "ci_qualified_packages", ROOT / ".github/actions/fedora-source-environment/qualified_packages.py")
ci_packages = importlib.util.module_from_spec(ci_spec)
ci_spec.loader.exec_module(ci_packages)

# rpm's tests/rpmvercmp.at, the reference for rpmvercmp().
RPMVERCMP = [
    ("1.0", "1.0", 0), ("1.0", "2.0", -1), ("2.0", "1.0", 1), ("2.0.1", "2.0.1", 0),
    ("2.0", "2.0.1", -1), ("2.0.1", "2.0", 1), ("2.0.1a", "2.0.1a", 0), ("2.0.1a", "2.0.1", 1),
    ("2.0.1", "2.0.1a", -1), ("5.5p1", "5.5p1", 0), ("5.5p1", "5.5p2", -1), ("5.5p2", "5.5p1", 1),
    ("5.5p10", "5.5p10", 0), ("5.5p1", "5.5p10", -1), ("5.5p10", "5.5p1", 1), ("10xyz", "10.1xyz", -1),
    ("10.1xyz", "10xyz", 1), ("xyz10", "xyz10", 0), ("xyz10", "xyz10.1", -1), ("xyz10.1", "xyz10", 1),
    ("xyz.4", "xyz.4", 0), ("xyz.4", "8", -1), ("8", "xyz.4", 1), ("xyz.4", "2", -1), ("2", "xyz.4", 1),
    ("5.5p2", "5.6p1", -1), ("5.6p1", "5.5p2", 1), ("5.6p1", "6.5p1", -1), ("6.5p1", "5.6p1", 1),
    ("6.0.rc1", "6.0", 1), ("6.0", "6.0.rc1", -1), ("10b2", "10a1", 1), ("10a2", "10b2", -1),
    ("1.0aa", "1.0aa", 0), ("1.0a", "1.0aa", -1), ("1.0aa", "1.0a", 1), ("10.0001", "10.0001", 0),
    ("10.0001", "10.1", 0), ("10.1", "10.0001", 0), ("10.0001", "10.0039", -1), ("10.0039", "10.0001", 1),
    ("4.999.9", "5.0", -1), ("5.0", "4.999.9", 1), ("20101121", "20101121", 0), ("20101121", "20101122", -1),
    ("20101122", "20101121", 1), ("2_0", "2_0", 0), ("2.0", "2_0", 0), ("2_0", "2.0", 0), ("a", "a", 0),
    ("a+", "a+", 0), ("a+", "a_", 0), ("a_", "a+", 0), ("+a", "+a", 0), ("+a", "_a", 0), ("_a", "+a", 0),
    ("+_", "+_", 0), ("_+", "+_", 0), ("_+", "_+", 0), ("+", "_", 0), ("_", "+", 0),
    ("1.0~rc1", "1.0~rc1", 0), ("1.0~rc1", "1.0", -1), ("1.0", "1.0~rc1", 1), ("1.0~rc1", "1.0~rc2", -1),
    ("1.0~rc2", "1.0~rc1", 1), ("1.0~rc1~git123", "1.0~rc1~git123", 0), ("1.0~rc1~git123", "1.0~rc1", -1),
    ("1.0~rc1", "1.0~rc1~git123", 1), ("1.0^", "1.0^", 0), ("1.0^", "1.0", 1), ("1.0", "1.0^", -1),
    ("1.0^git1", "1.0^git1", 0), ("1.0^git1", "1.0", 1), ("1.0", "1.0^git1", -1), ("1.0^git1", "1.0^git2", -1),
    ("1.0^git2", "1.0^git1", 1), ("1.0^git1", "1.01", -1), ("1.01", "1.0^git1", 1),
    ("1.0^20160101", "1.0^20160101", 0), ("1.0^20160101", "1.0.1", -1), ("1.0.1", "1.0^20160101", 1),
    ("1.0^20160101^git1", "1.0^20160101^git1", 0), ("1.0^20160102", "1.0^20160101^git1", 1),
    ("1.0^20160101^git1", "1.0^20160102", -1), ("1.0~rc1^git1", "1.0~rc1^git1", 0),
    ("1.0~rc1^git1", "1.0~rc1", 1), ("1.0~rc1", "1.0~rc1^git1", -1), ("1.0^git1~pre", "1.0^git1~pre", 0),
    ("1.0^git1", "1.0^git1~pre", 1), ("1.0^git1~pre", "1.0^git1", -1),
]


def series(name):
    return next(entry for entry in SERIES if entry["name"] == name)


class VersionOrder(unittest.TestCase):
    def test_rpmvercmp_matches_rpm(self):
        for first, second, expected in RPMVERCMP:
            with self.subTest(first=first, second=second):
                self.assertEqual(versionlock.rpmvercmp(first, second), expected)

    def test_conditions_compare_like_dnf5_versionlock(self):
        # Observed with dnf5 5.4.3 and hyprland-0.56.2-2.fc44: "< 0.56.2" and
        # "= 0.56.2" excluded it, "> 0.56.2" and ">= 0.56.2" admitted it.
        built = "0:0.56.2-2.fc44"
        self.assertFalse(versionlock.satisfies(built, "<", "0.56.2"))
        self.assertFalse(versionlock.satisfies(built, "=", "0.56.2"))
        self.assertTrue(versionlock.satisfies(built, ">", "0.56.2"))
        self.assertTrue(versionlock.satisfies(built, ">=", "0.56.2"))
        self.assertTrue(versionlock.satisfies(built, "<", "0.57~"))
        self.assertEqual(versionlock.compare_evr("1:0.1-1", "0:9.9-9"), 1, "the epoch decides first")

    def test_inventory_series_admit_patches_and_hold_back_the_next_release(self):
        versionlock.validate_series(SERIES)
        self.assertEqual({entry["name"] for entry in SERIES}, {"hyprland", "quickshell"})
        hyprland, quickshell = series("hyprland"), series("quickshell")
        for evr in ("0:0.56.2-2.fc44", "0.56.2-10.fc44", "0.56.3-1.fc44", "0.56.10-1.fc44"):
            self.assertTrue(versionlock.in_series(evr, hyprland), evr)
        for evr in ("0.56.1-3.fc44", "0.57.0-1.fc44", "0.57-1.fc44", "0.57~rc1-1.fc44", "0.57.0~git1-1",
                    "1.0.0-1.fc44", "1:0.56.2-2.fc44"):
            self.assertFalse(versionlock.in_series(evr, hyprland), evr)
        # Fedora's snapshot build of the qualified Quickshell release.
        self.assertTrue(versionlock.in_series("0.2.1^git20260209.dacfa9d-5.fc44", quickshell))
        self.assertTrue(versionlock.in_series("0.2.2-1.fc44", quickshell))
        for evr in ("0.2.0-1.fc44", "0.3.0-1.fc44", "0.3.0~rc1-1.fc44", "0.3-1.fc44"):
            self.assertFalse(versionlock.in_series(evr, quickshell), evr)

    def test_invalid_series_are_refused(self):
        for bad in ([{"name": "hyprland", "minimum": "0.57", "below": "0.56"}],
                    [{"name": "hyprland", "minimum": "0.56", "below": "0.56"}],
                    [{"name": "hyprland", "minimum": "0.56"}],
                    [{"name": "a b", "minimum": "1", "below": "2"}],
                    [{"name": "x", "minimum": "1\"", "below": "2"}],
                    [{"name": "x", "minimum": 1, "below": "2"}],
                    [{"name": "x", "minimum": "1", "below": "2"}, {"name": "x", "minimum": "1", "below": "2"}],
                    {"name": "x"}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                versionlock.validate_series(bad)


class LockFile(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cybexos-versionlock-")
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / "etc/dnf/versionlock.toml"

    def test_a_fresh_system_gets_one_entry_per_series(self):
        changed, preserved = versionlock.manage(self.path, SERIES)
        self.assertTrue(changed)
        self.assertIsNone(preserved)
        document = tomllib.loads(self.path.read_text())
        self.assertEqual(document["version"], "1.0")
        self.assertEqual([package["name"] for package in document["packages"]], ["hyprland", "quickshell"])
        for package in document["packages"]:
            self.assertTrue(package["comment"].startswith(versionlock.MARKER))
            bounds = series(package["name"])
            self.assertEqual(package["conditions"], [
                {"key": "evr", "comparator": ">=", "value": bounds["minimum"]},
                {"key": "evr", "comparator": "<", "value": bounds["below"]}])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o644)
        before = self.path.read_bytes()
        self.assertEqual(versionlock.manage(self.path, SERIES), (False, None))
        self.assertEqual(self.path.read_bytes(), before, "a converged file is not rewritten")

    def test_administrator_entries_are_kept_and_old_series_replaced(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_text('''version = "1.0"

# held back after a regression
[[packages]]
name = "mesa-*"
comment = "local"
[[packages.conditions]]
key = "evr"
comparator = "!="
value = "26.1.0-1.fc44"

[[packages]]
name = "hyprland"
comment = "CybexOS qualified series (docs/dependency-policy.md)"
[[packages.conditions]]
key = "evr"
comparator = "<"
value = "0.56~"

[[packages]]
name = "hyprland"
[[packages.conditions]]
key = "evr"
comparator = "="
value = "0.57.0-1.fc44"
''')
        self.assertEqual(versionlock.manage(self.path, SERIES), (True, None))
        packages = tomllib.loads(self.path.read_text())["packages"]
        self.assertEqual(packages[0], {"name": "mesa-*", "comment": "local", "conditions": [
            {"key": "evr", "comparator": "!=", "value": "26.1.0-1.fc44"}]})
        self.assertEqual(packages[1], {"name": "hyprland", "conditions": [
            {"key": "evr", "comparator": "=", "value": "0.57.0-1.fc44"}]},
            "an administrator's own hyprland entry admits their version alongside ours")
        managed = [package for package in packages if package.get("comment", "").startswith(versionlock.MARKER)]
        self.assertEqual(managed, versionlock.desired_entries(SERIES))
        self.assertEqual(versionlock.manage(self.path, SERIES), (False, None))

        # Uninstall removes ours and nothing else.
        self.assertEqual(versionlock.manage(self.path, []), (True, None))
        remaining = tomllib.loads(self.path.read_text())["packages"]
        self.assertEqual([package["name"] for package in remaining], ["mesa-*", "hyprland"])

    def test_unreadable_files_are_left_alone(self):
        self.path.parent.mkdir(parents=True)
        for text in ('version = "1.0"\n[[packages]\n', 'version = "2.0"\n', 'version = 1.0\n',
                     'version = "1.0"\npackages = "all"\n',
                     'version = "1.0"\n[[packages]]\nname = "x"\nwhen = 2026-01-01\n',
                     'version = "1.0"\n[[packages]]\nname = "x"\nextra = { a = 1 }\n'):
            with self.subTest(text=text):
                self.path.write_text(text)
                changed, preserved = versionlock.manage(self.path, SERIES)
                self.assertFalse(changed)
                self.assertTrue(preserved)
                self.assertEqual(self.path.read_text(), text)
        self.path.unlink()
        target = self.path.with_name("elsewhere.toml")
        target.write_text('version = "1.0"\n')
        self.path.symlink_to(target)
        self.assertEqual(versionlock.manage(self.path, SERIES)[0], False)
        self.assertEqual(target.read_text(), 'version = "1.0"\n')

    def test_check_mode_and_uninstall_without_a_file_write_nothing(self):
        self.assertEqual(versionlock.manage(self.path, SERIES, check=True), (True, None))
        self.assertFalse(self.path.exists())
        self.assertEqual(versionlock.manage(self.path, []), (False, None))
        self.assertFalse(self.path.exists())

    def test_strings_survive_a_rewrite(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_text('version = "1.0"\n[[packages]]\nname = "x"\ncomment = "quote \\" tab \\t ü"\n')
        versionlock.manage(self.path, SERIES)
        self.assertEqual(tomllib.loads(self.path.read_text())["packages"][0]["comment"], 'quote " tab \t ü')

    def test_installed_packages_outside_the_series_are_reported(self):
        installed = {"hyprland": "0:0.57.0-1.fc44", "quickshell": "0:0.2.1^git20260209.dacfa9d-5.fc44"}
        problems = versionlock.outside_series(SERIES, installed.get)
        self.assertEqual(len(problems), 1)
        self.assertIn("hyprland 0:0.57.0-1.fc44 is outside its qualified series", problems[0])
        self.assertEqual(versionlock.outside_series(SERIES, {}.get), [], "nothing installed yet")
        self.assertEqual(versionlock.outside_series(SERIES, {}.get, require=True),
                         ["hyprland is not installed", "quickshell is not installed"])

    @unittest.skipUnless(shutil.which("ansible"), "ansible-core is not installed")
    def test_the_ansible_module_converges_and_reports(self):
        arguments = json.dumps({"series": SERIES, "path": str(self.path), "report_installed": False})
        command = ["ansible", "localhost", "-i", "localhost,", "-c", "local", "-M", str(ROOT / "image/library"),
                   "-m", "cybexos_versionlock", "-a", arguments, "--one-line"]
        config = self.path.parents[2] / "ansible.cfg"
        config.write_text("[defaults]\n")
        environment = {**os.environ, "ANSIBLE_LOCALHOST_WARNING": "false", "ANSIBLE_STDOUT_CALLBACK": "default",
                       "ANSIBLE_CONFIG": str(config), "ANSIBLE_BECOME": "false",
                       "ANSIBLE_LOCAL_TEMP": str(self.path.parents[2] / "ansible-local"),
                       "ANSIBLE_REMOTE_TEMP": str(self.path.parents[2] / "ansible-remote")}
        first = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=120)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn("CHANGED", first.stdout)
        self.assertEqual(len(tomllib.loads(self.path.read_text())["packages"]), len(SERIES))
        second = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=120)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("SUCCESS", second.stdout)


class SourceCi(unittest.TestCase):
    def test_ci_reuses_the_product_lock_and_preserves_administrator_entries(self):
        with tempfile.TemporaryDirectory(prefix="cybexos-ci-series-") as temporary:
            path = Path(temporary) / "versionlock.toml"
            path.write_text('version = "1.0"\n[[packages]]\nname = "fixture"\n'
                            '[[packages.conditions]]\nkey = "evr"\ncomparator = "="\nvalue = "1"\n')
            ci_packages.prepare(SERIES, path)
            packages = tomllib.loads(path.read_text())["packages"]
            self.assertEqual(packages[0]["name"], "fixture")
            self.assertEqual(packages[1:], versionlock.desired_entries(SERIES))
            before = path.read_bytes()
            ci_packages.prepare(SERIES, path)
            self.assertEqual(path.read_bytes(), before)

    def test_ci_fails_when_a_lock_cannot_be_enforced(self):
        with tempfile.TemporaryDirectory(prefix="cybexos-ci-series-") as temporary:
            path = Path(temporary) / "versionlock.toml"
            path.write_text('version = "unrecognized"\n')
            with self.assertRaisesRegex(ValueError, "Cannot enforce"):
                ci_packages.prepare(SERIES, path)
            self.assertEqual(path.read_text(), 'version = "unrecognized"\n')

    def test_ci_rejects_missing_or_unqualified_runtimes(self):
        for version in (None, "0.2.0-1.fc44", "0.3.0-1.fc44", "1:0.2.1-1.fc44"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                ci_packages.verify(SERIES, ["quickshell"], lambda _name: version)
        self.assertEqual(ci_packages.verify(SERIES, ["quickshell"], lambda _name: "0.2.2-1.fc44"),
                         {"quickshell": "0.2.2-1.fc44"})
        with self.assertRaisesRegex(ValueError, "No qualified series"):
            ci_packages.verify(SERIES, ["unregistered"], lambda _name: "1")

    def test_shared_ci_action_enforces_and_checks_its_runtime(self):
        action = yaml.safe_load((ROOT / ".github/actions/fedora-source-environment/action.yml").read_text())
        step = next(step for step in action["runs"]["steps"] if step.get("id") == "copr")
        command = ".github/actions/fedora-source-environment/qualified_packages.py"
        self.assertLess(step["run"].index(command + " prepare"), step["run"].index("dnf install -y quickshell"))
        self.assertGreater(step["run"].index(command + " verify quickshell"),
                           step["run"].index("dnf install -y quickshell"))


class BothPaths(unittest.TestCase):
    @staticmethod
    def flatten(name):
        for task in yaml.safe_load((ROOT / "roles/base/tasks" / name).read_text()):
            if "ansible.builtin.import_tasks" in task:
                yield from BothPaths.flatten(task["ansible.builtin.import_tasks"])
            else:
                yield task

    def test_checkout_image_and_reconcile_apply_the_same_lock_before_packages(self):
        lock = list(self.flatten("versionlock.yml"))
        self.assertEqual(len(lock), 1)
        self.assertEqual(lock[0]["cybexos_versionlock"], {"series": "{{ qualified_package_series }}"})
        for entry in ("main.yml", "image.yml", "reconcile.yml"):
            with self.subTest(entry=entry):
                tasks = list(self.flatten(entry))
                self.assertIn(lock[0], tasks)
        for entry, first_package_task in (("main.yml", "Install Fedora baseline packages"),
                                          ("image.yml", "Install Fedora baseline packages")):
            names = [task.get("name") for task in self.flatten(entry)]
            self.assertLess(names.index(lock[0]["name"]), names.index(first_package_task),
                            f"{entry} must lock before installing packages")
        imports = yaml.safe_load((ROOT / "roles/base/tasks/main.yml").read_text())
        [entry] = [task for task in imports if task.get("ansible.builtin.import_tasks") == "versionlock.yml"]
        self.assertIn("quickshell", entry["tags"], "a shell-only deployment installs the locked packages too")
        # The base role runs before the desktop role installs Hyprland.
        site = (ROOT / "site.yml").read_text()
        self.assertLess(site.index("role: base"), site.index("role: desktop"))
        # Image provisioning reads the same inventory and finds the module
        # beside its playbook, as the checkout does through ansible.cfg.
        provision = yaml.safe_load((ROOT / "image/provision.yml").read_text())[0]
        self.assertIn("../inventory/group_vars/all.yml", provision["vars_files"])
        self.assertTrue((ROOT / "image/provision.yml").parent.joinpath("library/cybexos_versionlock.py").is_file())
        self.assertIn("library = image/library", (ROOT / "ansible.cfg").read_text())

    def test_the_iso_provision_payload_carries_the_same_lock_sources(self):
        from provision_payload import prepare_provision
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_provision(ROOT, payload)
            provision = payload / "usr/share/cybexos/provision"
            for relative in ("roles/base/tasks/versionlock.yml", "roles/base/tasks/main.yml",
                             "roles/base/tasks/image.yml", "roles/base/tasks/reconcile.yml",
                             "image/library/cybexos_versionlock.py", "inventory/group_vars/all.yml"):
                self.assertEqual((provision / relative).read_bytes(), (ROOT / relative).read_bytes(), relative)

    def test_the_image_build_refuses_packages_outside_the_series(self):
        compose = (ROOT / "image/compose").read_text()
        self.assertIn('source / "library/cybexos_versionlock.py"', compose)
        self.assertIn('["qualified_package_series"]', compose)
        self.assertIn("versionlock.outside_series(\n        qualified_series, lambda name: "
                      "versionlock.installed_evr(name, creator._instroot), require=True)", compose)
        self.assertLess(compose.index("versionlock.outside_series("), compose.index("creator.package()"))

    def test_uninstall_removes_only_the_managed_entries(self):
        tasks = {task["name"]: task for task in yaml.safe_load((ROOT / "roles/uninstall/tasks/main.yml").read_text())}
        task = tasks["Remove only the CybexOS qualified-series versionlock entries"]
        self.assertEqual(task["cybexos_versionlock"], {"series": [], "report_installed": False})

    def test_the_updater_tolerates_a_held_back_release(self):
        updater = (ROOT / "assets/scripts/cybexos-update-run").read_text()
        self.assertIn("dnf -y upgrade --refresh --no-best --downloadonly", updater)
        self.assertIn("dnf -y upgrade --refresh --no-best &", updater)
        self.assertNotIn("--best ", updater.replace("--no-best", ""))


if __name__ == "__main__":
    unittest.main()
