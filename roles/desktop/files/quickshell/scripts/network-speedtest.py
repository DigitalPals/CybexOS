#!/usr/bin/env python3
"""Sustained Fast.com speed test with interface selection and hard cleanup."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any


IFACE_RE = re.compile(r"^[A-Za-z0-9_.:@+-]{1,64}$")
FAST_TOKEN = "YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm"
workers: set[subprocess.Popen[bytes]] = set()
# Reentrant: the SIGTERM/SIGINT handler runs on the main thread between
# bytecodes and stops workers through this lock, which the main thread may
# already hold, e.g. while cleaning up after the first of two SIGTERMs (the
# overlay sends one per interface switch, cancel, and close).
workers_lock = threading.RLock()
cancel_event = threading.Event()


class SpeedError(Exception):
    pass


class Canceled(SpeedError):
    pass


def emit(kind: str, **values: Any) -> None:
    sys.stdout.write(json.dumps({"type": kind, **values}, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def env_float(name: str, fallback: float, minimum: float, maximum: float) -> float:
    try:
        value = float(os.environ.get(name, fallback))
    except ValueError:
        value = fallback
    return min(maximum, max(minimum, value))


def env_int(name: str, fallback: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, fallback))
    except ValueError:
        value = fallback
    return min(maximum, max(minimum, value))


def phase_seconds() -> float:
    # Omarchy runs each direction for five seconds. Keeping the duration fixed
    # lets parallel transfers ramp up and makes runs comparable.
    return env_float("NETWORK_SPEEDTEST_PHASE_SECONDS", 5.0, 0.25, 15.0)


def sample_interval() -> float:
    return env_float("NETWORK_SPEEDTEST_SAMPLE_INTERVAL", 1.0, 0.05, 2.0)


def parallelism() -> int:
    return env_int("NETWORK_SPEEDTEST_PARALLEL", 8, 1, 16)


def register(worker: subprocess.Popen[bytes]) -> None:
    with workers_lock:
        workers.add(worker)


def unregister(worker: subprocess.Popen[bytes]) -> None:
    with workers_lock:
        workers.discard(worker)


def worker_snapshot() -> list[subprocess.Popen[bytes]]:
    with workers_lock:
        return list(workers)


def stop_workers(force: bool = False) -> None:
    for worker in worker_snapshot():
        if worker.poll() is not None:
            unregister(worker)
            continue
        try:
            os.killpg(worker.pid, signal.SIGKILL if force else signal.SIGTERM)
        except ProcessLookupError:
            pass


def on_signal(signum: int, frame: Any) -> None:
    del signum, frame
    cancel_event.set()
    # Every curl owns a new process group, including anything curl might
    # launch. Closing the overlay therefore stops all test traffic at once.
    stop_workers()


def curl_prefix(interface: str, seconds: float) -> list[str]:
    return [
        "curl", "--location", "--fail", "--silent", "--show-error",
        "--connect-timeout", "5", "--max-time", str(max(2, math.ceil(seconds))),
        "--interface", interface,
    ]


def fetch_targets(interface: str) -> list[str]:
    count = env_int("NETWORK_SPEEDTEST_URL_COUNT", 3, 1, 8)
    api_url = os.environ.get(
        "NETWORK_SPEEDTEST_FAST_API_URL",
        "https://api.fast.com/netflix/speedtest/v2"
        f"?https=true&token={FAST_TOKEN}&urlCount={count}",
    )
    arguments = curl_prefix(interface, 10) + [api_url]
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    try:
        worker = subprocess.Popen(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            start_new_session=True,
        )
    except FileNotFoundError as error:
        raise SpeedError("curl is not installed") from error
    register(worker)
    try:
        try:
            stdout, _stderr = worker.communicate(timeout=12)
        except subprocess.TimeoutExpired as error:
            try:
                os.killpg(worker.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            worker.communicate()
            raise SpeedError("Fast.com endpoint discovery timed out") from error
    finally:
        unregister(worker)
    if cancel_event.is_set():
        raise Canceled("Canceled")
    if worker.returncode != 0:
        raise SpeedError("Could not reach Fast.com")
    if len(stdout) > 1_000_000:
        raise SpeedError("Fast.com returned an invalid endpoint list")
    try:
        response = json.loads(stdout.decode("utf-8", "strict"))
        targets = [str(target["url"]) for target in response.get("targets", [])
                   if isinstance(target, dict) and target.get("url")]
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, KeyError) as error:
        raise SpeedError("Fast.com returned an invalid endpoint list") from error
    if not targets:
        raise SpeedError("Fast.com did not provide a speed-test endpoint")
    return targets[:count]


def counter_path(interface: str, direction: str) -> Path:
    root = Path(os.environ.get("NETWORK_SPEEDTEST_COUNTER_ROOT", "/sys/class/net"))
    counter = "rx_bytes" if direction == "download" else "tx_bytes"
    return root / interface / "statistics" / counter


def read_counter(interface: str, direction: str) -> int:
    path = counter_path(interface, direction)
    try:
        value = int(path.read_text(encoding="ascii").strip())
    except (OSError, ValueError) as error:
        raise SpeedError(f"Could not read traffic counters for {interface}") from error
    if value < 0:
        raise SpeedError(f"Could not read traffic counters for {interface}")
    return value


def traffic_arguments(
    interface: str,
    direction: str,
    url: str,
    upload_path: str,
    duration: float,
) -> list[str]:
    arguments = curl_prefix(interface, duration + 3) + ["--output", "/dev/null"]
    if direction == "upload":
        arguments += [
            "--request", "POST",
            "--header", "Content-Type: application/octet-stream",
            "--data-binary", f"@{upload_path}",
        ]
    arguments.append(url)
    return arguments


def traffic_loop(
    index: int,
    interface: str,
    direction: str,
    urls: list[str],
    upload_path: str,
    duration: float,
    phase_stop: threading.Event,
    failures: list[str],
    failures_lock: threading.Lock,
) -> None:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    request = 0
    while not phase_stop.is_set() and not cancel_event.is_set():
        url = urls[(index + request) % len(urls)]
        request += 1
        try:
            worker = subprocess.Popen(
                traffic_arguments(interface, direction, url, upload_path, duration),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=environment,
                start_new_session=True,
            )
        except FileNotFoundError:
            with failures_lock:
                failures.append("curl is not installed")
            return
        register(worker)
        try:
            try:
                return_code = worker.wait(timeout=duration + 5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(worker.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                worker.wait()
                return_code = 124
        finally:
            unregister(worker)
        if phase_stop.is_set() or cancel_event.is_set():
            return
        if return_code != 0:
            with failures_lock:
                failures.append("A Fast.com transfer failed")
            return


def stable_measurement(samples: list[float]) -> float:
    if not samples:
        raise SpeedError("The selected interface did not report any traffic")
    # Ignore the first ramp-up interval, then take the median of the recent
    # readings. This keeps a single scheduler/network hiccup from defining the
    # result while retaining Omarchy's responsive once-per-second updates.
    settled = samples[1:] if len(samples) > 2 else samples
    recent = settled[-5:]
    value = statistics.median(recent)
    if value <= 0:
        raise SpeedError("No test traffic passed through the selected interface")
    return value


def run_phase(interface: str, direction: str, urls: list[str], upload_path: str) -> float:
    duration = phase_seconds()
    interval = sample_interval()
    count = parallelism()
    phase_stop = threading.Event()
    failures: list[str] = []
    failures_lock = threading.Lock()
    threads = [
        threading.Thread(
            target=traffic_loop,
            args=(index, interface, direction, urls, upload_path, duration,
                  phase_stop, failures, failures_lock),
            daemon=True,
        )
        for index in range(count)
    ]

    emit("phase", phase=direction, durationSeconds=duration, parallel=count)
    for thread in threads:
        thread.start()
    previous_counter = read_counter(interface, direction)
    previous_time = time.monotonic()
    deadline = previous_time + duration
    samples: list[float] = []
    expected_samples = max(1, math.ceil(duration / interval))
    try:
        while previous_time < deadline:
            wait_for = min(interval, max(0.0, deadline - previous_time))
            if cancel_event.wait(wait_for):
                raise Canceled("Canceled")
            current_time = time.monotonic()
            current_counter = read_counter(interface, direction)
            elapsed = current_time - previous_time
            delta = current_counter - previous_counter
            mbps = 0.0 if delta < 0 or elapsed <= 0 else delta * 8 / elapsed / 1_000_000
            samples.append(mbps)
            emit("sample", phase=direction, mbps=round(mbps, 2),
                 sample=len(samples), samples=expected_samples)
            previous_counter = current_counter
            previous_time = current_time
            if not any(thread.is_alive() for thread in threads):
                with failures_lock:
                    message = failures[0] if failures else "Fast.com transfers stopped early"
                raise SpeedError(message)
    finally:
        phase_stop.set()
        stop_workers()
        for thread in threads:
            thread.join(timeout=2)
        stop_workers(force=True)
    if cancel_event.is_set():
        raise Canceled("Canceled")
    return stable_measurement(samples)


def make_upload_file() -> str:
    size = env_int("NETWORK_SPEEDTEST_UPLOAD_BYTES", 64_000_000, 1_000_000, 128_000_000)
    stream = tempfile.NamedTemporaryFile(prefix="quickshell-speedtest-", delete=False)
    try:
        stream.truncate(size)
    except BaseException:
        path = stream.name
        stream.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        raise
    stream.close()
    return stream.name


def run_test(interface: str) -> None:
    # Validate the chosen interface before contacting the endpoint. This also
    # ensures the counter source and curl's --interface binding describe the
    # same physical device.
    read_counter(interface, "download")
    read_counter(interface, "upload")
    targets = fetch_targets(interface)
    download = run_phase(interface, "download", targets, "")
    upload_path = make_upload_file()
    try:
        upload = run_phase(interface, "upload", targets, upload_path)
    finally:
        try:
            os.unlink(upload_path)
        except FileNotFoundError:
            pass
    emit("completion", phase="complete", interface=interface,
         downloadMbps=round(download, 2), uploadMbps=round(upload, 2))


def main() -> int:
    parser = argparse.ArgumentParser(description="Quickshell sustained Fast.com speed test")
    parser.add_argument("--interface", required=True)
    arguments = parser.parse_args()
    if not IFACE_RE.fullmatch(arguments.interface):
        emit("error", phase="error", error="A valid network interface is required")
        return 2
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    try:
        run_test(arguments.interface)
        return 0
    except Canceled:
        emit("error", phase="canceled", error="Canceled")
        return 130
    except SpeedError as error:
        emit("error", phase="error", error=str(error))
        return 1
    finally:
        stop_workers()
        deadline = time.monotonic() + 1
        while worker_snapshot() and time.monotonic() < deadline:
            for worker in worker_snapshot():
                if worker.poll() is not None:
                    unregister(worker)
            if worker_snapshot():
                time.sleep(0.02)
        stop_workers(force=True)


if __name__ == "__main__":
    raise SystemExit(main())
