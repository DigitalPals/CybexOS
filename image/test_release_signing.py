"""Exercise the actual RPM/GnuPG/createrepo toolchain with a disposable key."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from github_release import verify_checksums, verify_metadata, verify_release
from release_metadata import channel_payload, public_key
from release_repository import create_repository


@unittest.skipUnless(all(shutil.which(tool) for tool in
                         ('rpmbuild', 'rpmsign', 'rpmkeys', 'createrepo_c', 'gpg', 'gpgconf')),
                     'RPM build/signing and repository tools unavailable')
class RealReleaseSigning(unittest.TestCase):
    def test_signing_subkey_and_repository_are_independently_verifiable(self):
        def run(args):
            result = subprocess.run(args, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

        with tempfile.TemporaryDirectory(prefix='cybexos-real-signing-') as temporary:
            work = Path(temporary)
            home = work / 'keyring'
            home.mkdir(mode=0o700)
            signing_home = work / 'signing-subkey-only'
            signing_home.mkdir(mode=0o700)
            try:
                gpg = ['gpg', '--homedir', str(home), '--batch', '--pinentry-mode',
                       'loopback', '--passphrase', '']
                run([*gpg, '--quick-generate-key', 'CybexOS disposable signing fixture',
                     'ed25519', 'cert', '1d'])
                listing = run([*gpg, '--with-colons', '--list-keys'])
                fingerprint = next(line.split(':')[9] for line in listing.splitlines()
                                   if line.startswith('fpr:'))
                run([*gpg, '--quick-add-key', fingerprint, 'ed25519', 'sign', '1d'])
                key = work / 'fixture.asc'
                key.write_text(run([*gpg, '--armor', '--export', fingerprint]))
                armor = public_key(key, fingerprint)
                # CI receives only the signing subkey, with a primary-key
                # stub. Exercise that exact custody split in a fresh keyring.
                subkey = run([*gpg, '--armor', '--export-secret-subkeys', fingerprint])
                subprocess.run(['gpg', '--homedir', str(signing_home), '--batch', '--import'],
                               input=subkey, text=True, capture_output=True, check=True)
                baseurl = 'https://fixtures.invalid/CybexOS/44/x86_64'
                payload = work / 'payload'
                for relative, content in channel_payload(baseurl, fingerprint, armor).items():
                    path = payload / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(content)
                top = work / 'rpmbuild'
                spec = work / 'fixture.spec'
                spec.write_text('''Name: cybexos-desktop
Version: 1.0.0
Release: 1
Summary: Disposable cryptographic integration fixture
License: MIT
BuildArch: x86_64
%global _binary_filedigest_algorithm 8
%description
Fixture only. Never installed or published.
%install
mkdir -p %{buildroot}
cp -a ''' + str(payload) + '''/. %{buildroot}/
%files
/etc/yum.repos.d/cybexos-desktop.repo
/usr/share/cybexos/update-channel.json
/usr/share/cybexos/update-key.asc
''')
                run(['rpmbuild', '--define', '_topdir ' + str(top), '-bb', str(spec)])
                package = next(top.rglob('*.rpm'))
                output = work / 'signed'
                create_repository([package], output, key, fingerprint, baseurl, signing_home,
                                  'https://github.com/DigitalPals/CybexOS/releases/download/v1.0.0')
                verify_checksums(output)
                verify_release(output, fingerprint, work)
                manifest = json.loads((output / 'release.json').read_text())
                verify_metadata(output, manifest['packages'])
                self.assertTrue(list((output / 'repodata').glob('*-primary.xml.gz')))
                # Cryptographic verification must reject modified signed data,
                # even if the unsigned SHA256SUMS inventory is rebuilt.
                with (output / 'release.json').open('a') as stream:
                    stream.write(' ')
                verify_home = work / 'tamper-check'
                verify_home.mkdir()
                with self.assertRaises(subprocess.CalledProcessError):
                    verify_release(output, fingerprint, verify_home)
            finally:
                for keyring in (home, signing_home):
                    subprocess.run(['gpgconf', '--homedir', str(keyring), '--kill', 'all'],
                                   check=False, capture_output=True)


if __name__ == '__main__':
    unittest.main()
