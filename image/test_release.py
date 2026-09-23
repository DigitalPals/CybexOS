"""Release metadata and repository tests; no image/RPM build or publication."""

import configparser
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release_metadata as metadata
import release_repository as repository


FEDORA_KEY = Path("/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-primary")
FEDORA_FINGERPRINT = "36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6"
PROVENANCE = {"source_revision": "3c585cd" + "0" * 33,
              "utc": "2026-09-23T12:34:56+00:00", "source_dirty": False,
              "build_id": "test-source-only"}


class ReleaseMetadataTests(unittest.TestCase):
    def test_urls_cannot_inject_dnf_configuration_or_credentials(self):
        for value in ("http://example.com", "https://user:pass@example.com",
                      "https://example.com\nenabled=0", "https://example.com/?token=secret",
                      "https://example.com/#fragment", "https://example.com/$token"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.repository_url(value)
        self.assertEqual(metadata.repository_url("https://packages.example/fedora/$releasever/$basearch/"),
                         "https://packages.example/fedora/$releasever/$basearch")

    def test_version_release_tracks_source_version_and_build_time(self):
        with tempfile.TemporaryDirectory() as directory:
            version = Path(directory) / "VERSION"
            version.write_text("0.0.0-dev\n")
            first = metadata.rpm_identity(version, PROVENANCE)
            later = metadata.rpm_identity(version, {**PROVENANCE, "utc": "2026-09-24T00:00:00Z"})
            self.assertEqual(first, ("0.0.0~dev", "1.20260923123456.g3c585cd00000"))
            self.assertLess(first[1], later[1])
            rendered = metadata.render_spec("Version: 0\nRelease: 0\n", version, PROVENANCE)
            self.assertIn("Version:        0.0.0~dev", rendered)
            self.assertIn(first[1] + "%{?dist}", rendered)
            version.write_text("1\n%post\nevil")
            with self.assertRaises(ValueError):
                metadata.rpm_identity(version, PROVENANCE)

    def test_no_channel_is_packaged_disabled_without_a_fake_endpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            (source / "build-provenance.json").write_text(json.dumps(PROVENANCE))
            payload = Path(directory) / "payload"
            metadata.install_update_channel(source, payload)
            config = configparser.ConfigParser()
            config.read(payload / "etc/yum.repos.d/cybexos-desktop.repo")
            channel = config["cybexos-desktop"]
            self.assertFalse(channel.getboolean("enabled"))
            self.assertTrue(channel.getboolean("gpgcheck"))
            self.assertTrue(channel.getboolean("repo_gpgcheck"))
            self.assertNotIn("baseurl", channel)
            self.assertEqual(json.loads((payload / "usr/share/cybexos/build.json").read_text()), PROVENANCE)

    @unittest.skipUnless(FEDORA_KEY.is_file() and shutil.which("gpg"), "Fedora public key/GnuPG unavailable")
    def test_real_public_key_is_fingerprint_pinned_and_packaged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "operator.json"
            config.write_text(json.dumps({"baseurl": "https://packages.example/44/x86_64",
                                         "fingerprint": FEDORA_FINGERPRINT, "key_file": str(FEDORA_KEY)}))
            files = metadata.stage_update_channel(config, root / "staged")
            self.assertEqual(set(files), {"image/update-channel.json", "image/update-key.asc"})
            self.assertNotIn("key_file", files["image/update-channel.json"].read_text())
            (root / "staged/build-provenance.json").write_text(json.dumps(PROVENANCE))
            metadata.install_update_channel(root / "staged", root / "payload")
            repo = (root / "payload/etc/yum.repos.d/cybexos-desktop.repo").read_text()
            self.assertIn("enabled=1", repo)
            self.assertIn("gpgkey=file:///usr/share/cybexos/update-key.asc", repo)
            with self.assertRaises(ValueError):
                metadata.public_key(FEDORA_KEY, "A" * 40)

    def test_private_key_material_is_rejected_before_gpg(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(metadata.subprocess, "run") as run:
            path = Path(directory) / "key.asc"
            path.write_text("-----BEGIN PGP PRIVATE KEY BLOCK-----")
            with self.assertRaises(ValueError):
                metadata.public_key(path, FEDORA_FINGERPRINT)
            run.assert_not_called()


class RepositoryTests(unittest.TestCase):
    def test_release_rejects_rpm_with_disabled_or_different_update_channel(self):
        content = metadata.channel_payload("https://packages.example/44", FEDORA_FINGERPRINT, b"reviewed public key")
        query = "8\n" + "".join(f"/{path}\t{hashlib.sha256(data).hexdigest()}\n" for path, data in content.items())
        with patch.object(repository, "run", return_value=subprocess.CompletedProcess([], 0, query)):
            repository.verify_embedded_channel(Path("fixture.rpm"), "https://packages.example/44",
                                              FEDORA_FINGERPRINT, b"reviewed public key")
            with self.assertRaisesRegex(ValueError, "update channel does not match"):
                repository.verify_embedded_channel(Path("fixture.rpm"), "https://different.example/44",
                                                  FEDORA_FINGERPRINT, b"reviewed public key")
        with patch.object(repository, "run", return_value=subprocess.CompletedProcess([], 0, "8\n")):
            with self.assertRaisesRegex(ValueError, "update channel does not match"):
                repository.verify_embedded_channel(Path("fixture.rpm"), "https://packages.example/44",
                                                  FEDORA_FINGERPRINT, b"reviewed public key")

    def test_digest_only_output_cannot_pass_signature_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(repository, "run", return_value=subprocess.CompletedProcess([], 0, "SHA256 digest: OK\n")):
                with self.assertRaisesRegex(ValueError, "No verified OpenPGP signature"):
                    repository.verify_signed_rpm(Path("desktop.rpm"), Path("public.asc"), directory)

    def test_publish_never_replaces_existing_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / "source", Path(directory) / "destination"
            source.mkdir()
            destination.mkdir()
            with self.assertRaises(FileExistsError):
                repository.rename_new_directory(source, destination)
            self.assertTrue(source.is_dir())
            self.assertTrue(destination.is_dir())

    def test_repository_failure_preserves_inputs_and_removes_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / "cybexos-desktop-1.x86_64.rpm"
            original.write_bytes(b"fixture RPM bytes; never executed")
            output = root / "release"
            with (patch.object(repository, "public_key", return_value=b"public key"),
                  patch.object(repository.shutil, "which", return_value="/fixture/tool"),
                  patch.object(repository, "package_identity", return_value={"name": "cybexos-desktop"}),
                  patch.object(repository, "verify_embedded_channel"),
                  patch.object(repository, "run", side_effect=subprocess.CalledProcessError(1, ["rpmsign"]))):
                with self.assertRaises(subprocess.CalledProcessError):
                    repository.create_repository([original], output, root / "public.asc",
                                                 FEDORA_FINGERPRINT, "https://packages.example/44")
            self.assertFalse(output.exists())
            self.assertEqual(original.read_bytes(), b"fixture RPM bytes; never executed")
            self.assertEqual(list(root.iterdir()), [original])


if __name__ == "__main__":
    unittest.main()
