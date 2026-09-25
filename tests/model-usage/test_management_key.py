from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "scripts" / "management-key.py"


class ManagementKeyTests(unittest.TestCase):
    def start(self, config, key="synthetic-management-secret", previous=""):
        process = subprocess.Popen(
            [sys.executable, "-u", str(HELPER)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "XDG_CONFIG_HOME": str(config)},
        )
        self.addCleanup(self.stop, process)
        process.stdin.write(json.dumps({"key": key, "previousPath": str(previous)}) + "\n")
        process.stdin.flush()
        return process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.kill()
        process.communicate()

    def test_commit_stores_private_key_and_rotation_removes_previous_managed_key(self):
        with tempfile.TemporaryDirectory() as config:
            process = self.start(config)
            response = process.stdout.readline()
            self.assertNotIn("synthetic-management-secret", response)
            path = Path(json.loads(response)["path"])
            self.assertEqual(path.read_text(), "synthetic-management-secret\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            stdout, stderr = process.communicate("commit\n", timeout=3)
            self.assertEqual((process.returncode, stdout, stderr), (0, "", ""))
            replacement = self.start(config, "replacement-secret", path)
            replacement_path = Path(json.loads(replacement.stdout.readline())["path"])
            replacement.communicate("commit\n", timeout=3)
            self.assertTrue(replacement_path.exists())
            self.assertFalse(path.exists())

    def test_abort_eof_and_termination_remove_staged_key_and_keep_existing_key(self):
        with tempfile.TemporaryDirectory() as config:
            existing = Path(config) / "custom.key"
            existing.write_text("existing")
            for action in ("abort", "eof", "terminate"):
                with self.subTest(action=action):
                    process = self.start(config, previous=existing)
                    path = Path(json.loads(process.stdout.readline())["path"])
                    if action == "terminate":
                        process.send_signal(signal.SIGTERM)
                    process.communicate("abort\n" if action == "abort" else "", timeout=3)
                    self.assertFalse(path.exists())
                    self.assertEqual(existing.read_text(), "existing")

    def test_commit_keeps_custom_key_files(self):
        with tempfile.TemporaryDirectory() as config:
            existing = Path(config) / "custom.key"
            existing.write_text("existing")
            process = self.start(config, previous=existing)
            process.stdout.readline()
            process.communicate("commit\n", timeout=3)
            self.assertEqual(existing.read_text(), "existing")

    def test_invalid_keys_are_rejected_without_echoing_input(self):
        with tempfile.TemporaryDirectory() as config:
            for key in ("", "  ", "secret\nsecond-line", "secret\x00", "é", "s" * 8192):
                with self.subTest(length=len(key)):
                    process = self.start(config, key)
                    stdout, stderr = process.communicate(timeout=3)
                    self.assertEqual(process.returncode, 1)
                    self.assertEqual((stdout, stderr), ("", ""))
            self.assertEqual(list(Path(config).rglob("*.key")), [])

    def test_largest_saved_key_fits_backend_file_limit(self):
        with tempfile.TemporaryDirectory() as config:
            process = self.start(config, "s" * 8191)
            path = Path(json.loads(process.stdout.readline())["path"])
            process.communicate("commit\n", timeout=3)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(path.stat().st_size, 8192)

    def test_symlink_or_public_key_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as config:
            directory = Path(config) / "omarchy/model-usage/management-keys"
            directory.parent.mkdir(parents=True)
            target = Path(config) / "target"
            target.mkdir(mode=0o700)
            directory.symlink_to(target)
            process = self.start(config)
            stdout, stderr = process.communicate(timeout=3)
            self.assertEqual((process.returncode, stdout, stderr), (1, "", ""))
            self.assertEqual(list(target.iterdir()), [])
            directory.unlink()
            directory.mkdir(mode=0o755)
            process = self.start(config)
            process.communicate(timeout=3)
            self.assertEqual(process.returncode, 1)
            self.assertEqual(list(directory.iterdir()), [])

    def test_both_credentials_commit_or_roll_back_together(self):
        for decision in ("commit", "abort"):
            with self.subTest(decision=decision), tempfile.TemporaryDirectory() as config:
                process = subprocess.Popen(
                    [sys.executable, "-u", str(HELPER)], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    env={**os.environ, "XDG_CONFIG_HOME": config})
                self.addCleanup(self.stop, process)
                keys = {"cliproxyKeyFile": "proxy-secret", "costKeeperPasswordFile": "keeper-secret"}
                process.stdin.write(json.dumps({"keys": keys, "previousPaths": {}}) + "\n")
                process.stdin.flush()
                response = process.stdout.readline()
                paths = json.loads(response)["paths"]
                self.assertEqual(set(paths), set(keys))
                for name, path in paths.items():
                    self.assertEqual(Path(path).read_text().strip(), keys[name])
                    self.assertEqual(Path(path).stat().st_mode & 0o777, 0o600)
                    self.assertNotIn(keys[name], response)
                process.communicate(decision + "\n", timeout=3)
                for path in paths.values():
                    self.assertEqual(Path(path).exists(), decision == "commit")

    def test_symlink_in_each_key_directory_ancestor_is_rejected(self):
        for depth in range(3):
            with self.subTest(depth=depth), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = root / "config"
                outside = root / "outside"
                outside.mkdir(mode=0o700)
                parts = ("config", "omarchy", "model-usage")
                parent = root
                for part in parts[:depth]:
                    parent /= part
                    parent.mkdir(mode=0o700)
                (parent / parts[depth]).symlink_to(outside, target_is_directory=True)
                process = self.start(config)
                stdout, stderr = process.communicate(timeout=3)
                self.assertEqual((process.returncode, stdout, stderr), (1, "", ""))
                self.assertEqual(list(outside.iterdir()), [])

    def test_abort_after_directory_swap_removes_only_the_original_staged_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = self.start(root / "config")
            path = Path(json.loads(process.stdout.readline())["path"])
            held = root / "held"
            path.parent.rename(held)
            outside = root / "outside"
            outside.mkdir(mode=0o700)
            sentinel = outside / path.name
            sentinel.write_text("untouched")
            path.parent.symlink_to(outside, target_is_directory=True)
            process.communicate("abort\n", timeout=3)
            self.assertEqual(process.returncode, 1)
            self.assertEqual(list(held.iterdir()), [])
            self.assertEqual(sentinel.read_text(), "untouched")

    def test_four_t3_credentials_commit_or_roll_back_together(self):
        for decision in ("commit", "abort"):
            with self.subTest(decision=decision), tempfile.TemporaryDirectory() as config:
                process = subprocess.Popen(
                    [sys.executable, "-u", str(HELPER)], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    env={**os.environ, "XDG_CONFIG_HOME": config})
                self.addCleanup(self.stop, process)
                keys = {"t3Token_server-" + str(i): "t3-secret-" + str(i) for i in range(4)}
                process.stdin.write(json.dumps({"keys": keys, "previousPaths": {}}) + "\n")
                process.stdin.flush()
                response = process.stdout.readline()
                paths = json.loads(response)["paths"]
                self.assertEqual(set(paths), set(keys))
                for name, path in paths.items():
                    self.assertEqual(Path(path).read_text().strip(), keys[name])
                    self.assertEqual(Path(path).stat().st_mode & 0o777, 0o600)
                    self.assertNotIn(keys[name], response)
                process.communicate(decision + "\n", timeout=3)
                for path in paths.values():
                    self.assertEqual(Path(path).exists(), decision == "commit")


if __name__ == "__main__":
    unittest.main()
