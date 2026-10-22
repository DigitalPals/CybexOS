#!/usr/bin/env python3
"""Linux-only, unprivileged SSH probe. Standard library and GNU df/ip only.

Newline JSON on stdout. stdin accepts {"interval": 2|5, "refresh": true}.
No files, credentials, services or persistent state are written on the host.
"""
import json
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import sys
import time


def read(path, fallback=""):
    try:
        return Path(path).read_text(errors="replace").strip()
    except OSError:
        return fallback


def cpu_ticks(text):
    result = {}
    for line in text.splitlines():
        parts = line.split()
        if parts and re.fullmatch(r"cpu\d*", parts[0]):
            # guest/guest_nice are already included in user/nice.
            ticks = [int(v) for v in parts[1:9]]
            result[parts[0]] = (sum(ticks), ticks[3] + ticks[4])
    return result


def cpu_percent(current, previous):
    if previous is None:
        return None
    total = current[0] - previous[0]
    idle = current[1] - previous[1]
    if total <= 0 or idle < 0 or idle > total:
        return None
    return round(100 * (total - idle) / total, 1)


def memory_info(text):
    fields = {}
    for line in text.splitlines():
        key, _, value = line.partition(":")
        if value.strip():
            fields[key] = int(value.split()[0]) * 1024
    total = fields.get("MemTotal", 0)
    available = fields.get("MemAvailable")
    # Do not confuse MemFree with memory available to applications.
    return {"total": total, "available": available,
            "used": total - available if available is not None else None,
            "swapTotal": fields.get("SwapTotal", 0),
            "swapUsed": fields.get("SwapTotal", 0) - fields.get("SwapFree", 0)}


def network_counters(text):
    result = {}
    for line in text.splitlines():
        name, sep, values = line.partition(":")
        fields = values.split()
        if sep and len(fields) >= 16 and name.strip() != "lo":
            result[name.strip()] = (int(fields[0]), int(fields[8]))
    return result


def rate(value, old, elapsed):
    return (value - old) / elapsed if old is not None and elapsed > 0 and value >= old else None


def temperatures():
    result = []
    for path in sorted(Path("/sys/class/hwmon").glob("hwmon*/temp*_input")):
        try:
            value = int(read(path)) / 1000
        except ValueError:
            continue
        if not -40 <= value <= 150:
            continue
        prefix = path.name.removesuffix("_input")
        label = read(path.with_name(prefix + "_label"), prefix)
        chip = read(path.parent / "name", path.parent.name)
        result.append({"name": chip + " · " + label, "celsius": value})
    if not result:
        for path in sorted(Path("/sys/class/thermal").glob("thermal_zone*/temp")):
            try:
                value = int(read(path)) / 1000
            except ValueError:
                continue
            if -40 <= value <= 150:
                result.append({"name": read(path.parent / "type", path.parent.name), "celsius": value})
    return result[:128]


def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=3,
                          check=True, env={**os.environ, "LC_ALL": "C"}).stdout


def storage():
    rows = []
    try:
        text = run(["df", "-l", "-B1", "--output=source,fstype,size,used,avail,pcent,target",
                    "-x", "tmpfs", "-x", "devtmpfs", "-x", "squashfs", "-x", "overlay"])
        for line in text.splitlines()[1:]:
            parts = line.split(None, 6)
            if len(parts) != 7:
                continue
            device, fs, total, used, free, percent, mount = parts
            rows.append({"device": device, "type": fs, "total": int(total),
                         "used": int(used), "free": int(free),
                         "percent": int(percent.rstrip("%")), "mount": mount})
        return sorted(rows, key=lambda row: row["mount"]), ""
    except (OSError, ValueError, subprocess.SubprocessError):
        return [], "Filesystem statistics unavailable"


def metadata():
    os_release = dict(line.split("=", 1) for line in read("/etc/os-release").splitlines() if "=" in line)
    model = next((line.split(":", 1)[1].strip() for line in read("/proc/cpuinfo").splitlines()
                  if line.startswith(("model name", "Hardware"))), "")
    addresses = {}
    default_interface = ""
    try:
        for link in json.loads(run(["ip", "-j", "address", "show"])):
            addresses[link["ifname"]] = [a["local"] for a in link.get("addr_info", [])
                                         if a.get("scope") == "global"]
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        pass
    try:
        routes = json.loads(run(["ip", "-j", "route", "show", "default"]))
        if routes:
            default_interface = min(routes, key=lambda r: r.get("metric", 0)).get("dev", "")
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
        pass
    return {"hostname": socket.gethostname(), "os": os_release.get("PRETTY_NAME", "Linux").strip('"'),
            "kernel": os.uname().release, "model": model, "cores": os.cpu_count(),
            "addresses": addresses, "defaultInterface": default_interface}


class Probe:
    def __init__(self):
        self.previous_cpu = {}
        self.previous_net = {}
        self.previous_time = None
        self.boot = ""
        self.slow_at = -60.0
        self.meta = {}
        self.disks = []
        self.storage_error = ""

    def sample(self):
        now = time.monotonic()
        boot = read("/proc/sys/kernel/random/boot_id")
        if boot != self.boot:
            self.previous_cpu, self.previous_net, self.previous_time = {}, {}, None
            self.boot = boot
        cpu = cpu_ticks(read("/proc/stat"))
        if "cpu" not in cpu:
            raise RuntimeError("This widget requires a Linux server with readable /proc")
        net = network_counters(read("/proc/net/dev"))
        elapsed = now - self.previous_time if self.previous_time is not None else 0
        if now - self.slow_at >= 60:
            self.meta = metadata()
            self.disks, self.storage_error = storage()
            self.slow_at = now
        interfaces = []
        for name, counters in net.items():
            previous = self.previous_net.get(name)
            interfaces.append({"name": name, "received": counters[0], "sent": counters[1],
                               "rx": rate(counters[0], previous[0] if previous else None, elapsed),
                               "tx": rate(counters[1], previous[1] if previous else None, elapsed),
                               "addresses": self.meta["addresses"].get(name, [])})
        result = {"version": 1, "boot": boot, "uptime": float(read("/proc/uptime").split()[0]),
                  "meta": self.meta, "cpu": cpu_percent(cpu["cpu"], self.previous_cpu.get("cpu")),
                  "perCore": [cpu_percent(v, self.previous_cpu.get(k)) for k, v in cpu.items() if k != "cpu"],
                  "load": list(os.getloadavg()), "memory": memory_info(read("/proc/meminfo")),
                  "temperatures": temperatures(), "storage": self.disks, "storageError": self.storage_error,
                  "network": sorted(interfaces, key=lambda row: row["name"])}
        self.previous_cpu, self.previous_net, self.previous_time = cpu, net, now
        return result


def main():
    probe = Probe()
    interval = 5
    pending = b""
    deadline = 0.0
    while True:
        if time.monotonic() >= deadline:
            print(json.dumps(probe.sample(), allow_nan=False, separators=(",", ":")), flush=True)
            deadline = time.monotonic() + interval
        ready, _, _ = select.select([sys.stdin], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            continue
        chunk = os.read(sys.stdin.fileno(), 4096)
        if not chunk:
            return
        pending += chunk
        if len(pending) > 8192:
            raise ValueError("Control request too large")
        while b"\n" in pending:
            line, pending = pending.split(b"\n", 1)
            try:
                request = json.loads(line)
                interval = max(2, min(60, int(request.get("interval", interval))))
                if request.get("refresh"):
                    probe.slow_at = -60.0
                deadline = min(deadline, time.monotonic() + (0 if request.get("refresh") else interval))
            except (ValueError, TypeError, AttributeError):
                continue


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
