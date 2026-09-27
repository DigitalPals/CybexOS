#!/usr/bin/env python3
"""Unprivileged telemetry, counter semantics and SSH stream lifecycle."""
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "roles/desktop/files/quickshell/scripts"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


probe = load("probe", "remote_server_probe.py")
launcher = load("launcher", "remote-server.py")


class RemoteServerTests(unittest.TestCase):
    def test_cpu_ignores_double_counted_guest_and_handles_reset(self):
        ticks = probe.cpu_ticks("cpu 100 20 30 400 50 5 10 0 25 10\ncpu0 1 2 3 4 5 6 7 8 9 10")
        self.assertEqual(ticks["cpu"], (615, 450))
        self.assertIsNone(probe.cpu_percent(ticks["cpu"], None))
        self.assertEqual(probe.cpu_percent((200, 100), (100, 50)), 50)
        self.assertIsNone(probe.cpu_percent((100, 50), (200, 100)))
        self.assertIsNone(probe.cpu_percent((100, 50), (100, 50)))

    def test_memory_uses_available_instead_of_free(self):
        memory = probe.memory_info("MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\nSwapTotal: 500 kB\nSwapFree: 300 kB")
        self.assertEqual(memory["used"], 600 * 1024)
        self.assertEqual(memory["available"], 400 * 1024)
        self.assertEqual(memory["swapUsed"], 200 * 1024)
        self.assertIsNone(probe.memory_info("MemTotal: 1000 kB")["used"])

    def test_rates_use_elapsed_time_and_do_not_spike_after_reset(self):
        text = "lo: 99 0 0 0 0 0 0 0 88 0 0 0 0 0 0 0\n eth0: 2000 0 0 0 0 0 0 0 900 0 0 0 0 0 0 0"
        self.assertEqual(probe.network_counters(text), {"eth0": (2000, 900)})
        self.assertEqual(probe.rate(2000, 1000, 2.5), 400)
        self.assertIsNone(probe.rate(2, 1000, 2.5))
        self.assertIsNone(probe.rate(2000, None, 2.5))
        self.assertIsNone(probe.rate(2000, 1000, 0))

    def test_storage_handles_spaces_and_failure(self):
        with patch.object(probe, "run", return_value="header\n/dev/sda ext4 1000 600 350 64% /a mount\n"):
            disks, error = probe.storage()
        self.assertFalse(error)
        self.assertEqual(disks[0]["mount"], "/a mount")
        self.assertEqual(disks[0]["free"], 350)
        with patch.object(probe, "run", side_effect=subprocess.TimeoutExpired("df", 3)):
            self.assertEqual(probe.storage(), ([], "Filesystem statistics unavailable"))

    def test_probe_caches_slow_data_and_resets_on_new_boot(self):
        files = {"/proc/stat": "cpu 100 0 0 100 0 0 0 0", "/proc/net/dev": "",
                 "/proc/meminfo": "MemTotal: 1000 kB\nMemAvailable: 600 kB",
                 "/proc/uptime": "100 100", "/proc/sys/kernel/random/boot_id": "a"}
        with patch.object(probe, "read", side_effect=lambda p, *_: files[str(p)]), \
             patch.object(probe, "metadata", return_value={"addresses": {}}) as meta, \
             patch.object(probe, "storage", return_value=([], "")) as disks, \
             patch.object(probe, "temperatures", return_value=[]), \
             patch.object(probe.time, "monotonic", side_effect=[100, 102, 104, 165]):
            collector = probe.Probe()
            self.assertIsNone(collector.sample()["cpu"])
            files["/proc/stat"] = "cpu 130 0 0 110 0 0 0 0"
            self.assertEqual(collector.sample()["cpu"], 75)
            files["/proc/sys/kernel/random/boot_id"] = "b"
            self.assertIsNone(collector.sample()["cpu"])
            collector.sample()
            self.assertEqual(meta.call_count, 2)
            self.assertEqual(disks.call_count, 2)

    def test_ssh_destination_is_data_and_host_verification_is_required(self):
        for host in ["john@10.10.0.7", "beast", "john@[2001:db8::1]"]:
            command = launcher.command(host)
            self.assertEqual(command[-2], host)
            for flag in ["BatchMode=yes", "StrictHostKeyChecking=yes", "ControlPath=none", "ClearAllForwardings=yes", "ForwardAgent=no"]:
                self.assertIn(flag, command)
        for host in ["-oProxyCommand=bad", "host;touch /tmp/no", "$(id)", "a b", "a\nb", ""]:
            with self.assertRaises(ValueError):
                launcher.command(host)

    def test_stream_controls_and_eof_stop_the_transport(self):
        # A fake SSH executable runs the exact transmitted, quoted program
        # locally. This covers delivery, framing and lifetime without a host.
        with tempfile.TemporaryDirectory(prefix="cybexos-remote-test-") as directory:
            fake = Path(directory) / "ssh"
            fake.write_text("#!/usr/bin/env python3\nimport os,sys\nos.execl('/bin/sh','sh','-c',sys.argv[-1])\n")
            fake.chmod(0o700)
            proc = subprocess.Popen([sys.executable, "-B", str(SCRIPTS / "remote-server.py"), "fixture"],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, start_new_session=True,
                                    env={**os.environ, "PATH": directory + ":" + os.environ["PATH"]})
            try:
                proc.stdin.write('not json\n{"interval":2}\n')
                proc.stdin.flush()
                samples = []
                for _ in range(2):
                    self.assertTrue(select.select([proc.stdout], [], [], 15)[0], "sample timed out")
                    samples.append(json.loads(proc.stdout.readline()))
                self.assertEqual(samples[0]["version"], 1)
                self.assertIsNone(samples[0]["cpu"])
                self.assertIsInstance(samples[1]["cpu"], (int, float))
                proc.stdin.close()
                self.assertEqual(proc.wait(timeout=5), 0, proc.stderr.read())
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=5)
                for stream in (proc.stdin, proc.stdout, proc.stderr):
                    stream.close()


if __name__ == "__main__":
    unittest.main()
