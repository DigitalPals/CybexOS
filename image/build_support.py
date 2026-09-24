"""Host-side image tooling. Importing this module never builds or boots an image."""
from contextlib import contextmanager
import ctypes
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import uuid


SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+~^-]*\Z")


def builder_cloud_config(public_key):
    """Configure the disposable builder without an init-local hostname race."""
    return {
        "users": [{"name": "builder", "groups": ["wheel"], "shell": "/bin/bash",
                   "sudo": "ALL=(ALL) NOPASSWD:ALL", "ssh_authorized_keys": [public_key]}],
        "ssh_pwauth": False,
        "disable_root": True,
        # Fedora's hostnamectl requires services unavailable in init-local.
        # Cloud-init records that early attempt as a degraded boot even when
        # its later retry succeeds. Set it once during the final stage.
        "preserve_hostname": True,
        "runcmd": [["hostnamectl", "set-hostname", "image-builder"]],
    }


def wait_for_builder_initialization(ssh, output):
    """Keep cloud-init failures strict and preserve their diagnosis on cleanup."""
    output = Path(output)
    result = subprocess.run([*ssh, "cloud-init status --wait --format=json"],
                            capture_output=True, text=True, timeout=300, check=False)
    status = output / "builder-cloud-init-status.log"
    status.write_text(result.stdout + result.stderr)
    if result.returncode:
        # Status 2 means degraded, not successful. Do not waive arbitrary
        # warnings; keep the useful guest evidence before deleting its disk.
        with (output / "builder-cloud-init.log").open("w") as stream:
            try:
                subprocess.run([*ssh, "sudo -n tail -n 400 /var/log/cloud-init.log"],
                               stdout=stream, stderr=subprocess.STDOUT, timeout=30,
                               check=False)
            except (OSError, subprocess.TimeoutExpired) as error:
                stream.write(f"Could not collect guest cloud-init log: {error}\n")
        raise RuntimeError(f"Builder cloud-init exited {result.returncode}; see {status.name} and builder-cloud-init.log")
    subprocess.run([*ssh, 'test "$(hostname)" = image-builder && sudo -n true && mkdir -p /home/builder/source'],
                   check=True, timeout=30)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_sidecar(path):
    """Verify one exact filename against its adjacent checksum file."""
    path = Path(path)
    sidecar = path.with_name(path.name + ".sha256")
    if sidecar.is_symlink() or not sidecar.is_file():
        raise ValueError("Artifact needs its adjacent regular .sha256 file")
    match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *]" + re.escape(path.name) + r"\n?", sidecar.read_text())
    if not match or digest(path) != match.group(1).lower():
        raise ValueError("Artifact checksum does not match its adjacent .sha256 file")
    return match.group(1).lower()


def build_id():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]


def atomic_json(path, value):
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".json-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def checksum_entries(directory):
    """Validate a flat artifact set. Reject traversal, duplicates and symlinks."""
    directory = Path(directory)
    entries = {}
    manifest = directory / "SHA256SUMS"
    if manifest.is_symlink() or not manifest.is_file():
        raise ValueError("SHA256SUMS must be a regular file, never a symlink")
    for line in manifest.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](?:\./)?([A-Za-z0-9][A-Za-z0-9._+~^-]*)", line)
        if not match:
            raise ValueError("Invalid SHA256SUMS entry")
        checksum, name = match.groups()
        path = directory / name
        if name in entries or path.is_symlink() or not path.is_file():
            raise ValueError(f"Unsafe or duplicate artifact: {name}")
        if digest(path) != checksum.lower():
            raise ValueError(f"Artifact checksum mismatch: {name}")
        entries[name] = checksum.lower()
    if not entries:
        raise ValueError("Empty artifact checksum manifest")
    files = {path.name for path in directory.iterdir() if path.name != "SHA256SUMS"}
    if files != set(entries):
        raise ValueError("Artifact directory contains unchecked files")
    return entries


def rename_new_directory(source, destination):
    """Linux atomic publication that refuses replacing even an empty directory."""
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = libc.renameat2
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    if renameat2(-100, os.fsencode(source), -100, os.fsencode(destination), 1):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def deliver_artifacts(staging, destination):
    """Verify all bytes before publishing an entire directory on one filesystem."""
    staging, destination = Path(staging), Path(destination)
    entries = checksum_entries(staging)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"Refusing to replace artifacts: {destination}")
    for path in staging.iterdir():
        path.chmod(0o644)
        with path.open("rb") as stream:
            os.fsync(stream.fileno())
    staging.chmod(0o755)
    # Linux RENAME_NOREPLACE also protects against a concurrent same-user
    # publisher creating an empty target after the check above.
    rename_new_directory(staging, destination)
    descriptor = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return entries


def validate_qemu_path(path):
    if any(character == "," or ord(character) < 32 for character in str(path)):
        raise ValueError("QEMU file paths cannot contain commas or control characters")
    return Path(path)


def existing_parent(path):
    path = Path(path).resolve()
    while not path.exists():
        path = path.parent
    return path


def preflight(output, cache, memory, cpus, minimum_free_gib=180):
    missing = [name for name in ("qemu-img", "qemu-system-x86_64", "ssh", "ssh-keygen", "scp") if not shutil.which(name)]
    seed_tool = next((name for name in ("cloud-localds", "xorriso", "genisoimage", "mkisofs") if shutil.which(name)), None)
    if seed_tool is None:
        missing.append("cloud-localds or xorriso")
    errors = []
    if missing:
        errors.append("Missing: " + ", ".join(missing) + ". Fedora: sudo dnf install qemu-kvm qemu-img xorriso openssh-clients python3-pyyaml edk2-ovmf. Debian: sudo apt install qemu-system-x86 qemu-utils cloud-image-utils openssh-client python3-yaml ovmf.")
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        errors.append("Read/write access to /dev/kvm is required (check the kvm group).")
    if memory < 4096 or cpus < 1:
        errors.append("Specify at least 4096 MiB RAM and one CPU; full builds normally need 24576 MiB.")
    available = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        available[key] = int(value.split()[0])
    if memory * 1024 > available.get("MemAvailable", 0):
        errors.append(f"Requested {memory} MiB RAM exceeds currently available {available.get('MemAvailable', 0) // 1024} MiB; close applications or reduce --memory.")
    if cpus > (os.cpu_count() or 1):
        errors.append(f"Requested {cpus} CPUs exceeds {os.cpu_count() or 1} host CPUs.")
    # The sparse builder resides in cache. Its peak estimate already includes
    # artifacts; reserve additional delivery space when output is another disk.
    parents = {existing_parent(cache): minimum_free_gib}
    output_parent = existing_parent(output)
    if output_parent.stat().st_dev != existing_parent(cache).stat().st_dev:
        parents[output_parent] = 24
    for parent, required in parents.items():
        free = shutil.disk_usage(parent).free / 2**30
        if free < required:
            errors.append(f"{parent}: {free:.1f} GiB free; require {required} GiB for build staging/delivery.")
    if errors:
        raise RuntimeError("\n".join(errors))
    return {"seed_tool": seed_tool, "memory_mib": memory, "cpus": cpus,
            "free_gib": {str(path): round(shutil.disk_usage(path).free / 2**30, 1) for path in parents}}


def create_seed(work, seed_tool):
    work = Path(work)
    if seed_tool == "cloud-localds":
        command = [seed_tool, str(work / "seed.iso"), str(work / "user-data"), str(work / "meta-data")]
    else:
        command = ([seed_tool, "-as", "mkisofs"] if seed_tool == "xorriso" else [seed_tool])
        command += ["-quiet", "-output", str(work / "seed.iso"), "-volid", "cidata", "-joliet", "-rock",
                    str(work / "user-data"), str(work / "meta-data")]
    subprocess.run(command, check=True)


def source_provenance(root, archive):
    def git(*args):
        result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=True)
        return result.stdout.strip()
    return {"revision": git("rev-parse", "HEAD"), "changes": git("status", "--porcelain=v1").splitlines(),
            "source_archive_sha256": digest(archive),
            "configuration_sha256": digest(root / "inventory/group_vars/all.yml")}


@contextmanager
def phase(name, records):
    started = time.monotonic()
    record = {"phase": name, "started_utc": datetime.now(timezone.utc).isoformat(), "status": "running"}
    records.append(record)
    print(f"\n[image] {name}", flush=True)
    try:
        yield
    except BaseException:
        record["status"] = "failed"
        print(f"[image] FAILED: {name}", flush=True)
        raise
    else:
        record["status"] = "complete"
    finally:
        record["seconds"] = round(time.monotonic() - started, 2)
        print(f"[image] {name}: {record['status']} ({record['seconds']:.1f}s)", flush=True)


def select_firmware(directory=Path("/usr/share/qemu/firmware"), fallback_root=Path("/usr/share")):
    """Use QEMU's machine-readable descriptor, preferring non-Secure-Boot UEFI."""
    for path in sorted(Path(directory).glob("*.json")):
        data = json.loads(path.read_text())
        if "uefi" not in data.get("interface-types", []) or "secure-boot" in data.get("features", []):
            continue
        if not any(target.get("architecture") == "x86_64" and any(fnmatch.fnmatch("pc-q35-9.0", machine) for machine in target.get("machines", [])) for target in data.get("targets", [])):
            continue
        mapping = data.get("mapping", {})
        if mapping.get("device") != "flash":
            continue
        code, variables = mapping.get("executable", {}), mapping.get("nvram-template", {})
        if all(item.get("format") in ("raw", "qcow2") and Path(item.get("filename", "")).is_file() for item in (code, variables)):
            return {"code": code, "variables": variables, "descriptor": str(path)}
    for folder, code, variables in (
        ("OVMF", "OVMF_CODE_4M.fd", "OVMF_VARS_4M.fd"),
        ("OVMF", "OVMF_CODE.fd", "OVMF_VARS.fd"),
        ("edk2/ovmf", "OVMF_CODE.fd", "OVMF_VARS.fd"),
        ("edk2/x64", "OVMF_CODE.4m.fd", "OVMF_VARS.4m.fd"),
    ):
        paths = [Path(fallback_root) / folder / name for name in (code, variables)]
        if all(path.is_file() for path in paths):
            return {"code": {"filename": str(paths[0]), "format": "raw"},
                    "variables": {"filename": str(paths[1]), "format": "raw"}, "descriptor": None}
    raise RuntimeError("No non-Secure-Boot x86_64 UEFI firmware found; install edk2-ovmf (Fedora) or ovmf (Debian).")


def prepare_firmware(work, selection=None):
    selected = selection or select_firmware()
    code, variables = selected["code"], selected["variables"]
    target = Path(work) / ("OVMF_VARS.qcow2" if variables["format"] == "qcow2" else "OVMF_VARS.fd")
    if not target.exists():
        shutil.copyfile(variables["filename"], target)
    return ["-drive", f"if=pflash,format={code['format']},readonly=on,file={code['filename']}",
            "-drive", f"if=pflash,format={variables['format']},file={target}"]
