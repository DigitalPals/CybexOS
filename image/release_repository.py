"""Create a signed desktop RPM repository in a new local directory.

Hosting is a separate release action. Original RPMs and the user's RPM keyring
are never changed. Signing keys remain in the operator's GnuPG keyring.
"""

import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request

from release_metadata import channel_payload, fingerprint, public_key, repository_url


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def sha256(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def rename_new_directory(source, destination):
    """Atomically publish on Linux without replacing even an empty directory."""
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = libc.renameat2
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    if renameat2(-100, os.fsencode(source), -100, os.fsencode(destination), 1):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def package_identity(path):
    result = run(["rpm", "-qp", "--qf", "%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}",
                  str(path)], capture_output=True, text=True)
    fields = result.stdout.split("\t")
    if len(fields) != 5 or fields[0] not in ("cybexos-desktop", "cybexos-offline-apps") or fields[4] != "x86_64":
        raise ValueError(f"Expected an x86_64 CybexOS desktop or offline-apps RPM: {path.name}")
    if any(not re.fullmatch(r"[A-Za-z0-9.~^+_-]+", field) for field in fields):
        raise ValueError("RPM identity contains invalid characters")
    return dict(zip(("name", "epoch", "version", "release", "arch"), fields))


def package_payload_identity(path):
    """Ignore build timestamps/signatures, but bind file contents and ownership."""
    result = run(['rpm', '-qp', '--qf',
                  '%{FILEDIGESTALGO}\n[%{FILENAMES}\t%{FILEDIGESTS}\t%{FILELINKTOS}\t%{FILEMODES}\t%{FILEUSERNAME}\t%{FILEGROUPNAME}\t%{FILEFLAGS}\t%{FILECAPS}\n]',
                  str(path)], capture_output=True, text=True)
    return hashlib.sha256('\n'.join(sorted(result.stdout.splitlines())).encode()).hexdigest()


def previous_packages(location, key, expected, baseurl, work):
    """Authenticate the previous published manifest before checking immutability."""
    if location is None:
        return []
    directory = Path(work) / 'previous-release'
    directory.mkdir()
    for name in ('release.json', 'release.json.asc'):
        if str(location).startswith('https://'):
            try:
                with urllib.request.urlopen(repository_url(str(location)) + '/' + name, timeout=30) as response:
                    data = response.read(2 * 1024 * 1024 + 1)
            except urllib.error.HTTPError as error:
                # No repository exists before the first public release.
                if error.code == 404 and name == 'release.json':
                    return []
                raise
        else:
            data = (Path(location) / name).read_bytes()
        if len(data) > 2 * 1024 * 1024:
            raise ValueError('Previous release manifest exceeds the size limit')
        (directory / name).write_bytes(data)
    home = directory / 'keyring'
    home.mkdir(mode=0o700)
    command = ['gpg', '--no-options', '--homedir', str(home), '--batch', '--no-autostart']
    run([*command, '--import', str(key)], capture_output=True)
    run([*command, '--verify', str(directory / 'release.json.asc'), str(directory / 'release.json')],
        capture_output=True)
    manifest = json.loads((directory / 'release.json').read_text())
    if manifest.get('fingerprint') != expected or manifest.get('baseurl') != baseurl or manifest.get('format') != 1:
        raise ValueError('Previous release does not match the reviewed channel')
    return manifest['packages']


def verify_offline_identity(identity, payload_sha256, previous):
    if identity['name'] != 'cybexos-offline-apps':
        return
    for item in previous:
        if all(item.get(key) == value for key, value in identity.items()):
            if item.get('payload_sha256') != payload_sha256:
                raise ValueError('Offline application payload changed under an existing NEVRA; advance its independent version')


def verify_signed_rpm(path, key, temporary):
    database = Path(temporary) / "rpmdb"
    database.mkdir(exist_ok=True)
    command = ["rpmkeys", "--dbpath", str(database), "--define", "_keyring rpmdb",
               "--define", "_pkgverify_level all", "--define", "_pkgverify_flags 0x0"]
    run([*command, "--import", str(key)], capture_output=True)
    result = run([*command, "--checksig", "--verbose", str(path)], capture_output=True, text=True,
                 env={**os.environ, "LC_ALL": "C"})
    # Do not mistake digest-only success for a verified release signature.
    if not re.search(r"(?im)^\s*.*\b(?:signature|openpgp)\b.*:\s*OK\s*$", result.stdout):
        raise ValueError(f"No verified OpenPGP signature on {path.name}")


def verify_embedded_channel(path, baseurl, key_id, armor):
    # RPM verifies payload/header integrity during signing and the subsequent
    # independent signature check. Inspect its file digests without extracting
    # or installing a multi-gigabyte application payload.
    result = run(["rpm", "-qp", "--qf", "%{FILEDIGESTALGO}\n[%{FILENAMES}\t%{FILEDIGESTS}\n]",
                  str(path)], capture_output=True, text=True)
    lines = result.stdout.splitlines()
    if not lines or lines[0] != "8":
        raise ValueError("Release RPMs must use SHA-256 file digests")
    digests = dict(line.split("\t", 1) for line in lines[1:] if "\t" in line)
    for relative, content in channel_payload(baseurl, key_id, armor).items():
        if digests.get("/" + relative) != hashlib.sha256(content).hexdigest():
            raise ValueError("RPM update channel does not match this release. Build it with the same --update-channel first.")


def create_repository(packages, output, key_file, key_id, baseurl, gnupghome=None,
                      packages_baseurl=None, previous_repository=None):
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Repository output must be a new directory; existing releases are preserved")
    expected = fingerprint(key_id)
    url = repository_url(baseurl)
    if packages_baseurl:
        packages_baseurl = repository_url(packages_baseurl)
        if '$' in packages_baseurl:
            raise ValueError('RPM download URLs must identify an immutable release')
    armor = public_key(key_file, expected)
    packages = [Path(path).resolve(strict=True) for path in packages]
    if not packages or len({path.name for path in packages}) != len(packages):
        raise ValueError("Supply RPMs with unique filenames")
    for path in packages:
        if path.suffix != ".rpm" or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+~^-]*\.rpm", path.name):
            raise ValueError("RPM filenames must be ASCII without spaces")
    for executable in ("rpm", "rpmkeys", "rpmsign", "createrepo_c", "gpg"):
        if not shutil.which(executable):
            raise ValueError(f"Missing {executable}; install rpm-sign, createrepo_c, and gnupg2 on Fedora")
    identities = [package_identity(path) for path in packages]
    names = [item['name'] for item in identities]
    if names.count('cybexos-desktop') != 1 or len(set(names)) != len(names):
        raise ValueError('Supply exactly one desktop RPM and at most one offline applications RPM')
    if len({json.dumps(item, sort_keys=True) for item in identities}) != len(identities):
        raise ValueError("Duplicate RPM identities cannot be published in one release")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".cybexos-repository-", dir=output.parent) as directory:
        work = Path(directory)
        stage = work / "repository"
        stage.mkdir()
        target_packages = stage / "Packages"
        target_packages.mkdir()
        key = stage / "CYBEXOS-desktop.asc"
        key.write_bytes(armor)
        previous = previous_packages(previous_repository, key, expected, url, work)
        command = ["rpmsign", "--addsign", "--key-id", expected,
                   "--define", "_openpgp_sign gpg"]
        signing = ["gpg", "--batch", "--local-user", expected]
        signing_environment = dict(os.environ)
        if gnupghome:
            home = Path(gnupghome).resolve(strict=True)
            signing_environment["GNUPGHOME"] = str(home)
            command += ["--undefine", "_gpg_path"]
            signing += ["--homedir", str(home)]
        records = []
        for original, identity in zip(packages, identities):
            payload_sha256 = package_payload_identity(original)
            verify_offline_identity(identity, payload_sha256, previous)
            destination = target_packages / original.name
            shutil.copyfile(original, destination)
            if identity["name"] == "cybexos-desktop":
                verify_embedded_channel(destination, url, expected, armor)
            run([*command, str(destination)], env=signing_environment)
            verify_signed_rpm(destination, key, work)
            record = {**identity, "file": str(destination.relative_to(stage)),
                      "sha256": sha256(destination), "unsigned_input_sha256": sha256(original),
                      "payload_sha256": payload_sha256}
            if packages_baseurl:
                record['url'] = packages_baseurl + '/' + destination.name
            records.append(record)
        if packages_baseurl:
            # GitHub Pages serves only metadata; large RPMs are release assets.
            # Scan Packages itself so relative locations are bare asset names.
            run(["createrepo_c", "--checksum", "sha256", "--general-compress-type", "gz", "--outputdir", str(stage),
                 "--baseurl", packages_baseurl + '/', str(target_packages)])
        else:
            run(["createrepo_c", "--checksum", "sha256", "--general-compress-type", "gz", str(stage)])
        metadata = stage / "repodata/repomd.xml"
        run([*signing, "--armor", "--detach-sign", "--output", str(metadata) + ".asc", str(metadata)])
        manifest = stage / "release.json"
        manifest.write_text(json.dumps({
            "format": 1, "created": datetime.now(timezone.utc).isoformat(),
            "fingerprint": expected, "baseurl": url, "packages": records,
        }, indent=2, sort_keys=True) + "\n")
        run([*signing, "--armor", "--detach-sign", "--output", str(manifest) + ".asc", str(manifest)])
        # Verify detached signatures in an independent keyring containing only
        # the reviewed public key; signing success alone is insufficient.
        verifier = work / "verify-gpg"
        verifier.mkdir(mode=0o700)
        verify = ["gpg", "--no-options", "--homedir", str(verifier), "--batch", "--no-autostart"]
        run([*verify, "--import", str(key)], capture_output=True)
        for signed in (metadata, manifest):
            run([*verify, "--verify", str(signed) + ".asc", str(signed)], capture_output=True)
        (stage / "update-channel.json").write_text(json.dumps({
            "baseurl": url, "fingerprint": expected, "key_file": key.name,
        }, indent=2) + "\n")
        files = sorted(path for path in stage.rglob("*") if path.is_file())
        (stage / "SHA256SUMS").write_text("".join(
            f"{sha256(path)}  {path.relative_to(stage)}\n" for path in files
        ))
        for path in [stage, *stage.rglob("*")]:
            path.chmod(0o755 if path.is_dir() else 0o644)
        # Renaming a completed sibling directory never exposes partial RPMs or
        # metadata and refuses replacing nonempty previous release directories.
        if output.exists() or output.is_symlink():
            raise ValueError("Repository output appeared while signing; refusing to replace it")
        rename_new_directory(stage, output)
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--key", required=True, help="Complete fingerprint of an existing signing key")
    parser.add_argument("--baseurl", required=True, help="HTTPS URL where this repository will be hosted")
    parser.add_argument("--gnupghome", type=Path)
    parser.add_argument("--packages-baseurl", help="HTTPS release-asset directory; keep large RPMs off the metadata host")
    parser.add_argument("--previous-repository", help="Previous signed repository directory or HTTPS URL; check offline RPM immutability")
    args = parser.parse_args(argv)
    try:
        destination = create_repository(args.packages, args.output, args.public_key, args.key,
                                        args.baseurl, args.gnupghome, args.packages_baseurl, args.previous_repository)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"release-repository: {error}\n")
    print(f"Signed repository ready for explicit hosting: {destination}")
    print(f"Use its update-channel.json with image/build --update-channel {destination / 'update-channel.json'}")
    return 0
