#!/usr/bin/env python3
"""Fixture tests for Btrfs recovery points, their boot menu and restore.

The helper runs against a plain directory tree: mock `btrfs`, `findmnt`,
`grubby`, `lsinitrd` and `grub2-editenv` stand in for the system, while real
`tar` and `mv --exchange` exercise archives and the atomic root exchange.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "roles/base/files/cybexos-system-snapshot"
RECOVERY = ROOT / "roles/base/files/recovery"
BOOT_UUID = "1a2b3c4d-0000-4000-8000-00000000b007"
ROOT_UUID = "5e6f7a8b-0000-4000-8000-0000000000f5"
MACHINE = "0123456789abcdef0123456789abcdef"

MOCKS = {
    "btrfs": r'''
import os, shutil, sys, uuid
from pathlib import Path
args = sys.argv[1:]
def marker(path):
    return Path(path) / ".subvolume"
if args[:2] == ["subvolume", "show"]:
    path = Path(args[2])
    if not marker(path).is_file():
        sys.exit(1)
    print(f"{path.name}\n\tName: \t{path.name}\n\tUUID: \t{marker(path).read_text().strip()}")
elif args[:2] == ["subvolume", "create"]:
    Path(args[2]).mkdir(parents=True)
    marker(args[2]).write_text(str(uuid.uuid4()))
elif args[:2] == ["subvolume", "snapshot"]:
    source, target = Path(args[-2]), Path(args[-1])
    if os.environ.get("MOCK_SNAPSHOT_FAIL") == str(target.name):
        sys.exit(1)
    shutil.copytree(source, target, symlinks=True)
    # Btrfs leaves an empty directory where a nested subvolume was.
    for nested in sorted(target.rglob(".subvolume"), reverse=True):
        if nested.parent != target:
            shutil.rmtree(nested.parent)
            nested.parent.mkdir()
    marker(target).write_text(str(uuid.uuid4()))
    (target / ".readonly").unlink(missing_ok=True)
    if "-r" in args:
        (target / ".readonly").write_text("")
elif args[:2] == ["subvolume", "delete"]:
    shutil.rmtree(args[-1])
elif args[:3] == ["subvolume", "list", "-o"]:
    base = Path(args[3])
    top = Path(os.environ["CYBEXOS_SNAPSHOT_TOPLEVEL"])
    for nested in sorted(base.rglob(".subvolume")):
        if nested.parent != base:
            print(f"ID 300 gen 1 top level 256 path {nested.parent.relative_to(top)}")
else:
    sys.exit(2)
''',
    "findmnt": r'''
import json, os, sys
args = sys.argv[1:]
table = json.loads(open(os.environ["MOCK_FINDMNT"]).read())
key = f"{args[args.index('--output') + 1]} {args[args.index('--target') + 1]}"
if key not in table:
    sys.exit(1)
print(table[key])
''',
    "grubby": r'''
import os, sys
if sys.argv[1:] == ["--default-kernel"]:
    print("/boot/vmlinuz-" + os.environ["MOCK_DEFAULT_KERNEL"])
''',
    "uname": r'''
import os
print(os.environ["MOCK_DEFAULT_KERNEL"])
''',
    "lsinitrd": r'''
import sys
data = open(sys.argv[1], errors="replace").read()
print("usr/lib/dracut/hooks/pre-pivot/10-cybexos-recovery-overlay.sh" if "recovery-module" in data else "usr/bin/init")
''',
    "grub2-editenv": r'''
import sys
from pathlib import Path
path, action, *rest = sys.argv[1:]
env = Path(path)
values = dict(line.split("=", 1) for line in env.read_text().splitlines() if "=" in line) if env.exists() else {}
if action == "list":
    print("\n".join(f"{key}={value}" for key, value in values.items()))
elif action == "set":
    for item in rest:
        key, value = item.split("=", 1)
        values[key] = value
elif action == "unset":
    for key in rest:
        values.pop(key, None)
env.write_text("".join(f"{key}={value}\n" for key, value in values.items()))
''',
    "restorecon": "",
    "mount": r'''
import os, sys
with open(os.environ["MOCK_MOUNT_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
''',
}


class Fixture:
    def __init__(self, base: Path) -> None:
        self.base = base
        self.bin = base / "bin"
        self.top = base / "top"
        self.boot = base / "sys/boot"
        self.runtime = base / "run"
        self.cmdline = base / "cmdline"
        self.lower = base / "lower"
        self.findmnt = base / "findmnt.json"
        self.bin.mkdir()
        for name, body in MOCKS.items():
            path = self.bin / name
            path.write_text("#!/usr/bin/python3\n" + body)
            path.chmod(0o755)
        for sub in ("root", "home"):
            self.subvolume(self.top / sub)
        self.cmdline.write_text(f"BOOT_IMAGE=/vmlinuz-6.20.1 root=UUID={ROOT_UUID} ro rootflags=subvol=root rhgb quiet\n")
        self.mounts(root_fstype="btrfs", root="/root")
        self.default_kernel = "6.20.1"

    @staticmethod
    def subvolume(path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)
        (path / ".subvolume").write_text(os.urandom(8).hex())

    def mounts(self, root_fstype: str, root: str, boot_fstype: str = "ext4") -> None:
        table = {
            "FSTYPE /": root_fstype, "FSROOT /": root, "FSROOT /home": "/home",
            "UUID /": ROOT_UUID, f"UUID {self.boot}": BOOT_UUID, f"FSTYPE {self.boot}": boot_fstype,
        }
        if root_fstype == "overlay":
            table.update({f"FSTYPE {self.lower}": "btrfs", f"UUID {self.lower}": ROOT_UUID})
        self.findmnt.write_text(json.dumps(table))

    def recovery_mount(self, point: str) -> None:
        self.mounts("overlay", "/")
        table = json.loads(self.findmnt.read_text())
        table[f"FSROOT {self.lower}"] = f"/cybexos-snapshots/root/{point}"
        table[f"OPTIONS {self.boot}"] = "ro,relatime,seclabel"
        self.findmnt.write_text(json.dumps(table))
        self.cmdline.write_text(f"root=UUID={ROOT_UUID} ro rootflags=subvol=cybexos-snapshots/root/{point} "
                                f"cybexos.recovery={point}\n")

    def kernel(self, version: str, *, root: bool = True, boot: bool = True, module: bool = True,
               options: str | None = None) -> None:
        if root:
            modules = self.top / "root/usr/lib/modules" / version
            modules.mkdir(parents=True, exist_ok=True)
            (modules / "vmlinuz").write_text(f"kernel {version}\n")
        if boot:
            self.boot.mkdir(parents=True, exist_ok=True)
            (self.boot / f"vmlinuz-{version}").write_text(f"kernel {version}\n")
            (self.boot / f"initramfs-{version}.img").write_text(
                "initramfs recovery-module\n" if module else "initramfs\n")
            (self.boot / f"System.map-{version}").write_text("map\n")
            entries = self.boot / "loader/entries"
            entries.mkdir(parents=True, exist_ok=True)
            (entries / f"{MACHINE}-{version}.conf").write_text(textwrap.dedent(f"""\
                title Fedora Linux ({version}) 44
                version {version}
                linux /vmlinuz-{version}
                initrd $tuned_initrd /initramfs-{version}.img
                options {options or f'root=UUID={ROOT_UUID} ro rootflags=subvol=root,compress=zstd:1 rd.luks.uuid=luks-{ROOT_UUID} rhgb quiet $tuned_params'}
                grub_users $grub_users
                """))
            (self.boot / "grub2").mkdir(exist_ok=True)

    def drop_kernel(self, version: str) -> None:
        shutil.rmtree(self.top / "root/usr/lib/modules" / version, ignore_errors=True)
        for name in (f"vmlinuz-{version}", f"initramfs-{version}.img", f"System.map-{version}",
                     f"loader/entries/{MACHINE}-{version}.conf"):
            (self.boot / name).unlink(missing_ok=True)

    def env(self, **extra: str) -> dict[str, str]:
        env = dict(os.environ)
        env.update({
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "CYBEXOS_SYSTEM_SNAPSHOT_TESTING": "1",
            "CYBEXOS_SNAPSHOT_TOPLEVEL": str(self.top),
            "CYBEXOS_SNAPSHOT_BOOT": str(self.boot),
            "CYBEXOS_SNAPSHOT_SYSROOT": str(self.top / "root"),
            "CYBEXOS_SNAPSHOT_CMDLINE": str(self.cmdline),
            "CYBEXOS_SNAPSHOT_RUNTIME": str(self.runtime),
            "CYBEXOS_SNAPSHOT_RECOVERY_LOWER": str(self.lower),
            "MOCK_FINDMNT": str(self.findmnt),
            "MOCK_DEFAULT_KERNEL": self.default_kernel,
            "MOCK_MOUNT_LOG": str(self.base / "mount.log"),
        })
        env.pop("CYBEXOS_SNAPSHOT_ID", None)
        env.update(extra)
        return env

    def run(self, *args: str, check: bool = True, **extra: str) -> subprocess.CompletedProcess:
        result = subprocess.run([str(HELPER), *args], env=self.env(**extra), text=True,
                                capture_output=True, timeout=60)
        if check and result.returncode != 0:
            raise AssertionError(f"{args} failed ({result.returncode}): {result.stderr}")
        return result

    def create(self, point: str, description: str = "update", **extra: str) -> str:
        return self.run("create", description, CYBEXOS_SNAPSHOT_ID=point, **extra).stdout

    @property
    def store(self) -> Path:
        return self.top / "cybexos-snapshots"

    def menu(self) -> str:
        return (self.boot / "grub2/cybexos-recovery.cfg").read_text()

    def index(self) -> dict:
        return json.loads((self.runtime / "recovery-points.json").read_text())

    def grubenv(self) -> str:
        path = self.boot / "grub2/grubenv"
        return path.read_text() if path.exists() else ""


class RecoveryPointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cybexos-snapshot-test.")
        self.fx = Fixture(Path(self.temporary.name))
        self.fx.kernel("6.20.1")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_create_prints_only_the_id_and_retains_five_pairs(self) -> None:
        for index in range(1, 8):
            point = f"2026090{index}T120000Z-{index}"
            self.assertEqual(self.fx.create(point, f"fixture {index}"), point + "\n")
        roots = sorted(path.name for path in (self.fx.store / "root").iterdir())
        self.assertEqual(roots, [f"2026090{index}T120000Z-{index}" for index in range(3, 8)])
        self.assertEqual(len(list((self.fx.store / "boot").glob("*.tar"))), 5)
        self.assertEqual((self.fx.store / "latest").read_text().strip(), "20260907T120000Z-7")
        self.assertEqual((self.fx.store / "metadata/20260907T120000Z-7.meta").read_text(), "fixture 7\n")
        self.assertEqual((self.fx.store / "metadata/20260907T120000Z-7.kernel").read_text(), "6.20.1\n")
        self.assertFalse((self.fx.store / "metadata/20260901T120000Z-1.kernel").exists())
        self.assertTrue((self.fx.store / "root/20260903T120000Z-3/.readonly").exists())
        members = subprocess.run(["tar", "--list", "--file", str(self.fx.store / "boot/20260907T120000Z-7.tar")],
                                 capture_output=True, text=True, check=True).stdout.split()
        self.assertIn("boot/vmlinuz-6.20.1", members)
        listing = self.fx.run("list").stdout.splitlines()
        self.assertEqual(listing[0], "20260903T120000Z-3\tfixture 3")
        self.assertEqual(len(listing), 5)

    def test_failed_snapshot_leaves_no_partial_point(self) -> None:
        result = self.fx.run("create", "x", check=False, CYBEXOS_SNAPSHOT_ID="20260901T120000Z-1",
                             MOCK_SNAPSHOT_FAIL="20260901T120000Z-1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(list((self.fx.store / "boot").iterdir()), [])
        self.assertEqual(list((self.fx.store / "metadata").iterdir()), [])

    def test_menu_entry_boots_the_snapshot_with_the_default_arguments(self) -> None:
        self.fx.create("20260901T120000Z-1", "update 20260901-1")
        menu = self.fx.menu()
        self.assertIn("submenu 'CybexOS recovery points' --id 'cybexos-recovery' {", menu)
        self.assertIn("--id 'cybexos-recovery-20260901T120000Z-1'", menu)
        self.assertIn("'2026-09-01 12:00 UTC - update 20260901-1'", menu)
        self.assertIn(f"search --no-floppy --fs-uuid --set=root '{BOOT_UUID}'", menu)
        self.assertIn("insmod ext2", menu)
        linux = next(line.strip() for line in menu.splitlines() if line.strip().startswith("linux "))
        self.assertEqual(linux, (
            f"linux '/vmlinuz-6.20.1' 'root=UUID={ROOT_UUID}' 'rd.luks.uuid=luks-{ROOT_UUID}' 'rhgb' 'quiet' "
            "'ro' 'rootflags=compress=zstd:1,subvol=cybexos-snapshots/root/20260901T120000Z-1' "
            "'cybexos.recovery=20260901T120000Z-1'"))
        self.assertIn("initrd '/initramfs-6.20.1.img'", menu)
        self.assertNotIn("$", menu)
        index = self.fx.index()
        self.assertTrue(index["supported"] and index["bootMenu"])
        self.assertEqual(index["points"][0]["kernel"], "6.20.1")
        self.assertTrue(index["points"][0]["bootable"])

    def test_untrusted_text_cannot_escape_grub_quoting(self) -> None:
        self.fx.kernel("6.20.1", options=f"root=UUID={ROOT_UUID} ro quiet evil';reboot;' a}}b $(x) ok=1")
        self.fx.create("20260901T120000Z-1", "it's $(reboot) `x` }\n{ menuentry 'pwn'")
        menu = self.fx.menu()
        body = "\n".join(line for line in menu.splitlines() if not line.startswith("#"))
        self.assertEqual(len(re.findall(r"^\s*menuentry ", body, re.MULTILINE)), 1)
        for line in body.splitlines():
            # Every quoted value is a whole token: an even number of quotes, no GRUB syntax inside.
            self.assertEqual(line.count("'") % 2, 0, line)
            for value in re.findall(r"'([^']*)'", line):
                self.assertNotRegex(value, r"[$`{};\\]", line)
        self.assertIn("'ok=1'", menu)
        self.assertNotIn("reboot;", menu)
        self.assertNotIn("a}b", menu)
        self.assertIn("it s (reboot) x menuentry pwn", menu)

    def test_kernel_selection_and_unbootable_reasons(self) -> None:
        self.fx.kernel("6.19.9")
        self.fx.create("20260901T120000Z-1")
        # A point from an older release has no recorded kernel.
        (self.fx.store / "metadata/20260901T120000Z-1.kernel").unlink()
        self.fx.run("refresh")
        self.assertEqual(self.fx.index()["points"][0]["kernel"], "6.20.1")
        self.fx.drop_kernel("6.20.1")
        self.fx.run("refresh")
        point = self.fx.index()["points"][0]
        self.assertEqual(point["kernel"], "6.19.9")
        self.assertTrue(point["bootable"])
        (self.fx.boot / "initramfs-6.19.9.img").write_text("initramfs without module\n")
        self.fx.run("refresh")
        point = self.fx.index()["points"][0]
        self.assertFalse(point["bootable"])
        self.assertIn("lacks the recovery module", point["reason"])
        self.assertNotIn("menuentry", self.fx.menu())
        self.fx.drop_kernel("6.19.9")
        self.fx.run("refresh")
        self.assertIn("no installed kernel", self.fx.index()["points"][0]["reason"])

    def test_refresh_reports_only_real_menu_changes(self) -> None:
        self.fx.create("20260901T120000Z-1")
        self.assertEqual(self.fx.run("refresh").stdout, "")
        self.fx.drop_kernel("6.20.1")
        self.assertEqual(self.fx.run("refresh").stdout, "CHANGED\n")

    def test_restore_swaps_roots_and_reconciles_boot(self) -> None:
        self.fx.kernel("6.19.9")
        self.fx.default_kernel = "6.20.1"
        (self.fx.top / "root/etc").mkdir()
        (self.fx.top / "root/etc/state").write_text("before update\n")
        self.fx.subvolume(self.fx.top / "root/var/lib/machines")
        (self.fx.top / "root/var/lib/machines/image").write_text("container\n")
        self.fx.create("20260901T120000Z-1")
        # The update: 6.21.0 arrives, 6.19.9 leaves, the system changes.
        self.fx.kernel("6.21.0")
        self.fx.drop_kernel("6.19.9")
        (self.fx.top / "root/etc/state").write_text("after update\n")
        result = self.fx.run("restore", "20260901T120000Z-1", CYBEXOS_SNAPSHOT_NOW="20260902T080000Z")
        self.assertIn("Restored recovery point 20260901T120000Z-1", result.stdout)
        root, replaced = self.fx.top / "root", self.fx.top / "root.replaced-20260902T080000Z"
        self.assertEqual((root / "etc/state").read_text(), "before update\n")
        self.assertEqual((replaced / "etc/state").read_text(), "after update\n")
        self.assertFalse((root / ".readonly").exists(), "the restored root must be writable")
        self.assertEqual((root / "var/lib/machines/image").read_text(), "container\n")
        # 6.19.9 came back from the archive; 6.21.0 has no modules in the restored root.
        self.assertTrue((self.fx.boot / "vmlinuz-6.19.9").is_file())
        self.assertTrue((self.fx.boot / f"loader/entries/{MACHINE}-6.19.9.conf").is_file())
        self.assertFalse((self.fx.boot / "vmlinuz-6.21.0").exists())
        backup = self.fx.store / "replaced/root.replaced-20260902T080000Z.boot"
        self.assertTrue((backup / "vmlinuz-6.21.0").is_file())
        self.assertTrue((backup / f"loader/entries/{MACHINE}-6.21.0.conf").is_file())
        self.assertIn(f"saved_entry={MACHINE}-6.20.1", self.fx.grubenv())
        record = json.loads((self.fx.store / "replaced/root.replaced-20260902T080000Z.json").read_text())
        self.assertEqual((record["state"], record["point"], record["kernel"]),
                         ("complete", "20260901T120000Z-1", "6.20.1"))
        self.assertEqual(self.fx.index()["replaced"][0]["name"], "root.replaced-20260902T080000Z")
        self.assertTrue((self.fx.store / "root/20260901T120000Z-1").is_dir(), "the point itself is kept")

    def test_interrupted_before_exchange_is_undone(self) -> None:
        self.fx.kernel("6.19.9")
        self.fx.create("20260901T120000Z-1")
        self.fx.drop_kernel("6.19.9")
        (self.fx.top / "root/marker").write_text("live\n")
        result = self.fx.run("restore", "20260901T120000Z-1", check=False, CYBEXOS_SNAPSHOT_NOW="20260902T080000Z",
                             CYBEXOS_SNAPSHOT_TEST_INTERRUPT="before-exchange")
        self.assertEqual(result.returncode, 9)
        self.assertTrue((self.fx.top / "root.incoming-20260902T080000Z").exists())
        self.assertTrue((self.fx.boot / "vmlinuz-6.19.9").exists(), "staged before the interruption")
        self.fx.run("refresh")
        self.assertFalse((self.fx.top / "root.incoming-20260902T080000Z").exists())
        self.assertFalse((self.fx.boot / "vmlinuz-6.19.9").exists(), "staged kernels are withdrawn")
        self.assertEqual((self.fx.top / "root/marker").read_text(), "live\n")
        self.assertEqual(list((self.fx.store / "replaced").iterdir()), [])

    def test_interrupted_after_exchange_is_completed(self) -> None:
        self.fx.create("20260901T120000Z-1")
        self.fx.kernel("6.21.0")
        (self.fx.top / "root/marker").write_text("live\n")
        result = self.fx.run("restore", "20260901T120000Z-1", check=False, CYBEXOS_SNAPSHOT_NOW="20260902T080000Z",
                             CYBEXOS_SNAPSHOT_TEST_INTERRUPT="after-exchange")
        self.assertEqual(result.returncode, 9)
        self.assertFalse((self.fx.top / "root/marker").exists(), "the exchange already happened")
        self.fx.run("refresh")
        replaced = self.fx.top / "root.replaced-20260902T080000Z"
        self.assertEqual((replaced / "marker").read_text(), "live\n")
        self.assertFalse((self.fx.top / "root.incoming-20260902T080000Z").exists())
        record = json.loads((self.fx.store / "replaced/root.replaced-20260902T080000Z.json").read_text())
        self.assertEqual(record["state"], "complete")
        self.assertFalse((self.fx.boot / "vmlinuz-6.21.0").exists())
        self.assertIn(f"saved_entry={MACHINE}-6.20.1", self.fx.grubenv())

    def test_restore_refuses_a_point_without_its_kernel(self) -> None:
        self.fx.create("20260901T120000Z-1")
        shutil.rmtree(self.fx.store / "root/20260901T120000Z-1/usr/lib/modules/6.20.1")
        (self.fx.store / "metadata/20260901T120000Z-1.kernel").unlink()
        result = self.fx.run("restore", "20260901T120000Z-1", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("contains no kernel", result.stderr)
        self.assertEqual(sorted(path.name for path in self.fx.top.iterdir()), ["cybexos-snapshots", "home", "root"])

    def test_recovery_boot_refuses_new_points_but_can_restore(self) -> None:
        self.fx.create("20260901T120000Z-1")
        self.fx.recovery_mount("20260901T120000Z-1")
        result = self.fx.run("create", "update", check=False, CYBEXOS_SNAPSHOT_ID="20260902T120000Z-2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("temporary recovery boot", result.stderr)
        self.fx.run("refresh")
        self.assertEqual(self.fx.index()["recoveryBoot"], "20260901T120000Z-1")
        self.fx.run("restore", "20260901T120000Z-1", CYBEXOS_SNAPSHOT_NOW="20260902T080000Z")
        self.assertTrue((self.fx.top / "root.replaced-20260902T080000Z").is_dir())
        # The recovery boot's read-only /boot is opened for the restore only.
        self.assertEqual((self.fx.base / "mount.log").read_text().splitlines(),
                         [f"-o remount,rw {self.fx.boot}", f"-o remount,ro {self.fx.boot}"])

    def test_pending_restart_blocks_changes_and_discard_of_running_root(self) -> None:
        self.fx.create("20260901T120000Z-1")
        self.fx.run("restore", "20260901T120000Z-1", CYBEXOS_SNAPSHOT_NOW="20260902T080000Z")
        self.fx.mounts("btrfs", "/root.replaced-20260902T080000Z")
        result = self.fx.run("create", "update", check=False, CYBEXOS_SNAPSHOT_ID="20260902T120000Z-2")
        self.assertIn("waiting for a restart", result.stderr)
        result = self.fx.run("discard", "root.replaced-20260902T080000Z", check=False)
        self.assertIn("is the running system", result.stderr)
        self.fx.run("refresh")
        self.assertTrue(self.fx.index()["pendingReboot"])
        self.fx.mounts("btrfs", "/root")
        self.fx.run("discard", "root.replaced-20260902T080000Z")
        self.assertFalse((self.fx.top / "root.replaced-20260902T080000Z").exists())
        self.assertEqual(list((self.fx.store / "replaced").iterdir()), [])
        self.assertEqual(json.loads(self.fx.run("replaced", "--json").stdout), [])

    def test_invalid_names_are_refused(self) -> None:
        for args in (("restore", "../root"), ("restore", "20260901T120000Z-1;x"),
                     ("discard", "root"), ("discard", "root.replaced-../x")):
            result = self.fx.run(*args, check=False)
            self.assertEqual(result.returncode, 1, args)

    def test_non_btrfs_hosts_skip_and_clear_a_stale_menu(self) -> None:
        self.fx.mounts("ext4", "/")
        self.assertEqual(self.fx.run("create", "x").stdout, "skipped: root filesystem is not Btrfs\n")
        (self.fx.boot / "grub2/cybexos-recovery.cfg").write_text("submenu stale {\n}\n")
        self.fx.run("refresh")
        self.assertNotIn("submenu", self.fx.menu())
        self.assertFalse(self.fx.index()["supported"])

    def test_unsupported_layout_is_refused(self) -> None:
        self.fx.mounts("btrfs", "/")
        result = self.fx.run("create", "x", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("expected separate /root and /home subvolumes", result.stderr)


class BootIntegrationTests(unittest.TestCase):
    def run_hook(self, cmdline_value: str | None, submount: bool = False):
        with tempfile.TemporaryDirectory(prefix="cybexos-recovery-hook.") as name:
            base = Path(name)
            newroot = base / "sysroot"
            (newroot / "etc").mkdir(parents=True)
            (newroot / "etc/fstab").write_text(
                f"UUID={ROOT_UUID} / btrfs subvol=root,compress=zstd:1 0 0\n"
                f"UUID={ROOT_UUID} /home btrfs subvol=home 0 0\n"
                f"UUID={BOOT_UUID} /boot ext4 defaults 1 2\n"
                "UUID=AB12-CD34 /boot/efi vfat umask=0077,shortname=winnt 0 2\n"
                "# UUID=x / keep-commented 0 0\n")
            mounts = base / "mounts"
            mounts.write_text(f"sysroot {newroot}/usr xfs rw 0 0\n" if submount else "")
            script = textwrap.dedent(f"""\
                set -u
                calls={base}/calls
                getarg() {{ [ -n "${{ARG:-}}" ] && printf '%s\\n' "$ARG"; }}
                ismounted() {{ return 0; }}
                warn() {{ printf 'warn %s\\n' "$*" >> "$calls"; }}
                info() {{ printf 'info %s\\n' "$*" >> "$calls"; }}
                mount() {{ printf 'mount %s\\n' "$*" >> "$calls"; }}
                umount() {{ printf 'umount %s\\n' "$*" >> "$calls"; }}
                grep() {{
                    if [ "${{3:-}}" = /proc/self/mounts ]; then command grep "$1" "$2" {mounts}; else command grep "$@"; fi
                }}
                NEWROOT={newroot}
                CYBEXOS_RECOVERY_BASE={base}/run
                . {RECOVERY}/90cybexos-recovery/cybexos-recovery-overlay.sh
                """)
            env = dict(os.environ, ARG=cmdline_value or "")
            subprocess.run(["bash", "-c", script], env=env, check=True, timeout=30)
            calls = (base / "calls").read_text() if (base / "calls").exists() else ""
            return calls, (newroot / "etc/fstab").read_text(), (base / "run/active").exists()

    def test_hook_is_inert_without_the_parameter(self) -> None:
        calls, fstab, active = self.run_hook(None)
        self.assertEqual(calls, "")
        self.assertNotIn("cybexos-recovery", fstab)
        self.assertFalse(active)

    def test_hook_rejects_malformed_ids(self) -> None:
        for value in ("../../x", "20260901T120000Z-1 rw", "latest"):
            calls, _, active = self.run_hook(value)
            self.assertIn("ignoring malformed recovery point", calls)
            self.assertNotIn("mount ", calls)
            self.assertFalse(active)

    def test_hook_overlays_the_snapshot_and_neutralises_the_root_remount(self) -> None:
        calls, fstab, active = self.run_hook("20260901T120000Z-1")
        order = [line.split(" ", 2)[1] for line in calls.splitlines() if line.startswith("mount ")]
        self.assertEqual(order, ["-t", "--make-private", "--move", "-t"])
        self.assertIn("-t tmpfs -o mode=0755 cybexos-recovery", calls)
        self.assertRegex(calls, r"mount -t overlay cybexos-recovery -o lowerdir=\S+/lower,upperdir=\S+/rw/upper,workdir=\S+/rw/work")
        self.assertIn(f"# cybexos-recovery: UUID={ROOT_UUID} / btrfs", fstab)
        self.assertIn(f"\nUUID={ROOT_UUID} /home btrfs subvol=home 0 0", fstab)
        self.assertIn(f"\nUUID={BOOT_UUID} /boot ext4 ro,defaults 1 2", fstab)
        self.assertIn("\nUUID=AB12-CD34 /boot/efi vfat ro,umask=0077,shortname=winnt 0 2", fstab)
        self.assertIn("\n# UUID=x / keep-commented", fstab)
        self.assertTrue(active)

    def test_hook_keeps_submounted_roots_read_only(self) -> None:
        calls, fstab, active = self.run_hook("20260901T120000Z-1", submount=True)
        self.assertIn("has submounts", calls)
        self.assertNotIn("mount ", calls)
        self.assertFalse(active)

    def test_boot_plumbing_contracts(self) -> None:
        include = subprocess.run([str(RECOVERY / "42_cybexos_recovery")], capture_output=True, text=True,
                                 check=True).stdout
        self.assertIn("source ${config_directory}/cybexos-recovery.cfg", include)
        setup = (RECOVERY / "90cybexos-recovery/module-setup.sh").read_text()
        self.assertIn("inst_hook pre-pivot", setup, "systemd initrds skip dracut mount hooks")
        self.assertIn("return 255", setup, "included only through dracut.conf.d")
        self.assertIn('add_dracutmodules+=" cybexos-recovery "', (RECOVERY / "90-cybexos-recovery.conf").read_text())
        hook = (RECOVERY / "95-cybexos-recovery.install").read_text()
        self.assertIn("refresh --quiet", hook)
        self.assertEqual(hook.rstrip().splitlines()[-1], "exit 0")
        unit = (RECOVERY / "cybexos-recovery-refresh.service").read_text()
        self.assertIn("ExecStart=/usr/local/libexec/cybexos-system-snapshot refresh --quiet", unit)
        self.assertIn("RemainAfterExit=yes", unit, "keeps repeated Ansible runs idempotent")


if __name__ == "__main__":
    unittest.main(verbosity=1)
