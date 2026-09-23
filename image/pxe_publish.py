"""Checksum-first, no-replace publication to a local iVentoy installation."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.request
from urllib.parse import urlsplit

from build_support import SAFE_NAME, checksum_entries, digest


# Statically inspected in the official 1.0.41 Linux release (no binaries run):
# query_status -> {"status":"running"|"refreshing"|...}; get_img_tree -> list.
# https://github.com/ventoy/PXE/releases/tag/v1.0.41
DEFAULT_CONTRACT = {"pxe_status_pointer": "/status", "pxe_running_value": "running",
                    "refresh_busy_pointer": "/status", "refresh_idle_value": "running",
                    "refresh_busy_value": "refreshing"}


def pointer(value, path):
    if not path.startswith("/"):
        raise ValueError("API contract paths must be JSON pointers")
    for part in path[1:].split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        value = value[int(part)] if isinstance(value, list) else value[part]
    return value


def validate_status(response, contract):
    if not isinstance(response, dict) or response.get("result", "success") != "success":
        raise RuntimeError("iVentoy status request did not succeed")
    try:
        running = pointer(response, contract["pxe_status_pointer"])
        busy = pointer(response, contract["refresh_busy_pointer"])
    except (KeyError, TypeError, IndexError, ValueError) as error:
        raise RuntimeError("iVentoy status shape differs from the reviewed API contract; inspect installed vtoy_image.html") from error
    if busy == contract["refresh_busy_value"]:
        return True
    if running != contract["pxe_running_value"]:
        raise RuntimeError(f"iVentoy PXE is not running: {running!r}")
    if busy not in (contract["refresh_idle_value"], contract["refresh_busy_value"]):
        raise RuntimeError("Unknown iVentoy refresh state")
    return busy == contract["refresh_busy_value"]


def tree_contains(value, filename):
    if isinstance(value, str):
        return value == filename or value.replace("\\", "/").rsplit("/", 1)[-1] == filename
    if isinstance(value, dict):
        return any(tree_contains(item, filename) for item in value.values())
    if isinstance(value, list):
        return any(tree_contains(item, filename) for item in value)
    return False


class IVentoy:
    def __init__(self, url, contract, timeout=180, request=None, sleep=time.sleep, clock=time.monotonic):
        parsed = urlsplit(url)
        if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("Run this tool on the PXE server and use its loopback iVentoy URL")
        self.url, self.contract, self.timeout = url, contract, timeout
        self.request = request or self._request
        self.sleep, self.clock = sleep, clock
        required = {"pxe_status_pointer", "pxe_running_value", "refresh_busy_pointer", "refresh_idle_value", "refresh_busy_value"}
        if not required.issubset(contract) or contract["refresh_idle_value"] == contract["refresh_busy_value"]:
            raise ValueError("Incomplete iVentoy API contract")

    def _request(self, method):
        request = urllib.request.Request(self.url, json.dumps({"method": method}).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def wait_idle(self):
        deadline = self.clock() + self.timeout
        while self.clock() < deadline:
            if not validate_status(self.request("query_status"), self.contract):
                return
            self.sleep(2)
        raise RuntimeError("iVentoy remained busy; published files are retained for a later refresh")

    def refresh(self, filename):
        deadline = self.clock() + self.timeout
        while self.clock() < deadline:
            self.wait_idle()
            result = self.request("refresh_img_list")
            if result.get("result") == "success":
                break
            if result.get("result") != "busy":
                raise RuntimeError(f"iVentoy rejected refresh: {result.get('result')!r}")
            self.sleep(2)
        else:
            raise RuntimeError("iVentoy refresh request remained busy")
        self.wait_idle()
        tree = self.request("get_img_tree")
        if not isinstance(tree, list) or not tree_contains(tree, filename):
            raise RuntimeError("iVentoy did not list the published filename")


def publish(iso, served, filename, expected=None):
    """Caller has validated iVentoy. Existing files are never replaced."""
    iso, served = Path(iso), Path(served)
    if not SAFE_NAME.fullmatch(filename) or not filename.endswith(".iso"):
        raise ValueError("ISO filename must be ASCII without spaces and end with .iso")
    if served.is_symlink() or not served.is_dir():
        raise ValueError("Served ISO directory must exist and must not be a symlink")
    destination, checksum = served / filename, served / (filename + ".sha256")
    actual = digest(iso)
    if expected is not None and actual != expected:
        raise ValueError("Source ISO changed after manifest verification")
    expected = actual
    if destination.exists() or checksum.exists() or destination.is_symlink() or checksum.is_symlink():
        if (destination.is_file() and checksum.is_file() and not destination.is_symlink() and not checksum.is_symlink()
                and digest(destination) == expected and checksum.read_text() == f"{expected}  {filename}\n"):
            return destination, expected  # Retry a failed refresh without replacing verified files.
        raise FileExistsError("Refusing to replace a different or incomplete existing ISO/checksum")
    with tempfile.TemporaryDirectory(prefix=".cybexos-publish-", dir=served.parent) as temporary:
        stage = Path(temporary)
        image = stage / filename
        shutil.copyfile(iso, image)
        image.chmod(0o644)
        if digest(image) != expected:
            raise RuntimeError("Staged ISO checksum mismatch; nothing published")
        sums = stage / checksum.name
        sums.write_text(f"{expected}  {filename}\n")
        sums.chmod(0o644)
        for path in (image, sums):
            with path.open("rb") as stream:
                os.fsync(stream.fileno())
        # Hardlinks publish already-complete bytes atomically and fail if a
        # competing process created either destination. Staging is same FS.
        os.link(sums, checksum)
        try:
            os.link(image, destination)
        except BaseException:
            checksum.unlink()
            raise
        descriptor = os.open(served, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    return destination, expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path, help="Verified build artifacts directory containing SHA256SUMS")
    parser.add_argument("--served", type=Path, default=Path("/data/pxe/iso"))
    parser.add_argument("--api-contract", type=Path, help="JSON pointers/values reviewed against the installed iVentoy UI")
    parser.add_argument("--url", default="http://127.0.0.1:26000/iventoy/json")
    parser.add_argument("--execute", action="store_true", help="Explicitly publish and refresh iVentoy; default only checks artifacts")
    args = parser.parse_args()
    entries = checksum_entries(args.artifacts)
    isos = [name for name in entries if name.endswith(".iso")]
    if len(isos) != 1:
        parser.error("artifacts must contain exactly one checksummed ISO")
    name = isos[0]
    if not args.execute:
        print(json.dumps({"action": "publish-and-refresh", "filename": name, "sha256": entries[name], "destination": str(args.served / name), "executed": False}, indent=2))
        return
    contract = json.loads(args.api_contract.read_text()) if args.api_contract else DEFAULT_CONTRACT
    client = IVentoy(args.url, contract)
    subprocess.run(["systemctl", "is-active", "--quiet", "iventoy.service"], check=True)
    client.wait_idle()
    destination, checksum = publish(args.artifacts / name, args.served, name, entries[name])
    try:
        client.refresh(name)
        subprocess.run(["systemctl", "is-active", "--quiet", "iventoy.service"], check=True)
    except BaseException as error:
        raise RuntimeError(f"Published verified ISO retained at {destination}; refresh verification failed: {error}. Inspect status before retrying; no service restart was attempted.") from error
    print(f"Published {destination}\nSHA256 {checksum}\niVentoy refresh/list/PXE/service checks passed.")
