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
                seed = payload / 'usr/share/cybexos/user-seed/tool'
                seed.parent.mkdir(parents=True)
                seed.write_text('independent offline application fixture\n')
                top = work / 'rpmbuild'
                spec = work / 'fixture.spec'
                spec.write_text('''Name: cybexos-desktop
Version: 1.0.0
Release: 1
Summary: Disposable cryptographic integration fixture
License: MIT
BuildArch: x86_64
Requires: cybexos-offline-apps = 0.9.0-1
%global _binary_filedigest_algorithm 8
%description
Fixture only. Never installed or published.
%package -n cybexos-offline-apps
Version: 0.9.0
Release: 1
Summary: Independently versioned offline fixture
%description -n cybexos-offline-apps
Fixture only.
%install
mkdir -p %{buildroot}
cp -a ''' + str(payload) + '''/. %{buildroot}/
%files
/etc/yum.repos.d/cybexos-desktop.repo
/usr/share/cybexos/update-channel.json
/usr/share/cybexos/update-key.asc
%files -n cybexos-offline-apps
/usr/share/cybexos/user-seed
''')
                run(['rpmbuild', '--define', '_topdir ' + str(top), '-bb', str(spec)])
                packages = sorted(top.rglob('*.rpm'))
                self.assertEqual(len(packages), 2)
                output = work / 'signed'
                create_repository(packages, output, key, fingerprint, baseurl, signing_home,
                                  'https://github.com/DigitalPals/CybexOS/releases/download/v1.0.0')
                verify_checksums(output)
                verify_release(output, fingerprint, work)
                manifest = json.loads((output / 'release.json').read_text())
                self.assertEqual({item['name']: item['version'] for item in manifest['packages']},
                                 {'cybexos-desktop': '1.0.0', 'cybexos-offline-apps': '0.9.0'})
                verify_metadata(output, manifest['packages'])
                self.assertTrue(list((output / 'repodata').glob('*-primary.xml.gz')))
                # Rebuilding/signing identical files is allowed; their RPM
                # build timestamps are not the independently versioned payload.
                create_repository(packages, work / 'same-payload', key, fingerprint, baseurl,
                                  signing_home, previous_repository=output)
                seed.write_text('changed application without a version bump\n')
                run(['rpmbuild', '--define', '_topdir ' + str(top), '-bb', str(spec)])
                with self.assertRaisesRegex(ValueError, 'existing NEVRA'):
                    create_repository(packages, work / 'changed-payload', key, fingerprint, baseurl,
                                      signing_home, previous_repository=output)
                self.assertFalse((work / 'changed-payload').exists())
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
