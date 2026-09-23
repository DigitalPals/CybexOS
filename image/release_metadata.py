"""Public desktop release metadata shared by the builder and RPM packager."""

from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlsplit


def fingerprint(value):
    value = str(value).replace(" ", "").upper()
    if not re.fullmatch(r"[0-9A-F]{40}|[0-9A-F]{64}", value):
        raise ValueError("Use the complete OpenPGP signing-key fingerprint")
    return value


def repository_url(value):
    if not isinstance(value, str) or any(char.isspace() for char in value) or "\\" in value:
        raise ValueError("The desktop repository needs one HTTPS base URL")
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment):
        raise ValueError("The desktop repository must use HTTPS without credentials, query, or fragment")
    remainder = value.replace("$releasever", "").replace("$basearch", "")
    if "$" in remainder or any(ord(char) < 32 for char in value):
        raise ValueError("Only $releasever and $basearch repository variables are supported")
    return value.rstrip("/")


def public_key(path, expected):
    """Verify one public key in a disposable GnuPG home and return ASCII armor."""
    expected = fingerprint(expected)
    path = Path(path).resolve(strict=True)
    data = path.read_bytes()
    if len(data) > 1024 * 1024 or b"PRIVATE KEY" in data:
        raise ValueError("The update channel accepts a public key, never private signing material")
    with tempfile.TemporaryDirectory(prefix="cybexos-public-key-") as directory:
        command = ["gpg", "--no-options", "--homedir", directory, "--batch", "--no-autostart"]
        result = subprocess.run(
            [*command, "--with-colons", "--show-keys", str(path)],
            check=True, capture_output=True, text=True,
        )
        primaries = []
        waiting = False
        for line in result.stdout.splitlines():
            fields = line.split(":")
            if fields[0] in ("sec", "ssb"):
                raise ValueError("Private keys cannot be embedded in an image")
            if fields[0] == "pub":
                if fields[1] in ("r", "e", "d"):
                    raise ValueError("The update key is revoked, expired, or disabled")
                waiting = True
            elif fields[0] == "fpr" and waiting:
                primaries.append(fields[9].upper())
                waiting = False
        if primaries != [expected]:
            raise ValueError("The update public key does not match the single expected fingerprint")
        subprocess.run([*command, "--import", str(path)], check=True, capture_output=True)
        return subprocess.run(
            [*command, "--armor", "--export", expected], check=True, capture_output=True,
        ).stdout


def stage_update_channel(config_path, destination):
    """Return explicit archive additions containing only validated public data."""
    config_path = Path(config_path).resolve(strict=True)
    if config_path.stat().st_size > 65536:
        raise ValueError("Update channel configuration is too large")
    config = json.loads(config_path.read_text())
    if not isinstance(config, dict) or set(config) != {"baseurl", "fingerprint", "key_file"}:
        raise ValueError("Update channel requires exactly baseurl, fingerprint, and key_file")
    normalized = {"baseurl": repository_url(config["baseurl"]),
                  "fingerprint": fingerprint(config["fingerprint"])}
    key_path = Path(config["key_file"]).expanduser()
    if not key_path.is_absolute():
        key_path = config_path.parent / key_path
    armor = public_key(key_path, normalized["fingerprint"])
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    settings = destination / "update-channel.json"
    key = destination / "update-key.asc"
    settings.write_text(json.dumps(normalized, sort_keys=True, indent=2) + "\n")
    key.write_bytes(armor)
    settings.chmod(0o644)
    key.chmod(0o644)
    return {"image/update-channel.json": settings, "image/update-key.asc": key}


def rpm_identity(version_file, provenance):
    version = Path(version_file).read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?", version):
        raise ValueError("VERSION must contain major.minor.patch with an optional prerelease")
    version = version.replace("-", "~", 1)
    revision = provenance.get("source_revision", "")
    if not re.fullmatch(r"[0-9a-f]{40,64}", revision):
        raise ValueError("Build provenance needs the full source revision")
    timestamp = datetime.fromisoformat(provenance["utc"].replace("Z", "+00:00"))
    if timestamp.tzinfo is None:
        raise ValueError("Build time must include its timezone")
    release = "1." + timestamp.astimezone(timezone.utc).strftime("%Y%m%d%H%M%S")
    release += ".g" + revision[:12]
    if provenance.get("source_dirty"):
        release += ".dirty"
    return version, release


def render_spec(source_spec, version_file, provenance):
    version, release = rpm_identity(version_file, provenance)
    result, count = re.subn(r"(?m)^Version:.*$", f"Version:        {version}", source_spec)
    if count != 1:
        raise ValueError("Desktop spec must contain exactly one Version field")
    result, count = re.subn(r"(?m)^Release:.*$", f"Release:        {release}%{{?dist}}", result)
    if count != 1:
        raise ValueError("Desktop spec must contain exactly one Release field")
    return result


def channel_payload(baseurl, expected, armor):
    """Canonical enabled-channel bytes, also checked before release signing."""
    url, expected = repository_url(baseurl), fingerprint(expected)
    lines = ["# Managed CybexOS desktop release channel.", "[cybexos-desktop]",
             "name=CybexOS desktop updates", "gpgcheck=1", "repo_gpgcheck=1",
             "skip_if_unavailable=0", "metadata_expire=6h", "enabled=1",
             f"baseurl={url}", "gpgkey=file:///usr/share/cybexos/update-key.asc"]
    status = {"enabled": True, "baseurl": url, "fingerprint": expected}
    return {"etc/yum.repos.d/cybexos-desktop.repo": ("\n".join(lines) + "\n").encode(),
            "usr/share/cybexos/update-channel.json": (json.dumps(status, indent=2) + "\n").encode(),
            "usr/share/cybexos/update-key.asc": armor}


def install_update_channel(source_image_dir, payload_dir):
    """Package a disabled channel by default, or the explicitly pinned channel."""
    source_image_dir, payload_dir = Path(source_image_dir), Path(payload_dir)
    source = source_image_dir / "update-channel.json"
    lines = ["# Managed CybexOS desktop release channel.", "[cybexos-desktop]",
             "name=CybexOS desktop updates", "gpgcheck=1", "repo_gpgcheck=1",
             "skip_if_unavailable=0", "metadata_expire=6h"]
    vendor = payload_dir / "usr/share/cybexos"
    vendor.mkdir(parents=True, exist_ok=True)
    if source.exists():
        config = json.loads(source.read_text())
        if set(config) != {"baseurl", "fingerprint"}:
            raise ValueError("Invalid normalized desktop update channel")
        url = repository_url(config["baseurl"])
        expected = fingerprint(config["fingerprint"])
        key = public_key(source_image_dir / "update-key.asc", expected)
        for relative, content in channel_payload(url, expected, key).items():
            path = payload_dir / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            path.chmod(0o644)
    else:
        lines += ["# Configure --update-channel when building a release.", "enabled=0"]
        status = {"enabled": False}
        repo = payload_dir / "etc/yum.repos.d/cybexos-desktop.repo"
        repo.parent.mkdir(parents=True, exist_ok=True)
        repo.write_text("\n".join(lines) + "\n")
        repo.chmod(0o644)
        (vendor / "update-channel.json").write_text(json.dumps(status, indent=2) + "\n")
    provenance = source_image_dir / "build-provenance.json"
    if not provenance.is_file():
        raise ValueError("Build provenance is missing; build through image/build")
    build = json.loads(provenance.read_text())
    (vendor / "build.json").write_text(json.dumps(build, indent=2, sort_keys=True) + "\n")
    return build
