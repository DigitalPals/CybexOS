from __future__ import annotations

import concurrent.futures
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import model_usage_common as common


class PrivateStateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.outside = self.root / "outside"
        self.outside.mkdir(mode=0o755)
        self.sentinel = self.outside / "cache.json"
        self.sentinel.write_text("untouched")
        self.sentinel.chmod(0o644)

    def assertOutsideUnchanged(self):
        self.assertEqual(self.sentinel.read_text(), "untouched")
        self.assertEqual(stat.S_IMODE(self.sentinel.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(self.outside.stat().st_mode), 0o755)
        self.assertEqual(list(self.outside.iterdir()), [self.sentinel])

    def test_create_and_replace_private_state_without_changing_ancestors(self):
        parent = self.root / "parent"
        parent.mkdir(mode=0o755)
        path = parent / "state" / "nested" / "cache.json"
        common.atomic_write_json(path, {"value": "first"})
        old_inode = path.stat().st_ino
        common.atomic_write_json(path, {"value": "second"})
        self.assertEqual(json.loads(path.read_text()), {"value": "second"})
        self.assertNotEqual(path.stat().st_ino, old_inode)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(path.parent.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o755)
        self.assertEqual(list(path.parent.iterdir()), [path])

    def test_owned_readable_leaf_is_tightened_but_not_through_a_symlink(self):
        directory = self.root / "state"
        directory.mkdir(mode=0o755)
        common.atomic_write_json(directory / "cache.json", {})
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        directory = self.root / "alias"
        directory.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaises(OSError):
            common.atomic_write_json(directory / "cache.json", {"secret": "new"})
        self.assertOutsideUnchanged()

    def test_symlink_at_every_directory_depth_is_rejected(self):
        for depth in range(3):
            with self.subTest(depth=depth):
                base = self.root / str(depth)
                base.mkdir(mode=0o700)
                parts = ("config", "omarchy", "state")
                directory = base
                for part in parts[:depth]:
                    directory /= part
                    directory.mkdir(mode=0o700)
                (directory / parts[depth]).symlink_to(self.outside, target_is_directory=True)
                with self.assertRaises(OSError):
                    common.atomic_write_json(base.joinpath(*parts, "cache.json"), {"secret": "new"})
                self.assertOutsideUnchanged()

    def test_group_or_world_writable_directory_is_rejected_without_chmod(self):
        for mode in (0o770, 0o777, 0o1777):
            for leaf in (True, False):
                with self.subTest(mode=oct(mode), leaf=leaf):
                    directory = self.root / f"unsafe-{mode}-{leaf}"
                    directory.mkdir()
                    directory.chmod(mode)
                    path = directory / "cache.json" if leaf else directory / "private" / "cache.json"
                    if mode == 0o1777 and not leaf and os.getuid() == 0:
                        # Root-owned sticky ancestors intentionally support /tmp.
                        # CI runs as root, so this fixture has that same policy.
                        common.atomic_write_json(path, {})
                        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), mode)
                        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
                        continue
                    with self.assertRaises(PermissionError):
                        common.atomic_write_json(path, {})
                    self.assertEqual(stat.S_IMODE(directory.stat().st_mode), mode)
                    self.assertEqual(list(directory.iterdir()), [])

    def test_foreign_owned_leaf_and_ancestor_are_rejected(self):
        directory = self.root / "foreign"
        directory.mkdir(mode=0o755)
        inode = directory.stat().st_ino
        real_fstat = os.fstat

        def foreign_owner(fd):
            info = real_fstat(fd)
            if info.st_ino == inode:
                values = list(info)
                values[4] = os.getuid() + 1
                return os.stat_result(values)
            return info

        for path in (directory / "cache.json", directory / "child" / "cache.json"):
            with mock.patch.object(common.os, "fstat", side_effect=foreign_owner):
                with self.assertRaises(PermissionError):
                    common.atomic_write_json(path, {})
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o755)
            self.assertEqual(list(directory.iterdir()), [])

    def test_parent_traversal_and_filesystem_root_are_rejected(self):
        for path in (self.root / "missing" / ".." / "outside" / "cache.json", Path("/cache.json")):
            with self.assertRaises(PermissionError):
                common.atomic_write_json(path, {})
        self.assertOutsideUnchanged()

    def test_directory_swap_after_open_cannot_redirect_creation_or_chmod(self):
        directory = self.root / "state"
        directory.mkdir(mode=0o755)
        moved = self.root / "held"
        real_open = os.open

        def swap_after_open(path, flags, *args, **kwargs):
            fd = real_open(path, flags, *args, **kwargs)
            if path == "state" and flags & os.O_DIRECTORY:
                directory.rename(moved)
                directory.symlink_to(self.outside, target_is_directory=True)
            return fd

        with mock.patch.object(common.os, "open", side_effect=swap_after_open):
            common.atomic_write_json(directory / "cache.json", {"secret": "new"})
        self.assertEqual(json.loads((moved / "cache.json").read_text()), {"secret": "new"})
        self.assertEqual(stat.S_IMODE(moved.stat().st_mode), 0o700)
        self.assertOutsideUnchanged()

    def test_swapped_ancestor_cannot_redirect_nested_directory_creation(self):
        parent = self.root / "parent"
        parent.mkdir(mode=0o700)
        moved = self.root / "held"
        real_open = os.open

        def swap_after_open(path, flags, *args, **kwargs):
            fd = real_open(path, flags, *args, **kwargs)
            if path == "parent" and flags & os.O_DIRECTORY:
                parent.rename(moved)
                parent.symlink_to(self.outside, target_is_directory=True)
            return fd

        with mock.patch.object(common.os, "open", side_effect=swap_after_open):
            common.atomic_write_json(parent / "new" / "nested" / "cache.json", {})
        self.assertEqual(json.loads((moved / "new/nested/cache.json").read_text()), {})
        self.assertOutsideUnchanged()

    def test_directory_swap_before_replacement_and_cleanup_stays_on_original_fd(self):
        for fail in (False, True):
            with self.subTest(fail=fail):
                directory = self.root / f"state-{fail}"
                directory.mkdir(mode=0o700)
                target = directory / "cache.json"
                common.atomic_write_json(target, {"old": True})
                moved = self.root / f"held-{fail}"
                real_replace = os.replace

                def swap_before_replace(src, dst, **kwargs):
                    directory.rename(moved)
                    directory.symlink_to(self.outside, target_is_directory=True)
                    if fail:
                        raise OSError("simulated replace failure")
                    return real_replace(src, dst, **kwargs)

                with mock.patch.object(common.os, "replace", side_effect=swap_before_replace):
                    if fail:
                        with self.assertRaises(OSError):
                            common.atomic_write_json(target, {"new": True})
                    else:
                        common.atomic_write_json(target, {"new": True})
                self.assertEqual(json.loads((moved / "cache.json").read_text()),
                                 {"old": True} if fail else {"new": True})
                self.assertEqual(list(moved.iterdir()), [moved / "cache.json"])
                self.assertOutsideUnchanged()

    def test_destination_links_are_replaced_without_touching_the_referent(self):
        directory = self.root / "state"
        directory.mkdir(mode=0o700)
        for kind in ("symlink", "hardlink"):
            with self.subTest(kind=kind):
                target = directory / kind
                if kind == "symlink":
                    target.symlink_to(self.sentinel)
                else:
                    os.link(self.sentinel, target)
                common.atomic_write_json(target, {"secret": "new"})
                self.assertFalse(target.is_symlink())
                self.assertEqual(json.loads(target.read_text()), {"secret": "new"})
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
                self.assertOutsideUnchanged()

    def test_temporary_symlink_collision_is_neither_followed_nor_removed(self):
        directory = self.root / "state"
        directory.mkdir(mode=0o700)
        collision = directory / (".model-usage-" + "a" * 32 + ".tmp")
        collision.symlink_to(self.sentinel)
        with mock.patch.object(common.secrets, "token_hex", side_effect=["a" * 32, "b" * 32]):
            common.atomic_write_json(directory / "cache.json", {})
        self.assertTrue(collision.is_symlink())
        self.assertOutsideUnchanged()
        with mock.patch.object(common.secrets, "token_hex", return_value="a" * 32):
            with self.assertRaises(FileExistsError):
                common.atomic_write_json(directory / "cache.json", {"changed": True})
        self.assertEqual(json.loads((directory / "cache.json").read_text()), {})
        self.assertOutsideUnchanged()

    def test_symlink_inserted_during_mkdir_race_is_rejected(self):
        directory = self.root / "state"
        real_mkdir = os.mkdir

        def race_mkdir(path, *args, **kwargs):
            if path == "state":
                directory.symlink_to(self.outside, target_is_directory=True)
                raise FileExistsError
            return real_mkdir(path, *args, **kwargs)

        with mock.patch.object(common.os, "mkdir", side_effect=race_mkdir):
            with self.assertRaises(OSError):
                common.atomic_write_json(directory / "cache.json", {})
        self.assertOutsideUnchanged()

    def test_serialization_failure_preserves_old_state_and_removes_temporary(self):
        directory = self.root / "state"
        target = directory / "cache.json"
        common.atomic_write_json(target, {"old": True})
        with self.assertRaises(TypeError):
            common.atomic_write_json(target, {"new": object()})
        self.assertEqual(json.loads(target.read_text()), {"old": True})
        self.assertEqual(list(directory.iterdir()), [target])

    def test_concurrent_collectors_publish_complete_json(self):
        target = self.root / "state" / "nested" / "cache.json"
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda n: common.atomic_write_json(target, {"value": n}), range(16)))
        self.assertIn(json.loads(target.read_text())["value"], range(16))
        self.assertEqual(list(target.parent.iterdir()), [target])


if __name__ == "__main__":
    unittest.main()
